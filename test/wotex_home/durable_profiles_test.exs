Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableProfilesTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Profiles.{Artifact, Custody}
  alias WotexHome.Semantics.Observation
  alias WotexHome.Mutation
  alias WotexHome.Lifx.ProfileCatalogue
  @collection_store __MODULE__.Store

  setup do
    temporary = System.tmp_dir!() |> String.trim_trailing("/")

    temporary =
      if String.starts_with?(temporary, "/var/"), do: "/private" <> temporary, else: temporary

    directory =
      Path.join(temporary, "woh-durable-profiles-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    root = Path.join(directory, "profiles")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    custody = start_supervised!({Custody, root: root, store_owner: @collection_store})
    path = Path.join(directory, "home.sqlite")

    store =
      start_supervised!({Store, path: path, profile_custody: custody, name: @collection_store})

    {:ok, manager, 1} = Store.provision_principal(store, "manager:1", ["profile:manage"], [])
    {:ok, maintainer, 2} = Store.provision_principal(store, "maintainer:1", ["host:maintain"], [])

    {:ok, reader, 3} = Store.provision_principal(store, "reader:1", ["read"], [])

    authority = Authority.new(store: store, profile_custody: custody)
    bytes = File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))
    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      directory: directory,
      root: root,
      custody: custody,
      path: path,
      store: store,
      manager: manager,
      maintainer: maintainer,
      reader: reader,
      authority: authority,
      bytes: bytes
    }
  end

  test "framed import and Store-owned collection preserve independent permissions and retained approvals",
       c do
    max_bytes = c.bytes <> String.duplicate(" ", 32_768 - byte_size(c.bytes))
    encoded = Base.url_encode64(max_bytes, padding: false)

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             profile_route(c, c.reader, "profile_import", %{"artifact_base64" => encoded})

    assert %{"outcome" => "ok", "profile_artifact" => artifact} =
             profile_route(c, c.manager, "profile_import", %{"artifact_base64" => encoded})

    assert artifact["authority_changed"] == false
    assert {:ok, 3} = Store.revision(c.store)

    assert %{"outcome" => "error", "reason" => "invalid_profile_import"} =
             profile_route(c, c.manager, "profile_import", %{"artifact_base64" => encoded <> "="})

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             profile_route(c, c.manager, "profile_import", %{
               "artifact_base64" => encoded,
               "path" => "/caller/path"
             })

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             profile_route(c, c.maintainer, "profiles_collect", %{})

    assert %{"outcome" => "error", "reason" => "maintenance_required"} =
             profile_route(c, c.manager, "profiles_collect", %{})

    {digest, operation, approved} = approve(c)

    assert %{"outcome" => "ok", "profile_collection" => %{"removed_objects" => 1}} =
             profile_route(c, c.manager, "profiles_collect", %{})

    assert {:ok, _} = Custody.read(c.custody, digest)

    assert %{"outcome" => "ok", "profile_receipt" => receipt} =
             profile_route(c, c.manager, "profile_change", %{"change" => operation})

    assert receipt == WotexHome.Profiles.Wire.encode(approved)

    assert %{"outcome" => "ok", "profile_receipt" => ^receipt} =
             profile_route(c, c.manager, "profile_operation_status", %{
               "authority_epoch" => 1,
               "operation_id" => operation["operation_id"]
             })

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             profile_route(c, c.reader, "profile_operation_status", %{
               "authority_epoch" => 1,
               "operation_id" => operation["operation_id"]
             })

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             profile_route(c, c.reader, "profile_target", %{"thing_id" => "light:absent"})

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             profile_route(c, c.reader, "profile_review_status", %{
               "review_token" => "review:missing"
             })

    assert %{"outcome" => "error", "reason" => "invalid_target"} =
             profile_route(c, c.manager, "profile_target", %{"thing_id" => 5})

    stop_supervised!(Custody)

    assert %{"outcome" => "ok", "profile_catalogue" => catalogue} =
             profile_route(c, c.manager, "profiles", %{})

    assert hd(catalogue["items"])["byte_availability"] == "unavailable"

    assert %{"outcome" => "ok", "profile_receipt" => ^receipt} =
             profile_route(c, c.manager, "profile_operation_status", %{
               "authority_epoch" => 1,
               "operation_id" => operation["operation_id"]
             })
  end

  defp profile_route(c, credential, operation, fields) do
    request =
      Map.merge(
        %{
          "api_version" => 1,
          "operation" => operation,
          "credential" => Base.url_encode64(credential, padding: false)
        },
        fields
      )

    {:ok, frame} = WotexHome.LocalAPI.Frame.encode_request(request)
    {:ok, <<_::32, body::binary>>} = WotexHome.LocalAPI.Server.route_frame(c.authority, frame)
    {:ok, response} = WotexHome.LocalAPI.Frame.decode_response(body)
    response
  end

  test "import remains inert and permissions are independent", c do
    assert {:error, :permission_denied} =
             Authority.stage_profile(c.authority, c.reader, c.bytes)

    assert {:ok, digest} = Authority.stage_profile(c.authority, c.manager, c.bytes)
    assert {:ok, 3} = Store.revision(c.store)

    assert {:ok, %{items: [], policy_generation: 0}} =
             Authority.profile_catalogue(c.authority, c.manager)

    assert {:error, :permission_denied} =
             Authority.profile_change(c.authority, c.maintainer, input(c, "approve", digest, 0))

    assert {:error, :maintenance_required} =
             Authority.profile_change(c.authority, c.manager, input(c, "approve", digest, 0))

    assert {:error, :permission_denied} =
             Authority.begin_maintenance(c.authority, c.manager, 1, "maint:wrong", 3)

    assert {:ok, 3} = Store.revision(c.store)
    assert {:ok, new_manager, 4} = Authority.provision_profile_manager(c.authority)
    assert {:error, :principal_exists} = Authority.provision_profile_manager(c.authority)
    assert {:ok, %{items: []}} = Authority.profile_catalogue(c.authority, new_manager)
  end

  test "coarse enrollment cannot turn an approved external label into current authority", c do
    {digest, _original, approved} = approve(c)
    {:ok, artifact} = Custody.read(c.custody, digest)
    {:ok, external} = Artifact.declaration(artifact, "light:external")
    {:ok, compiled} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:compiled")
    assert {:ok, _} = Store.enroll_thing(c.store, external)
    assert {:ok, _} = Store.enroll_thing(c.store, compiled.thing)

    assert {:ok, credential, _} =
             Store.provision_principal(
               c.store,
               "control:fixture",
               ["read", "control:ordinary", "rule:review"],
               [
                 external.id,
                 compiled.thing.id
               ]
             )

    {:ok, %{begin_revision: begin_revision}} =
      Authority.maintenance_status(c.authority, c.maintainer)

    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.end_maintenance(
               c.authority,
               c.maintainer,
               1,
               "maint:end",
               revision,
               begin_revision
             )

    {:ok, revision} = Store.revision(c.store)
    {report, capability} = report_fixture(external)
    assert {:error, :profile_selection_unavailable} = Store.record(c.store, report, capability)

    assert {:error, :profile_selection_unavailable} =
             Store.record_batch(c.store, external, [report])

    assert {:error, :profile_selection_unavailable} =
             Store.lifx_refresh_basis(c.store, credential, external.id)

    {:ok, mutation} =
      Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "profile:coarse:request",
        "expected_revision" => 0,
        "target_id" => external.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:error, :profile_selection_unavailable} =
             Store.submit_request(c.store, credential, mutation)

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{writable: true}} = Store.health(c.store)

    assert {:ok, %{facts: facts, report_revisions: reports}} =
             Store.rule_facts_live(c.store, credential, [
               {external.id, "power"},
               {compiled.thing.id, "power"}
             ])

    assert facts[{external.id, "power"}] == :unknown
    assert reports[{external.id, "power"}] == nil
    {compiled_report, compiled_capability} = report_fixture(compiled.thing)
    assert {:ok, _} = Store.record(c.store, compiled_report, compiled_capability)

    assert {:ok, %{facts: facts}} =
             Store.rule_facts_live(c.store, credential, [
               {external.id, "power"},
               {compiled.thing.id, "power"}
             ])

    assert facts[{external.id, "power"}] == :unknown
    assert {:known, %{kind: :boolean, data: false}} = facts[{compiled.thing.id, "power"}]
    File.rm!(Path.join(c.root, digest <> ".json"))

    assert {:ok, %{items: [%{"trust_revision" => trust}]}} =
             Store.profile_catalogue(c.store, c.manager)

    assert trust == approved.final_revision
    assert {:error, :profile_selection_unavailable} = Store.record(c.store, report, capability)
    assert {:ok, %{writable: true}} = Store.health(c.store)
  end

  test "damaged profile authority links disable observation writes instead of reporting unavailable bytes",
       c do
    {digest, _original, _approved} = approve(c)
    {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:compiled")
    assert {:ok, _} = Store.enroll_thing(c.store, package.thing)
    {:ok, db} = Sqlite3.open(c.path)

    assert {:ok, []} =
             SQL.query(
               db,
               "UPDATE profile_operations SET input_digest=? WHERE artifact_digest=?",
               [String.duplicate("f", 64), digest]
             )

    Sqlite3.close(db)
    {report, capability} = report_fixture(package.thing)
    assert {:error, :store_unavailable} = Store.record(c.store, report, capability)
    assert {:ok, %{writable: false}} = Store.health(c.store)
    assert :not_found = Store.current(c.store, package.thing.id, "power")
  end

  defp report_fixture(thing) do
    capability = thing.capabilities["power"]

    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "source:fixture",
          "source_sequence" => 1,
          "boot_epoch" => "boot:fixture",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_000,
          "received_monotonic_ms" => 10
        },
        capability
      )

    {report, capability}
  end

  test "collection checks lifecycle authority and maintenance before touching inert bytes", c do
    {:ok, digest} = Authority.stage_profile(c.authority, c.manager, c.bytes)
    assert {:error, :permission_denied} = Authority.collect_profiles(c.authority, c.reader)
    assert {:error, :permission_denied} = Authority.collect_profiles(c.authority, c.maintainer)
    assert {:error, :maintenance_required} = Authority.collect_profiles(c.authority, c.manager)
    assert {:ok, _} = Custody.read(c.custody, digest)
    assert {:error, :invalid_profile_collection} = Custody.collect(c.custody, [])
    begin(c)
    {:ok, revision} = Store.revision(c.store)
    assert {:ok, %{removed_objects: 1}} = Authority.collect_profiles(c.authority, c.manager)
    assert {:ok, ^revision} = Store.revision(c.store)
  end

  test "Store-owned collection preserves revoked history and external review leases", c do
    {digest, original, approved} = approve(c)
    {:ok, leased} = Authority.stage_profile(c.authority, c.manager, " " <> c.bytes)
    {:ok, inert} = Authority.stage_profile(c.authority, c.manager, "  " <> c.bytes)
    {:ok, lease} = Custody.lease(c.custody, leased)
    assert {:ok, %{removed_objects: 1}} = Authority.collect_profiles(c.authority, c.manager)
    assert {:error, :profile_artifact_unavailable} = Custody.read(c.custody, inert)
    assert {:ok, _} = Custody.read(c.custody, digest)
    assert {:ok, _} = Custody.read(c.custody, leased)
    assert :ok = Custody.release(c.custody, lease.token)
    assert {:ok, %{removed_objects: 1}} = Authority.collect_profiles(c.authority, c.manager)

    assert {:ok, _} =
             Authority.profile_change(
               c.authority,
               c.manager,
               input(c, "revoke", digest, approved.final_revision)
             )

    assert {:ok, %{removed_objects: 0, digests: [^digest]}} =
             Authority.collect_profiles(c.authority, c.manager)

    assert {:ok, ^approved} = Authority.profile_change(c.authority, c.manager, original)

    assert {:ok, %{items: [%{"state" => :revoked}]}} =
             Authority.profile_catalogue(c.authority, c.manager)
  end

  test "the retained reference snapshot survives Store restart and missing external bytes", c do
    {digest, original, approved} = approve(c)
    File.rm!(Path.join(c.root, digest <> ".json"))
    stop_supervised(Store)

    store =
      start_supervised!(
        {Store, path: c.path, profile_custody: c.custody, name: @collection_store}
      )

    authority = Authority.new(store: store, profile_custody: c.custody)
    {:ok, inert} = Authority.stage_profile(authority, c.manager, " " <> c.bytes)

    assert {:ok, %{removed_objects: 1, digests: []}} =
             Authority.collect_profiles(authority, c.manager)

    assert {:error, :profile_artifact_unavailable} = Custody.read(c.custody, inert)
    assert {:ok, ^approved} = Authority.profile_change(authority, c.manager, original)

    assert {:ok, %{items: [%{"artifact_digest" => ^digest}]}} =
             Authority.profile_catalogue(authority, c.manager)
  end

  test "approval is an immutable scoped receipt without selection or qualification", c do
    {digest, original, receipt} = approve(c)

    assert receipt.action == "approve" and receipt.policy_generation == 1 and
             receipt.trust_generation == 1

    assert receipt.changed_targets == 0 and receipt.invalidated_requests == 0
    assert {:ok, ^receipt} = Authority.profile_change(c.authority, c.manager, original)

    assert {:ok, ^receipt} =
             Authority.profile_operation_status(
               c.authority,
               c.manager,
               1,
               original["operation_id"]
             )

    assert {:error, :profile_operation_conflict} =
             Authority.profile_change(
               c.authority,
               c.manager,
               Map.put(original, "expected_revision", receipt.final_revision)
             )

    assert {:ok, %{items: [item]}} = Authority.profile_catalogue(c.authority, c.manager)
    assert item["artifact_digest"] == digest and item["state"] == :approved
    assert item["qualification_status"] == :pending_physical_evidence
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)

    assert {:ok, [[0], [0], [0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM profile_current UNION ALL SELECT COUNT(*) FROM profile_qualifications UNION ALL SELECT COUNT(*) FROM enrolled_things"
             )

    assert :ok = Integrity.validate_snapshot(db)
    Sqlite3.close(db)
  end

  test "revocation and historical retry work with missing bytes, including restart", c do
    {digest, original, approved} = approve(c)
    File.rm!(Path.join(c.root, digest <> ".json"))
    assert {:ok, ^approved} = Authority.profile_change(c.authority, c.manager, original)
    revoke = input(c, "revoke", digest, approved.final_revision)
    assert {:ok, revoked} = Authority.profile_change(c.authority, c.manager, revoke)

    assert revoked.trust_generation == 2 and
             revoked.previous_trust_revision == approved.final_revision

    assert {:ok, %{items: [%{"state" => :revoked}]}} =
             Authority.profile_catalogue(c.authority, c.manager)

    assert {:ok, ^revoked} = Authority.profile_change(c.authority, c.manager, revoke)
    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path})
    authority = Authority.new(store: store)
    assert {:ok, ^approved} = Authority.profile_change(authority, c.manager, original)

    assert {:ok, ^revoked} =
             Authority.profile_operation_status(authority, c.manager, 1, revoke["operation_id"])

    assert {:ok, %{items: [%{"state" => :revoked}]}} =
             Authority.profile_catalogue(authority, c.manager)
  end

  test "different bytes claiming an admitted label never replace it", c do
    {digest, _, approved} = approve(c)
    {:ok, other_digest} = Authority.stage_profile(c.authority, c.manager, " " <> c.bytes)

    assert {:error, :profile_label_conflict} =
             Authority.profile_change(
               c.authority,
               c.manager,
               input(c, "approve", other_digest, 0)
             )

    assert {:ok, approved.final_revision} == Store.revision(c.store)

    assert {:ok, %{items: [%{"artifact_digest" => ^digest}]}} =
             Authority.profile_catalogue(c.authority, c.manager)
  end

  test "current epoch, Store revision and original trust revision all recheck", c do
    {digest, _, approved} = approve(c)
    revoke = input(c, "revoke", digest, approved.final_revision)

    assert {:error, :stale_authority_epoch} =
             Authority.profile_change(
               c.authority,
               c.manager,
               Map.put(revoke, "authority_epoch", 2)
             )

    assert {:error, :resnapshot_required} =
             Authority.profile_change(
               c.authority,
               c.manager,
               Map.put(revoke, "expected_revision", 0)
             )

    assert {:error, :profile_trust_changed} =
             Authority.profile_change(
               c.authority,
               c.manager,
               Map.put(revoke, "expected_trust_revision", 0)
             )

    assert {:ok, approved.final_revision} == Store.revision(c.store)
  end

  test "operation status is principal-private and revoked authors grant no current trust", c do
    {_digest, original, _receipt} = approve(c)
    {:ok, other, _} = Store.provision_principal(c.store, "manager:2", ["profile:manage"], [])

    assert :not_found =
             Authority.profile_operation_status(c.authority, other, 1, original["operation_id"])

    assert {:ok, _} = Store.revoke_principal(c.store, "manager:1")

    assert {:error, :unauthorized} =
             Authority.profile_operation_status(
               c.authority,
               c.manager,
               1,
               original["operation_id"]
             )

    assert {:ok, %{items: [%{"state" => :author_unavailable}]}} =
             Authority.profile_catalogue(c.authority, other)
  end

  test "a failed multi-row approval rolls back metadata, journal, policy and receipt", c do
    {:ok, digest} = Authority.stage_profile(c.authority, c.manager, c.bytes)
    begin(c)
    original = input(c, "approve", digest, 0)
    {:ok, before_revision} = Store.revision(c.store)
    {:ok, db} = Sqlite3.open(c.path)

    Sqlite3.execute(
      db,
      "CREATE TRIGGER fail_profile BEFORE INSERT ON profile_operations BEGIN SELECT RAISE(ABORT, 'fixture failure'); END"
    )

    assert {:error, :store_unavailable} =
             Authority.profile_change(c.authority, c.manager, original)

    assert {:ok, ^before_revision} = Store.revision(c.store)

    assert {:ok, [[0], [0], [0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM portable_profiles UNION ALL SELECT COUNT(*) FROM profile_operations UNION ALL SELECT value FROM meta WHERE key='profile_policy_generation'"
             )

    assert :ok = Integrity.validate_snapshot(db)
    Sqlite3.execute(db, "DROP TRIGGER fail_profile")
    Sqlite3.close(db)
    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody})
    assert {:ok, _} = Store.profile_change(store, c.manager, original)
  end

  test "corrupt live history disables writes without minting another revision", c do
    {digest, _, approved} = approve(c)
    {:ok, db} = Sqlite3.open(c.path)

    Sqlite3.execute(
      db,
      "UPDATE profile_operations SET input_digest='#{String.duplicate("0", 64)}'"
    )

    assert {:error, :corrupt_profile_ledger} = Authority.profile_catalogue(c.authority, c.manager)

    assert {:error, :store_unavailable} =
             Authority.profile_change(
               c.authority,
               c.manager,
               input(c, "revoke", digest, approved.final_revision)
             )

    assert {:ok, approved.final_revision} == Store.revision(c.store)
    assert {:error, :corrupt_profile_ledger} = Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    stop_supervised(Store)

    assert {:error, {{:store_open_failed, :corrupt_profile_ledger}, _}} =
             start_supervised({Store, path: c.path})
  end

  test "reapproval retains revocation history and advances exact trust generations", c do
    {digest, _, approved} = approve(c)
    revoke = input(c, "revoke", digest, approved.final_revision)
    assert {:ok, revoked} = Authority.profile_change(c.authority, c.manager, revoke)

    reapprove =
      input(c, "approve", digest, revoked.final_revision)
      |> Map.put("operation_id", "profile:reapprove:#{digest}")

    assert {:ok, current} = Authority.profile_change(c.authority, c.manager, reapprove)
    assert current.trust_generation == 3 and current.policy_generation == 3

    assert {:ok, %{items: [%{"state" => :approved, "trust_revision" => trust}]}} =
             Authority.profile_catalogue(c.authority, c.manager)

    assert trust == current.final_revision
    assert {:ok, ^revoked} = Authority.profile_change(c.authority, c.manager, revoke)
    assert {:ok, current.final_revision} == Store.revision(c.store)
  end

  test "a detached approval journal event cannot become an ordinary unavailable profile", c do
    {digest, _, approved} = approve(c)
    {:ok, db} = Sqlite3.open(c.path)

    assert :ok =
             Sqlite3.execute(
               db,
               "UPDATE authority_journal SET entity_id='#{String.duplicate("0", 64)}' WHERE revision=#{approved.final_revision}"
             )

    assert {:error, :corrupt_profile_ledger} = Integrity.validate_snapshot(db)
    assert {:error, :corrupt_profile_ledger} = Store.profile_catalogue(c.store, c.manager)

    assert {:error, :store_unavailable} =
             Store.profile_change(
               c.store,
               c.manager,
               input(c, "revoke", digest, approved.final_revision)
             )

    Sqlite3.close(db)
  end

  test "encrypted recovery retains exact dependencies and stays quarantined", c do
    {digest, _, approved} = approve(c)
    archive = Path.join(c.directory, "backup.woh")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:ok, %{dependencies: dependencies}} = Backup.verify(archive, key)

    assert [%{artifact_digest: ^digest, projection_digest: projection, registry_digest: registry}] =
             dependencies.profile_artifacts

    assert byte_size(projection) == 64 and byte_size(registry) == 64
    assert dependencies.profile_operation_rows == 1 and dependencies.profile_selection_rows == 0
    refute dependencies.portable_profile_bytes_included
    refute dependencies.profile_history_reactivates_on_restore
    destination = Path.join(c.directory, "quarantine.sqlite")

    assert {:ok, %{quarantined: true, store_revision: revision}} =
             Backup.stage_restore(archive, key, destination)

    assert revision == approved.final_revision

    assert {:error, {{:store_open_failed, :restore_requires_transfer}, _}} =
             start_supervised({Store, path: destination}, id: :quarantined)
  end

  test "schema eighteen migration and archive preserve old identity without inventing approvals",
       c do
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)

    Sqlite3.execute(
      db,
      WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
        "PRAGMA user_version=18; UPDATE principals SET permissions='[\"read\"]' WHERE principal_id='manager:1'"
    )

    archive = Path.join(c.directory, "schema18.woh")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Backup.export(db, archive, key)

    assert {:ok, %{dependencies: %{profile_artifacts: [], profile_operation_rows: 0}}} =
             Backup.verify(archive, key)

    Sqlite3.close(db)
    store = start_supervised!({Store, path: c.path})
    assert {:ok, 3} = Store.revision(store)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    assert {:ok, [[24]]} = SQL.query(db, "PRAGMA user_version")

    assert {:ok, [[0], [0]]} =
             SQL.query(
               db,
               "SELECT value FROM meta WHERE key='profile_policy_generation' UNION ALL SELECT COUNT(*) FROM portable_profiles"
             )

    assert :ok = Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    assert {:error, :permission_denied} = Store.profile_catalogue(store, c.manager)
  end

  defp approve(c) do
    {:ok, digest} = Authority.stage_profile(c.authority, c.manager, c.bytes)
    begin(c)
    original = input(c, "approve", digest, 0)
    assert {:ok, receipt} = Authority.profile_change(c.authority, c.manager, original)
    {digest, original, receipt}
  end

  defp begin(c) do
    {:ok, revision} = Store.revision(c.store)

    {:ok, _} =
      Authority.begin_maintenance(c.authority, c.maintainer, 1, "maint:profile", revision)
  end

  defp input(c, action, digest, trust) do
    {:ok, revision} = Store.revision(c.store)

    %{
      "action" => action,
      "authority_epoch" => 1,
      "operation_id" => "profile:#{action}:#{digest}",
      "expected_revision" => revision,
      "artifact_digest" => digest,
      "expected_trust_revision" => trust
    }
  end
end
