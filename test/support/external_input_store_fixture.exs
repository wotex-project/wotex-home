defmodule WotexHome.ExternalInputStoreFixture do
  @moduledoc false

  import ExUnit.Callbacks
  alias WotexHome.Authority
  alias WotexHome.Durable.Store

  alias WotexHome.Profiles.{
    AuthoringObject,
    Custody,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ProducerIdentity,
    ReaderSelection
  }

  @owner __MODULE__.Store

  def setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()

    root =
      Path.join(
        temporary,
        "woh-external-input-context-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root, store_owner: @owner})
    sources = start_supervised!({ExternalSourceOwner, publisher: self()})

    %{
      root: root,
      custody_root: custody_root,
      path: Path.join(root, "home.sqlite"),
      custody: custody,
      sources: sources
    }
  end

  def fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/" <> name <> ".json"))

  def prepare(c, options \\ []) do
    family = Keyword.get(options, :family, "temperature")
    source_changes = Keyword.get(options, :source, %{"trust" => "authenticated_device"})
    policy_changes = Keyword.get(options, :policy, %{})

    source =
      Keyword.get(
        options,
        :source_inputs,
        fixture("external-source-selections")[family]["inputs"]
      )

    r = source["reader"]
    {:ok, producer} = ProducerIdentity.current()

    installed =
      if options[:legacy], do: r["installed"], else: Map.put(r["installed"], "producer", producer)

    {:ok, reader} = ReaderSelection.new(installed, r["capture"], r["reader_limits"])

    {:ok, selection} =
      ExternalSourceSelection.new(
        Map.merge(source["source"], source_changes),
        reader,
        Enum.map(
          source["channels"],
          &update_in(&1, ["policy"], fn policy -> Map.merge(policy, policy_changes) end)
        )
      )

    {:ok, _} = ExternalSourceOwner.publish(c.sources, selection)
    {:ok, catalogue} = ExternalSourceOwner.catalogue(c.sources)

    reports =
      start_supervised!(
        {WotexHome.Profiles.ExternalReportOwner,
         publisher: self(),
         source_owner: c.sources,
         store_owner: @owner,
         ttl_ms: Keyword.get(options, :report_ttl_ms, 60_000)}
      )

    store =
      start_supervised!(
        {Store,
         path: c.path,
         profile_custody: c.custody,
         external_reader: reader,
         external_source_owner: c.sources,
         external_report_owner: reports,
         qualification_case_keys: Keyword.get(options, :case_keys, %{}),
         qualification_decision_keys: Keyword.get(options, :decision_keys, %{}),
         name: @owner}
      )

    {:ok, credential, revision} =
      Store.provision_principal(
        store,
        "operator:1",
        ["enroll:review", "host:maintain", "profile:manage"],
        []
      )

    v =
      Keyword.get_lazy(options, :fixture, fn ->
        if family == "multi",
          do: fixture("generic-read-semantics")["multi"]["fixture"],
          else: fixture(family)
      end)

    docs =
      [{"envelope", v["envelope"]}, {"profile", v["profile"]}] ++
        Enum.map(v["definitions"], &{"definition", &1})

    {handles, revision} =
      Enum.map_reduce(Enum.with_index(docs), revision, fn {{kind, data}, n}, revision ->
        {:ok, bytes} = Wotex.JSON.encode(data)
        {:ok, object} = AuthoringObject.new(kind, bytes)
        {:ok, summary} = AuthoringObject.summary(object)

        {:ok, receipt} =
          Store.import_authoring_object(
            store,
            credential,
            %{
              "authority_epoch" => 1,
              "operation_id" => "import:#{n}",
              "expected_revision" => revision,
              "object" => summary
            },
            bytes
          )

        {%{
           "object_digest" => summary["object_digest"],
           "first_revision" => receipt["first_revision"]
         }, receipt["revision"]}
      end)

    [envelope, profile | definitions] = handles

    objects = %{
      "envelope_ref" => envelope,
      "profile" => %{"reference" => v["envelope"]["profile"], "object_ref" => profile},
      "definitions" =>
        Enum.zip_with(
          v["envelope"]["definitions"],
          definitions,
          &%{"reference" => &1, "object_ref" => &2}
        )
    }

    {:ok, inspected} =
      Store.inspect_external_profile(store, credential, %{
        "authority_epoch" => 1,
        "operation_id" => "inspection:1",
        "expected_revision" => revision,
        "inspection" => Map.put(objects, "reader_basis_sha256", reader.data["basis_sha256"])
      })

    {:ok, manifest} =
      Store.external_inspection_artifact(
        store,
        credential,
        Map.take(inspected, ~w(authority_epoch operation_id revision input_sha256 result_sha256))
      )

    {:ok, barrier} =
      Store.begin_maintenance(store, credential, 1, "maintenance:1", inspected["revision"])

    artifact = manifest["artifact_digest"]

    {:ok, approved} =
      Store.change_external_trust(store, credential, %{
        "authority_epoch" => 1,
        "operation_id" => "trust:1",
        "expected_revision" => barrier.revision,
        "action" => "approve",
        "artifact_digest" => artifact,
        "expected_trust_revision" => 0,
        "expected_policy_generation" => 0,
        "inspection_ref" =>
          Map.take(
            inspected,
            ~w(authority_epoch operation_id revision input_sha256 result_sha256)
          ),
        "acknowledgement" => "operator_digest_approval"
      })

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "selection:1",
      "expected_revision" => approved["revision"],
      "action" => "select",
      "target_id" => "sensor:external",
      "artifact_digest" => artifact,
      "expected_trust_revision" => approved["revision"],
      "expected_policy_generation" => approved["policy_generation"],
      "expected_selection_revision" => 0,
      "expected_resource_revision" => 0,
      "source_ref" => source["source"]["source_ref"],
      "source_owner_epoch" => catalogue["owner_epoch"],
      "source_selection_sha256" => selection.sha256,
      "objects" => objects,
      "acknowledgement" => "operator_external_selection"
    }

    {:ok, selected} = Store.change_external_target(store, credential, input)

    {credential, _revision} =
      if Keyword.get(options, :grant, true) do
        {:ok, rotated, revision} =
          Store.grant_target_and_rotate(store, "operator:1", "sensor:external")

        {rotated, revision}
      else
        {credential, selected["revision"]}
      end

    operator_credential = credential

    {:ok, credential, revision} =
      Store.provision_principal(
        store,
        "reviewer:input",
        ["qualify:profile", "rule:review", "read", "host:maintain"],
        ["sensor:external"]
      )

    {:ok, _} =
      Store.end_maintenance(
        store,
        credential,
        1,
        "maintenance:end",
        revision,
        barrier.begin_revision
      )

    Map.merge(c, %{
      selected: selected,
      store: store,
      credential: credential,
      operator_credential: operator_credential,
      reader: reader,
      selection: selection,
      input: input,
      trust: approved,
      authority: Authority.new(store: store, profile_custody: c.custody),
      reports: reports,
      family: family,
      case_keys: Keyword.get(options, :case_keys, %{}),
      decision_keys: Keyword.get(options, :decision_keys, %{})
    })
  end

  def restart(c) do
    stop_supervised!(Store)

    store =
      start_supervised!(
        {Store,
         path: c.path,
         profile_custody: c.custody,
         external_reader: c.reader,
         external_source_owner: c.sources,
         external_report_owner: c.reports,
         qualification_case_keys: c.case_keys,
         qualification_decision_keys: c.decision_keys,
         name: @owner}
      )

    %{c | store: store, authority: Authority.new(store: store, profile_custody: c.custody)}
  end
end
