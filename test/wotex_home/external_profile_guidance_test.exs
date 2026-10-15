defmodule WotexHome.ExternalProfileGuidanceTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Server}

  alias WotexHome.Profiles.{
    AuthoringObject,
    Custody,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ReaderSelection
  }

  @owner __MODULE__.Store

  defmodule SourceProbe do
    @moduledoc false

    use GenServer
    def start_link(value), do: GenServer.start_link(__MODULE__, value)
    def init(value), do: {:ok, value}

    def handle_call(:catalogue, _, {parent, response} = state) do
      send(parent, :source_catalogue_called)
      {:reply, response, state}
    end
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp revision(store) do
    {:ok, value} = Store.revision(store)
    value
  end

  setup do
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "guidance-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp owner(c, family) do
    root = Path.join(c.root, "profiles")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    source = fixture("external-source-selections")[family]
    r = source["inputs"]["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])

    {:ok, selection} =
      ExternalSourceSelection.new(
        source["inputs"]["source"],
        reader,
        source["inputs"]["channels"]
      )

    custody = start_supervised!({Custody, root: root, store_owner: @owner})
    sources = start_supervised!({ExternalSourceOwner, publisher: self()})
    {:ok, _} = ExternalSourceOwner.publish(sources, selection)

    store =
      start_supervised!(
        {Store,
         path: Path.join(c.root, "home.sqlite"),
         name: @owner,
         profile_custody: custody,
         external_reader: reader,
         external_source_owner: sources}
      )

    {:ok, credential, first} =
      Store.provision_principal(
        store,
        "operator:guide",
        ~w(enroll:review host:maintain profile:manage),
        []
      )

    v = fixture(family)

    documents =
      [{"envelope", v["envelope"]}, {"profile", v["profile"]}] ++
        Enum.map(v["definitions"], &{"definition", &1})

    {handles, current} =
      Enum.map_reduce(Enum.with_index(documents), first, fn {{kind, value}, index}, current ->
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
              "expected_revision" => current,
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

    inspection = %{
      "authority_epoch" => 1,
      "operation_id" => "inspection:guide",
      "expected_revision" => current,
      "inspection" => Map.put(objects, "reader_basis_sha256", reader.data["basis_sha256"])
    }

    {:ok, receipt} = Store.inspect_external_profile(store, credential, inspection)

    Map.merge(c, %{
      store: store,
      credential: credential,
      reader: reader,
      sources: sources,
      selection: selection,
      source_fixture: source,
      custody: custody,
      objects: objects,
      receipt: receipt,
      reference:
        Map.take(receipt, ~w(authority_epoch operation_id revision input_sha256 result_sha256)),
      authority: Authority.new(store: store, profile_custody: custody),
      family: family
    })
  end

  for family <- ~w(temperature research) do
    test "#{family} reads independent context, sources, absent target and owned artifact without writes",
         c do
      c = owner(c, unquote(family))
      before = revision(c.store)
      assert {:ok, context} = Authority.external_profile_context(c.authority, c.credential)

      assert Map.keys(context) |> Enum.sort() ==
               ~w(authority_epoch format maintenance maintenance_revision policy_generation principal_id reader store_revision)

      assert context["format"] == "wotex-home.external-profile-context@1"

      assert context["reader"] == %{
               "state" => "available",
               "basis_sha256" => c.reader.data["basis_sha256"],
               "reason" => nil
             }

      assert context["maintenance"] == "normal" and context["maintenance_revision"] == 0
      assert context["principal_id"] == "operator:guide" and context["store_revision"] == before

      assert {:ok, sources} = Authority.external_source_catalogue(c.authority, c.credential)
      assert sources["state"] == "available" and sources["reason"] == nil
      {:ok, catalogue} = ExternalSourceOwner.catalogue(c.sources)
      assert sources["owner_epoch"] == catalogue["owner_epoch"]

      expected =
        Map.take(
          c.source_fixture["data"],
          ~w(method policy_sha256 reader_basis_sha256 source_epoch source_generation source_ref trust)
        )
        |> Map.put("source_selection_sha256", c.source_fixture["sha256"])

      assert sources["sources"] == [expected]
      refute JSON.encode!(sources) =~ "stable_id"
      refute JSON.encode!(sources) =~ "capture"

      assert {:ok, target} =
               Authority.external_target_basis(c.authority, c.credential, "sensor:guide")

      assert Map.take(
               target,
               ~w(state selection_revision selection_generation resource_revision binding_revision artifact_digest trust_revision)
             ) ==
               %{
                 "state" => "absent",
                 "selection_revision" => 0,
                 "selection_generation" => 0,
                 "resource_revision" => 0,
                 "binding_revision" => 0,
                 "artifact_digest" => nil,
                 "trust_revision" => 0
               }

      assert {:ok, artifact} =
               Authority.external_inspection_artifact(c.authority, c.credential, c.reference)

      expected = fixture("external-trust")[c.family]
      assert artifact["artifact"] == expected["artifact"]
      assert artifact["artifact_digest"] == expected["artifact_digest"]
      assert artifact["inspection_ref"] == c.reference
      assert artifact["store_revision"] == before and artifact["authority_epoch"] == 1
      assert :sys.get_state(c.custody).leases == %{}
      assert :sys.get_state(c.sources).entries == %{}
      assert revision(c.store) == before
      assert {:ok, %{dispatch_enabled: false}} = Store.health(c.store)
    end

    test "#{family} target counters survive selection, publisher loss and revocation", c do
      c = owner(c, unquote(family))

      {:ok, barrier} =
        Store.begin_maintenance(c.store, c.credential, 1, "maintenance:guide", revision(c.store))

      assert {:ok, active} = Store.external_profile_context(c.store, c.credential)
      assert active["maintenance"] == "maintenance"
      assert active["maintenance_revision"] == barrier.revision
      digest = fixture("external-trust")[c.family]["artifact_digest"]

      approve = %{
        "authority_epoch" => 1,
        "operation_id" => "approve:guide",
        "expected_revision" => barrier.revision,
        "action" => "approve",
        "artifact_digest" => digest,
        "expected_trust_revision" => 0,
        "expected_policy_generation" => 0,
        "inspection_ref" => c.reference,
        "acknowledgement" => "operator_digest_approval"
      }

      assert {:ok, trusted} = Store.change_external_trust(c.store, c.credential, approve)
      {:ok, catalogue} = ExternalSourceOwner.catalogue(c.sources)

      select = %{
        "authority_epoch" => 1,
        "operation_id" => "select:guide",
        "expected_revision" => revision(c.store),
        "action" => "select",
        "target_id" => "sensor:guide",
        "artifact_digest" => digest,
        "expected_trust_revision" => trusted["revision"],
        "expected_policy_generation" => trusted["policy_generation"],
        "expected_selection_revision" => 0,
        "expected_resource_revision" => 0,
        "source_ref" => c.selection.data["source_ref"],
        "source_owner_epoch" => catalogue["owner_epoch"],
        "source_selection_sha256" => c.selection.sha256,
        "objects" => c.objects,
        "acknowledgement" => "operator_external_selection"
      }

      assert {:ok, selected} = Store.change_external_target(c.store, c.credential, select)
      before = revision(c.store)
      assert {:ok, basis} = Store.external_target_basis(c.store, c.credential, "sensor:guide")
      assert basis["state"] == "selected" and basis["selection_revision"] == selected["revision"]
      assert basis["resource_revision"] == 0 and basis["binding_revision"] == selected["revision"]
      assert basis["artifact_digest"] == digest and basis["trust_revision"] == trusted["revision"]
      assert revision(c.store) == before
      GenServer.stop(c.sources)

      assert {:ok, %{"state" => "unavailable", "owner_epoch" => nil, "sources" => []}} =
               Store.external_source_catalogue(c.store, c.credential)

      assert {:ok, ^basis} = Store.external_target_basis(c.store, c.credential, "sensor:guide")
      assert {:ok, replacement} = GenServer.start_link(ExternalSourceOwner, publisher: self())

      try do
        :sys.replace_state(c.store, &%{&1 | external_source_owner: replacement})
        assert {:ok, empty} = Store.external_source_catalogue(c.store, c.credential)
        assert empty["state"] == "available" and empty["sources"] == []
        refute empty["owner_epoch"] == catalogue["owner_epoch"]
        assert {:ok, _} = ExternalSourceOwner.publish(replacement, c.selection)
        assert {:ok, fresh} = Store.external_source_catalogue(c.store, c.credential)
        assert length(fresh["sources"]) == 1
        assert fresh["owner_epoch"] == empty["owner_epoch"]
        assert {:ok, ^basis} = Store.external_target_basis(c.store, c.credential, "sensor:guide")
        assert revision(c.store) == before
      after
        GenServer.stop(replacement)
      end

      revoke =
        Map.merge(approve, %{
          "operation_id" => "revoke:guide",
          "expected_revision" => before,
          "action" => "revoke",
          "expected_trust_revision" => trusted["revision"],
          "expected_policy_generation" => trusted["policy_generation"],
          "inspection_ref" => nil,
          "acknowledgement" => nil
        })

      assert {:ok, revoked} = Store.change_external_trust(c.store, c.credential, revoke)
      before = revision(c.store)
      assert {:ok, retired} = Store.external_target_basis(c.store, c.credential, "sensor:guide")

      assert retired["state"] == "revoked" and retired["selection_generation"] == 2 and
               retired["resource_revision"] == 1

      assert retired["binding_revision"] == selected["revision"] and
               retired["trust_revision"] == revoked["revision"]

      assert retired["policy_generation"] == revoked["policy_generation"]
      :sys.replace_state(c.store, &%{&1 | external_reader: nil})

      assert {:ok, %{"reader" => %{"state" => "unavailable", "basis_sha256" => nil}}} =
               Store.external_profile_context(c.store, c.credential)

      assert {:ok, ^retired} = Store.external_target_basis(c.store, c.credential, "sensor:guide")

      assert {:error, :external_reader_unavailable} =
               Store.external_inspection_artifact(c.store, c.credential, c.reference)

      assert {:ok, _} =
               Store.external_inspection_status(
                 c.store,
                 c.credential,
                 1,
                 c.receipt["operation_id"]
               )

      assert revision(c.store) == before

      :sys.replace_state(c.store, fn state ->
        :ok =
          Exqlite.Sqlite3.execute(
            state.db,
            "UPDATE profile_external_target_current SET generation = 99 WHERE target_id = 'sensor:guide'"
          )

        state
      end)

      assert {:error, :corrupt_external_targets} =
               Store.external_target_basis(c.store, c.credential, "sensor:guide")

      refute :sys.get_state(c.store).writable
      assert revision(c.store) == before
    end

    test "#{family} missing private bytes release sequential leases while historical status survives",
         c do
      c = owner(c, unquote(family))
      before = revision(c.store)
      digest = c.objects["profile"]["object_ref"]["object_digest"]
      path = Path.join([c.root, "profiles", digest <> ".json"])
      hidden = Path.join(c.root, "unavailable-object.json")
      File.rename!(path, hidden)

      try do
        assert {:error, :authoring_object_unavailable} =
                 Store.external_inspection_artifact(c.store, c.credential, c.reference)

        assert :sys.get_state(c.custody).leases == %{}

        assert {:ok, _} =
                 Store.external_inspection_status(
                   c.store,
                   c.credential,
                   1,
                   c.receipt["operation_id"]
                 )

        assert revision(c.store) == before
      after
        File.rename!(hidden, path)
      end

      assert {:ok, _} = Store.external_inspection_artifact(c.store, c.credential, c.reference)
      assert :sys.get_state(c.custody).leases == %{}
      assert revision(c.store) == before
      GenServer.stop(c.custody)

      assert {:error, :profile_custody_unavailable} =
               Store.external_inspection_artifact(c.store, c.credential, c.reference)

      assert Process.alive?(c.store)

      assert {:ok, _} =
               Store.external_inspection_status(
                 c.store,
                 c.credential,
                 1,
                 c.receipt["operation_id"]
               )

      assert revision(c.store) == before
    end
  end

  test "current permission and exact actor/reference checks precede source work", c do
    c = owner(c, "temperature")

    {:ok, manager, _} =
      Store.provision_principal(c.store, "operator:manager", ["profile:manage"], [])

    {:ok, stranger, _} =
      Store.provision_principal(c.store, "operator:other", ~w(profile:manage enroll:review), [])

    probe = start_supervised!({SourceProbe, {self(), {:ok, %{}}}})
    :sys.replace_state(c.store, &%{&1 | external_source_owner: probe})
    assert {:error, :unauthorized} = Store.external_source_catalogue(c.store, <<0::256>>)
    assert {:error, :permission_denied} = Store.external_source_catalogue(c.store, manager)

    assert {:error, :permission_denied} =
             Store.external_target_basis(c.store, manager, "sensor:guide")

    refute_received :source_catalogue_called
    assert :not_found = Store.external_inspection_artifact(c.store, stranger, c.reference)

    assert {:error, :stale_external_reference} =
             Store.external_inspection_artifact(
               c.store,
               c.credential,
               Map.put(c.reference, "input_sha256", String.duplicate("0", 64))
             )

    for ref <- [
          Map.put(c.reference, "extra", true),
          Map.put(c.reference, "revision", true),
          Map.put(c.reference, "authority_epoch", 1.0)
        ] do
      assert {:error, :invalid_external_inspection_reference} =
               Store.external_inspection_artifact(c.store, c.credential, ref)
    end

    before = revision(c.store)

    assert {:error, :invalid_external_source_catalogue} =
             Store.external_source_catalogue(c.store, c.credential)

    assert_received :source_catalogue_called
    assert revision(c.store) == before
  end

  test "legacy collisions stay explicit and all guidance refuses a genuinely retired authority",
       c do
    c = owner(c, "temperature")

    capability = %{
      "thing_id" => "light:legacy",
      "role" => "Light",
      "key" => "power",
      "value_kind" => "boolean",
      "unit" => "none",
      "operations" => ["read", "write"],
      "risk_class" => "ordinary",
      "profile_ref" => "lifx.old:1",
      "evidence_ref" => "fixture:power:1",
      "freshness_ms" => 5000,
      "constraints" => %{},
      "extensions" => %{}
    }

    {:ok, thing} =
      WotexHome.Semantics.Thing.new(%{
        "id" => "light:legacy",
        "role" => "Light",
        "profile_ref" => "lifx.old:1",
        "capabilities" => [capability]
      })

    assert {:ok, _} = Store.enroll_thing(c.store, thing)
    before = revision(c.store)

    assert {:error, :external_target_collision} =
             Store.external_target_basis(c.store, c.credential, "light:legacy")

    assert revision(c.store) == before

    {:ok, transfer, _} = Authority.provision_transfer(c.authority)

    {:ok, barrier} =
      Store.begin_maintenance(c.store, c.credential, 1, "maintenance:retire", revision(c.store))

    assert {:ok, _} =
             Store.retire_controller(c.store, transfer, %{
               "authority_epoch" => 1,
               "operation_id" => "retire:guidance",
               "expected_revision" => barrier.revision,
               "destination_owner_id" => String.duplicate("a", 64)
             })

    before = revision(c.store)
    probe = start_supervised!({SourceProbe, {self(), {:ok, %{}}}})
    :sys.replace_state(c.store, &%{&1 | external_source_owner: probe})

    for read <- [
          fn -> Store.external_profile_context(c.store, c.credential) end,
          fn -> Store.external_source_catalogue(c.store, c.credential) end,
          fn -> Store.external_target_basis(c.store, c.credential, "sensor:guide") end,
          fn -> Store.external_inspection_artifact(c.store, c.credential, c.reference) end
        ] do
      assert {:error, :source_retired} = read.()
    end

    refute_received :source_catalogue_called
    assert revision(c.store) == before
  end

  test "source projection rejects malformed, duplicate, unsorted and oversized owner catalogues",
       c do
    c = owner(c, "temperature")
    {:ok, catalogue} = ExternalSourceOwner.catalogue(c.sources)
    [row] = catalogue["sources"]
    later = put_in(row, ["data", "source_ref"], "zz:source") |> Map.put("source_ref", "zz:source")
    probe = start_supervised!({SourceProbe, {self(), {:ok, catalogue}}})
    :sys.replace_state(c.store, &%{&1 | external_source_owner: probe})
    before = revision(c.store)

    for malformed <- [
          Map.put(catalogue, "extra", nil),
          Map.put(catalogue, "owner_epoch", String.duplicate("A", 32)),
          Map.put(catalogue, "sources", [row, row]),
          Map.put(catalogue, "sources", [later, row]),
          Map.put(catalogue, "sources", List.duplicate(row, 33)),
          Map.put(catalogue, "sources", [Map.put(row, "extra", nil)]),
          Map.put(catalogue, "sources", [put_in(row, ["data", "source_generation"], true)]),
          Map.put(catalogue, "sources", [put_in(row, ["data", "source_ref"], "mismatched")]),
          Map.put(catalogue, "sources", [row | :improper])
        ] do
      parent = self()
      :sys.replace_state(probe, fn _ -> {parent, {:ok, malformed}} end)

      assert {:error, :invalid_external_source_catalogue} =
               Store.external_source_catalogue(c.store, c.credential)

      assert revision(c.store) == before
    end
  end

  test "CLI reference files reject links, permissive parents and oversized or coerced input", c do
    c = owner(c, "temperature")
    encoded = Base.url_encode64(c.credential, padding: false)
    file = Path.join(c.root, "reference.json")
    linked = Path.join(c.root, "link.json")
    File.write!(file, JSON.encode!(c.reference))
    File.chmod!(file, 0o600)
    command = ["external-inspection-artifact", file]
    assert {:ok, _} = CLI.build_request(command, encoded)
    File.ln!(file, linked)

    assert {:error, :invalid_external_inspection_reference_file} =
             CLI.build_request(command, encoded)

    File.rm!(linked)
    File.ln_s!(file, linked)

    assert {:error, :invalid_external_inspection_reference_file} =
             CLI.build_request(["external-inspection-artifact", linked], encoded)

    File.rm!(linked)
    File.chmod!(c.root, 0o755)

    assert {:error, :invalid_external_inspection_reference_file} =
             CLI.build_request(command, encoded)

    File.chmod!(c.root, 0o700)

    for bytes <- [
          String.duplicate(" ", 4097),
          JSON.encode!(Map.put(c.reference, "revision", "1"))
        ] do
      File.write!(file, bytes)

      assert {:error, :invalid_external_inspection_reference_file} =
               CLI.build_request(command, encoded)
    end

    assert {:error, :usage} = CLI.build_request(["external-profile-context", "extra"], encoded)
    assert {:error, :usage} = CLI.build_request(["external-target-basis"], encoded)
  end

  @tag requires_socket: true
  test "closed framed routes and CLI preserve exact read outputs and safe input custody", c do
    c = owner(c, "research")
    socket = Path.join(c.root, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    encoded = Base.url_encode64(c.credential, padding: false)
    reference_file = Path.join(c.root, "reference.json")
    File.write!(reference_file, JSON.encode!(c.reference))
    File.chmod!(reference_file, 0o600)
    credential_file = Path.join(c.root, "credential")
    File.write!(credential_file, encoded)
    File.chmod!(credential_file, 0o600)
    before = revision(c.store)

    for {command, fields} <- [
          {["external-profile-context"], %{}},
          {["external-source-catalogue"], %{}},
          {["external-target-basis", "sensor:new"], %{"target_id" => "sensor:new"}},
          {["external-inspection-artifact", reference_file], %{"inspection_ref" => c.reference}}
        ] do
      [name | _] = command
      operation = String.replace(name, "-", "_")

      expected =
        Map.merge(
          %{"api_version" => 1, "operation" => operation, "credential" => encoded},
          fields
        )

      assert {:ok, ^expected} = CLI.build_request(command, encoded)

      assert {:ok, %{"outcome" => "ok", ^operation => result} = response} =
               Client.request(socket, expected)

      assert result["store_revision"] == before and result["principal_id"] == "operator:guide"

      output =
        capture_io(fn ->
          assert 0 ==
                   CLI.main(["--socket", socket, "--credential-file", credential_file] ++ command)
        end)

      assert JSON.decode!(String.trim(output)) == response

      assert {:ok, %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"}} =
               Client.request(socket, Map.put(expected, "extra", true))
    end

    assert revision(c.store) == before
    File.chmod!(reference_file, 0o644)

    assert {:error, :invalid_external_inspection_reference_file} =
             CLI.build_request(["external-inspection-artifact", reference_file], encoded)

    File.chmod!(reference_file, 0o600)
    File.write!(reference_file, ~s({"revision":1,"revision":2}))

    assert {:error, :invalid_external_inspection_reference_file} =
             CLI.build_request(["external-inspection-artifact", reference_file], encoded)

    File.write!(reference_file, JSON.encode!(Map.put(c.reference, "operation_id", "absent")))

    capture_io(fn ->
      assert 4 ==
               CLI.main([
                 "--socket",
                 socket,
                 "--credential-file",
                 credential_file,
                 "external-inspection-artifact",
                 reference_file
               ])
    end)
  end
end
