System.fetch_env!("HOME_AUTHORING_ARCHIVE_EBINS")
|> JSON.decode!()
|> Enum.each(fn path ->
  true = Code.prepend_path(path)
end)

# Home's ordinary test project does not contain these optional dependency
# implementations when it consolidates protocols. Restore OTP/Elixir's original
# dynamic protocol for this isolated archive-backed process only.
:code.purge(String.Chars)

{:module, String.Chars} =
  :code.load_abs(
    Path.join(:code.lib_dir(:elixir, :ebin), "Elixir.String.Chars")
    |> String.to_charlist()
  )

defmodule HomeAuthoringStoreArchiveTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Profiles.{AuthoringCandidate, AuthoringContract, AuthoringObject, Custody}
  alias Exqlite.Sqlite3
  @owner __MODULE__.Store

  defp fixture(family),
    do: JSON.decode!(File.read!("test/fixtures/profiles/" <> family <> ".json"))

  setup do
    root = Path.join(System.tmp_dir!(), "candidate-archive-#{System.unique_integer([:positive])}")
    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root, store_owner: @owner})
    v = fixture("temperature")

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", %{
        "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
        "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
        "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
      })

    limits = fixture("authoring-mechanics")["temperature"]["limits"]
    {:ok, contract} = AuthoringContract.export(installed, limits)

    {:ok, reader} =
      WotexHome.Profiles.ReaderSelection.new(installed, v["capture"], v["reader_limits"])

    path = Path.join(root, "home.sqlite")

    store =
      start_supervised!(
        {Store,
         path: path,
         profile_custody: custody,
         authoring_contract: contract,
         authoring_capture: v["capture"],
         external_reader: reader,
         name: @owner}
      )

    {:ok, credential, 1} = Store.provision_principal(store, "author:1", ["profile:manage"], [])

    %{
      root: root,
      path: path,
      store: store,
      custody: custody,
      credential: credential,
      contract: contract,
      reader: reader,
      authority: Authority.new(store: store, profile_custody: custody)
    }
  end

  defp import(c, kind, bytes, revision, operation) do
    {:ok, o} = AuthoringObject.new(kind, bytes)
    {:ok, s} = AuthoringObject.summary(o)

    {:ok, r} =
      Store.import_authoring_object(
        c.store,
        c.credential,
        %{
          "authority_epoch" => 1,
          "operation_id" => operation,
          "expected_revision" => revision,
          "object" => s
        },
        bytes
      )

    %{"object_digest" => s["object_digest"], "first_revision" => r["first_revision"]}
  end

  defp input(c, ref, revision, operation \\ "candidate:1") do
    %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "request" => %{
        "mode" => "manual",
        "contract_digest" => c.contract.contract_sha256,
        "base_draft_ref" => ref,
        "source_refs" => [],
        "fixture_refs" => [],
        "instruction" => "manual review",
        "limits" => c.contract.inputs["limits"]
      }
    }
  end

  defp draft(family), do: fixture("authoring-mechanics")[family]["draft_bytes"]

  defp inspection_input(c, family, start_revision \\ 1) do
    v = fixture(family)

    data =
      [{"envelope", v["envelope"]}, {"profile", v["profile"]}] ++
        Enum.map(v["definitions"], &{"definition", &1})

    {handles, revision} =
      Enum.map_reduce(Enum.with_index(data), start_revision, fn {{kind, data}, index}, revision ->
        {:ok, bytes} = Wotex.JSON.encode(data)
        ref = import(c, kind, bytes, revision, "external:#{index}")
        {ref, revision + 1}
      end)

    [envelope, profile | definitions] = handles

    %{
      "authority_epoch" => 1,
      "operation_id" => "inspection:1",
      "expected_revision" => revision,
      "inspection" => %{
        "reader_basis_sha256" => c.reader.data["basis_sha256"],
        "envelope_ref" => envelope,
        "profile" => %{"reference" => v["envelope"]["profile"], "object_ref" => profile},
        "definitions" =>
          Enum.zip_with(v["envelope"]["definitions"], definitions, fn reference, handle ->
            %{"reference" => reference, "object_ref" => handle}
          end)
      }
    }
  end

  for family <- ~w(temperature research) do
    @inspection_family family
    test "#{@inspection_family} external inspection retains exact original independently imported closure",
         c do
      i = inspection_input(c, @inspection_family)
      assert {:ok, receipt} = Authority.inspect_external_profile(c.authority, c.credential, i)
      assert receipt["revision"] == i["expected_revision"] + 1
      assert receipt["home_consumption"] == "matched"

      assert receipt["envelope_sha256"] ==
               fixture(@inspection_family)["identities"]["envelope_sha256"]

      assert {:ok, ^receipt} = Store.inspect_external_profile(c.store, c.credential, i)

      assert {:ok, ^receipt} =
               Store.external_inspection_status(c.store, c.credential, 1, "inspection:1")

      assert {:error, :external_inspection_conflict} =
               Store.inspect_external_profile(
                 c.store,
                 c.credential,
                 put_in(i, ["inspection", "reader_basis_sha256"], String.duplicate("0", 64))
               )

      assert {:ok, [[0]]} =
               SQL.query(
                 :sys.get_state(c.store).db,
                 "SELECT COUNT(*) FROM profile_authoring_reviews"
               )

      assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
      assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    end
  end

  test "external original remains history after missing bytes, disabled reader and restart", c do
    i = inspection_input(c, "temperature")
    assert {:ok, receipt} = Store.inspect_external_profile(c.store, c.credential, i)

    File.rm!(
      Path.join([
        c.root,
        "profiles",
        i["inspection"]["profile"]["object_ref"]["object_digest"] <> ".json"
      ])
    )

    assert {:error, :authoring_object_unavailable} =
             Store.inspect_external_profile(
               c.store,
               c.credential,
               Map.merge(i, %{
                 "operation_id" => "inspection:missing",
                 "expected_revision" => receipt["revision"]
               })
             )

    assert {:ok, ^receipt} = Store.inspect_external_profile(c.store, c.credential, i)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)

    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    assert {:ok, ^receipt} = Store.inspect_external_profile(store, c.credential, i)

    assert {:ok, ^receipt} =
             Store.external_inspection_status(store, c.credential, 1, "inspection:1")

    assert {:error, :external_reader_unavailable} =
             Store.inspect_external_profile(
               store,
               c.credential,
               Map.merge(i, %{
                 "operation_id" => "inspection:next",
                 "expected_revision" => receipt["revision"]
               })
             )
  end

  test "external inspection guards CAS, epoch, owned first revision, reader basis and another principal",
       c do
    i = inspection_input(c, "temperature")

    wrong_kind =
      put_in(i, ["inspection", "profile", "object_ref"], i["inspection"]["envelope_ref"])

    assert {:error, :stale_external_reference} =
             Store.inspect_external_profile(c.store, c.credential, wrong_kind)

    for {bad, expected} <- [
          {Map.put(i, "expected_revision", 0), :resnapshot_required},
          {Map.put(i, "authority_epoch", 2), :stale_authority_epoch},
          {put_in(i, ["inspection", "envelope_ref", "first_revision"], 1),
           :stale_external_reference},
          {put_in(i, ["inspection", "reader_basis_sha256"], String.duplicate("0", 64)),
           :stale_external_basis}
        ] do
      assert {:error, ^expected} = Store.inspect_external_profile(c.store, c.credential, bad)
    end

    {:ok, other, revision} = Store.provision_principal(c.store, "other:1", ["profile:manage"], [])

    assert :not_found =
             Store.inspect_external_profile(
               c.store,
               other,
               Map.put(i, "expected_revision", revision)
             )

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(c.store).db,
               "SELECT COUNT(*) FROM profile_external_inspections"
             )

    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "actual external insert fault rolls back journal, revision and result with no leases", c do
    i = inspection_input(c, "temperature")
    db = :sys.get_state(c.store).db

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TEMP TRIGGER refuse_external BEFORE INSERT ON profile_external_inspections BEGIN SELECT RAISE(ABORT,'fixture'); END"
      )

    assert {:error, :store_unavailable} = Store.inspect_external_profile(c.store, c.credential, i)
    assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_external_inspections")

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM authority_journal WHERE event_type='external_profile_inspected'"
             )

    assert {:ok, [[revision]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")
    assert revision == i["expected_revision"]
    assert :ok = Integrity.validate_snapshot(db)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "external original lookup precedes removed public reader APIs and maintenance while revocation denies reads",
       c do
    i = inspection_input(c, "temperature")
    assert {:ok, original} = Store.inspect_external_profile(c.store, c.credential, i)
    producer_path = :code.which(Wotex.Profiles.Binding) |> List.to_string() |> Path.dirname()
    true = Code.delete_path(producer_path)
    :code.purge(Wotex.Profiles.Binding)
    :code.delete(Wotex.Profiles.Binding)

    try do
      refute Code.ensure_loaded?(Wotex.Profiles.Binding)
      assert {:ok, ^original} = Store.inspect_external_profile(c.store, c.credential, i)

      assert {:ok, ^original} =
               Store.external_inspection_status(c.store, c.credential, 1, "inspection:1")

      assert {:error, :profiles_producer_unavailable} =
               Store.inspect_external_profile(
                 c.store,
                 c.credential,
                 Map.merge(i, %{
                   "operation_id" => "inspection:absent",
                   "expected_revision" => original["revision"]
                 })
               )
    after
      true = Code.prepend_path(producer_path)
      assert Code.ensure_loaded?(Wotex.Profiles.Binding)
    end

    {:ok, manager, revision} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    assert {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", revision)

    assert {:error, :maintenance_active} =
             Store.inspect_external_profile(
               c.store,
               c.credential,
               Map.merge(i, %{
                 "operation_id" => "inspection:maintenance",
                 "expected_revision" => barrier.revision
               })
             )

    assert {:ok, ^original} = Store.inspect_external_profile(c.store, c.credential, i)
    {:ok, _} = Store.revoke_principal(c.store, "author:1")
    assert {:error, :unauthorized} = Store.inspect_external_profile(c.store, c.credential, i)

    assert {:error, :unauthorized} =
             Store.external_inspection_status(c.store, c.credential, 1, "inspection:1")
  end

  test "deep external document identity corruption is refused even with a rewritten receipt hash",
       c do
    alias WotexHome.Profiles.ExternalInspection
    i = inspection_input(c, "temperature")
    assert {:ok, receipt} = Store.inspect_external_profile(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[document]]} =
      SQL.query(db, "SELECT result_document FROM profile_external_inspections")

    {:ok, result} = ExternalInspection.decode_result(document)

    result =
      put_in(
        result,
        ["envelope", "document_identities", Access.at(0), "raw_sha256"],
        String.duplicate("0", 64)
      )

    {:ok, document} = ExternalInspection.encode_result(result)

    {:ok, receipt_document} =
      ExternalInspection.encode_receipt(Map.put(receipt, "result_sha256", sha(document)))

    {:ok, []} =
      SQL.query(
        db,
        "UPDATE profile_external_inspections SET result_document=?,receipt_document=?",
        [document, receipt_document]
      )

    assert {:error, :corrupt_external_inspections} = Integrity.validate_snapshot(db)

    assert {:error, :corrupt_external_inspections} =
             Store.external_inspection_status(c.store, c.credential, 1, "inspection:1")

    assert {:error, :store_unavailable} = Store.inspect_external_profile(c.store, c.credential, i)
  end

  test "external inspection originals and actual bytes survive encrypted quarantine recovery",
       c do
    i = inspection_input(c, "temperature")
    assert {:ok, receipt} = Store.inspect_external_profile(c.store, c.credential, i)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "external.backup")
    assert {:ok, _} = Store.export_profile_backup(c.store, archive, key)
    assert {:ok, _} = Backup.verify(archive, key)
    target = Path.join(c.root, "external-quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, key, target)
    {:ok, db} = Sqlite3.open(Path.join(target, "home.sqlite"))
    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, [[document]]} =
             SQL.query(db, "SELECT receipt_document FROM profile_external_inspections")

    assert {:ok, ^receipt} = WotexHome.Profiles.ExternalInspection.decode_receipt(document)
    Sqlite3.close(db)
    database = Path.join(c.root, "external-db.backup")
    assert {:ok, _} = Store.export_backup(c.store, database, key)
    assert {:ok, report} = Backup.verify(database, key)
    refute report.dependencies.authoring_bytes_included

    assert {:error, :profile_bytes_missing} =
             Backup.stage_profile_restore(database, key, Path.join(c.root, "external-missing"))
  end

  test "schema 31 migration preserves review originals and creates no external inspection", c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")
    assert {:ok, original} = Store.review_authoring_candidate(c.store, c.credential, i)
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE IF EXISTS profile_external_observation_current; DROP TABLE IF EXISTS profile_external_observation_sequences; DROP TABLE IF EXISTS profile_external_observations; DROP TABLE IF EXISTS profile_external_source_bindings; DROP TABLE IF EXISTS profile_external_target_current; DROP TABLE IF EXISTS profile_external_target_history; DROP TABLE IF EXISTS profile_external_target_operations; DROP TABLE profile_external_trust_operations; DROP TABLE profile_external_artifacts; DELETE FROM meta WHERE key='external_profile_policy_generation'; DROP TABLE profile_external_inspections; PRAGMA user_version=31;"
      )

    assert :ok = Integrity.validate_schema_version(31, db)
    Sqlite3.close(db)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    assert {:ok, [[35]]} = SQL.query(:sys.get_state(store).db, "PRAGMA user_version")

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(store).db,
               "SELECT COUNT(*) FROM profile_external_inspections"
             )

    assert {:ok, ^original} = Store.authoring_review_status(store, c.credential, 1, "review:1")
    assert {:ok, revision} = Store.revision(store)
    assert revision == original["revision"]
  end

  defp prepare_external_trust(c, family) do
    prepare_external_trust_session(c, family).input
  end

  for family <- ~w(temperature research) do
    @operator_family family
    test "#{@operator_family} external socket and CLI recover exact originals and distinguish current revoked trust",
         c do
      alias WotexHome.{CLI, LocalAPI.Client, LocalAPI.Server}
      import ExUnit.CaptureIO
      inspection_input = inspection_input(c, @operator_family)
      socket = Path.join(c.root, "ipc/home.sock")
      start_supervised!({Server, authority: c.authority, socket_path: socket})
      encoded = Base.url_encode64(c.credential, padding: false)
      credential_file = Path.join(c.root, "operator-credential")
      File.write!(credential_file, encoded)
      File.chmod!(credential_file, 0o600)
      flags = ["--socket", socket, "--credential-file", credential_file]
      file = Path.join(c.root, "original.json")
      File.write!(file, JSON.encode!(inspection_input))
      File.chmod!(file, 0o600)

      output =
        capture_io(fn -> assert 0 == CLI.main(flags ++ ["external-profile-inspect", file]) end)

      inspection = JSON.decode!(output)["external_inspection_receipt"]

      assert {:ok, ^inspection} =
               Authority.inspect_external_profile(c.authority, c.credential, inspection_input)

      assert inspection["envelope_sha256"] ==
               fixture(@operator_family)["identities"]["envelope_sha256"]

      status =
        capture_io(fn ->
          assert 0 == CLI.main(flags ++ ["external-inspection-status", "1", "inspection:1"])
        end)

      assert JSON.decode!(status)["external_inspection_receipt"] == inspection

      {:ok, manager, revision} =
        Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

      {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", revision)

      change = %{
        "authority_epoch" => 1,
        "operation_id" => "trust:operator",
        "expected_revision" => barrier.revision,
        "action" => "approve",
        "artifact_digest" => fixture("external-trust")[@operator_family]["artifact_digest"],
        "expected_trust_revision" => 0,
        "expected_policy_generation" => 0,
        "inspection_ref" =>
          Map.take(
            inspection,
            ~w(authority_epoch operation_id revision input_sha256 result_sha256)
          ),
        "acknowledgement" => "operator_digest_approval"
      }

      File.write!(file, JSON.encode!(change))

      output =
        capture_io(fn -> assert 0 == CLI.main(flags ++ ["external-trust-change", file]) end)

      approved = JSON.decode!(output)["external_trust_receipt"]
      assert {:ok, ^approved} = Authority.change_external_trust(c.authority, c.credential, change)
      assert approved["artifact_digest"] == change["artifact_digest"]
      # Discard the committed mutation response; recover through scoped status.
      revoke =
        Map.merge(change, %{
          "operation_id" => "trust:operator:revoke",
          "expected_revision" => approved["revision"],
          "expected_trust_revision" => approved["revision"],
          "expected_policy_generation" => 1,
          "action" => "revoke",
          "inspection_ref" => nil,
          "acknowledgement" => nil
        })

      request = %{
        "api_version" => 1,
        "operation" => "external_trust_change",
        "credential" => encoded,
        "change" => revoke
      }

      assert {:ok, %{"outcome" => "ok"}} = Client.request(socket, request)

      status =
        capture_io(fn ->
          assert 0 == CLI.main(flags ++ ["external-trust-status", "1", "trust:operator:revoke"])
        end)

      revoked = JSON.decode!(status)["external_trust_receipt"]
      assert revoked["action"] == "revoke"
      assert {:ok, ^revoked} = Authority.change_external_trust(c.authority, c.credential, revoke)

      historical =
        capture_io(fn ->
          assert 0 == CLI.main(flags ++ ["external-trust-status", "1", "trust:operator"])
        end)

      assert JSON.decode!(historical)["external_trust_receipt"] == approved
      current = capture_io(fn -> assert 0 == CLI.main(flags ++ ["external-profiles"]) end)
      catalogue = JSON.decode!(current)["external_profile_catalogue"]
      assert hd(catalogue["items"])["state"] == "revoked"
      assert {:ok, ^catalogue} = Authority.external_profile_catalogue(c.authority, c.credential)
      assert {:ok, revision} = Store.revision(c.store)
      assert revision == revoked["revision"]
      assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    end
  end

  defp prepare_external_trust_session(c, family) do
    input = inspection_input(c, family)
    {:ok, inspection} = Store.inspect_external_profile(c.store, c.credential, input)

    {:ok, manager, revision} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", revision)

    trust = %{
      "authority_epoch" => 1,
      "operation_id" => "trust:1",
      "expected_revision" => barrier.revision,
      "action" => "approve",
      "artifact_digest" => fixture("external-trust")[family]["artifact_digest"],
      "expected_trust_revision" => 0,
      "expected_policy_generation" => 0,
      "inspection_ref" =>
        Map.take(inspection, ~w(authority_epoch operation_id revision input_sha256 result_sha256)),
      "acknowledgement" => "operator_digest_approval"
    }

    %{input: trust, manager: manager, begin_revision: barrier.revision, inspection_input: input}
  end

  for family <- ~w(temperature research) do
    @trust_family family
    test "#{@trust_family} exact closure approval/revoke/reapprove has independent local policy and original history",
         c do
      i = prepare_external_trust(c, @trust_family)
      assert {:ok, approved} = Authority.change_external_trust(c.authority, c.credential, i)

      assert approved["action"] == "approve" and approved["trust_generation"] == 1 and
               approved["policy_generation"] == 1

      assert {:ok, ^approved} = Store.change_external_trust(c.store, c.credential, i)
      assert {:ok, ^approved} = Store.external_trust_status(c.store, c.credential, 1, "trust:1")
      assert {:ok, catalogue} = Store.external_profile_catalogue(c.store, c.credential)
      assert [item] = catalogue["items"]
      assert item["state"] == "approved" and item["artifact_digest"] == i["artifact_digest"]

      assert {:ok, [[0]]} =
               SQL.query(
                 :sys.get_state(c.store).db,
                 "SELECT value FROM meta WHERE key='profile_policy_generation'"
               )

      revoke =
        Map.merge(i, %{
          "operation_id" => "trust:2",
          "expected_revision" => approved["revision"],
          "expected_trust_revision" => approved["revision"],
          "expected_policy_generation" => 1,
          "action" => "revoke",
          "inspection_ref" => nil,
          "acknowledgement" => nil
        })

      assert {:ok, revoked} = Store.change_external_trust(c.store, c.credential, revoke)
      assert revoked["trust_generation"] == 2 and revoked["policy_generation"] == 2
      assert {:ok, catalogue} = Store.external_profile_catalogue(c.store, c.credential)
      assert hd(catalogue["items"])["state"] == "revoked"

      again =
        Map.merge(i, %{
          "operation_id" => "trust:3",
          "expected_revision" => revoked["revision"],
          "expected_trust_revision" => revoked["revision"],
          "expected_policy_generation" => 2
        })

      assert {:ok, reapproved} = Store.change_external_trust(c.store, c.credential, again)

      assert reapproved["trust_generation"] == 3 and
               reapproved["artifact_first_approval_revision"] == approved["revision"]

      assert {:ok, ^approved} = Store.change_external_trust(c.store, c.credential, i)
      assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
      assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    end
  end

  test "new external trust checks counters, epoch, original actor and digest before committing",
       c do
    i = prepare_external_trust(c, "temperature")

    for {bad, code} <- [
          {Map.put(i, "authority_epoch", 2), :stale_authority_epoch},
          {Map.put(i, "expected_revision", 0), :resnapshot_required},
          {Map.put(i, "expected_policy_generation", 1), :external_policy_changed},
          {Map.put(i, "expected_trust_revision", 1), :external_trust_changed},
          {put_in(i, ["inspection_ref", "result_sha256"], String.duplicate("0", 64)),
           :stale_external_reference},
          {Map.put(i, "artifact_digest", String.duplicate("0", 64)), :external_artifact_mismatch}
        ] do
      assert {:error, ^code} = Store.change_external_trust(c.store, c.credential, bad)
    end

    {:ok, other, revision} = Store.provision_principal(c.store, "other:1", ["profile:manage"], [])

    assert :not_found =
             Store.change_external_trust(
               c.store,
               other,
               Map.put(i, "expected_revision", revision)
             )

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(c.store).db,
               "SELECT COUNT(*) FROM profile_external_trust_operations"
             )

    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "retained external approval survives missing bytes/reader while revoke never needs either",
       c do
    i = prepare_external_trust(c, "temperature")
    assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)

    {:ok, [[profile]]} =
      SQL.query(
        :sys.get_state(c.store).db,
        "SELECT object_digest FROM profile_authoring_objects WHERE kind='profile'"
      )

    File.rm!(Path.join([c.root, "profiles", profile <> ".json"]))
    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    assert {:ok, ^approved} = Store.change_external_trust(store, c.credential, i)

    revoke =
      Map.merge(i, %{
        "operation_id" => "trust:2",
        "expected_revision" => approved["revision"],
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => 1,
        "action" => "revoke",
        "inspection_ref" => nil,
        "acknowledgement" => nil
      })

    assert {:ok, revoked} = Store.change_external_trust(store, c.credential, revoke)
    assert revoked["action"] == "revoke" and revoked["reader_basis_sha256"] == nil
    assert {:ok, ^approved} = Store.external_trust_status(store, c.credential, 1, "trust:1")
  end

  test "new trust requires maintenance and rejects duplicate states and changed originals", c do
    session = prepare_external_trust_session(c, "temperature")
    i = session.input

    assert {:ok, ended} =
             Store.end_maintenance(
               c.store,
               session.manager,
               1,
               "maint:end",
               i["expected_revision"],
               session.begin_revision
             )

    no_barrier = Map.put(i, "expected_revision", ended.revision)

    assert {:error, :maintenance_required} =
             Store.change_external_trust(c.store, c.credential, no_barrier)

    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, session.manager, 1, "maint:2", ended.revision)

    i = Map.put(i, "expected_revision", barrier.revision)
    assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)

    assert {:error, :external_trust_conflict} =
             Store.change_external_trust(
               c.store,
               c.credential,
               Map.put(i, "expected_revision", 0)
             )

    next =
      Map.merge(i, %{
        "operation_id" => "trust:next",
        "expected_revision" => approved["revision"],
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => 1
      })

    assert {:error, :external_already_approved} =
             Store.change_external_trust(c.store, c.credential, next)

    revoke =
      Map.merge(next, %{"action" => "revoke", "inspection_ref" => nil, "acknowledgement" => nil})

    assert {:ok, revoked} = Store.change_external_trust(c.store, c.credential, revoke)

    twice =
      Map.merge(revoke, %{
        "operation_id" => "trust:twice",
        "expected_revision" => revoked["revision"],
        "expected_trust_revision" => revoked["revision"],
        "expected_policy_generation" => 2
      })

    assert {:error, :external_already_revoked} =
             Store.change_external_trust(c.store, c.credential, twice)

    assert {:ok, ^approved} = Store.change_external_trust(c.store, c.credential, i)
    assert {:ok, revision} = Store.revision(c.store)
    assert revision == revoked["revision"]
  end

  test "actual producer loss leaves original approval and metadata revoke available", c do
    i = prepare_external_trust(c, "temperature")
    assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)
    producer_path = :code.which(Wotex.Profiles.Binding) |> List.to_string() |> Path.dirname()
    true = Code.delete_path(producer_path)
    :code.purge(Wotex.Profiles.Binding)
    :code.delete(Wotex.Profiles.Binding)

    try do
      refute Code.ensure_loaded?(Wotex.Profiles.Binding)
      assert {:ok, ^approved} = Store.change_external_trust(c.store, c.credential, i)
      assert {:ok, ^approved} = Store.external_trust_status(c.store, c.credential, 1, "trust:1")

      revoke =
        Map.merge(i, %{
          "operation_id" => "trust:revoke",
          "expected_revision" => approved["revision"],
          "expected_trust_revision" => approved["revision"],
          "expected_policy_generation" => 1,
          "action" => "revoke",
          "inspection_ref" => nil,
          "acknowledgement" => nil
        })

      assert {:ok, revoked} = Store.change_external_trust(c.store, c.credential, revoke)

      next =
        Map.merge(i, %{
          "operation_id" => "trust:again",
          "expected_revision" => revoked["revision"],
          "expected_trust_revision" => revoked["revision"],
          "expected_policy_generation" => 2
        })

      assert {:error, :profiles_producer_unavailable} =
               Store.change_external_trust(c.store, c.credential, next)

      assert {:ok, revision} = Store.revision(c.store)
      assert revision == revoked["revision"]
      assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    after
      true = Code.prepend_path(producer_path)
      assert Code.ensure_loaded?(Wotex.Profiles.Binding)
    end
  end

  test "new approval refuses missing owned bytes and a changed host capture after restart", c do
    i = prepare_external_trust(c, "temperature")

    profile =
      fixture("external-trust")["temperature"]["artifact"]["objects"]
      |> Enum.find(&(&1["kind"] == "profile"))

    path = Path.join([c.root, "profiles", profile["object_digest"] <> ".json"])
    bytes = File.read!(path)
    File.rm!(path)

    assert {:error, :authoring_object_unavailable} =
             Store.change_external_trust(c.store, c.credential, i)

    File.write!(path, bytes)
    File.chmod!(path, 0o400)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    capture = Map.put(c.reader.inputs["capture"], "capture_epoch", String.duplicate("d", 32))

    {:ok, digest} =
      Wotex.Profiles.Capture.digest(
        Map.delete(capture, "digest"),
        hd(c.reader.inputs["installed"]["bindings"]),
        c.reader.inputs["reader_limits"]
      )

    capture = Map.put(capture, "digest", digest)

    {:ok, reader} =
      WotexHome.Profiles.ReaderSelection.new(
        c.reader.inputs["installed"],
        capture,
        c.reader.inputs["reader_limits"]
      )

    stop_supervised(Store)

    store =
      start_supervised!(
        {Store, path: c.path, profile_custody: c.custody, external_reader: reader, name: @owner}
      )

    assert {:error, :stale_external_basis} = Store.change_external_trust(store, c.credential, i)
    assert {:ok, revision} = Store.revision(store)
    assert revision == i["expected_revision"]
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "external approval SQL fault rolls back first manifest, policy counter and journal", c do
    i = prepare_external_trust(c, "temperature")
    db = :sys.get_state(c.store).db

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TEMP TRIGGER refuse_trust BEFORE INSERT ON profile_external_trust_operations BEGIN SELECT RAISE(ABORT,'fixture'); END"
      )

    assert {:error, :store_unavailable} = Store.change_external_trust(c.store, c.credential, i)
    assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_external_trust_operations")
    assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_external_artifacts")

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT value FROM meta WHERE key='external_profile_policy_generation'"
             )

    assert {:ok, [[revision]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")
    assert revision == i["expected_revision"]
    assert :ok = Integrity.validate_snapshot(db)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "another operator reapproves identical owned bytes without changing first artifact metadata or old originals",
       c do
    session = prepare_external_trust_session(c, "temperature")
    i = session.input
    assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)

    assert {:ok, ended} =
             Store.end_maintenance(
               c.store,
               session.manager,
               1,
               "maint:end",
               approved["revision"],
               session.begin_revision
             )

    {:ok, other, revision} = Store.provision_principal(c.store, "other:1", ["profile:manage"], [])
    assert revision > ended.revision
    other_c = %{c | credential: other}
    inspection_input = inspection_input(other_c, "temperature", revision)
    assert {:ok, original} = Store.inspect_external_profile(c.store, other, inspection_input)

    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, session.manager, 1, "maint:2", original["revision"])

    revoke =
      Map.merge(i, %{
        "operation_id" => "other:revoke",
        "expected_revision" => barrier.revision,
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => 1,
        "action" => "revoke",
        "inspection_ref" => nil,
        "acknowledgement" => nil
      })

    assert {:ok, revoked} = Store.change_external_trust(c.store, other, revoke)

    again =
      Map.merge(i, %{
        "operation_id" => "other:approve",
        "expected_revision" => revoked["revision"],
        "expected_trust_revision" => revoked["revision"],
        "expected_policy_generation" => 2,
        "inspection_ref" =>
          Map.take(original, ~w(authority_epoch operation_id revision input_sha256 result_sha256))
      })

    assert {:ok, reapproved} = Store.change_external_trust(c.store, other, again)
    assert reapproved["artifact_first_approval_revision"] == approved["revision"]
    assert {:ok, catalogue} = Store.external_profile_catalogue(c.store, other)
    assert hd(catalogue["items"])["trust_author"] == "other:1"
    assert {:ok, ^approved} = Store.change_external_trust(c.store, c.credential, i)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "withdrawn approving permission blocks original reads and current approval while another manager can revoke",
       c do
    i = prepare_external_trust(c, "temperature")
    assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)
    {:ok, other, _} = Store.provision_principal(c.store, "other:1", ["profile:manage"], [])
    {:ok, revision} = Store.revoke_principal(c.store, "author:1")
    assert {:ok, catalogue} = Store.external_profile_catalogue(c.store, other)
    assert hd(catalogue["items"])["state"] == "author_unavailable"
    assert {:error, :unauthorized} = Store.change_external_trust(c.store, c.credential, i)

    assert {:error, :unauthorized} =
             Store.external_trust_status(c.store, c.credential, 1, "trust:1")

    revoke =
      Map.merge(i, %{
        "operation_id" => "other:revoke",
        "expected_revision" => revision,
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => 1,
        "action" => "revoke",
        "inspection_ref" => nil,
        "acknowledgement" => nil
      })

    assert {:ok, _} = Store.change_external_trust(c.store, other, revoke)
    assert {:ok, catalogue} = Store.external_profile_catalogue(c.store, other)
    assert hd(catalogue["items"])["state"] == "revoked"
  end

  test "different bytes with an already retained label conflict permanently after revocation",
       c do
    session = prepare_external_trust_session(c, "temperature")
    i = session.input
    assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)

    revoke =
      Map.merge(i, %{
        "operation_id" => "trust:2",
        "expected_revision" => approved["revision"],
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => 1,
        "action" => "revoke",
        "inspection_ref" => nil,
        "acknowledgement" => nil
      })

    assert {:ok, revoked} = Store.change_external_trust(c.store, c.credential, revoke)

    assert {:ok, ended} =
             Store.end_maintenance(
               c.store,
               session.manager,
               1,
               "maint:end",
               revoked["revision"],
               session.begin_revision
             )

    envelope =
      put_in(
        fixture("temperature")["envelope"],
        ["provenance", "publisher"],
        "different attribution"
      )

    {:ok, bytes} = Wotex.JSON.encode(envelope)
    handle = import(c, "envelope", bytes, ended.revision, "variant:envelope")

    altered =
      session.inspection_input
      |> Map.merge(%{
        "operation_id" => "inspection:variant",
        "expected_revision" => ended.revision + 1
      })
      |> put_in(["inspection", "envelope_ref"], handle)

    assert {:ok, inspection} = Store.inspect_external_profile(c.store, c.credential, altered)
    artifact = fixture("external-trust")["temperature"]["artifact"]
    {:ok, object} = AuthoringObject.new("envelope", bytes)
    {:ok, summary} = AuthoringObject.summary(object)
    artifact = put_in(artifact, ["objects", Access.at(0)], Map.put(summary, "reference", nil))
    {:ok, digest} = WotexHome.Profiles.ExternalArtifact.identity(artifact)
    assert digest != i["artifact_digest"]

    assert {:ok, barrier} =
             Store.begin_maintenance(
               c.store,
               session.manager,
               1,
               "maint:2",
               inspection["revision"]
             )

    other =
      Map.merge(i, %{
        "operation_id" => "trust:variant",
        "artifact_digest" => digest,
        "expected_revision" => barrier.revision,
        "expected_policy_generation" => 2,
        "inspection_ref" =>
          Map.take(
            inspection,
            ~w(authority_epoch operation_id revision input_sha256 result_sha256)
          )
      })

    assert {:error, :external_label_conflict} =
             Store.change_external_trust(c.store, c.credential, other)

    assert {:ok, revision} = Store.revision(c.store)
    assert revision == barrier.revision
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  for damage <- ~w(manifest counter journal orphan) do
    @trust_damage damage
    test "external trust #{@trust_damage} corruption fails closed and fences later writes", c do
      i = prepare_external_trust(c, "temperature")
      assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)
      db = :sys.get_state(c.store).db

      case @trust_damage do
        "manifest" ->
          {:ok, [[doc]]} =
            SQL.query(db, "SELECT artifact_document FROM profile_external_artifacts")

          {:ok, manifest} = WotexHome.Profiles.ExternalArtifact.decode(doc)

          {:ok, doc} =
            WotexHome.Profiles.ExternalArtifact.encode(Map.put(manifest, "id", "changed:label"))

          {:ok, []} =
            SQL.query(
              db,
              "UPDATE profile_external_artifacts SET id='changed:label',artifact_document=?",
              [doc]
            )

        "counter" ->
          {:ok, []} =
            SQL.query(
              db,
              "UPDATE meta SET value=2 WHERE key='external_profile_policy_generation'"
            )

        "journal" ->
          {:ok, []} =
            SQL.query(db, "UPDATE authority_journal SET entity_id='wrong' WHERE revision=?", [
              approved["revision"]
            ])

        "orphan" ->
          {:ok, []} = SQL.query(db, "DELETE FROM profile_external_trust_operations")
      end

      assert {:error, :corrupt_external_trust} = Integrity.validate_snapshot(db)

      assert {:error, :corrupt_external_trust} =
               Store.external_profile_catalogue(c.store, c.credential)

      assert {:error, :store_unavailable} = Store.change_external_trust(c.store, c.credential, i)
    end
  end

  test "external approvals retain exact decisions in encrypted quarantine and database-only dependency declarations",
       c do
    i = prepare_external_trust(c, "temperature")
    assert {:ok, approved} = Store.change_external_trust(c.store, c.credential, i)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "trust.backup")
    assert {:ok, _} = Store.export_profile_backup(c.store, archive, key)
    assert {:ok, _} = Backup.verify(archive, key)
    target = Path.join(c.root, "trust-quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, key, target)
    {:ok, db} = Sqlite3.open(Path.join(target, "home.sqlite"))
    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, [[doc]]} =
             SQL.query(db, "SELECT receipt_document FROM profile_external_trust_operations")

    assert {:ok, ^approved} = WotexHome.Profiles.ExternalTrust.decode_receipt(doc)
    Sqlite3.close(db)
    database = Path.join(c.root, "trust-db.backup")
    assert {:ok, _} = Store.export_backup(c.store, database, key)
    assert {:ok, report} = Backup.verify(database, key)
    refute report.dependencies.authoring_bytes_included
  end

  test "actual schema 32 migration grants no trust to retained inspections", c do
    i = inspection_input(c, "temperature")
    assert {:ok, original} = Store.inspect_external_profile(c.store, c.credential, i)
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE IF EXISTS profile_external_observation_current; DROP TABLE IF EXISTS profile_external_observation_sequences; DROP TABLE IF EXISTS profile_external_observations; DROP TABLE IF EXISTS profile_external_source_bindings; DROP TABLE IF EXISTS profile_external_target_current; DROP TABLE IF EXISTS profile_external_target_history; DROP TABLE IF EXISTS profile_external_target_operations; DROP TABLE profile_external_trust_operations; DROP TABLE profile_external_artifacts; DELETE FROM meta WHERE key='external_profile_policy_generation'; PRAGMA user_version=32;"
      )

    assert :ok = Integrity.validate_schema_version(32, db)
    Sqlite3.close(db)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    assert {:ok, [[35]]} = SQL.query(:sys.get_state(store).db, "PRAGMA user_version")

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(store).db,
               "SELECT COUNT(*) FROM profile_external_artifacts"
             )

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(store).db,
               "SELECT value FROM meta WHERE key='external_profile_policy_generation'"
             )

    assert {:ok, ^original} =
             Store.external_inspection_status(store, c.credential, 1, "inspection:1")
  end

  defp review_candidate(c, family, change \\ fn f -> f end, draft_bytes \\ nil) do
    v = fixture("authoring-sources")[family]
    source = import(c, "source", v["source"]["payload"], 1, "source:1")
    ref = import(c, "draft", draft_bytes || draft(family), 2, "draft:1")
    fixtures = fixture("authoring-fixtures")[family]["fixtures"] |> change.()

    {refs, revision} =
      Enum.map_reduce(Enum.with_index(fixtures), 3, fn {f, index}, revision ->
        bytes = if is_binary(f), do: f, else: JSON.encode!(f)
        handle = import(c, "fixture", bytes, revision, "fixture:#{index}")
        {handle, revision + 1}
      end)

    envelope =
      import(c, "envelope", JSON.encode!(fixture(family)["envelope"]), revision, "envelope:1")

    i =
      input(c, ref, revision + 1)
      |> put_in(["request", "source_refs"], [source])
      |> put_in(["request", "fixture_refs"], Enum.sort_by(refs, & &1["object_digest"]))

    {:ok, candidate} = Store.assess_authoring_candidate(c.store, c.credential, i)
    %{candidate: candidate, envelope: envelope, evidence: v["evidence"], draft: ref}
  end

  defp review_input(prepared, mode, operation \\ "review:1") do
    c = prepared.candidate

    %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => c["revision"],
      "review" => %{
        "mode" => mode,
        "candidate_ref" =>
          Map.take(c, ~w(authority_epoch operation_id revision input_sha256 assessment_sha256)),
        "evidence" => prepared.evidence,
        "unresolved_paths" => [],
        "envelope_ref" => if(mode == "complete", do: prepared.envelope)
      }
    }
  end

  for family <- ~w(temperature research) do
    @family family
    test "#{@family} source and complete review retain separate outcomes and immutable originals",
         c do
      prepared = review_candidate(c, @family)
      source = review_input(prepared, "source")

      assert {:ok, receipt} =
               Authority.review_authoring_candidate(c.authority, c.credential, source)

      assert receipt["source_review"] == "attributed" and
               receipt["fixture_status"] == "not_assessed"

      assert receipt["proposal_status"] == "incomplete" and
               receipt["home_consumption"] == "not_assessed"

      assert {:ok, ^receipt} = Store.review_authoring_candidate(c.store, c.credential, source)

      complete =
        review_input(prepared, "complete", "review:2")
        |> Map.put("expected_revision", receipt["revision"])

      assert {:ok, checked} = Store.review_authoring_candidate(c.store, c.credential, complete)
      assert checked["source_review"] == "attributed" and checked["fixture_status"] == "passed"
      assert checked["home_consumption"] == "matched" and checked["proposal_status"] == "complete"
      assert {:ok, ^checked} = Store.authoring_review_status(c.store, c.credential, 1, "review:2")
      assert {:ok, ^checked} = Store.review_authoring_candidate(c.store, c.credential, complete)

      assert {:error, :authoring_operation_conflict} =
               Store.review_authoring_candidate(
                 c.store,
                 c.credential,
                 put_in(complete, ["review", "unresolved_paths"], [
                   hd(prepared.evidence)["instance_path"]
                 ])
               )

      assert {:ok, original} =
               Store.authoring_candidate_status(c.store, c.credential, 1, "candidate:1")

      assert original == prepared.candidate
      assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
      assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
    end
  end

  test "missing/unresolved source and failed independent fixtures cannot become complete proposals",
       c do
    prepared =
      review_candidate(c, "temperature", fn [normal, sentinel] ->
        [
          put_in(normal, ["expected", "normalized_value"], %{"type" => "sint", "value" => "99"}),
          sentinel
        ]
      end)

    i = review_input(prepared, "complete") |> put_in(["review", "evidence"], [])
    assert {:ok, receipt} = Store.review_authoring_candidate(c.store, c.credential, i)
    assert receipt["source_review"] == "incomplete" and receipt["fixture_status"] == "failed"
    assert receipt["proposal_status"] == "incomplete"

    i =
      review_input(prepared, "source", "review:2")
      |> Map.put("expected_revision", receipt["revision"])
      |> put_in(["review", "unresolved_paths"], [hd(prepared.evidence)["instance_path"]])

    assert {:ok, receipt} = Store.review_authoring_candidate(c.store, c.credential, i)
    assert receipt["source_review"] == "incomplete"
  end

  test "review originals survive missing payload/configuration and restart without renewed computation",
       c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")
    assert {:ok, receipt} = Store.review_authoring_candidate(c.store, c.credential, i)
    File.rm!(Path.join([c.root, "profiles", prepared.draft["object_digest"] <> ".json"]))
    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    assert {:ok, ^receipt} = Store.review_authoring_candidate(store, c.credential, i)
    assert {:ok, ^receipt} = Store.authoring_review_status(store, c.credential, 1, "review:1")
    expected = receipt["revision"]
    assert {:ok, ^expected} = Store.revision(store)
  end

  test "review SQL fault rolls back journal/result/revision and releases every temporary byte lease",
       c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")
    db = :sys.get_state(c.store).db

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TEMP TRIGGER refuse_review BEFORE INSERT ON profile_authoring_reviews BEGIN SELECT RAISE(ABORT,'fixture'); END"
      )

    assert {:error, :store_unavailable} =
             Store.review_authoring_candidate(c.store, c.credential, i)

    assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_reviews")
    assert {:ok, [[revision]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")
    assert revision == prepared.candidate["revision"]

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_candidate_reviewed'"
             )

    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    assert :ok = Integrity.validate_snapshot(db)
  end

  test "duplicate fixture JSON refuses before retaining review metadata", c do
    prepared =
      review_candidate(c, "temperature", fn [f | _] ->
        ["{\"id\":\"duplicate\"," <> String.slice(JSON.encode!(f), 1..-1//1)]
      end)

    i = review_input(prepared, "complete")

    assert {:error, :invalid_authoring_fixture} =
             Store.review_authoring_candidate(c.store, c.credential, i)

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(c.store).db,
               "SELECT COUNT(*) FROM profile_authoring_reviews"
             )

    assert {:ok, revision} = Store.revision(c.store)
    assert revision == prepared.candidate["revision"]
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "changed selected contract and mismatched capture refuse new reviews without changing originals",
       c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")
    assert {:ok, original} = Store.review_authoring_candidate(c.store, c.credential, i)

    next =
      Map.merge(i, %{"operation_id" => "review:next", "expected_revision" => original["revision"]})

    limits = Map.update!(c.contract.inputs["limits"], "max_check_steps", &(&1 - 1))
    {:ok, changed} = AuthoringContract.export(c.contract.inputs["installed"], limits)
    stop_supervised(Store)

    store =
      start_supervised!(
        {Store,
         path: c.path,
         profile_custody: c.custody,
         authoring_contract: changed,
         authoring_capture: fixture("temperature")["capture"],
         name: @owner}
      )

    assert {:error, :stale_authoring_basis} =
             Store.review_authoring_candidate(store, c.credential, next)

    assert {:ok, ^original} = Store.review_authoring_candidate(store, c.credential, i)
    stop_supervised(Store)
    capture = put_in(fixture("temperature")["capture"], ["fields", "model", "value"], "unmatched")

    {:ok, digest} =
      Wotex.Profiles.Capture.digest(
        Map.delete(capture, "digest"),
        hd(c.contract.inputs["installed"]["bindings"]),
        c.contract.inputs["limits"]["reader"]
      )

    capture = Map.put(capture, "digest", digest)

    store =
      start_supervised!(
        {Store,
         path: c.path,
         profile_custody: c.custody,
         authoring_contract: c.contract,
         authoring_capture: capture,
         name: @owner}
      )

    assert {:error, :invalid_external_closure} =
             Store.review_authoring_candidate(store, c.credential, next)

    assert {:ok, ^original} = Store.review_authoring_candidate(store, c.credential, i)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "review original replay precedes maintenance and absent producer checks", c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")
    assert {:ok, original} = Store.review_authoring_candidate(c.store, c.credential, i)
    producer_path = :code.which(Wotex.Profiles.Artifacts) |> List.to_string() |> Path.dirname()
    true = Code.delete_path(producer_path)
    :code.purge(Wotex.Profiles.Artifacts)
    :code.delete(Wotex.Profiles.Artifacts)

    try do
      refute Code.ensure_loaded?(Wotex.Profiles.Artifacts)
      assert {:ok, ^original} = Store.review_authoring_candidate(c.store, c.credential, i)

      assert {:ok, ^original} =
               Store.authoring_review_status(c.store, c.credential, 1, "review:1")

      assert {:error, :profiles_producer_unavailable} =
               Store.review_authoring_candidate(
                 c.store,
                 c.credential,
                 Map.merge(i, %{
                   "operation_id" => "review:absent",
                   "expected_revision" => original["revision"]
                 })
               )
    after
      true = Code.prepend_path(producer_path)
      assert Code.ensure_loaded?(Wotex.Profiles.Artifacts)
    end

    {:ok, manager, revision} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    assert {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", revision)

    assert {:error, :maintenance_active} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               Map.merge(i, %{
                 "operation_id" => "review:maintenance",
                 "expected_revision" => barrier.revision
               })
             )

    assert {:ok, ^original} = Store.review_authoring_candidate(c.store, c.credential, i)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "review current CAS, epoch, candidate reference, permission and capture selection remain independent guards",
       c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")

    assert {:error, :resnapshot_required} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "expected_revision", 0)
             )

    assert {:error, :stale_authority_epoch} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "authority_epoch", 2)
             )

    assert {:error, :stale_authoring_reference} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               put_in(
                 i,
                 ["review", "candidate_ref", "assessment_sha256"],
                 String.duplicate("0", 64)
               )
             )

    {:ok, other, next} = Store.provision_principal(c.store, "other:1", ["profile:manage"], [])

    assert :not_found =
             Store.review_authoring_candidate(
               c.store,
               other,
               Map.put(i, "expected_revision", next)
             )

    stop_supervised(Store)

    store =
      start_supervised!(
        {Store,
         path: c.path, profile_custody: c.custody, authoring_contract: c.contract, name: @owner}
      )

    assert {:error, :authoring_capture_unavailable} =
             Store.review_authoring_candidate(
               store,
               c.credential,
               Map.put(i, "expected_revision", next)
             )

    source =
      put_in(i, ["review", "mode"], "source")
      |> put_in(["review", "envelope_ref"], nil)
      |> Map.put("expected_revision", next)

    assert {:ok, _} = Store.review_authoring_candidate(store, c.credential, source)
    {:ok, _} = Store.revoke_principal(store, "author:1")

    assert {:error, :unauthorized} =
             Store.authoring_review_status(store, c.credential, 1, "review:1")

    assert {:error, :unauthorized} = Store.review_authoring_candidate(store, c.credential, source)
  end

  test "changed review evidence digest fails correspondence even after receipt result hash is updated",
       c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")
    assert {:ok, _} = Store.review_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[document, receipt_doc]]} =
      SQL.query(db, "SELECT result_document,receipt_document FROM profile_authoring_reviews")

    {:ok, result} = WotexHome.Profiles.AuthoringReview.decode_result(document)
    {:ok, receipt} = WotexHome.Profiles.AuthoringReview.decode_receipt(receipt_doc)
    result = put_in(result, ["source", "evidence_sha256"], String.duplicate("0", 64))
    {:ok, document} = WotexHome.Profiles.AuthoringReview.encode_result(result)

    {:ok, receipt_doc} =
      WotexHome.Profiles.AuthoringReview.encode_receipt(
        Map.put(receipt, "result_sha256", sha(document))
      )

    {:ok, []} =
      SQL.query(db, "UPDATE profile_authoring_reviews SET result_document=?,receipt_document=?", [
        document,
        receipt_doc
      ])

    assert {:error, :corrupt_authoring_reviews} = Integrity.validate_snapshot(db)

    assert {:error, :corrupt_authoring_reviews} =
             Store.authoring_review_status(c.store, c.credential, 1, "review:1")

    assert {:error, :store_unavailable} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "operation_id", "next")
             )
  end

  for damage <- ~w(candidate journal orphan) do
    @damage damage
    test "#{@damage} review metadata corruption refuses reads and fences subsequent writes", c do
      alias WotexHome.Profiles.AuthoringReview
      prepared = review_candidate(c, "temperature")
      i = review_input(prepared, "source")
      assert {:ok, receipt} = Store.review_authoring_candidate(c.store, c.credential, i)
      db = :sys.get_state(c.store).db

      case @damage do
        "candidate" ->
          changed =
            put_in(i, ["review", "candidate_ref", "assessment_sha256"], String.duplicate("0", 64))

          {:ok, document} = AuthoringReview.encode(changed)

          {:ok, receipt_doc} =
            AuthoringReview.encode_receipt(Map.put(receipt, "input_sha256", sha(document)))

          {:ok, []} =
            SQL.query(
              db,
              "UPDATE profile_authoring_reviews SET input_document=?,receipt_document=?",
              [document, receipt_doc]
            )

        "journal" ->
          {:ok, []} =
            SQL.query(db, "UPDATE authority_journal SET entity_id='wrong' WHERE revision=?", [
              receipt["revision"]
            ])

        "orphan" ->
          {:ok, []} = SQL.query(db, "DELETE FROM profile_authoring_reviews")
      end

      assert {:error, :corrupt_authoring_reviews} = Integrity.validate_snapshot(db)

      assert {:error, :corrupt_authoring_reviews} =
               Store.authoring_review_status(c.store, c.credential, 1, "review:1")

      assert {:error, :store_unavailable} =
               Store.review_authoring_candidate(c.store, c.credential, i)
    end
  end

  test "reviews preserve exact original metadata in inclusive and database-only quarantine recovery",
       c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "complete")
    assert {:ok, receipt} = Store.review_authoring_candidate(c.store, c.credential, i)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "reviews.backup")
    assert {:ok, _} = Store.export_profile_backup(c.store, archive, key)
    assert {:ok, _} = Backup.verify(archive, key)
    target = Path.join(c.root, "review-quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, key, target)
    {:ok, db} = Sqlite3.open(Path.join(target, "home.sqlite"))
    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, [[doc]]} =
             SQL.query(db, "SELECT receipt_document FROM profile_authoring_reviews")

    assert {:ok, ^receipt} = WotexHome.Profiles.AuthoringReview.decode_receipt(doc)
    Sqlite3.close(db)
    database = Path.join(c.root, "review-db.backup")
    assert {:ok, _} = Store.export_backup(c.store, database, key)
    assert {:ok, report} = Backup.verify(database, key)
    refute report.dependencies.authoring_bytes_included

    assert {:error, :profile_bytes_missing} =
             Backup.stage_profile_restore(database, key, Path.join(c.root, "missing"))
  end

  test "schema 30 migration preserves candidate receipts and grants no source review", c do
    prepared = review_candidate(c, "temperature")
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE IF EXISTS profile_external_observation_current; DROP TABLE IF EXISTS profile_external_observation_sequences; DROP TABLE IF EXISTS profile_external_observations; DROP TABLE IF EXISTS profile_external_source_bindings; DROP TABLE IF EXISTS profile_external_target_current; DROP TABLE IF EXISTS profile_external_target_history; DROP TABLE IF EXISTS profile_external_target_operations; DROP TABLE profile_external_trust_operations; DROP TABLE profile_external_artifacts; DELETE FROM meta WHERE key='external_profile_policy_generation'; DROP TABLE profile_external_inspections; DROP TABLE profile_authoring_reviews; PRAGMA user_version=30;"
      )

    assert :ok = Integrity.validate_schema_version(30, db)
    Sqlite3.close(db)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    expected = prepared.candidate["revision"]
    assert {:ok, ^expected} = Store.revision(store)
    assert {:ok, [[35]]} = SQL.query(:sys.get_state(store).db, "PRAGMA user_version")

    assert {:ok, [[0]]} =
             SQL.query(:sys.get_state(store).db, "SELECT COUNT(*) FROM profile_authoring_reviews")

    assert {:ok, receipt} =
             Store.authoring_candidate_status(store, c.credential, 1, "candidate:1")

    assert receipt == prepared.candidate
  end

  defp retain_fixture_row(db, input, assessment_document, base_receipt) do
    revision = input["expected_revision"] + 1
    {:ok, document} = AuthoringCandidate.encode(input)

    receipt =
      Map.merge(base_receipt, %{
        "operation_id" => input["operation_id"],
        "revision" => revision,
        "input_sha256" => sha(document),
        "assessment_sha256" => sha(assessment_document)
      })

    {:ok, receipt_document} = AuthoringCandidate.encode_receipt(receipt)

    {:ok, []} =
      SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
        revision,
        "authoring_candidate_assessed",
        input["operation_id"]
      ])

    {:ok, []} =
      SQL.query(db, "INSERT INTO profile_authoring_candidates VALUES (?,?,?,?,?,?,?)", [
        "author:1",
        1,
        input["operation_id"],
        document,
        assessment_document,
        receipt_document,
        revision
      ])

    {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [revision])
    {revision, byte_size(document), byte_size(assessment_document)}
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp retain_trust_fixture(db, input, outcome, first, generation, policy) do
    alias WotexHome.Profiles.{ExternalInspection, ExternalTrust}
    {:ok, document} = ExternalTrust.encode(input)
    {:ok, outcome_document} = ExternalTrust.encode_outcome(outcome)
    revision = input["expected_revision"] + 1

    basis =
      if input["action"] == "approve" do
        {:ok, inspection} = ExternalInspection.decode_result(outcome["inspection_document"])
        inspection["reader_basis_sha256"]
      end

    receipt = %{
      "authority_epoch" => 1,
      "operation_id" => input["operation_id"],
      "revision" => revision,
      "input_sha256" => sha(document),
      "action" => input["action"],
      "artifact_digest" => input["artifact_digest"],
      "previous_trust_revision" => input["expected_trust_revision"],
      "trust_generation" => generation,
      "policy_generation" => policy,
      "artifact_first_approval_revision" => first,
      "reader_basis_sha256" => basis,
      "outcome_sha256" => sha(outcome_document)
    }

    {:ok, receipt_document} = ExternalTrust.encode_receipt(receipt)

    event =
      if input["action"] == "approve",
        do: "external_profile_approved",
        else: "external_profile_revoked"

    {:ok, []} =
      SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
        revision,
        event,
        input["artifact_digest"]
      ])

    {:ok, []} =
      SQL.query(db, "INSERT INTO profile_external_trust_operations VALUES (?,?,?,?,?,?,?)", [
        "author:1",
        1,
        input["operation_id"],
        document,
        outcome_document,
        receipt_document,
        revision
      ])

    {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [revision])

    {:ok, []} =
      SQL.query(db, "UPDATE meta SET value=? WHERE key='external_profile_policy_generation'", [
        policy
      ])

    {revision, byte_size(outcome_document)}
  end

  test "1024 alternating retained trust decisions refuse further work but preserve the original",
       c do
    alias WotexHome.Profiles.ExternalTrust
    i = prepare_external_trust(c, "temperature")
    assert {:ok, first} = Store.change_external_trust(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[outcome_doc]]} =
      SQL.query(db, "SELECT outcome_document FROM profile_external_trust_operations")

    {:ok, approved_outcome} = ExternalTrust.decode_outcome(outcome_doc)

    revoked_outcome =
      Map.merge(approved_outcome, %{
        "action" => "revoke",
        "inspection_ref" => nil,
        "artifact_document" => nil,
        "inspection_document" => nil
      })

    :ok = Sqlite3.execute(db, "BEGIN")

    revision =
      Enum.reduce(2..1024, first["revision"], fn generation, revision ->
        approve = rem(generation, 2) == 1
        action = if approve, do: "approve", else: "revoke"

        next =
          Map.merge(i, %{
            "operation_id" => "trust:#{generation}",
            "expected_revision" => revision,
            "expected_trust_revision" => revision,
            "expected_policy_generation" => generation - 1,
            "action" => action,
            "inspection_ref" => if(approve, do: i["inspection_ref"]),
            "acknowledgement" => if(approve, do: "operator_digest_approval")
          })

        {revision, _} =
          retain_trust_fixture(
            db,
            next,
            if(approve, do: approved_outcome, else: revoked_outcome),
            first["revision"],
            generation,
            generation
          )

        revision
      end)

    :ok = Sqlite3.execute(db, "COMMIT")
    assert :ok = Integrity.validate_snapshot(db)

    next =
      Map.merge(i, %{
        "operation_id" => "trust:over",
        "expected_revision" => revision,
        "expected_trust_revision" => revision,
        "expected_policy_generation" => 1024
      })

    assert {:error, :external_trust_capacity} =
             Store.change_external_trust(c.store, c.credential, next)

    assert {:ok, ^first} = Store.change_external_trust(c.store, c.credential, i)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "64 real distinct envelope approvals refuse a further artifact without reopening another label",
       c do
    session = prepare_external_trust_session(c, "temperature")
    i = session.input
    assert {:ok, first} = Store.change_external_trust(c.store, c.credential, i)

    assert {:ok, ended} =
             Store.end_maintenance(
               c.store,
               session.manager,
               1,
               "maint:end",
               first["revision"],
               session.begin_revision
             )

    {variants, revision} =
      Enum.map_reduce(1..64, ended.revision, fn n, revision ->
        data = Map.put(fixture("temperature")["envelope"], "id", "portable:capacity:#{n}")
        {:ok, bytes} = Wotex.JSON.encode(data)
        handle = import(c, "envelope", bytes, revision, "capacity:envelope:#{n}")

        input =
          session.inspection_input
          |> Map.merge(%{
            "operation_id" => "inspection:capacity:#{n}",
            "expected_revision" => revision + 1
          })
          |> put_in(["inspection", "envelope_ref"], handle)

        {:ok, inspection} = Store.inspect_external_profile(c.store, c.credential, input)
        {:ok, object} = AuthoringObject.new("envelope", bytes)
        {:ok, summary} = AuthoringObject.summary(object)

        artifact =
          put_in(
            fixture("external-trust")["temperature"]["artifact"],
            ["objects", Access.at(0)],
            Map.put(summary, "reference", nil)
          )
          |> Map.put("id", data["id"])

        {:ok, digest} = WotexHome.Profiles.ExternalArtifact.identity(artifact)
        {%{digest: digest, inspection: inspection}, inspection["revision"]}
      end)

    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, session.manager, 1, "maint:2", revision)

    {accepted, [over]} = Enum.split(variants, 63)

    revision =
      Enum.reduce(Enum.with_index(accepted, 1), barrier.revision, fn {v, policy}, revision ->
        next =
          Map.merge(i, %{
            "operation_id" => "trust:capacity:#{policy}",
            "artifact_digest" => v.digest,
            "expected_revision" => revision,
            "expected_policy_generation" => policy,
            "inspection_ref" =>
              Map.take(
                v.inspection,
                ~w(authority_epoch operation_id revision input_sha256 result_sha256)
              )
          })

        assert {:ok, receipt} = Store.change_external_trust(c.store, c.credential, next)
        receipt["revision"]
      end)

    next =
      Map.merge(i, %{
        "operation_id" => "trust:over",
        "artifact_digest" => over.digest,
        "expected_revision" => revision,
        "expected_policy_generation" => 64,
        "inspection_ref" =>
          Map.take(
            over.inspection,
            ~w(authority_epoch operation_id revision input_sha256 result_sha256)
          )
      })

    assert {:error, :external_trust_capacity} =
             Store.change_external_trust(c.store, c.credential, next)

    assert {:ok, catalogue} = Store.external_profile_catalogue(c.store, c.credential)
    assert length(catalogue["items"]) == 64
    assert {:ok, ^first} = Store.change_external_trust(c.store, c.credential, i)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "real 29-channel closure reaches the outcome byte ceiling before the trust original count",
       c do
    alias WotexHome.Profiles.{ExternalArtifact, ExternalTrust}
    v = fixture("temperature")
    [definition] = v["definitions"]

    # The selected reader's 32 reachable references include the profile,
    # binding and raw-value contract, leaving room for 29 definitions.
    {definitions, revision} =
      Enum.map_reduce(1..29, 1, fn n, revision ->
        id =
          "urn:capacity:" <>
            String.duplicate("x", 235) <> String.pad_leading(Integer.to_string(n), 3, "0")

        data = Map.put(definition, "id", id)
        {:ok, reference} = Wotex.Profiles.Definition.reference(data, v["reader_limits"])
        {:ok, bytes} = Wotex.JSON.encode(data)
        handle = import(c, "definition", bytes, revision, "large:def:#{n}")
        {%{reference: reference, handle: handle}, revision + 1}
      end)

    [channel] = v["profile"]["channels"]

    channels =
      Enum.with_index(definitions, 1)
      |> Enum.map(fn {d, n} ->
        id = "channel" <> String.pad_leading(Integer.to_string(n), 3, "0")

        Map.merge(channel, %{
          "id" => id,
          "semantic" => d.reference,
          "affordance" => %{"kind" => "property", "name" => id}
        })
      end)

    profile = Map.put(v["profile"], "channels", channels)
    {:ok, profile_ref} = Wotex.Profiles.Profile.reference(profile, v["reader_limits"])
    {:ok, bytes} = Wotex.JSON.encode(profile)
    profile_handle = import(c, "profile", bytes, revision, "large:profile")
    contract_ref = hd(v["envelope"]["home_contracts"])["contract_ref"]

    envelope =
      Map.merge(v["envelope"], %{
        "id" => "portable:large",
        "profile" => profile_ref,
        "definitions" => Enum.map(definitions, & &1.reference),
        "home_contracts" =>
          Enum.map(channels, &%{"channel_id" => &1["id"], "contract_ref" => contract_ref})
      })

    {:ok, bytes} = Wotex.JSON.encode(envelope)
    envelope_handle = import(c, "envelope", bytes, revision + 1, "large:envelope")

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "inspection:large",
      "expected_revision" => revision + 2,
      "inspection" => %{
        "reader_basis_sha256" => c.reader.data["basis_sha256"],
        "envelope_ref" => envelope_handle,
        "profile" => %{"reference" => profile_ref, "object_ref" => profile_handle},
        "definitions" =>
          Enum.map(definitions, &%{"reference" => &1.reference, "object_ref" => &1.handle})
      }
    }

    assert {:ok, inspection} = Store.inspect_external_profile(c.store, c.credential, input)

    handles =
      [{envelope_handle, nil}, {profile_handle, profile_ref}] ++
        Enum.map(definitions, &{&1.handle, &1.reference})

    objects =
      Enum.map(handles, fn {handle, ref} ->
        {:ok, record} =
          Store.read_authoring_object(c.store, c.credential, handle["object_digest"])

        Map.put(record["object"], "reference", ref)
      end)

    {:ok, digest} =
      ExternalArtifact.identity(%{
        "format" => "wotex-home.external-artifact@1",
        "id" => "portable:large",
        "version" => v["envelope"]["version"],
        "objects" => objects
      })

    {:ok, manager, revision} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", revision)

    i = %{
      "authority_epoch" => 1,
      "operation_id" => "trust:large",
      "expected_revision" => barrier.revision,
      "action" => "approve",
      "artifact_digest" => digest,
      "expected_trust_revision" => 0,
      "expected_policy_generation" => 0,
      "inspection_ref" =>
        Map.take(inspection, ~w(authority_epoch operation_id revision input_sha256 result_sha256)),
      "acknowledgement" => "operator_digest_approval"
    }

    assert {:ok, first} = Store.change_external_trust(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[doc]]} =
      SQL.query(db, "SELECT outcome_document FROM profile_external_trust_operations")

    {:ok, approved} = ExternalTrust.decode_outcome(doc)

    revoked =
      Map.merge(approved, %{
        "action" => "revoke",
        "inspection_ref" => nil,
        "artifact_document" => nil,
        "inspection_document" => nil
      })

    :ok = Sqlite3.execute(db, "BEGIN")

    {revision, total, count} =
      Enum.reduce_while(2..1024, {first["revision"], byte_size(doc), 1}, fn n,
                                                                            {revision, total,
                                                                             count} ->
        approve = rem(n, 2) == 1
        outcome = if approve, do: approved, else: revoked
        {:ok, bytes} = ExternalTrust.encode_outcome(outcome)

        if total + byte_size(bytes) > 4_194_304 do
          {:halt, {revision, total, count}}
        else
          next =
            Map.merge(i, %{
              "operation_id" => "trust:capacity:#{n}",
              "expected_revision" => revision,
              "expected_trust_revision" => revision,
              "expected_policy_generation" => n - 1,
              "action" => outcome["action"],
              "inspection_ref" => outcome["inspection_ref"],
              "acknowledgement" => if(approve, do: "operator_digest_approval")
            })

          {revision, _} = retain_trust_fixture(db, next, outcome, first["revision"], n, n)
          {:cont, {revision, total + byte_size(bytes), count + 1}}
        end
      end)

    :ok = Sqlite3.execute(db, "COMMIT")
    assert count < 1024 and rem(count, 2) == 0 and total <= 4_194_304
    assert total + byte_size(doc) > 4_194_304
    assert :ok = Integrity.validate_snapshot(db)

    next =
      Map.merge(i, %{
        "operation_id" => "trust:over",
        "expected_revision" => revision,
        "expected_trust_revision" => revision,
        "expected_policy_generation" => count
      })

    assert {:error, :external_trust_capacity} =
             Store.change_external_trust(c.store, c.credential, next)

    assert {:ok, ^first} = Store.change_external_trust(c.store, c.credential, i)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  defp retain_inspection_fixture(db, input, result, original) do
    alias WotexHome.Profiles.ExternalInspection
    revision = input["expected_revision"] + 1
    {:ok, document} = ExternalInspection.encode(input)
    {:ok, result_document} = ExternalInspection.encode_result(result)

    receipt =
      Map.merge(original, %{
        "operation_id" => input["operation_id"],
        "revision" => revision,
        "input_sha256" => sha(document),
        "result_sha256" => sha(result_document)
      })

    {:ok, receipt_document} = ExternalInspection.encode_receipt(receipt)

    {:ok, []} =
      SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
        revision,
        "external_profile_inspected",
        input["operation_id"]
      ])

    {:ok, []} =
      SQL.query(db, "INSERT INTO profile_external_inspections VALUES (?,?,?,?,?,?,?)", [
        "author:1",
        1,
        input["operation_id"],
        document,
        result_document,
        receipt_document,
        revision
      ])

    {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [revision])
    {revision, byte_size(document), byte_size(result_document)}
  end

  test "1024 retained external originals refuse new work while retaining exact replay", c do
    i = inspection_input(c, "temperature")
    assert {:ok, original} = Store.inspect_external_profile(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[document]]} =
      SQL.query(db, "SELECT result_document FROM profile_external_inspections")

    {:ok, result} = WotexHome.Profiles.ExternalInspection.decode_result(document)
    :ok = Sqlite3.execute(db, "BEGIN")

    for offset <- 1..1023 do
      retain_inspection_fixture(
        db,
        Map.merge(i, %{
          "operation_id" => "inspection:#{offset + 1}",
          "expected_revision" => original["revision"] + offset - 1
        }),
        result,
        original
      )
    end

    :ok = Sqlite3.execute(db, "COMMIT")
    revision = original["revision"] + 1023
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :external_inspection_capacity} =
             Store.inspect_external_profile(
               c.store,
               c.credential,
               Map.merge(i, %{
                 "operation_id" => "inspection:over",
                 "expected_revision" => revision
               })
             )

    assert {:ok, ^original} = Store.inspect_external_profile(c.store, c.credential, i)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  for dimension <- ~w(input result) do
    @dimension dimension
    test "external #{@dimension} byte capacity refuses below the original count ceiling", c do
      alias WotexHome.Profiles.ExternalInspection
      i = inspection_input(c, "temperature")
      assert {:ok, original} = Store.inspect_external_profile(c.store, c.credential, i)
      db = :sys.get_state(c.store).db

      {i, original} =
        if @dimension == "input" do
          # Sparse high-revision metadata isolates the input ceiling: wide
          # first-import references are absent from the result encoding.
          high = 1_000_000_000_000
          rebased = Map.put(i, "expected_revision", high - 1)
          {:ok, document} = ExternalInspection.encode(rebased)
          receipt = Map.merge(original, %{"revision" => high, "input_sha256" => sha(document)})
          {:ok, receipt_doc} = ExternalInspection.encode_receipt(receipt)
          :ok = Sqlite3.execute(db, "BEGIN")

          {:ok, []} =
            SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
              high,
              "external_profile_inspected",
              i["operation_id"]
            ])

          {:ok, []} =
            SQL.query(
              db,
              "UPDATE profile_external_inspections SET input_document=?,receipt_document=?,revision=?",
              [document, receipt_doc, high]
            )

          {:ok, []} =
            SQL.query(db, "DELETE FROM authority_journal WHERE revision=?", [original["revision"]])

          {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [high])
          :ok = Sqlite3.execute(db, "COMMIT")
          assert :ok = Integrity.validate_snapshot(db)
          {rebased, receipt}
        else
          {i, original}
        end

      {:ok, [[input_doc, result_doc]]} =
        SQL.query(db, "SELECT input_document,result_document FROM profile_external_inspections")

      {:ok, result} = ExternalInspection.decode_result(result_doc)

      {defs, revision} =
        Enum.map_reduce(1..32, original["revision"], fn n, revision ->
          id =
            "urn:capacity:" <>
              String.duplicate("x", 235) <> String.pad_leading(Integer.to_string(n), 3, "0")

          data = hd(fixture("temperature")["definitions"]) |> Map.put("id", id)

          {:ok, ref} =
            Wotex.Profiles.Definition.reference(data, fixture("temperature")["reader_limits"])

          {:ok, bytes} = Wotex.JSON.encode(data)
          handle = import(c, "definition", bytes, revision, "capacity:#{n}")
          {%{"reference" => ref, "object_ref" => handle}, revision + 1}
        end)

      large = put_in(i, ["inspection", "definitions"], defs)

      objects =
        Enum.map(defs, fn d ->
          {:ok, object} =
            Store.read_authoring_object(c.store, c.credential, d["object_ref"]["object_digest"])

          %{"reference" => d["reference"], "raw_sha256" => object["object"]["payload_sha256"]}
        end)

      [profile | _] = result["envelope"]["document_identities"]
      large_result = put_in(result, ["envelope", "document_identities"], [profile | objects])

      large_result =
        if @dimension == "result" do
          contract = hd(result["envelope"]["home_contracts"])["contract_ref"]

          channels =
            for n <- 1..32,
                do: %{
                  "channel_id" =>
                    "c" <>
                      String.duplicate("x", 123) <>
                      String.pad_leading(Integer.to_string(n), 3, "0"),
                  "contract_ref" => contract
                }

          put_in(large_result, ["envelope", "home_contracts"], channels)
        else
          large_result
        end

      # Canonical direct historical metadata fixtures exercise limits, not new producer compatibility.
      {:ok, large_doc} = ExternalInspection.encode(Map.put(large, "expected_revision", revision))
      {:ok, large_result_doc} = ExternalInspection.encode_result(large_result)

      large_size =
        if @dimension == "input", do: byte_size(large_doc), else: byte_size(large_result_doc)

      total = if @dimension == "input", do: byte_size(input_doc), else: byte_size(result_doc)
      :ok = Sqlite3.execute(db, "BEGIN")

      {revision, total, count} =
        Enum.reduce_while(1..1023, {revision, total, 1}, fn n, {revision, total, count} ->
          operation = "inspection:capacity:#{n}"

          operation =
            if @dimension == "input",
              do: String.pad_trailing(operation, 128, "x"),
              else: operation

          next =
            Map.merge(large, %{
              "operation_id" => operation,
              "expected_revision" => revision
            })

          {:ok, encoded} = ExternalInspection.encode(next)
          size = if @dimension == "input", do: byte_size(encoded), else: large_size

          if total + size > 4_194_304 do
            {:halt, {revision, total, count}}
          else
            {revision, _, _} = retain_inspection_fixture(db, next, large_result, original)
            {:cont, {revision, total + size, count + 1}}
          end
        end)

      {revision, total, count} =
        if @dimension == "result" do
          Enum.reduce_while(1..1023, {revision, total, count}, fn n, {revision, total, count} ->
            if total + byte_size(result_doc) > 4_194_304 do
              {:halt, {revision, total, count}}
            else
              next =
                Map.merge(i, %{
                  "operation_id" => "inspection:small:#{n}",
                  "expected_revision" => revision
                })

              {revision, _, _} = retain_inspection_fixture(db, next, result, original)
              {:cont, {revision, total + byte_size(result_doc), count + 1}}
            end
          end)
        else
          {revision, total, count}
        end

      :ok = Sqlite3.execute(db, "COMMIT")
      assert count < 1024 and total <= 4_194_304
      assert :ok = Integrity.validate_snapshot(db)
      next = if @dimension == "input", do: large, else: i

      operation =
        if @dimension == "input",
          do: String.pad_trailing("inspection:over", 128, "x"),
          else: "inspection:over"

      next =
        Map.merge(next, %{"operation_id" => operation, "expected_revision" => revision})

      assert {:error, :external_inspection_capacity} =
               Store.inspect_external_profile(c.store, c.credential, next)

      assert {:ok, ^original} = Store.inspect_external_profile(c.store, c.credential, i)
      assert {:ok, ^revision} = Store.revision(c.store)
      assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    end
  end

  defp retain_review_fixture(db, input, result, original) do
    alias WotexHome.Profiles.AuthoringReview
    revision = input["expected_revision"] + 1
    {:ok, document} = AuthoringReview.encode(input)
    {:ok, result_document} = AuthoringReview.encode_result(result)

    receipt =
      Map.merge(original, %{
        "operation_id" => input["operation_id"],
        "revision" => revision,
        "input_sha256" => sha(document),
        "result_sha256" => sha(result_document),
        "source_review" => result["source"]["status"],
        "proposal_status" =>
          AuthoringReview.proposal_status(
            result["source"]["status"],
            original["home_consumption"],
            original["fixture_status"]
          )
      })

    {:ok, receipt_document} = AuthoringReview.encode_receipt(receipt)

    {:ok, []} =
      SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
        revision,
        "authoring_candidate_reviewed",
        input["operation_id"]
      ])

    {:ok, []} =
      SQL.query(db, "INSERT INTO profile_authoring_reviews VALUES (?,?,?,?,?,?,?)", [
        "author:1",
        1,
        input["operation_id"],
        document,
        result_document,
        receipt_document,
        revision
      ])

    {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [revision])
    {revision, byte_size(document), byte_size(result_document)}
  end

  test "1024 review originals refuse further work while preserving exact replay", c do
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "source")
    assert {:ok, original} = Store.review_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db
    {:ok, [[document]]} = SQL.query(db, "SELECT result_document FROM profile_authoring_reviews")
    {:ok, result} = WotexHome.Profiles.AuthoringReview.decode_result(document)
    :ok = Sqlite3.execute(db, "BEGIN")

    for offset <- 1..1023 do
      retain_review_fixture(
        db,
        Map.merge(i, %{
          "operation_id" => "review:#{offset + 1}",
          "expected_revision" => original["revision"] + offset - 1
        }),
        result,
        original
      )
    end

    :ok = Sqlite3.execute(db, "COMMIT")
    revision = original["revision"] + 1023
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :authoring_review_capacity} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               Map.merge(i, %{"operation_id" => "review:over", "expected_revision" => revision})
             )

    assert {:ok, ^original} = Store.review_authoring_candidate(c.store, c.credential, i)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "review input bytes reach the exact aggregate boundary before the original count ceiling",
       c do
    alias WotexHome.Profiles.AuthoringReview
    prepared = review_candidate(c, "temperature")
    i = review_input(prepared, "source")
    assert {:ok, original} = Store.review_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[input_document, result_document]]} =
      SQL.query(
        db,
        "SELECT input_document,result_document FROM profile_authoring_reviews"
      )

    {:ok, result} = AuthoringReview.decode_result(result_document)
    [first | _] = prepared.evidence
    # Direct historical metadata fixtures exercise capacity, not new producer/source truth.
    evidence =
      for n <- 1..256,
          do: Map.put(first, "locator", String.pad_leading(Integer.to_string(n), 256, "x"))

    evidence = Enum.sort_by(evidence, &{&1["instance_path"], &1["source_ref"], &1["locator"]})
    :ok = Sqlite3.execute(db, "BEGIN")

    {revision, total, count} =
      Enum.reduce_while(1..1023, {original["revision"], byte_size(input_document), 1}, fn offset,
                                                                                          {revision,
                                                                                           total,
                                                                                           count} ->
        next =
          Map.merge(i, %{
            "operation_id" => "review:#{offset + 1}",
            "expected_revision" => revision
          })
          |> put_in(["review", "evidence"], evidence)

        {:ok, full} = AuthoringReview.encode(next)
        remaining = 4_194_304 - total
        next = if byte_size(full) <= remaining, do: next, else: fit_review_input(next, remaining)
        {:ok, document} = AuthoringReview.encode(next)
        roots = result["source"]["required_paths"]
        citations = Enum.frequencies_by(next["review"]["evidence"], & &1["instance_path"])

        source =
          Map.merge(result["source"], %{
            "evidence_sha256" => AuthoringReview.evidence_digest(next["review"]["evidence"], []),
            "covered_paths" => Enum.filter(roots, &(citations[&1] == 1)),
            "missing_paths" => Enum.filter(roots, &(citations[&1] == nil)),
            "ambiguous_paths" => Enum.filter(roots, &(Map.get(citations, &1, 0) > 1)),
            "status" =>
              if(Enum.any?(citations, fn {_, n} -> n > 1 end),
                do: "ambiguous",
                else: "incomplete"
              )
          })

        {revision, _, _} =
          retain_review_fixture(db, next, Map.put(result, "source", source), original)

        state = {revision, total + byte_size(document), count + 1}
        if elem(state, 1) == 4_194_304, do: {:halt, state}, else: {:cont, state}
      end)

    :ok = Sqlite3.execute(db, "COMMIT")
    assert total == 4_194_304 and count < 1024
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :authoring_review_capacity} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               Map.merge(i, %{"operation_id" => "review:over", "expected_revision" => revision})
             )

    assert {:ok, ^original} = Store.review_authoring_candidate(c.store, c.credential, i)
    assert {:ok, ^revision} = Store.revision(c.store)
  end

  defp fit_review_input(input, target) do
    alias WotexHome.Profiles.AuthoringReview

    evidence =
      Enum.map(
        input["review"]["evidence"],
        &Map.update!(&1, "locator", fn s -> String.slice(s, -3, 3) end)
      )

    input = fit_review_minimum(put_in(input, ["review", "evidence"], evidence), target)
    {:ok, document} = AuthoringReview.encode(input)

    {evidence, 0} =
      Enum.map_reduce(input["review"]["evidence"], target - byte_size(document), fn e,
                                                                                    remaining ->
        padding = min(253, remaining)
        {Map.update!(e, "locator", &(String.duplicate("x", padding) <> &1)), remaining - padding}
      end)

    evidence = Enum.sort_by(evidence, &{&1["instance_path"], &1["source_ref"], &1["locator"]})
    put_in(input, ["review", "evidence"], evidence)
  end

  test "review result-byte capacity refuses below 1024 originals using an actual 32-channel candidate",
       c do
    alias WotexHome.Profiles.AuthoringReview
    data = JSON.decode!(draft("temperature"))
    [channel] = data["profile"]["channels"]
    channels = for n <- 0..31, do: Map.put(channel, "id", "sample#{n}")
    bytes = JSON.encode!(put_in(data, ["profile", "channels"], channels))
    prepared = review_candidate(c, "temperature", fn _ -> [] end, bytes)
    i = review_input(prepared, "source") |> put_in(["review", "evidence"], [])
    assert {:ok, original} = Store.review_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db
    {:ok, [[document]]} = SQL.query(db, "SELECT result_document FROM profile_authoring_reviews")
    {:ok, result} = AuthoringReview.decode_result(document)
    assert length(result["source"]["required_paths"]) == 132
    size = byte_size(document)
    count = div(4_194_304, size)
    assert count < 1024
    :ok = Sqlite3.execute(db, "BEGIN")

    for offset <- 1..(count - 1) do
      retain_review_fixture(
        db,
        Map.merge(i, %{
          "operation_id" => "review:#{offset + 1}",
          "expected_revision" => original["revision"] + offset - 1
        }),
        result,
        original
      )
    end

    :ok = Sqlite3.execute(db, "COMMIT")
    revision = original["revision"] + count - 1

    assert {:ok, [[^count, total]]} =
             SQL.query(
               db,
               "SELECT COUNT(*),SUM(length(CAST(result_document AS BLOB))) FROM profile_authoring_reviews"
             )

    assert total <= 4_194_304 and total + size > 4_194_304
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :authoring_review_capacity} =
             Store.review_authoring_candidate(
               c.store,
               c.credential,
               Map.merge(i, %{"operation_id" => "review:over", "expected_revision" => revision})
             )

    assert {:ok, ^original} = Store.review_authoring_candidate(c.store, c.credential, i)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  defp fit_review_minimum(input, target) do
    {:ok, document} = WotexHome.Profiles.AuthoringReview.encode(input)

    if byte_size(document) <= target,
      do: input,
      else:
        fit_review_minimum(update_in(input, ["review", "evidence"], &Enum.drop(&1, -1)), target)
  end

  defp assessment_fixture_bytes(data, target) do
    [diagnostic] = data["report"]["diagnostics"]
    {:ok, smallest} = AuthoringCandidate.encode_assessment(data)
    two = put_in(data, ["report", "diagnostics"], [diagnostic, diagnostic])
    {:ok, second} = AuthoringCandidate.encode_assessment(two)
    increment = byte_size(second) - byte_size(smallest)
    extra = target - byte_size(smallest)
    count = min(64, div(extra, increment) + 1)
    padding = extra - (count - 1) * increment
    path = if padding == 0, do: "", else: "/" <> String.duplicate("x", padding - 1)

    diagnostics =
      List.duplicate(diagnostic, count)
      |> List.replace_at(count - 1, Map.put(diagnostic, "instance_path", path))

    {:ok, bytes} =
      AuthoringCandidate.encode_assessment(put_in(data, ["report", "diagnostics"], diagnostics))

    assert byte_size(bytes) == target
    bytes
  end

  test "the retained assessment-byte ceiling is exact and cannot be spent by another original",
       c do
    ref = import(c, "draft", "{", 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[original]]} =
      SQL.query(db, "SELECT assessment_document FROM profile_authoring_candidates")

    {:ok, data} = AuthoringCandidate.decode_assessment(original)
    # These are bounded historical metadata fixtures, not new producer truth.
    full =
      put_in(
        data,
        ["report", "diagnostics"],
        List.duplicate(hd(data["report"]["diagnostics"]), 64)
      )

    {:ok, full_document} = AuthoringCandidate.encode_assessment(full)
    :ok = Sqlite3.execute(db, "BEGIN")

    {revision, total, count} =
      Enum.reduce_while(4..1026, {3, byte_size(original), 1}, fn revision, {_, total, count} ->
        remaining = 4_194_304 - total

        if remaining == 0 do
          {:halt, {revision - 1, total, count}}
        else
          size = min(byte_size(full_document), remaining)
          leftover = remaining - size

          size =
            if leftover > 0 and leftover < byte_size(original),
              do: size - byte_size(original),
              else: size

          document = assessment_fixture_bytes(data, size)

          retain_fixture_row(
            db,
            input(c, ref, revision - 1, "candidate:#{revision}"),
            document,
            receipt
          )

          {:cont, {revision, total + size, count + 1}}
        end
      end)

    :ok = Sqlite3.execute(db, "COMMIT")
    assert total == 4_194_304 and count < 1024
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, revision, "over-assessments")
             )

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{object_count: 1, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "explicit source and fixture handles retain ownership without falsely claiming fixture comparison",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    source = import(c, "source", "independent source", 2, "import:2")
    fixture = import(c, "fixture", "[]", 3, "import:3")

    i =
      input(c, ref, 4)
      |> put_in(["request", "source_refs"], [source])
      |> put_in(["request", "fixture_refs"], [fixture])

    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    assert receipt["fixture_status"] == "not_assessed"
    assert receipt["source_review"] == "not_assessed"
    assert {:ok, ^receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    wrong = input(c, ref, 5, "candidate:2") |> put_in(["request", "source_refs"], [ref])

    assert {:error, :stale_authoring_reference} =
             Store.assess_authoring_candidate(c.store, c.credential, wrong)

    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "1024 retained originals refuse a new original before payload publication but allow exact replay",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[assessment]]} =
      SQL.query(db, "SELECT assessment_document FROM profile_authoring_candidates")

    :ok = Sqlite3.execute(db, "BEGIN")

    for revision <- 4..1026 do
      retain_fixture_row(
        db,
        input(c, ref, revision - 1, "candidate:#{revision}"),
        assessment,
        receipt
      )
    end

    :ok = Sqlite3.execute(db, "COMMIT")
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 1026, "over-bound")
             )

    assert {:ok, ^receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    assert {:ok, 1026} = Store.revision(c.store)
    assert {:ok, %{object_count: 2, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "the retained input-byte ceiling refuses even below the original count bound", c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[assessment, original]]} =
      SQL.query(db, "SELECT assessment_document,input_document FROM profile_authoring_candidates")

    :ok = Sqlite3.execute(db, "BEGIN")

    {revision, total, count} =
      Enum.reduce_while(4..1026, {3, byte_size(original), 1}, fn revision, {_, total, count} ->
        next =
          input(c, ref, revision - 1, "candidate:#{revision}")
          |> put_in(["request", "instruction"], String.duplicate("x", 4096))

        {:ok, doc} = AuthoringCandidate.encode(next)

        if total + byte_size(doc) <= 4_194_304 do
          retain_fixture_row(db, next, assessment, receipt)
          {:cont, {revision, total + byte_size(doc), count + 1}}
        else
          remaining = 4_194_304 - total

          next =
            put_in(
              next,
              ["request", "instruction"],
              String.duplicate("x", max(0, 4096 - (byte_size(doc) - remaining)))
            )

          {:ok, doc} = AuthoringCandidate.encode(next)

          if byte_size(doc) <= remaining do
            retain_fixture_row(db, next, assessment, receipt)
            {:halt, {revision, total + byte_size(doc), count + 1}}
          else
            {:halt, {revision - 1, total, count}}
          end
        end
      end)

    :ok = Sqlite3.execute(db, "COMMIT")
    assert count < 1024 and total == 4_194_304
    assert :ok = Integrity.validate_snapshot(db)

    next =
      input(c, ref, revision, "over-bytes")
      |> put_in(["request", "instruction"], String.duplicate("x", 4096))

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(c.store, c.credential, next)

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{object_count: 2, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "128 shared retained frames stop both a new derived bundle and a new imported source before publication",
       c do
    first = import(c, "draft", draft("temperature"), 1, "import:1")
    second = import(c, "draft", draft("research"), 2, "import:2")

    assert {:ok, candidate} =
             Store.assess_authoring_candidate(c.store, c.credential, input(c, first, 3))

    revision =
      Enum.reduce(1..125, 4, fn index, revision ->
        import(c, "source", "source:#{index}", revision, "source:#{index}")
        revision + 1
      end)

    assert {:ok, %{object_count: 128}} = Custody.inventory(c.custody)

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, second, revision, "candidate:2")
             )

    {:ok, object} = AuthoringObject.new("source", "must remain absent")
    {:ok, summary} = AuthoringObject.summary(object)

    assert {:error, :authoring_object_capacity} =
             Store.import_authoring_object(
               c.store,
               c.credential,
               %{
                 "authority_epoch" => 1,
                 "operation_id" => "over-custody",
                 "expected_revision" => revision,
                 "object" => summary
               },
               "must remain absent"
             )

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{object_count: 128, lease_count: 0}} = Custody.inventory(c.custody)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)

    # Files can be missing while immutable candidate history remains retained.
    # Filling that filesystem hole with v1 bytes must not bypass the logical union.
    File.rm!(Path.join([c.root, "profiles", candidate["bundle"]["object_digest"] <> ".json"]))
    bytes = File.read!("test/support/profiles/lifx-power.json")
    assert {:ok, digest} = Custody.stage(c.custody, bytes)

    {:ok, manager, next} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    assert {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", next)

    assert {:error, :profile_capacity} =
             Store.profile_change(c.store, c.credential, %{
               "action" => "approve",
               "authority_epoch" => 1,
               "operation_id" => "legacy:over",
               "expected_revision" => barrier.revision,
               "artifact_digest" => digest,
               "expected_trust_revision" => 0
             })

    assert {:ok, %{writable: true}} = Store.health(c.store)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  for corruption <- [:receipt, :journal, :reference] do
    @corruption corruption
    test "tampered #{@corruption} correspondence is refused without renewed current authority",
         c do
      ref = import(c, "draft", draft("temperature"), 1, "import:1")
      i = input(c, ref, 2)
      assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
      db = :sys.get_state(c.store).db

      case @corruption do
        :receipt ->
          {:ok, doc} =
            AuthoringCandidate.encode_receipt(Map.put(receipt, "operation_id", "other"))

          {:ok, []} =
            SQL.query(db, "UPDATE profile_authoring_candidates SET receipt_document=?", [doc])

        :journal ->
          {:ok, []} =
            SQL.query(db, "UPDATE authority_journal SET entity_id='other' WHERE revision=3")

        :reference ->
          changed = put_in(i, ["request", "base_draft_ref", "first_revision"], 1)
          {:ok, doc} = AuthoringCandidate.encode(changed)
          {:ok, r} = AuthoringCandidate.encode_receipt(Map.put(receipt, "input_sha256", sha(doc)))

          {:ok, []} =
            SQL.query(
              db,
              "UPDATE profile_authoring_candidates SET input_document=?,receipt_document=?",
              [doc, r]
            )
      end

      assert {:error, :corrupt_authoring_candidates} = Integrity.validate_snapshot(db)

      assert {:error, :corrupt_authoring_candidates} =
               Store.authoring_candidate_status(c.store, c.credential, 1, "candidate:1")

      assert {:error, :store_unavailable} =
               Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 3, "new"))
    end
  end

  test "the shared 4-MiB complete-frame ceiling stops a derived bundle below the object count limit",
       c do
    first = import(c, "draft", draft("temperature"), 1, "import:1")
    second = import(c, "draft", draft("research"), 2, "import:2")
    assert {:ok, _} = Store.assess_authoring_candidate(c.store, c.credential, input(c, first, 3))
    {:ok, inventory} = Custody.inventory(c.custody)

    {revision, total} =
      Enum.reduce_while(1..32, {4, inventory.total_bytes}, fn index, {revision, total} ->
        remaining = 4_194_304 - total

        if remaining == 0 do
          {:halt, {revision, total}}
        else
          size = min(262_144, remaining - 42)
          prefix = "source:#{index}:"
          bytes = prefix <> String.duplicate("x", size - byte_size(prefix))
          import(c, "source", bytes, revision, "source:#{index}")
          {:cont, {revision + 1, total + size + 42}}
        end
      end)

    assert total == 4_194_304
    assert {:ok, %{object_count: count, total_bytes: 4_194_304}} = Custody.inventory(c.custody)
    assert count < 128

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, second, revision, "candidate:2")
             )

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{total_bytes: 4_194_304, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "both manual quantities retain exact original bundle/assessment identities and immutable receipts",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, r} = Authority.assess_authoring_candidate(c.authority, c.credential, i)

    assert r["revision"] == 3 and r["disposition"] == "compatible" and
             r["capture_status"] == "not_supplied"

    assert r["bundle"]["payload_sha256"] ==
             fixture("authoring-mechanics")["temperature"]["bundle_sha256"]

    assert {:ok, ^r} = Store.assess_authoring_candidate(c.store, c.credential, i)

    assert {:ok, ^r} =
             Authority.authoring_candidate_status(c.authority, c.credential, 1, "candidate:1")

    assert {:error, :authoring_operation_conflict} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               put_in(i, ["request", "instruction"], "changed")
             )

    ref = import(c, "draft", draft("research"), 3, "import:2")

    assert {:ok, r} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 4, "candidate:2")
             )

    assert r["bundle"]["payload_sha256"] ==
             fixture("authoring-mechanics")["research"]["bundle_sha256"]

    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "original lookup survives missing bytes, absent configured producer and restart", c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, r} = Store.assess_authoring_candidate(c.store, c.credential, i)
    File.rm!(Path.join([c.root, "profiles", ref["object_digest"] <> ".json"]))
    File.rm!(Path.join([c.root, "profiles", r["bundle"]["object_digest"] <> ".json"]))

    producer_path = :code.which(Wotex.Profiles.Artifacts) |> List.to_string() |> Path.dirname()
    true = Code.delete_path(producer_path)
    :code.purge(Wotex.Profiles.Artifacts)
    :code.delete(Wotex.Profiles.Artifacts)

    try do
      refute Code.ensure_loaded?(Wotex.Profiles.Artifacts)
      assert {:ok, ^r} = Store.assess_authoring_candidate(c.store, c.credential, i)

      assert {:error, :profiles_producer_unavailable} =
               Store.assess_authoring_candidate(
                 c.store,
                 c.credential,
                 input(c, ref, 3, "producer:absent")
               )
    after
      true = Code.prepend_path(producer_path)
      assert Code.ensure_loaded?(Wotex.Profiles.Artifacts)
    end

    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    assert {:ok, ^r} = Store.assess_authoring_candidate(store, c.credential, i)
    assert {:ok, ^r} = Store.authoring_candidate_status(store, c.credential, 1, "candidate:1")
    assert {:ok, 3} = Store.revision(store)
    assert :not_found = Store.authoring_candidate_status(store, c.credential, 1, "absent")
  end

  test "invalid syntax and producer-compatible shape with unsupported selector stay invalid proposals",
       c do
    ref = import(c, "draft", "{", 1, "import:1")
    assert {:ok, r} = Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))
    assert r["disposition"] == "invalid" and r["bundle"] == nil

    data =
      JSON.decode!(draft("temperature"))
      |> put_in(["profile", "channels", Access.at(0), "selector"], %{
        "unknown-selector" => "private-canary"
      })

    ref = import(c, "draft", JSON.encode!(data), 3, "import:2")

    assert {:ok, r} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 4, "candidate:2")
             )

    assert r["disposition"] == "invalid"
    refute inspect(r) =~ "private-canary"

    assert {:ok, [[_, assessment]]} =
             SQL.query(
               :sys.get_state(c.store).db,
               "SELECT revision,assessment_document FROM profile_authoring_candidates WHERE revision=5"
             )

    assert {:ok, a} = AuthoringCandidate.decode_assessment(assessment)
    assert a["report"]["diagnostics"] != []
  end

  test "permission, current CAS/epoch/contract and complete actor-owned reference checks precede assessment",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)

    assert {:error, :resnapshot_required} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "expected_revision", 1)
             )

    assert {:error, :stale_authority_epoch} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "authority_epoch", 2)
             )

    assert {:error, :stale_authoring_basis} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               put_in(i, ["request", "contract_digest"], String.duplicate("0", 64))
             )

    assert {:error, :stale_authoring_reference} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               put_in(i, ["request", "base_draft_ref", "first_revision"], 1)
             )

    {:ok, other, 3} = Store.provision_principal(c.store, "author:2", ["profile:manage"], [])

    assert :not_found =
             Store.assess_authoring_candidate(c.store, other, Map.put(i, "expected_revision", 3))

    {:ok, reader, 4} = Store.provision_principal(c.store, "reader:1", ["read"], [])
    assert {:error, :permission_denied} = Store.assess_authoring_candidate(c.store, reader, i)
    {:ok, manager, 5} = Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])
    assert {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", 5)

    assert {:error, :maintenance_active} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "expected_revision", barrier.revision)
             )

    assert {:ok, _} = Store.revoke_principal(c.store, "author:1")
    assert {:error, :unauthorized} = Store.assess_authoring_candidate(c.store, c.credential, i)
  end

  test "SQL fault rolls back candidate, event and revision, releases leases and leaves a collectable inert bundle",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    db = :sys.get_state(c.store).db

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TEMP TRIGGER refuse_candidate BEFORE INSERT ON profile_authoring_candidates BEGIN SELECT RAISE(ABORT,'fixture'); END"
      )

    assert {:error, :store_unavailable} =
             Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))

    assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_candidates")
    assert {:ok, [[2]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_candidate_assessed'"
             )

    assert {:ok, %{object_count: 2, lease_count: 0}} = Custody.inventory(c.custody)
    assert :ok = Integrity.validate_snapshot(db)
  end

  test "candidate bundle references survive collection and authenticated inclusive quarantine restore",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    assert {:ok, r} = Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))
    {:ok, manager, 4} = Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])
    assert {:ok, _} = Store.begin_maintenance(c.store, manager, 1, "maint:1", 4)
    assert {:ok, _} = Custody.stage_object(c.custody, "source", "orphan")
    assert {:ok, %{removed_objects: 1}} = Store.collect_profiles(c.store, c.credential)
    assert {:ok, _} = Custody.read_object(c.custody, r["bundle"]["object_digest"])
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "inclusive.backup")
    assert {:ok, %{authoring_objects: 2}} = Store.export_profile_backup(c.store, archive, key)
    assert {:ok, report} = Backup.verify(archive, key)

    assert length(report.dependencies.authoring_objects) == 2 and
             report.dependencies.authoring_bytes_included

    target = Path.join(c.root, "quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, key, target)
    {:ok, db} = Sqlite3.open(Path.join(target, "home.sqlite"))
    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, [[receipt]]} =
             SQL.query(db, "SELECT receipt_document FROM profile_authoring_candidates")

    assert {:ok, ^r} = AuthoringCandidate.decode_receipt(receipt)
    Sqlite3.close(db)

    database = Path.join(c.root, "database.backup")
    assert {:ok, _} = Store.export_backup(c.store, database, key)
    assert {:ok, metadata} = Backup.verify(database, key)
    refute metadata.dependencies.authoring_bytes_included
    assert length(metadata.dependencies.authoring_objects) == 2

    assert {:ok, %{quarantined: true}} =
             Backup.stage_restore(database, key, Path.join(c.root, "database.sqlite"))

    assert {:error, :profile_bytes_missing} =
             Backup.stage_profile_restore(database, key, Path.join(c.root, "incomplete"))

    File.rm!(Path.join([c.root, "profiles", r["bundle"]["object_digest"] <> ".json"]))

    assert {:error, :authoring_object_unavailable} =
             Store.export_profile_backup(c.store, Path.join(c.root, "missing.backup"), key)
  end

  test "changed retained assessment is corrupt history and cannot admit a new candidate", c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    assert {:ok, _} = Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))
    db = :sys.get_state(c.store).db

    assert {:ok, []} =
             SQL.query(db, "UPDATE profile_authoring_candidates SET assessment_document='[]'")

    assert {:error, :corrupt_authoring_candidates} = Integrity.validate_snapshot(db)

    assert {:error, :corrupt_authoring_candidates} =
             Store.authoring_candidate_status(c.store, c.credential, 1, "candidate:1")

    assert {:error, :store_unavailable} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 3, "candidate:2")
             )
  end

  test "schema 29 migration retains actual owned drafts and creates only an empty candidate table",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE IF EXISTS profile_external_observation_current; DROP TABLE IF EXISTS profile_external_observation_sequences; DROP TABLE IF EXISTS profile_external_observations; DROP TABLE IF EXISTS profile_external_source_bindings; DROP TABLE IF EXISTS profile_external_target_current; DROP TABLE IF EXISTS profile_external_target_history; DROP TABLE IF EXISTS profile_external_target_operations; DROP TABLE profile_external_trust_operations; DROP TABLE profile_external_artifacts; DELETE FROM meta WHERE key='external_profile_policy_generation'; DROP TABLE profile_external_inspections; DROP TABLE profile_authoring_reviews; DROP TABLE profile_authoring_candidates; PRAGMA user_version=29;"
      )

    assert :ok = Integrity.validate_schema_version(29, db)
    Sqlite3.close(db)

    store =
      start_supervised!(
        {Store,
         path: c.path, profile_custody: c.custody, authoring_contract: c.contract, name: @owner}
      )

    assert {:ok, 2} = Store.revision(store)
    assert {:ok, [[35]]} = SQL.query(:sys.get_state(store).db, "PRAGMA user_version")

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(store).db,
               "SELECT COUNT(*) FROM profile_authoring_candidates"
             )

    assert {:ok, _} = Store.read_authoring_object(store, c.credential, ref["object_digest"])
  end
end
