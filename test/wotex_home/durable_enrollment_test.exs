defmodule WotexHome.DurableEnrollmentTest do
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Discovery.{Candidate, EnrollmentReview, Interview, Profile}
  alias WotexHome.Durable.{Backup, Registry, Store}
  alias WotexHome.Lifx.{ProductRegistry, ProfileBasis}
  alias WotexHome.LocalAPI.{Client, Server}
  alias WotexHome.Mutation
  alias WotexHome.Qualification.{Attestation, Claims, Decision, Evidence, Programme}
  alias WotexHome.Semantics.{Observation, Thing}

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

  @qualification_cohort %{
    "source_identity_ref" => String.duplicate("a", 64),
    "hardware_sku" => "lifx.old-eu",
    "hardware_revision" => "rev.1",
    "firmware" => "2.0",
    "adapter_profile" => "lifx.old-eu:1.0.0",
    "native_stack" => "wotex-udp:test",
    "host_os" => "macos:test",
    "runtime" => "otp:test",
    "network_topology" => "isolated-lan:1",
    "application" => "home:test",
    "model" => "none"
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

    assert {:ok, 3} =
             commit(store, owner_credential, [candidate], interview, [profile], thing, @selection)

    assert {:ok, changed_thing} =
             Thing.new(%{
               "id" => thing.id,
               "role" => thing.role,
               "profile_ref" => thing.profile_ref,
               "capabilities" => [%{@power | "freshness_ms" => 4_000}]
             })

    assert {:error, :enrollment_conflict} =
             commit(
               store,
               owner_credential,
               [candidate],
               interview,
               [profile],
               changed_thing,
               @selection
             )

    assert {:error, :enrollment_conflict} =
             commit(
               store,
               owner_credential,
               [candidate],
               interview,
               [profile],
               thing,
               %{@selection | "review_ref" => "review:new"}
             )

    assert {:ok, 3} = Store.revision(store)

    assert {:ok,
            %{
              state: :current,
              review_revision: 3,
              binding_revision: 3,
              digest_version: 2,
              thing_id: "light:desk"
            }} = Store.enrollment_review_status(store, owner_credential, "review:1")

    assert :not_found = Store.enrollment_review_status(store, other_credential, "review:1")
    assert :not_found = Store.enrollment_review_status(store, owner_credential, "review:missing")

    assert {:error, :invalid_id} =
             Store.enrollment_review_status(store, owner_credential, "bad id")

    socket_path = Path.join(Path.dirname(path), "s/h.sock")
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    assert {:ok,
            %{
              "outcome" => "ok",
              "enrollment_review" => %{
                "state" => "current",
                "review_ref" => "review:1",
                "thing_id" => "light:desk",
                "review_revision" => 3,
                "binding_revision" => 3
              }
            }} =
             Client.request(socket_path, %{
               "api_version" => 1,
               "operation" => "enrollment_status",
               "credential" => Base.url_encode64(owner_credential, padding: false),
               "review_ref" => "review:1"
             })

    assert {:ok, %{"outcome" => "not_found"}} =
             Client.request(socket_path, %{
               "api_version" => 1,
               "operation" => "enrollment_status",
               "credential" => Base.url_encode64(other_credential, padding: false),
               "review_ref" => "review:1"
             })

    :ok = GenServer.stop(server)

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

    assert {:ok, %{state: :current, review_revision: 3}} =
             Store.enrollment_review_status(reopened, owner_credential, "review:1")

    assert {:ok, 3} =
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

    assert {:error, :enrollment_conflict} =
             commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, %{state: :superseded, review_revision: 2, binding_revision: 5}} =
             Store.enrollment_review_status(store, owner, "review:1")

    assert {:ok, %{state: :current, review_revision: 5, binding_revision: 5}} =
             Store.enrollment_review_status(store, owner, "review:2")

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

    assert {:ok, 7} = Store.revoke_thing(reopened, thing.id)

    assert {:ok, %{state: :revoked}} =
             Store.enrollment_review_status(reopened, owner, "review:1")

    assert {:ok, %{state: :revoked}} =
             Store.enrollment_review_status(reopened, owner, "review:2")

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
               "DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; DROP TABLE profile_qualifications; DROP TABLE enrollment_review_history; ALTER TABLE enrollment_bindings DROP COLUMN digest_version; PRAGMA user_version=6"
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
    assert [[11]] = rows(db, "PRAGMA user_version")
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

  test "held direct power queues only with current synthetic qualification and fresh report", %{
    path: path
  } do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, controller, 3} =
             Store.provision_principal(store, "controller:1", ["control:ordinary"], [thing.id])

    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:power",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => thing.id,
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => true}
             })

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.submit_request(store, controller, mutation)

    {:ok, report} = power_report(thing.capabilities["power"], false)
    assert {:ok, 5} = Store.record(store, report, thing.capabilities["power"])

    assert {:error, :profile_unqualified} =
             Store.admit_held_power(store, controller, 1, "op:power", "boot:1", 101)

    assert {:ok, %{held_requests: 1, queued_requests: 0, store_revision: 5}} = Store.health(store)
    :ok = GenServer.stop(store)
    qualification_keys = insert_synthetic_qualification(path, 6, thing)

    assert {:ok, reopened} = Store.start_link([path: path] ++ qualification_keys)

    assert {:error, :unauthorized} =
             Store.admit_held_power(
               reopened,
               :binary.copy(<<1>>, 32),
               1,
               "op:power",
               "boot:1",
               101
             )

    assert {:error, :observation_unavailable} =
             Store.admit_held_power(reopened, controller, 1, "op:power", "boot:other", 101)

    assert {:ok, %{disposition: :queued, reason: nil, revision: 7} = queued} =
             Store.admit_held_power(reopened, controller, 1, "op:power", "boot:1", 101)

    assert {:ok, ^queued} =
             Store.admit_held_power(reopened, controller, 1, "op:power", "boot:1", 9_999)

    assert {:ok,
            %{held_requests: 0, queued_requests: 1, dispatch_enabled: false, store_revision: 7}} =
             Store.health(reopened)

    :ok = GenServer.stop(reopened)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [["queued", "light:desk", 0, 5, 7, <<1, 1>>]] =
             rows(
               db,
               "SELECT state, effect_domain, rule_generation, baseline_revision, admission_revision, planned_value FROM request_execution"
             )

    :ok = Sqlite3.close(db)
    assert {:ok, again} = Store.start_link([path: path] ++ qualification_keys)
    assert {:ok, ^queued} = Store.request_status(again, controller, 1, "op:power")

    no_send_mutation = %{
      mutation
      | operation_id: "op:no-send",
        value: %{"type" => "boolean", "value" => false}
    }

    assert {:ok, %{disposition: :held, revision: 8}} =
             Store.submit_request(again, controller, no_send_mutation)

    assert {:error, :effect_domain_busy} =
             Store.settle_held_power_noop(again, controller, 1, "op:no-send", "boot:1", 101)

    assert {:error, :effect_domain_busy} =
             Store.admit_held_power(again, controller, 1, "op:no-send", "boot:1", 101)

    second_mutation = %{mutation | operation_id: "op:second"}

    assert {:ok, %{disposition: :held, revision: 9}} =
             Store.submit_request(again, controller, second_mutation)

    assert {:error, :effect_domain_busy} =
             Store.admit_held_power(again, controller, 1, "op:second", "boot:1", 101)

    assert {:ok, %{held_requests: 2, queued_requests: 1, store_revision: 9}} =
             Store.health(again)

    assert {:ok, 13} = Store.revoke_thing(again, thing.id)

    assert {:ok, %{disposition: :rejected, reason: "target_revoked", revision: 13}} =
             Store.request_status(again, controller, 1, "op:power")

    :ok = GenServer.stop(again)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [["revoked"]] = rows(db, "SELECT status FROM profile_qualifications")
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM request_execution")
    :ok = Sqlite3.close(db)
  end

  test "admission closes an already reported value without qualification or queued work", %{
    path: path
  } do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, controller, 3} =
             Store.provision_principal(store, "controller:1", ["control:ordinary"], [thing.id])

    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:already",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => thing.id,
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => true}
             })

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.submit_request(store, controller, mutation)

    {:ok, report} = power_report(thing.capabilities["power"], true)
    assert {:ok, 5} = Store.record(store, report, thing.capabilities["power"])

    assert {:ok, %{disposition: :rejected, reason: "already_reported_no_send", revision: 6}} =
             Store.admit_held_power(store, controller, 1, "op:already", "boot:1", 101)

    assert {:ok, %{held_requests: 0, queued_requests: 0, dispatch_enabled: false}} =
             Store.health(store)

    :ok = GenServer.stop(store)
  end

  test "owner cancellation releases queued work before claim and preserves retry identity", %{
    path: path
  } do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, controller, 3} =
             Store.provision_principal(store, "controller:1", ["control:ordinary"], [thing.id])

    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:first",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => thing.id,
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => true}
             })

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.submit_request(store, controller, mutation)

    {:ok, report} = power_report(thing.capabilities["power"], false)
    assert {:ok, 5} = Store.record(store, report, thing.capabilities["power"])
    :ok = GenServer.stop(store)
    qualification_keys = insert_synthetic_qualification(path, 6, thing)
    assert {:ok, reopened} = Store.start_link([path: path] ++ qualification_keys)

    assert {:ok, %{disposition: :queued, revision: 7}} =
             Store.admit_held_power(reopened, controller, 1, "op:first", "boot:1", 101)

    assert {:ok,
            %{disposition: :rejected, reason: "cancelled_before_claim", revision: 8} = cancelled} =
             Store.cancel_request(reopened, controller, 1, "op:first")

    assert {:ok, ^cancelled} = Store.cancel_request(reopened, controller, 1, "op:first")
    assert {:ok, ^cancelled} = Store.submit_request(reopened, controller, mutation)

    next_mutation = %{mutation | operation_id: "op:next"}

    assert {:ok, %{disposition: :held, revision: 9}} =
             Store.submit_request(reopened, controller, next_mutation)

    assert {:ok, %{disposition: :queued, revision: 10}} =
             Store.admit_held_power(reopened, controller, 1, "op:next", "boot:1", 101)

    assert {:ok, %{held_requests: 0, queued_requests: 1, store_revision: 10}} =
             Store.health(reopened)

    :ok = GenServer.stop(reopened)
  end

  test "trusted worker claim is durable but grants no send and does not requeue on worker exit",
       %{
         path: path
       } do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, controller, 3} =
             Store.provision_principal(store, "controller:1", ["control:ordinary"], [thing.id])

    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:claim",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => thing.id,
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => true}
             })

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.submit_request(store, controller, mutation)

    {:ok, report} = power_report(thing.capabilities["power"], false)
    assert {:ok, 5} = Store.record(store, report, thing.capabilities["power"])
    :ok = GenServer.stop(store)
    qualification_keys = insert_synthetic_qualification(path, 6, thing)
    assert {:ok, reopened} = Store.start_link([path: path] ++ qualification_keys)

    assert {:ok, %{disposition: :queued, revision: 7}} =
             Store.admit_held_power(reopened, controller, 1, "op:claim", "boot:1", 101)

    assert {:error, :observation_unavailable} =
             Store.claim_queued_power(reopened, "controller:1", 1, "op:claim", "boot:other", 101)

    claim_root = Path.join(Path.dirname(path), "qualification_claims")
    assert [claim_file] = File.ls!(claim_root)
    claim_path = Path.join(claim_root, claim_file)
    hidden_path = claim_path <> ".held"
    assert :ok = File.rename(claim_path, hidden_path)

    assert {:error, :qualification_artifact_unavailable} =
             Store.claim_queued_power(reopened, "controller:1", 1, "op:claim", "boot:1", 101)

    assert :ok = File.rename(hidden_path, claim_path)

    assert {:ok, %{queued_requests: 1, claimed_requests: 0, store_revision: 7}} =
             Store.health(reopened)

    parent = self()

    worker =
      spawn(fn ->
        send(
          parent,
          {:claim_result,
           Store.claim_queued_power(reopened, "controller:1", 1, "op:claim", "boot:1", 101)}
        )

        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(worker)

    assert_receive {:claim_result, {:ok, %{disposition: :claimed, revision: 8} = claimed, token}},
                   1_000

    assert byte_size(token) == 32

    assert {:ok, %{items: claim_events, next_after: 8, has_more: false}} =
             Store.request_events_page(reopened, controller, 0, 100)

    assert Enum.map(claim_events, &{&1["disposition"], &1["revision"]}) ==
             [{"held", 4}, {"queued", 7}, {"claimed", 8}]

    assert {:error, :claim_owner_active} =
             Store.reject_abandoned_claim(reopened, "controller:1", 1, "op:claim")

    send(worker, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}

    assert {:ok, %{queued_requests: 0, claimed_requests: 1, dispatch_enabled: false}} =
             Store.health(reopened)

    assert {:error, :request_not_held} = Store.cancel_request(reopened, controller, 1, "op:claim")
    :ok = GenServer.stop(reopened)
    assert {:ok, db} = Sqlite3.open(path)

    assert {:ok, statement} =
             Sqlite3.prepare(
               db,
               "SELECT typeof(claim_token), length(claim_token) FROM request_execution"
             )

    assert {:ok, [["blob", 32]]} = Sqlite3.fetch_all(db, statement)
    assert :ok = Sqlite3.release(db, statement)
    assert :ok = Sqlite3.close(db)
    assert {:ok, again} = Store.start_link([path: path] ++ qualification_keys)
    assert {:ok, ^claimed} = Store.request_status(again, controller, 1, "op:claim")

    assert {:error, :request_not_queued} =
             Store.claim_queued_power(again, "controller:1", 1, "op:claim", "boot:1", 102)

    assert {:ok,
            %{disposition: :rejected, reason: "worker_abandoned_before_handoff", revision: 9} =
              abandoned} =
             Store.reject_abandoned_claim(again, "controller:1", 1, "op:claim")

    assert {:error, :request_not_claimed} =
             Store.reject_abandoned_claim(again, "controller:1", 1, "op:claim")

    assert {:ok, ^abandoned} = Store.request_status(again, controller, 1, "op:claim")
    assert {:ok, %{claimed_requests: 0}} = Store.health(again)

    assert {:ok, %{items: [abandoned_event], next_after: 9, has_more: false}} =
             Store.request_events_page(again, controller, 8, 100)

    assert abandoned_event == %{
             "authority_epoch" => 1,
             "operation_id" => "op:claim",
             "disposition" => "rejected",
             "reason" => "worker_abandoned_before_handoff",
             "revision" => 9
           }

    next_mutation = %{mutation | operation_id: "op:next"}

    assert {:ok, %{disposition: :held, revision: 10}} =
             Store.submit_request(again, controller, next_mutation)

    assert {:ok, %{disposition: :queued, revision: 11}} =
             Store.admit_held_power(again, controller, 1, "op:next", "boot:1", 101)

    assert {:ok, %{disposition: :claimed, revision: 12}, next_token} =
             Store.claim_queued_power(again, "controller:1", 1, "op:next", "boot:1", 101)

    assert byte_size(next_token) == 32

    held_mutation = %{mutation | operation_id: "op:held:during-fence"}

    assert {:ok, %{disposition: :held, revision: 13}} =
             Store.submit_request(again, controller, held_mutation)

    assert {:error, :stale_store_revision} = Store.fence_rule_generation(again, 12, 1)
    assert {:error, :stale_authority_epoch} = Store.fence_rule_generation(again, 13, 2)

    assert {:ok, %{store_revision: 16, rule_generation: 1, affected_requests: 2}} =
             Store.fence_rule_generation(again, 13, 1)

    assert {:ok, %{rule_generation: 1, held_requests: 0, claimed_requests: 0}} =
             Store.health(again)

    assert {:error, :request_not_claimed} =
             Store.reject_abandoned_claim(again, "controller:1", 1, "op:next")

    assert {:ok, %{disposition: :rejected, reason: "rule_generation_fenced", revision: 16}} =
             Store.request_status(again, controller, 1, "op:next")

    assert {:ok, %{disposition: :rejected, reason: "rule_generation_fenced", revision: 15}} =
             Store.request_status(again, controller, 1, "op:held:during-fence")

    post_mutation = %{mutation | operation_id: "op:after-fence"}

    assert {:ok, %{disposition: :held, revision: 17}} =
             Store.submit_request(again, controller, post_mutation)

    assert {:ok, %{disposition: :queued, revision: 18}} =
             Store.admit_held_power(again, controller, 1, "op:after-fence", "boot:1", 101)

    assert {:ok, %{disposition: :claimed, revision: 19}, _token} =
             Store.claim_queued_power(again, "controller:1", 1, "op:after-fence", "boot:1", 101)

    assert {:ok, 21} = Store.revoke_thing(again, thing.id)

    assert {:ok, %{disposition: :rejected, reason: "target_revoked", revision: 21}} =
             Store.request_status(again, controller, 1, "op:after-fence")

    :ok = GenServer.stop(again)
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
               "DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; DROP TABLE profile_qualifications; DROP TABLE enrollment_review_history; DROP TABLE enrollment_bindings; PRAGMA user_version=5"
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
    assert [[11]] = rows(db, "PRAGMA user_version")
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM enrollment_bindings")
    :ok = Sqlite3.close(db)
  end

  test "version-seven reviewed identity migrates with backup verification", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; DROP TABLE profile_qualifications; PRAGMA user_version=7"
             )

    key = :binary.copy(<<11>>, 32)
    archive = path <> ".v7.backup"
    assert {:ok, %{store_revision: 2}} = Backup.export(db, archive, key)

    assert {:ok,
            %{
              store_revision: 2,
              dependencies: %{
                qualified_profile_rows: 0,
                claim_package_refs: [],
                reviewer_keys_required: false
              }
            }} = Backup.verify(archive, key)

    :ok = Sqlite3.close(db)

    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, 2} = Store.revision(migrated)
    :ok = GenServer.stop(migrated)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[11]] = rows(db, "PRAGMA user_version")
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM profile_qualifications")
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

  defp power_report(capability, value) do
    Observation.new(
      %{
        "thing_id" => "light:desk",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => value},
        "quality" => "reported",
        "trust" => "unauthenticated_local",
        "source_epoch" => "device:1",
        "source_sequence" => 1,
        "boot_epoch" => "boot:1",
        "source_time_utc_ms" => nil,
        "received_time_utc_ms" => 1_000_100,
        "received_monotonic_ms" => 100
      },
      capability
    )
  end

  defp insert_synthetic_qualification(path, revision, thing) do
    {case_public, case_private} =
      :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<1>>, 32))

    {decision_public, decision_private} =
      :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<2>>, 32))

    case_key_id = "fixture:case-reviewer"
    decision_key_id = "fixture:physical-reviewer"
    assert {:ok, runtime_digest} = ProfileBasis.runtime_digest()
    assert {:ok, document} = Registry.encode_thing(thing)
    assert {:ok, cases, programme_digest} = Programme.lifx_power_cases()
    assert {:ok, cohort_digest} = Evidence.cohort_digest(@qualification_cohort)
    assert {:ok, db} = Sqlite3.open(path)
    assert [[identity_digest]] = rows(db, "SELECT identity_digest FROM enrollment_bindings")

    basis = %{
      profile: "lifx-direct-power-v1",
      thing_id: thing.id,
      profile_ref: thing.profile_ref,
      qualification_ref: @selection["qualification_ref"],
      identity_digest: identity_digest,
      product: {1, 27},
      firmware: {2, 0},
      registry_digest: ProductRegistry.pinned_digest(),
      declaration_digest: test_digest(document),
      runtime_digest: runtime_digest,
      scope: :profile_mapping_only,
      status: :pending_physical_qualification
    }

    basis = Map.put(basis, :basis_digest, test_digest(basis))
    assert ProfileBasis.valid?(basis)

    attestations =
      Enum.map(cases, fn case_definition ->
        receipt =
          Map.merge(case_definition, %{
            "receipt_id" => "receipt:#{case_definition["case_id"]}",
            "status" => "passed",
            "cohort" => @qualification_cohort,
            "source_identity_ref" => @qualification_cohort["source_identity_ref"],
            "command_sequence" => ["fixture:request", "fixture:report"],
            "assertions" => [%{"id" => "matches", "expected" => true, "actual" => true}],
            "artifact_digests" => [String.duplicate("d", 64)],
            "exclusions" => [],
            "blockers" => [],
            "reviewer_ref" => case_key_id
          })

        assert {:ok, payload} =
                 Attestation.signing_payload(case_key_id, programme_digest, receipt)

        %{
          "receipt" => receipt,
          "reviewer_key_id" => case_key_id,
          "programme_digest" => programme_digest,
          "signature" =>
            :crypto.sign(:eddsa, :none, payload, [case_private, :ed25519])
            |> Base.url_encode64(padding: false)
        }
      end)

    decision = %{
      "schema" => "wotex-home.lifx-power-decision.v1",
      "scope" => "lifx_direct_power_v1",
      "outcome" => "allow_direct_power",
      "thing_id" => thing.id,
      "profile_ref" => thing.profile_ref,
      "resource_revision" => 0,
      "identity_digest" => identity_digest,
      "basis_digest" => basis.basis_digest,
      "registry_digest" => basis.registry_digest,
      "runtime_digest" => runtime_digest,
      "programme_digest" => programme_digest,
      "cohort_digest" => cohort_digest,
      "evidence_set_digest" => Decision.evidence_set_digest(attestations),
      "reviewer_key_id" => decision_key_id
    }

    assert {:ok, payload} = Decision.signing_payload(decision)

    signed = %{
      "decision" => decision,
      "signature" =>
        :crypto.sign(:eddsa, :none, payload, [decision_private, :ed25519])
        |> Base.url_encode64(padding: false)
    }

    case_keys = %{case_key_id => case_public}
    decision_keys = %{decision_key_id => decision_public}

    assert {:ok, verified} =
             Decision.verify(
               signed,
               basis,
               @qualification_cohort,
               attestations,
               case_keys,
               decision_keys
             )

    assert :ok =
             Claims.put(Path.join(Path.dirname(path), "qualification_claims"), verified)

    assert :ok =
             Sqlite3.execute(
               db,
               "INSERT INTO authority_journal VALUES (#{revision}, 'profile_qualified', 'light:desk')"
             )

    assert {:ok, statement} =
             Sqlite3.prepare(
               db,
               "INSERT INTO profile_qualifications VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'qualified', ?)"
             )

    assert :ok =
             Sqlite3.bind(statement, [
               "light:desk",
               "lifx.old-eu:1.0.0",
               0,
               identity_digest,
               basis.basis_digest,
               ProductRegistry.pinned_digest(),
               runtime_digest,
               verified.evidence_ref,
               revision
             ])

    assert {:ok, []} = Sqlite3.fetch_all(db, statement)
    assert :ok = Sqlite3.release(db, statement)
    assert :ok = Sqlite3.execute(db, "UPDATE meta SET value = #{revision} WHERE key = 'revision'")
    :ok = Sqlite3.close(db)
    [qualification_case_keys: case_keys, qualification_decision_keys: decision_keys]
  end

  defp test_digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

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
