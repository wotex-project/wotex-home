defmodule Woh.Tool.NativeExternalBuilderLive do
  @moduledoc false

  alias Woh.Tool.Command
  alias WotexHome.{Authority, Durable.Store}

  alias WotexHome.Profiles.{
    AuthoringObject,
    Custody,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ReaderSelection
  }

  @owner __MODULE__.Store

  def run(executable, parent) do
    for family <- ~w(temperature research), do: owner(executable, parent, family)
    :ok
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))
  defp stop(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid))

  defp revision(store) do
    {:ok, value} = Store.revision(store)
    value
  end

  defp owner(executable, parent, family) do
    root = Path.join(parent, family)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    custody_root = Path.join(root, "objects")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    source = fixture("external-source-selections")[family]["inputs"]
    r = source["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, selection} = ExternalSourceSelection.new(source["source"], reader, source["channels"])
    {:ok, custody} = Custody.start_link(root: custody_root, store_owner: @owner)
    {:ok, sources} = ExternalSourceOwner.start_link(publisher: self())
    {:ok, _} = ExternalSourceOwner.publish(sources, selection)

    {:ok, store} =
      Store.start_link(
        path: Path.join(root, "home.sqlite"),
        name: @owner,
        profile_custody: custody,
        external_reader: reader,
        external_source_owner: sources
      )

    try do
      authority = Authority.new(store: store, profile_custody: custody)

      {:ok, credential, _} =
        Store.provision_principal(
          store,
          "operator:builder",
          ~w(profile:manage enroll:review host:maintain),
          []
        )

      objects = imports(store, credential, family)

      c = %{
        store: store,
        authority: authority,
        credential: credential,
        executable: executable,
        objects: objects,
        custody: custody,
        sources: sources
      }

      {inspection_input, inspection_receipt} = first_inspection(c)

      {:ok, _} =
        Store.begin_maintenance(store, credential, 1, "maintenance:builder", revision(store))

      {approve_input, approved} = approve(c, inspection_receipt)
      {select_input, selected} = select(c, inspection_receipt, approved)
      stop(sources)
      :sys.replace_state(store, &%{&1 | external_reader: nil, profile_custody: nil})
      {target_revoke_input, target_revoked} = revoke_target(c, selected)
      {trust_revoke_input, trust_revoked} = revoke_trust(c, approved)
      before = revision(store)

      for {kind, input, receipt} <- [
            {:inspection, inspection_input, inspection_receipt},
            {:trust, approve_input, approved},
            {:target, select_input, selected},
            {:target, target_revoke_input, target_revoked},
            {:trust, trust_revoke_input, trust_revoked}
          ] do
        {:ok, ^receipt} =
          apply(Authority, :"external_#{kind}_status", [
            authority,
            credential,
            1,
            input["operation_id"]
          ])
      end

      ^before = revision(store)
      true = :sys.get_state(custody).leases == %{}
      {:ok, %{dispatch_enabled: false}} = Store.health(store)
    after
      Enum.each([store, sources, custody], &stop/1)
    end
  end

  defp imports(store, credential, family) do
    data = fixture(family)

    docs =
      [{"envelope", data["envelope"]}, {"profile", data["profile"]}] ++
        Enum.map(data["definitions"], &{"definition", &1})

    handles =
      Enum.with_index(docs)
      |> Enum.map(fn {{kind, value}, index} ->
        {:ok, bytes} = Wotex.JSON.encode(value)
        {:ok, object} = AuthoringObject.new(kind, bytes)
        {:ok, summary} = AuthoringObject.summary(object)

        {:ok, receipt} =
          Store.import_authoring_object(
            store,
            credential,
            %{
              "authority_epoch" => 1,
              "operation_id" => "import:#{index}",
              "expected_revision" => revision(store),
              "object" => summary
            },
            bytes
          )

        %{
          "object_digest" => summary["object_digest"],
          "first_revision" => receipt["first_revision"]
        }
      end)

    [envelope, profile | definitions] = handles

    %{
      "envelope_ref" => envelope,
      "profile" => %{"reference" => data["envelope"]["profile"], "object_ref" => profile},
      "definitions" =>
        Enum.zip_with(
          data["envelope"]["definitions"],
          definitions,
          &%{"reference" => &1, "object_ref" => &2}
        )
    }
  end

  defp base(c, operation) do
    {:ok, context} = Authority.external_profile_context(c.authority, c.credential)
    {:ok, catalogue} = Authority.external_profile_catalogue(c.authority, c.credential)

    {%{
       "context" => context,
       "catalogue" => catalogue,
       "operation" => operation,
       "objects" => c.objects
     },
     %{
       "authority_epoch" => context["authority_epoch"],
       "operation_id" => operation,
       "expected_revision" => context["store_revision"]
     }}
  end

  defp build(c, method, kind, inputs, expected) do
    before = revision(c.store)
    leases = :sys.get_state(c.custody).leases

    case Command.run_diagnostic(
           c.executable,
           ["--build"],
           262_144,
           10_000,
           JSON.encode!(%{"method" => method, "inputs" => inputs}) <> "\n"
         ) do
      {:ok, output} ->
        result = JSON.decode!(output)
        true = result["input"] == expected

        codec =
          case kind do
            :inspection -> WotexHome.Profiles.ExternalInspection
            :trust -> WotexHome.Profiles.ExternalTrust
            :target -> WotexHome.Profiles.ExternalTarget
          end

        {:ok, document} = codec.encode(expected)
        true = result["document"] == document
        true = result["sha256"] == Base.encode16(:crypto.hash(:sha256, document), case: :lower)
        ^before = revision(c.store)
        ^leases = :sys.get_state(c.custody).leases
        result["input"]

      {:error, reason} ->
        Mix.raise("native #{method} builder failed: #{reason}")
    end
  end

  defp first_inspection(c) do
    {inputs, common} = base(c, "inspection:builder")

    expected =
      Map.put(
        common,
        "inspection",
        Map.put(c.objects, "reader_basis_sha256", inputs["context"]["reader"]["basis_sha256"])
      )

    input = build(c, "inspection", :inspection, inputs, expected)
    {:ok, receipt} = Authority.inspect_external_profile(c.authority, c.credential, input)
    {input, receipt}
  end

  defp approve(c, inspection) do
    {inputs, common} = base(c, "approve:builder")

    reference =
      Map.take(inspection, ~w(authority_epoch operation_id revision input_sha256 result_sha256))

    {:ok, artifact} = Authority.external_inspection_artifact(c.authority, c.credential, reference)

    expected =
      Map.merge(common, %{
        "action" => "approve",
        "artifact_digest" => artifact["artifact_digest"],
        "expected_trust_revision" => 0,
        "expected_policy_generation" => inputs["context"]["policy_generation"],
        "inspection_ref" => reference,
        "acknowledgement" => "operator_digest_approval"
      })

    inputs = Map.merge(inputs, %{"inspection" => inspection, "artifact" => artifact})
    input = build(c, "approve", :trust, inputs, expected)
    {:ok, receipt} = Authority.change_external_trust(c.authority, c.credential, input)
    {input, receipt}
  end

  defp select(c, inspection, approved) do
    {inputs, common} = base(c, "select:builder")

    reference =
      Map.take(inspection, ~w(authority_epoch operation_id revision input_sha256 result_sha256))

    {:ok, artifact} = Authority.external_inspection_artifact(c.authority, c.credential, reference)
    {:ok, target} = Authority.external_target_basis(c.authority, c.credential, "sensor:builder")
    {:ok, sources} = Authority.external_source_catalogue(c.authority, c.credential)
    [source] = sources["sources"]

    expected =
      Map.merge(common, %{
        "action" => "select",
        "target_id" => "sensor:builder",
        "artifact_digest" => artifact["artifact_digest"],
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => inputs["context"]["policy_generation"],
        "expected_selection_revision" => 0,
        "expected_resource_revision" => 0,
        "source_ref" => source["source_ref"],
        "source_owner_epoch" => sources["owner_epoch"],
        "source_selection_sha256" => source["source_selection_sha256"],
        "objects" => c.objects,
        "acknowledgement" => "operator_external_selection"
      })

    inputs =
      Map.merge(inputs, %{
        "target" => target,
        "sources" => sources,
        "source" => source["source_ref"],
        "artifact" => artifact
      })

    input = build(c, "select", :target, inputs, expected)
    {:ok, receipt} = Authority.change_external_target(c.authority, c.credential, input)
    {input, receipt}
  end

  defp revoke_target(c, selected) do
    {inputs, common} = base(c, "revoke-target:builder")
    {:ok, target} = Authority.external_target_basis(c.authority, c.credential, "sensor:builder")

    expected =
      Map.merge(common, %{
        "action" => "revoke",
        "target_id" => target["target_id"],
        "artifact_digest" => target["artifact_digest"],
        "expected_trust_revision" => target["trust_revision"],
        "expected_policy_generation" => inputs["context"]["policy_generation"],
        "expected_selection_revision" => selected["revision"],
        "expected_resource_revision" => selected["resource_revision"],
        "source_ref" => nil,
        "source_owner_epoch" => nil,
        "source_selection_sha256" => nil,
        "objects" => nil,
        "acknowledgement" => nil
      })

    input = build(c, "revokeTarget", :target, Map.put(inputs, "target", target), expected)
    {:ok, receipt} = Authority.change_external_target(c.authority, c.credential, input)
    {input, receipt}
  end

  defp revoke_trust(c, approved) do
    {inputs, common} = base(c, "revoke-trust:builder")

    expected =
      Map.merge(common, %{
        "action" => "revoke",
        "artifact_digest" => approved["artifact_digest"],
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => inputs["context"]["policy_generation"],
        "inspection_ref" => nil,
        "acknowledgement" => nil
      })

    input =
      build(
        c,
        "revokeTrust",
        :trust,
        Map.put(inputs, "chosen_artifact", approved["artifact_digest"]),
        expected
      )

    {:ok, receipt} = Authority.change_external_trust(c.authority, c.credential, input)
    {input, receipt}
  end
end
