defmodule WotexHome.DurableEnrollmentTest do
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Discovery.{Candidate, EnrollmentReview, Interview, Profile}
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Mutation
  alias WotexHome.Semantics.Thing

  @candidate %{
    "interface_id" => "en0",
    "transport" => "udp",
    "source_endpoint" => "192.0.2.10:56700",
    "receive_epoch" => "scan:1",
    "received_monotonic_ms" => 100,
    "raw_ref" => "capture:1",
    "claimed_identifiers" => %{
      "manufacturer" => "LIFX",
      "model" => "old-eu",
      "stable_id" => "d073d5000001"
    },
    "trust_class" => "untrusted_network"
  }

  @interview %{
    "candidate_ref" => "capture:1",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware" => "2.0",
    "stable_id" => "d073d5000001"
  }

  @profile %{
    "id" => "lifx.old-eu",
    "version" => "1.0.0",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware_versions" => ["2.0"],
    "rank" => 10,
    "qualification_ref" => "cohort:old-eu:1"
  }

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old-eu:1.0.0",
    "evidence_ref" => "cohort:old-eu:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @selection %{
    "operator_id" => "owner:1",
    "candidate_ref" => "capture:1",
    "stable_id" => "d073d5000001",
    "profile_ref" => "lifx.old-eu:1.0.0",
    "qualification_ref" => "cohort:old-eu:1",
    "method" => "legacy_tofu",
    "review_ref" => "review:1"
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-enrollment-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, path: Path.join(directory, "home.sqlite")}
  end

  test "authenticated review binds identity once and survives restart and backup", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, owner_credential, 1} =
             Store.provision_principal(store, "owner:1", ["enroll:review"], [])

    assert {:ok, other_credential, 2} =
             Store.provision_principal(store, "owner:2", ["enroll:review"], [])

    {candidate, interview, profile, thing} = fixtures()

    assert {:error, :unauthorized} =
             commit(
               store,
               :binary.copy(<<1>>, 32),
               [candidate],
               interview,
               [profile],
               thing,
               @selection
             )

    assert {:error, :permission_denied} =
             commit(store, other_credential, [candidate], interview, [profile], thing, @selection)

    assert {:ok, 3} =
             commit(store, owner_credential, [candidate], interview, [profile], thing, @selection)

    assert {:ok, review} =
             EnrollmentReview.new([candidate], interview, [profile], thing, @selection)

    assert {:error, :enrollment_conflict} =
             commit(store, owner_credential, [candidate], interview, [profile], thing, @selection)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [["light:desk", "d073d5000001", "owner:1", "legacy_tofu", 3]] =
             rows(
               db,
               "SELECT thing_id, stable_id, operator_id, method, revision FROM enrollment_bindings"
             )

    identity_digest = review.identity_digest
    assert [[^identity_digest]] = rows(db, "SELECT identity_digest FROM enrollment_bindings")

    assert [[2, "lifx.old-eu:1.0.0", "LIFX", "old-eu", "2.0"]] =
             rows(
               db,
               "SELECT digest_version, profile_ref, manufacturer, model, firmware FROM enrollment_review_history"
             )

    :ok = Sqlite3.close(db)
    key = :binary.copy(<<7>>, 32)
    archive = path <> ".backup"
    assert {:ok, %{store_revision: 3}} = Store.export_backup(store, archive, key)
    assert {:ok, %{store_revision: 3}} = Backup.verify(archive, key)
    :ok = GenServer.stop(store)

    assert {:ok, reopened} = Store.start_link(path: path)

    assert {:error, :enrollment_conflict} =
             commit(
               reopened,
               owner_credential,
               [candidate],
               interview,
               [profile],
               thing,
               @selection
             )

    :ok = GenServer.stop(reopened)
  end

  test "authenticated re-review replaces current identity and rejects held work", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, controller, 3} =
             Store.provision_principal(store, "controller:1", ["control:ordinary"], [thing.id])

    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:1",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => thing.id,
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => true}
             })

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.submit_request(store, controller, mutation)

    changed_interview = %{interview | firmware: "2.1"}
    expanded_profile = %{profile | firmware_versions: ["2.0", "2.1"]}
    next_selection = %{@selection | "review_ref" => "review:2"}

    assert {:error, :permission_denied} =
             Store.rereview_enrollment(
               store,
               controller,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               next_selection
             )

    assert {:ok, 6} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               next_selection
             )

    assert {:ok, %{disposition: :rejected, reason: "identity_rechecked", revision: 6}} =
             Store.request_status(store, controller, 1, "op:1")

    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [["review:2", 2, 5]] =
             rows(db, "SELECT review_ref, digest_version, revision FROM enrollment_bindings")

    assert [["review:1", "2.0"], ["review:2", "2.1"]] =
             rows(
               db,
               "SELECT review_ref, firmware FROM enrollment_review_history ORDER BY revision"
             )

    :ok = Sqlite3.close(db)
    assert {:ok, reopened} = Store.start_link(path: path)
    assert {:ok, %{held_requests: 0, store_revision: 6}} = Store.health(reopened)
    :ok = GenServer.stop(reopened)
  end

  test "version-six binding migrates as legacy until a new authenticated review", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "DROP TABLE enrollment_review_history; ALTER TABLE enrollment_bindings DROP COLUMN digest_version; PRAGMA user_version=6"
             )

    key = :binary.copy(<<9>>, 32)
    archive = path <> ".v6.backup"
    assert {:ok, %{store_revision: 2}} = Backup.export(db, archive, key)
    assert {:ok, %{store_revision: 2}} = Backup.verify(archive, key)
    :ok = Sqlite3.close(db)

    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, 2} = Store.revision(migrated)

    assert {:ok, 3} =
             Store.rereview_enrollment(
               migrated,
               owner,
               [candidate],
               interview,
               [profile],
               thing,
               %{@selection | "review_ref" => "review:2"}
             )

    :ok = GenServer.stop(migrated)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[7]] = rows(db, "PRAGMA user_version")
    assert [[2]] = rows(db, "SELECT digest_version FROM enrollment_bindings")

    assert [[1, nil, nil, nil], [2, "LIFX", "old-eu", "2.0"]] =
             rows(
               db,
               "SELECT digest_version, manufacturer, model, firmware FROM enrollment_review_history ORDER BY revision"
             )

    :ok = Sqlite3.close(db)
  end

  test "startup and backup verification reject a review history mismatch", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "UPDATE enrollment_review_history SET identity_digest = '#{String.duplicate("0", 64)}'"
             )

    key = :binary.copy(<<10>>, 32)
    archive = path <> ".corrupt.backup"
    assert {:ok, _} = Backup.export(db, archive, key)
    assert {:error, :invalid_backup} = Backup.verify(archive, key)
    :ok = Sqlite3.close(db)
    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, {:schema_inconsistent, false}}} =
             Store.start_link(path: path)
  end

  test "a second Thing cannot inherit an already selected physical identity", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, credential, 1} =
             Store.provision_principal(store, "owner:1", ["enroll:review"], [])

    {candidate, interview, profile, thing} = fixtures()

    assert {:ok, 2} =
             commit(store, credential, [candidate], interview, [profile], thing, @selection)

    assert {:ok, 3} = Store.revoke_thing(store, "light:desk")

    second = %{
      thing
      | id: "light:other",
        capabilities: %{"power" => %{thing.capabilities["power"] | thing_id: "light:other"}}
    }

    assert {:error, :enrollment_conflict} =
             commit(store, credential, [candidate], interview, [profile], second, @selection)

    assert {:ok, %{active_things: 0, store_revision: 3}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  test "version-five snapshot verifies and migrates without changing its revision", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, _credential, 1} =
             Store.provision_principal(store, "owner:1", ["enroll:review"], [])

    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "DROP TABLE enrollment_review_history; DROP TABLE enrollment_bindings; PRAGMA user_version=5"
             )

    key = :binary.copy(<<8>>, 32)
    archive = path <> ".v5.backup"
    assert {:ok, %{store_revision: 1}} = Backup.export(db, archive, key)
    assert {:ok, %{store_revision: 1}} = Backup.verify(archive, key)
    :ok = Sqlite3.close(db)

    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, 1} = Store.revision(migrated)
    :ok = GenServer.stop(migrated)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[7]] = rows(db, "PRAGMA user_version")
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM enrollment_bindings")
    :ok = Sqlite3.close(db)
  end

  defp commit(store, credential, candidates, interview, profiles, thing, selection) do
    Store.commit_enrollment(store, credential, candidates, interview, profiles, thing, selection)
  end

  defp fixtures do
    assert {:ok, candidate} = Candidate.new(@candidate)
    assert {:ok, interview} = Interview.new(@interview, candidate)
    assert {:ok, profile} = Profile.new(@profile)

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old-eu:1.0.0",
               "capabilities" => [@power]
             })

    {candidate, interview, profile, thing}
  end

  defp rows(db, sql) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      {:ok, result} = Sqlite3.fetch_all(db, statement)
      result
    after
      :ok = Sqlite3.release(db, statement)
    end
  end
end
