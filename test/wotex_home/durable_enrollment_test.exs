Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableEnrollmentTest do
  @moduledoc false

  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Discovery.{Candidate, EnrollmentReview, Interview, Profile}
  alias WotexHome.Durable.{Backup, Registry, Store}
  alias WotexHome.Lifx.{Ledger, Packet, ProductRegistry, ProfileBasis, Transport}
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
      "stable_id" => "lifx:d073d5000001"
    },
    "trust_class" => "untrusted_network"
  }

  @interview %{
    "candidate_ref" => "capture:1",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware" => "2.0",
    "stable_id" => "lifx:d073d5000001"
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
    "stable_id" => "lifx:d073d5000001",
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

  defmodule PowerTransport do
    @moduledoc false
    @behaviour Transport

    @impl true
    def send({worker, observer}, endpoint, bytes) do
      {:ok, packet} = Packet.decode(bytes)
      send(observer, {:power_packet, packet.type})

      response =
        case packet.type do
          117 -> reply(packet, 45, <<>>)
          116 -> reply(packet, 118, <<65_535::little-16>>)
        end

      send(worker, {:power_datagram, endpoint, response})
      :ok
    end

    @impl true
    def recv({_worker, _observer}, timeout_ms) do
      receive do
        {:power_datagram, endpoint, bytes} -> {:ok, endpoint, bytes}
      after
        timeout_ms -> {:error, :timeout}
      end
    end

    defp reply(%Packet{source: source, target: target, sequence: sequence}, type, payload) do
      size = 36 + byte_size(payload)

      <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
        sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
    end
  end

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

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [["light:desk", "lifx:d073d5000001", "owner:1", "legacy_tofu", 3]] =
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

  @tag requires_socket: true
  test "enrollment status socket scopes the retained review to its owner", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, owner_credential, 1} =
             Store.provision_principal(store, "owner:1", ["enroll:review"], [])

    assert {:ok, other_credential, 2} =
             Store.provision_principal(store, "owner:2", ["enroll:review"], [])

    {candidate, interview, profile, thing} = fixtures()

    assert {:ok, 3} =
             commit(store, owner_credential, [candidate], interview, [profile], thing, @selection)

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
    :ok = GenServer.stop(store)
  end

  test "authenticated re-review replaces current identity and rejects held work", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:error, :review_conflict} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               interview,
               [profile],
               thing,
               @selection
             )

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

    assert {:ok, 5} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               next_selection
             )

    assert {:ok, 5} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               next_selection
             )

    assert {:error, :review_conflict} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               interview,
               [expanded_profile],
               thing,
               next_selection
             )

    assert {:ok, %{disposition: :rejected, reason: "identity_rechecked", revision: 6}} =
             Store.request_status(store, controller, 1, "op:1")

    assert {:error, :enrollment_conflict} =
             commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:error, :enrollment_conflict} =
             commit(
               store,
               owner,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               next_selection
             )

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

    assert {:ok, 5} =
             Store.rereview_enrollment(
               reopened,
               owner,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               next_selection
             )

    assert {:ok, 6} = Store.revision(reopened)

    assert {:ok, 7} = Store.revoke_thing(reopened, thing.id)

    assert {:ok, %{state: :revoked}} =
             Store.enrollment_review_status(reopened, owner, "review:1")

    assert {:ok, %{state: :revoked}} =
             Store.enrollment_review_status(reopened, owner, "review:2")

    :ok = GenServer.stop(reopened)
  end

  test "a superseded re-review reference cannot be retried as current", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    changed_interview = %{interview | firmware: "2.1"}
    expanded_profile = %{profile | firmware_versions: ["2.0", "2.1"]}
    first = %{@selection | "review_ref" => "review:2"}
    second = %{@selection | "review_ref" => "review:3"}

    assert {:ok, 3} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               first
             )

    assert {:ok, 4} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               interview,
               [expanded_profile],
               thing,
               second
             )

    assert {:error, :review_conflict} =
             Store.rereview_enrollment(
               store,
               owner,
               [candidate],
               changed_interview,
               [expanded_profile],
               thing,
               first
             )

    assert {:ok, %{state: :superseded, review_revision: 3, binding_revision: 4}} =
             Store.enrollment_review_status(store, owner, "review:2")

    :ok = GenServer.stop(store)
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
               WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
                 "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP INDEX power_handoff_time; ALTER TABLE request_execution DROP COLUMN handoff_store_boot_epoch; ALTER TABLE request_execution DROP COLUMN handoff_store_monotonic_ms; DROP TABLE rule_candidate_reviews; DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; DROP TABLE profile_qualifications; DROP TABLE enrollment_review_history; ALTER TABLE enrollment_bindings DROP COLUMN digest_version; PRAGMA user_version=6"
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
    assert [[20]] = rows(db, "PRAGMA user_version")
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

    assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:already")

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

    assert ["explicit_request", 4, 1, 7] == causal_root(path, "op:first")

    assert {:ok,
            %{disposition: :rejected, reason: "cancelled_before_claim", revision: 8} = cancelled} =
             Store.cancel_request(reopened, controller, 1, "op:first")

    assert {:ok, ^cancelled} = Store.cancel_request(reopened, controller, 1, "op:first")
    assert {:ok, ^cancelled} = Store.submit_request(reopened, controller, mutation)
    assert ["explicit_request", 4, 1, 7] == causal_root(path, "op:first")

    next_mutation = %{mutation | operation_id: "op:next"}

    assert {:ok, %{disposition: :held, revision: 9}} =
             Store.submit_request(reopened, controller, next_mutation)

    assert {:ok, %{disposition: :queued, revision: 10}} =
             Store.admit_held_power(reopened, controller, 1, "op:next", "boot:1", 101)

    assert {:ok, %{held_requests: 0, queued_requests: 1, store_revision: 10}} =
             Store.health(reopened)

    :ok = GenServer.stop(reopened)
    assert {:ok, again} = Store.start_link([path: path] ++ qualification_keys)
    assert {:ok, ^cancelled} = Store.submit_request(again, controller, mutation)
    assert ["explicit_request", 4, 1, 7] == causal_root(path, "op:first")
    :ok = GenServer.stop(again)
  end

  test "combined control and qualification survive guarded claim, handoff and restart",
       %{
         path: path
       } do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(store, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, controller, 3} =
             Store.provision_principal(
               store,
               "controller:1",
               ["control:ordinary", "qualify:profile"],
               [thing.id]
             )

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

    assert ["explicit_request", 4, 1, 7] == causal_root(path, "op:claim")

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

    assert ["explicit_request", 4, 1, 7] == causal_root(path, "op:claim")
    assert ["explicit_request", 10, 1, 11] == causal_root(path, "op:next")
    assert ["explicit_request", 13, 0, nil] == causal_root(path, "op:held:during-fence")

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

    parent = self()
    assert {:ok, power_supervisor} = Task.Supervisor.start_link()

    authority =
      Authority.new(store: again, power_supervisor: power_supervisor, power_dispatch: true)

    assert {:ok, ledger} = Ledger.new(42)
    assert {:ok, target} = Packet.target_from_hex("d073d5000001")
    assert {:ok, execution_clock} = Agent.start_link(fn -> 101 end)

    transport_factory = fn ->
      {:ok, {PowerTransport, {self(), parent}}, fn -> send(parent, :power_transport_closed) end}
    end

    assert {:ok, %{disposition: :observed, revision: 23}, settled_ledger} =
             Authority.lifx_execute_power(
               authority,
               "controller:1",
               1,
               "op:after-fence",
               candidate,
               target,
               ledger,
               transport_factory: transport_factory,
               clock: fn ->
                 Agent.get_and_update(execution_clock, &{{&1, 1_000_000 + &1}, &1 + 1})
               end,
               source_epoch: "device:1",
               source_sequence: 2,
               boot_epoch: "boot:1",
               ack_timeout_ms: 100,
               read_timeout_ms: 100,
               duration_ms: 0
             )

    assert map_size(settled_ledger.pending) == 0
    assert map_size(:sys.get_state(again).claim_owners) == 0
    {:ok, receipt_db} = Sqlite3.open(path, mode: :readonly)

    [[22, receipt_epoch, receipt_ms]] =
      rows(
        receipt_db,
        "SELECT revision, received_store_boot_epoch, received_store_monotonic_ms FROM observation_current"
      )

    assert receipt_epoch == :sys.get_state(again).clock_epoch and is_integer(receipt_ms)

    assert [[22, receipt_epoch, receipt_ms]] ==
             rows(
               receipt_db,
               "SELECT revision, received_store_boot_epoch, received_store_monotonic_ms FROM journal WHERE revision=22"
             )

    assert :ok = Store.validate_snapshot(receipt_db)
    :ok = Sqlite3.close(receipt_db)
    assert_receive {:power_packet, 117}, 1_000
    assert_receive {:power_packet, 116}, 1_000
    assert_receive :power_transport_closed, 1_000
    assert_eventually(fn -> Task.Supervisor.children(power_supervisor) == [] end)

    assert_eventually(fn ->
      Store.request_status(again, controller, 1, "op:after-fence") ==
        {:ok,
         %WotexHome.Durable.Receipt{
           principal_id: "controller:1",
           authority_epoch: 1,
           operation_id: "op:after-fence",
           disposition: :observed,
           reason: nil,
           revision: 23
         }}
    end)

    assert {:ok,
            %{
              claimed_requests: 0,
              unknown_outcomes: 0,
              store_revision: 23,
              dispatch_enabled: false
            }} = Store.health(again)

    assert {:ok, %{items: handoff_events, next_after: 23, has_more: false}} =
             Store.request_events_page(again, controller, 18, 100)

    assert Enum.map(handoff_events, &{&1["disposition"], &1["reason"], &1["revision"]}) ==
             [
               {"claimed", nil, 19},
               {"dispatching", nil, 20},
               {"protocol_accepted", nil, 21},
               {"observed", nil, 23}
             ]

    contradicted_mutation = %{
      mutation
      | operation_id: "op:contradicted",
        value: %{"type" => "boolean", "value" => false}
    }

    assert {:ok, %{disposition: :held, revision: 24}} =
             Store.submit_request(again, controller, contradicted_mutation)

    advance_store_clock(again, 250)

    assert {:ok, %{disposition: :queued, revision: 25}} =
             Store.admit_held_power(again, controller, 1, "op:contradicted", "boot:1", 106)

    assert {:ok, contradiction_clock} = Agent.start_link(fn -> 106 end)
    assert {:ok, contradiction_ledger} = Ledger.new(43)

    assert {:ok,
            %{
              disposition: :contradicted,
              reason: "readback_mismatch",
              revision: 30
            }, _ledger} =
             Authority.lifx_execute_power(
               authority,
               "controller:1",
               1,
               "op:contradicted",
               candidate,
               target,
               contradiction_ledger,
               transport_factory: transport_factory,
               clock: fn ->
                 Agent.get_and_update(contradiction_clock, &{{&1, 1_000_000 + &1}, &1 + 1})
               end,
               source_epoch: "device:1",
               source_sequence: 3,
               boot_epoch: "boot:1",
               ack_timeout_ms: 100,
               read_timeout_ms: 100,
               duration_ms: 0
             )

    unknown_mutation = %{
      mutation
      | operation_id: "op:worker-exit",
        value: %{"type" => "boolean", "value" => false}
    }

    assert {:ok, %{disposition: :held, revision: 31}} =
             Store.submit_request(again, controller, unknown_mutation)

    advance_store_clock(again, 250)

    assert {:ok, %{disposition: :queued, revision: 32}} =
             Store.admit_held_power(again, controller, 1, "op:worker-exit", "boot:1", 111)

    exit_worker =
      spawn(fn ->
        {:ok, claim} =
          Store.claim_lifx_power(
            again,
            "controller:1",
            1,
            "op:worker-exit",
            "boot:1",
            111
          )

        send(parent, {:exit_claim, claim})

        receive do
          :handoff ->
            send(
              parent,
              {:exit_handoff,
               Store.handoff_claimed_power(
                 again,
                 "controller:1",
                 1,
                 "op:worker-exit",
                 claim.token,
                 111
               )}
            )

            receive do
              :ack ->
                send(
                  parent,
                  {:exit_ack,
                   Store.accept_power_ack(again, "controller:1", 1, "op:worker-exit", claim.token)}
                )
            end

            receive do
              :finish -> :ok
            end
        end
      end)

    exit_monitor = Process.monitor(exit_worker)
    assert_receive {:exit_claim, %{receipt: %{revision: 33}} = exit_claim}, 1_000

    assert {:error, :claim_not_owned} =
             Store.handoff_claimed_power(
               again,
               "controller:1",
               1,
               "op:worker-exit",
               exit_claim.token,
               111
             )

    send(exit_worker, :handoff)
    assert_receive {:exit_handoff, {:ok, %{disposition: :dispatching, revision: 34}}}, 1_000
    exit_timing = handoff_timing(path, "op:worker-exit")

    # A disjoint authority write must not lose the live handoff owner. Its death
    # still needs durable unknown settlement, without a restart or resend.
    assert {:ok, _diagnostic, 35} =
             Store.provision_principal(again, "diagnostic:unrelated", ["read"], [])

    send(exit_worker, :ack)
    assert_receive {:exit_ack, {:ok, %{disposition: :protocol_accepted, revision: 36}}}, 1_000
    assert handoff_timing(path, "op:worker-exit") == exit_timing

    assert {:ok, _other_diagnostic, 37} =
             Store.provision_principal(again, "diagnostic:another", ["read"], [])

    send(exit_worker, :finish)
    assert_receive {:DOWN, ^exit_monitor, :process, ^exit_worker, :normal}, 1_000

    assert_eventually(fn ->
      match?(
        {:ok,
         %{
           disposition: :outcome_unknown,
           reason: "worker_exit_after_handoff",
           revision: 38
         }},
        Store.request_status(again, controller, 1, "op:worker-exit")
      )
    end)

    assert {:ok, %{unknown_outcomes: 1, store_revision: 38}} = Store.health(again)
    assert handoff_timing(path, "op:worker-exit") == exit_timing

    assert map_size(:sys.get_state(again).claim_owners) == 0
    assert {:ok, 39} = Store.revoke_thing(again, thing.id)
    assert handoff_timing(path, "op:worker-exit") == exit_timing

    :ok = GenServer.stop(again)
  end

  for boundary <- [:claim, :handoff],
      {name, sql} <- [
        {"missing root", "DELETE FROM request_causal_roots WHERE operation_id='op:attempt'"},
        {"wrong reservation",
         "UPDATE request_causal_roots SET reservation_revision=4 WHERE operation_id='op:attempt'"}
      ] do
    @corrupt_boundary boundary
    @corrupt_cause_sql sql
    test "#{name} independently disables the writer at #{boundary}", %{path: path} do
      {store, credential, _thing} = attempt_fixture(path)
      boundary = @corrupt_boundary
      {_disposition, token} = prepare_attempt_boundary(boundary, store, credential)
      {:ok, original} = Store.request_status(store, credential, 1, "op:attempt")
      {:ok, revision} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)
      :ok = Sqlite3.execute(db, @corrupt_cause_sql)
      assert {:error, _} = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      assert {:error, :corrupt_receipt} = attempt_boundary(boundary, store, credential, token)
      assert {:ok, ^original} = Store.request_status(store, credential, 1, "op:attempt")
      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, %{writable: false, dispatch_enabled: false}} = Store.health(store)
      assert [nil, nil, nil] == operation_timing_or_absent(path, "op:attempt")
      :ok = GenServer.stop(store)
    end
  end

  for boundary <- [:claim, :handoff] do
    @causal_boundary boundary
    test "legacy missing causal provenance independently blocks #{@causal_boundary}", %{
      path: path
    } do
      {store, credential, _thing} = attempt_fixture(path)
      boundary = @causal_boundary
      {_disposition, token} = prepare_attempt_boundary(boundary, store, credential)
      {:ok, original} = Store.request_status(store, credential, 1, "op:attempt")
      {:ok, revision} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)
      # Fault injection conservatively loses provenance, not the spent budget.
      :ok =
        Sqlite3.execute(
          db,
          "UPDATE request_causal_roots SET origin='legacy_request', created_revision=NULL, reservation_revision=NULL WHERE operation_id='op:attempt'"
        )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)

      assert {:error, :causal_provenance_unavailable} =
               attempt_boundary(boundary, store, credential, token)

      assert {:ok, ^original} = Store.request_status(store, credential, 1, "op:attempt")
      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
      assert ["legacy_request", nil, 1, nil] == causal_root(path, "op:attempt")
      assert [nil, nil, nil] == operation_timing_or_absent(path, "op:attempt")
      :ok = GenServer.stop(store)
    end
  end

  test "a lost root rolls back queue acceptance and disables the corrupted writer", %{path: path} do
    {store, credential, _thing} = attempt_fixture(path)
    {:ok, revision} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "DELETE FROM request_causal_roots WHERE operation_id='op:attempt'")
    :ok = Sqlite3.close(db)

    assert {:error, :corrupt_receipt} =
             Store.admit_held_power(store, credential, 1, "op:attempt", "boot:1", 101)

    assert {:ok, ^revision} = Store.revision(store)

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.request_status(store, credential, 1, "op:attempt")

    assert {:ok, %{writable: false, queued_requests: 0, held_requests: 1}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  test "a conservatively spent legacy root cannot be readmitted or refunded", %{path: path} do
    {store, credential, _thing} = attempt_fixture(path)
    {:ok, revision} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE request_causal_roots SET origin='legacy_request', created_revision=NULL, reserved_effects=1 WHERE operation_id='op:attempt'"
      )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)

    assert {:error, :causal_budget_exhausted} =
             Store.admit_held_power(store, credential, 1, "op:attempt", "boot:1", 101)

    assert {:ok, ^revision} = Store.revision(store)

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.request_status(store, credential, 1, "op:attempt")

    assert {:ok, %{writable: true, queued_requests: 0, held_requests: 1}} = Store.health(store)
    assert ["legacy_request", nil, 1, nil] == causal_root(path, "op:attempt")

    assert {:ok, %{disposition: :rejected, reason: "cancelled"}} =
             Store.cancel_request(store, credential, 1, "op:attempt")

    assert ["legacy_request", nil, 1, nil] == causal_root(path, "op:attempt")
    :ok = GenServer.stop(store)
  end

  for boundary <- [:admission, :claim, :handoff] do
    @rule_boundary boundary
    test "a new operator override blocks rule work at #{@rule_boundary}", %{path: path} do
      {store, credential, manager, thing} = active_rule_fixture(path)

      assert {:ok, %{disposition: :held}} =
               Authority.invoke_rule(
                 Authority.new(store: store),
                 credential,
                 1,
                 "op:rule",
                 1,
                 "rule:power"
               )

      token = prepare_rule_boundary(@rule_boundary, store, credential)

      assert {:ok, _} =
               Store.issue_override_operation_live(
                 store,
                 credential,
                 1,
                 "override:rule",
                 thing.id,
                 0,
                 60_000
               )

      {:ok, revision} = Store.revision(store)

      assert {:error, :operator_override_active} =
               rule_boundary(@rule_boundary, store, credential, token)

      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, %{writable: true}} = Store.health(store)
      assert [nil, nil, nil] == operation_timing_or_absent(path, "op:rule")

      assert {:ok, _} =
               Store.revoke_override_operation_live(store, credential, 1, "override:rule")

      assert {:ok, _} = rule_boundary(@rule_boundary, store, credential, token)
      assert {:ok, _} = Authority.rule_status(Authority.new(store: store), manager)
      :ok = GenServer.stop(store)
    end
  end

  for boundary <- [:admission, :claim, :handoff] do
    @damaged_rule_boundary boundary
    test "damaged activation blocks rule work at #{@damaged_rule_boundary} without handoff",
         %{path: path} do
      {store, credential, _manager, _thing} = active_rule_fixture(path)
      authority = Authority.new(store: store)

      assert {:ok, _} =
               Authority.invoke_rule(authority, credential, 1, "op:rule", 1, "rule:power")

      token = prepare_rule_boundary(@damaged_rule_boundary, store, credential)
      {:ok, original} = Store.request_status(store, credential, 1, "op:rule")
      {:ok, revision} = Store.revision(store)
      root = causal_root(path, "op:rule")
      {:ok, db} = Sqlite3.open(path)
      :ok = Sqlite3.execute(db, "UPDATE rule_activations SET previous_generation=1")
      :ok = Sqlite3.close(db)

      assert {:error, :corrupt_rule_admission} =
               rule_boundary(@damaged_rule_boundary, store, credential, token)

      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, ^original} = Store.request_status(store, credential, 1, "op:rule")
      assert causal_root(path, "op:rule") == root
      assert [nil, nil, nil] == operation_timing_or_absent(path, "op:rule")
      assert {:ok, %{writable: false, dispatch_enabled: false}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  for {phase, unknown, disposition} <- [
        {:held, 0, :rejected},
        {:queued, 0, :rejected},
        {:claimed, 0, :rejected},
        {:dispatching, 1, :outcome_unknown}
      ] do
    @maintenance_phase phase
    @maintenance_unknown unknown
    @maintenance_disposition disposition
    test "maintenance fences #{@maintenance_phase} rule work and preserves uncertainty", %{
      path: path
    } do
      {store, credential, manager, _thing} = active_rule_fixture(path)

      {:ok, maintainer, _} =
        Store.provision_principal(store, "maintainer:fixture", ["host:maintain"], [])

      authority = Authority.new(store: store)

      assert {:ok, _} =
               Authority.invoke_rule(authority, credential, 1, "op:rule", 1, "rule:power")

      phase = @maintenance_phase

      token = prepare_maintenance_boundary(phase, store, credential)
      root = causal_root(path, "op:rule")
      {:ok, expected} = Store.revision(store)
      unknown = @maintenance_unknown

      assert {:ok,
              %{affected_requests: 1, unknown_outcomes: ^unknown, rule_generation: 2} = barrier} =
               Authority.begin_maintenance(authority, maintainer, 1, "maintenance:1", expected)

      disposition = @maintenance_disposition

      assert {:ok, %{disposition: ^disposition}} =
               Store.request_status(store, credential, 1, "op:rule")

      assert causal_root(path, "op:rule") == root

      assert {:error, :maintenance_active} =
               Store.admit_held_power(store, credential, 1, "op:rule", "boot:1", 101)

      assert {:error, :maintenance_active} =
               Store.claim_lifx_power(store, "controller:1", 1, "op:rule", "boot:1", 101)

      verify_maintenance_ack(phase, store, token)
      assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      assert :ok = Sqlite3.close(db)

      assert {:ok, _} =
               Authority.end_maintenance(
                 authority,
                 maintainer,
                 1,
                 "resume:1",
                 barrier.revision,
                 barrier.revision
               )

      assert {:ok, %{state: :inactive, admission_revision: 0, rule_generation: 2}} =
               Store.rule_status(store, manager)

      :ok = GenServer.stop(store)
    end
  end

  test "activation rejects old claims and discloses handed-off rule effects as unknown", %{
    path: path
  } do
    {store, credential, manager, _thing} = active_rule_fixture(path)
    authority = Authority.new(store: store)
    assert {:ok, _} = Authority.invoke_rule(authority, credential, 1, "op:rule", 1, "rule:power")
    token = prepare_rule_boundary(:handoff, store, credential)
    assert {:ok, %{disposition: :dispatching}} = rule_boundary(:handoff, store, credential, token)
    {:ok, expected} = Store.revision(store)

    assert {:ok, %{unknown_outcomes: 1, affected_requests: 1, rule_generation: 2}} =
             Authority.suspend_rules(authority, manager, 1, "rule:suspend", expected)

    assert {:ok,
            %{disposition: :outcome_unknown, reason: "rule_generation_changed_after_handoff"}} =
             Store.request_status(store, credential, 1, "op:rule")

    assert {:error, :request_not_handed_off} =
             Store.accept_power_ack(store, "controller:1", 1, "op:rule", token)

    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    assert ["explicit_request", _, 1, _] = causal_root(path, "op:rule")
    :ok = GenServer.stop(store)
  end

  for boundary <- [:admission, :claim, :handoff] do
    @invariant_boundary boundary
    test "expired reported constraints block #{@invariant_boundary} without consuming an attempt",
         %{path: path} do
      {store, credential, thing} = attempt_fixture(path)

      {:ok, policy, _} =
        Store.provision_principal(store, "policy:1", ["policy:manage", "read"], [thing.id])

      {:ok, predicate} =
        WotexHome.Rules.Predicate.new(%{
          "op" => "eq",
          "fact" => %{"thing_id" => thing.id, "capability_key" => "power"},
          "value" => %{"type" => "boolean", "value" => false}
        })

      {:ok, expected} = Store.revision(store)

      assert {:ok, _} =
               Authority.set_invariant(
                 Authority.new(store: store),
                 policy,
                 1,
                 "policy:install",
                 expected,
                 thing.id,
                 0,
                 predicate
               )

      assert {:ok, %{disposition: :rejected, reason: "invariant_policy_changed"}} =
               Store.request_status(store, credential, 1, "op:attempt")

      {:ok, report} = power_report(thing.capabilities["power"], false)

      assert {:ok, _} =
               Store.record(store, %{report | source_sequence: 2}, thing.capabilities["power"])

      {:ok, mutation} =
        Mutation.new(%{
          "api_version" => 1,
          "authority_epoch" => 1,
          "operation_id" => "op:guarded",
          "expected_revision" => 0,
          "target_id" => thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true}
        })

      assert {:ok, %{disposition: :held}} = Store.submit_request(store, credential, mutation)
      boundary = @invariant_boundary

      token = prepare_invariant_boundary(boundary, store, credential)

      {:ok, revision} = Store.revision(store)
      advance_store_clock(store, 5_001)

      result = invariant_boundary(boundary, store, credential, token)

      assert {:error, :invariant_unresolved} = result
      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, %{writable: true}} = Store.health(store)
      assert [nil, nil, nil] == operation_timing_or_absent(path, "op:guarded")
      :ok = GenServer.stop(store)
    end
  end

  for boundary <- [:admission, :claim, :handoff] do
    @boundary boundary
    test "durable attempt exhaustion is independently rechecked at #{@boundary}", %{path: path} do
      {store, credential, thing} = attempt_fixture(path)
      boundary = @boundary

      {disposition, token} = prepare_attempt_boundary(boundary, store, credential)

      assert {:ok, original} = Store.request_status(store, credential, 1, "op:attempt")
      assert original.disposition == disposition
      root_before_guard = causal_root(path, "op:attempt")
      seed_attempt_history(path, store, thing)
      advance_store_clock(store, 10_000)
      assert {:ok, revision} = Store.revision(store)

      assert {:error, :attempt_rate_exhausted} =
               attempt_boundary(boundary, store, credential, token)

      # A different worker observation time is not a Store rate-clock override.
      assert_observation_clock_is_not_rate_clock(boundary, store, credential)

      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, ^original} = Store.request_status(store, credential, 1, "op:attempt")
      assert causal_root(path, "op:attempt") == root_before_guard
      assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
      assert [nil, nil, nil] == operation_timing_or_absent(path, "op:attempt")

      advance_store_clock(store, 60_000)
      assert {:ok, _} = attempt_boundary(boundary, store, credential, token)
      assert {:ok, next_revision} = Store.revision(store)
      assert next_revision == revision + 1
      assert ["explicit_request", 4, 1, reservation] = causal_root(path, "op:attempt")
      assert reservation == reservation_revision_for(boundary, next_revision)
      :ok = GenServer.stop(store)
    end
  end

  test "credential rotation, another principal and generation fencing never replenish Thing history",
       %{path: path} do
    {store, credential, thing} = attempt_fixture(path)
    seed_attempt_history(path, store, thing)
    advance_store_clock(store, 10_000)

    assert {:ok, _replacement, _revision} =
             Store.rotate_principal_credential(store, "controller:1")

    assert {:error, :unauthorized} = Store.request_status(store, credential, 1, "op:attempt")

    assert {:ok, other, _revision} =
             Store.provision_principal(store, "controller:2", ["control:ordinary"], [thing.id])

    {:ok, mutation} =
      Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "op:other",
        "expected_revision" => 0,
        "target_id" => thing.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:ok, %{disposition: :held}} = Store.submit_request(store, other, mutation)

    assert {:error, :attempt_rate_exhausted} =
             Store.admit_held_power(store, other, 1, "op:other", "boot:1", 101)

    assert {:ok, revision} = Store.revision(store)
    assert {:ok, %{rule_generation: 1}} = Store.fence_rule_generation(store, revision, 1)

    assert {:ok, %{disposition: :held}} =
             Store.submit_request(store, other, %{mutation | operation_id: "op:after-generation"})

    assert {:error, :attempt_rate_exhausted} =
             Store.admit_held_power(store, other, 1, "op:after-generation", "boot:1", 101)

    :ok = GenServer.stop(store)
  end

  for actual <- [true, false] do
    @actual actual
    test "unknown power reconciles with new #{@actual} evidence without repeating its effect",
         %{path: path} do
      assert {:ok, initial} = Store.start_link(path: path)

      assert {:ok, owner, 1} =
               Store.provision_principal(initial, "owner:1", ["enroll:review"], [])

      {candidate, interview, profile, thing} = fixtures()

      assert {:ok, 2} =
               commit(initial, owner, [candidate], interview, [profile], thing, @selection)

      assert {:ok, controller, 3} =
               Store.provision_principal(initial, "controller:1", ["control:ordinary"], [thing.id])

      assert {:ok, mutation} =
               Mutation.new(%{
                 "api_version" => 1,
                 "operation_id" => "op:reconcile",
                 "authority_epoch" => 1,
                 "expected_revision" => 0,
                 "target_id" => thing.id,
                 "capability_key" => "power",
                 "value" => %{"type" => "boolean", "value" => true}
               })

      assert {:ok, %{revision: 4}} = Store.submit_request(initial, controller, mutation)
      capability = thing.capabilities["power"]
      {:ok, baseline} = power_report(capability, false)
      assert {:ok, 5} = Store.record(initial, baseline, capability)
      :ok = GenServer.stop(initial)
      keys = insert_synthetic_qualification(path, 6, thing)
      assert {:ok, store} = Store.start_link([path: path] ++ keys)

      assert {:ok, %{revision: 7}} =
               Store.admit_held_power(store, controller, 1, "op:reconcile", "boot:1", 101)

      parent = self()
      store_state = :sys.get_state(store)
      store_epoch = store_state.clock_epoch
      before_ms = System.monotonic_time(:millisecond) - store_state.clock_origin

      worker =
        spawn(fn ->
          {:ok, claim} =
            Store.claim_lifx_power(store, "controller:1", 1, "op:reconcile", "boot:1", 101)

          {:ok, _} =
            Store.handoff_claimed_power(
              store,
              "controller:1",
              1,
              "op:reconcile",
              claim.token,
              101
            )

          result =
            Store.mark_power_outcome_unknown(
              store,
              "controller:1",
              1,
              "op:reconcile",
              claim.token,
              :readback_timeout
            )

          send(parent, {:unknown, result})

          receive do
            :close_transport -> :ok
          end
        end)

      monitor = Process.monitor(worker)
      assert_receive {:unknown, {:ok, %{disposition: :outcome_unknown, revision: 10}}}, 1_000
      assert map_size(:sys.get_state(store).claim_owners) == 1

      assert [9, ^store_epoch, store_ms] = timing = handoff_timing(path, "op:reconcile")
      assert store_epoch != "boot:1"
      assert store_ms >= before_ms
      assert store_ms <= System.monotonic_time(:millisecond) - store_state.clock_origin

      assert {:error, :worker_still_active} =
               Store.reconcile_unknown_power(
                 store,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 5,
                 "boot:1",
                 101
               )

      send(worker, :close_transport)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
      assert_eventually(fn -> map_size(:sys.get_state(store).claim_owners) == 0 end)

      assert {:error, :reconciliation_evidence_not_new} =
               Store.reconcile_unknown_power(
                 store,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 5,
                 "boot:1",
                 101
               )

      assert {:error, :stale_receipt_revision} =
               Store.reconcile_unknown_power(
                 store,
                 controller,
                 1,
                 "op:reconcile",
                 9,
                 5,
                 "boot:1",
                 101
               )

      assert {:ok, 10} = Store.revision(store)
      :ok = GenServer.stop(store)

      # Restart loses volatile observations' freshness, not the unresolved row.
      assert {:ok, reopened} = Store.start_link([path: path] ++ keys)
      assert :sys.get_state(reopened).clock_epoch != store_epoch
      assert handoff_timing(path, "op:reconcile") == timing
      authority = Authority.new(store: reopened)
      {:ok, report} = power_report(capability, @actual)

      synthetic = %{
        report
        | source_sequence: 2,
          boot_epoch: "boot:recovery",
          received_monotonic_ms: 200,
          trust: "synthetic_lab"
      }

      assert {:ok, 11} = Store.record(reopened, synthetic, capability)

      assert {:error, :invalid_power_readback} =
               Authority.reconcile_lifx_power(
                 authority,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 11,
                 "boot:recovery",
                 201
               )

      fresh = %{synthetic | source_sequence: 3, trust: "unauthenticated_local"}
      assert {:ok, 12} = Store.record(reopened, fresh, capability)

      assert {:error, :reconciliation_evidence_changed} =
               Authority.reconcile_lifx_power(
                 authority,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 11,
                 "boot:recovery",
                 201
               )

      assert {:error, :invalid_power_readback} =
               Authority.reconcile_lifx_power(
                 authority,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:other",
                 201
               )

      assert {:error, :observation_unavailable} =
               Authority.reconcile_lifx_power(
                 authority,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:recovery",
                 5_201
               )

      assert {:error, :unauthorized} =
               Authority.reconcile_lifx_power(
                 authority,
                 :binary.copy(<<1>>, 32),
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:recovery",
                 201
               )

      assert {:error, :permission_denied} =
               Authority.reconcile_lifx_power(
                 authority,
                 owner,
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:recovery",
                 201
               )

      assert {:ok, %{disposition: :outcome_unknown, revision: 10}} =
               Store.request_status(reopened, controller, 1, "op:reconcile")

      assert {:ok, 12} = Store.revision(reopened)

      claim_root = Path.join(Path.dirname(path), "qualification_claims")
      assert [claim_file] = File.ls!(claim_root)
      claim_path = Path.join(claim_root, claim_file)
      hidden_path = claim_path <> ".hidden"
      assert :ok = File.rename(claim_path, hidden_path)

      assert {:error, :qualification_artifact_unavailable} =
               Authority.reconcile_lifx_power(
                 authority,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:recovery",
                 201
               )

      assert :ok = File.rename(hidden_path, claim_path)
      assert {:ok, 12} = Store.revision(reopened)

      disposition = if @actual, do: :observed, else: :contradicted
      reason = if @actual, do: "reconciled_report:10:12", else: "reconciled_mismatch:10:12"

      assert {:ok, %{disposition: ^disposition, reason: ^reason, revision: 13} = receipt} =
               Authority.reconcile_lifx_power(
                 authority,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:recovery",
                 201
               )

      assert {:ok, ^receipt} =
               Authority.reconcile_lifx_power(
                 authority,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:recovery",
                 201
               )

      assert {:ok, 13} = Store.revision(reopened)
      assert {:ok, %{unknown_outcomes: 0}} = Store.health(reopened)
      assert handoff_timing(path, "op:reconcile") == timing

      # Domain release admits a separate ID; reconciliation itself never queues.
      assert ["explicit_request", 4, 1, 7] == causal_root(path, "op:reconcile")

      next = %{
        mutation
        | operation_id: "op:after-reconcile",
          value: %{"type" => "boolean", "value" => not @actual}
      }

      assert {:ok, %{revision: 14, disposition: :held}} =
               Store.submit_request(reopened, controller, next)

      assert {:error, :attempt_history_cold} =
               Store.admit_held_power(
                 reopened,
                 controller,
                 1,
                 next.operation_id,
                 "boot:recovery",
                 201
               )

      assert {:ok, 14} = Store.revision(reopened)
      advance_store_clock(reopened, 60_000)

      assert {:ok, %{revision: 15, disposition: :queued}} =
               Store.admit_held_power(
                 reopened,
                 controller,
                 1,
                 next.operation_id,
                 "boot:recovery",
                 201
               )

      assert {:ok, ^receipt} = Store.submit_request(reopened, controller, mutation)
      :ok = GenServer.stop(reopened)
      assert {:ok, again} = Store.start_link([path: path] ++ keys)

      assert {:ok, ^receipt} =
               Store.reconcile_unknown_power(
                 again,
                 controller,
                 1,
                 "op:reconcile",
                 10,
                 12,
                 "boot:recovery",
                 201
               )

      assert {:ok, 15} = Store.revision(again)
      :ok = GenServer.stop(again)
    end
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
               WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
                 "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP INDEX power_handoff_time; ALTER TABLE request_execution DROP COLUMN handoff_store_boot_epoch; ALTER TABLE request_execution DROP COLUMN handoff_store_monotonic_ms; DROP TABLE rule_candidate_reviews; DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; DROP TABLE profile_qualifications; DROP TABLE enrollment_review_history; DROP TABLE enrollment_bindings; PRAGMA user_version=5"
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
    assert [[20]] = rows(db, "PRAGMA user_version")
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
               WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
                 "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP INDEX power_handoff_time; ALTER TABLE request_execution DROP COLUMN handoff_store_boot_epoch; ALTER TABLE request_execution DROP COLUMN handoff_store_monotonic_ms; DROP TABLE rule_candidate_reviews; DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; DROP TABLE profile_qualifications; PRAGMA user_version=7"
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
    assert [[20]] = rows(db, "PRAGMA user_version")
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM profile_qualifications")
    :ok = Sqlite3.close(db)
  end

  defp commit(store, credential, candidates, interview, profiles, thing, selection) do
    Store.commit_enrollment(store, credential, candidates, interview, profiles, thing, selection)
  end

  defp assert_eventually(predicate, attempts \\ 100)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(1)
      assert_eventually(predicate, attempts - 1)
    end
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

    assert :ok =
             Sqlite3.execute(
               db,
               "INSERT INTO profile_qualification_history (thing_id,profile_ref,resource_revision,identity_digest,basis_digest,registry_digest,runtime_digest,evidence_ref,revision,provenance,declaration_document,principal_id,authority_epoch,binding_revision) SELECT q.thing_id,q.profile_ref,q.resource_revision,q.identity_digest,q.basis_digest,q.registry_digest,q.runtime_digest,q.evidence_ref,q.revision,'guarded_current',t.document,b.operator_id,(SELECT value FROM meta WHERE key='authority_epoch'),b.revision FROM profile_qualifications q JOIN enrolled_things t ON t.thing_id=q.thing_id JOIN enrollment_bindings b ON b.thing_id=q.thing_id"
             )

    assert :ok = Sqlite3.execute(db, "UPDATE meta SET value = #{revision} WHERE key = 'revision'")
    :ok = Sqlite3.close(db)
    [qualification_case_keys: case_keys, qualification_decision_keys: decision_keys]
  end

  defp test_digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp attempt_fixture(path) do
    {:ok, initial} = Store.start_link(path: path)
    assert {:ok, owner, 1} = Store.provision_principal(initial, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = fixtures()
    assert {:ok, 2} = commit(initial, owner, [candidate], interview, [profile], thing, @selection)

    assert {:ok, credential, 3} =
             Store.provision_principal(initial, "controller:1", ["control:ordinary"], [thing.id])

    {:ok, mutation} =
      Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "op:attempt",
        "expected_revision" => 0,
        "target_id" => thing.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.submit_request(initial, credential, mutation)

    capability = thing.capabilities["power"]
    {:ok, report} = power_report(capability, false)
    assert {:ok, 5} = Store.record(initial, report, capability)
    :ok = GenServer.stop(initial)
    keys = insert_synthetic_qualification(path, 6, thing)
    {:ok, store} = Store.start_link([path: path] ++ keys)
    {store, credential, thing}
  end

  defp active_rule_fixture(path) do
    {store, credential, thing} = attempt_fixture(path)

    {:ok, manager, _} =
      Store.provision_principal(
        store,
        "manager:rule",
        ["rule:manage", "rule:review", "control:ordinary"],
        [thing.id]
      )

    authority = Authority.new(store: store)

    source = %{
      "version" => 1,
      "id" => "rule:power",
      "source_revision" => 1,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => thing.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      },
      "authority_class" => "automation",
      "unknown_policy" => "block",
      "ownership_ms" => 1,
      "cooldown_ms" => 0,
      "causal_budget" => 1
    }

    {:ok, expected} = Store.revision(store)

    {:ok, admission} =
      Authority.admit_rule(authority, manager, 1, "rule:admit", expected, [source])

    assert {:ok, %{rule_generation: 1}} =
             Authority.activate_rule(
               authority,
               manager,
               1,
               "rule:activate",
               admission.revision,
               admission.revision
             )

    {store, credential, manager, thing}
  end

  defp prepare_maintenance_boundary(:held, _store, _credential), do: nil

  defp prepare_maintenance_boundary(:queued, store, credential),
    do: prepare_rule_boundary(:claim, store, credential)

  defp prepare_maintenance_boundary(:claimed, store, credential),
    do: prepare_rule_boundary(:handoff, store, credential)

  defp prepare_maintenance_boundary(:dispatching, store, credential) do
    token = prepare_rule_boundary(:handoff, store, credential)
    assert {:ok, _} = rule_boundary(:handoff, store, credential, token)
    token
  end

  defp verify_maintenance_ack(:dispatching, store, token),
    do:
      assert(
        {:error, :request_not_handed_off} =
          Store.accept_power_ack(store, "controller:1", 1, "op:rule", token)
      )

  defp verify_maintenance_ack(_phase, _store, _token), do: :ok

  defp prepare_rule_boundary(:admission, _store, _credential), do: nil

  defp prepare_rule_boundary(boundary, store, credential) do
    assert {:ok, %{disposition: :queued}} =
             Store.admit_held_power(store, credential, 1, "op:rule", "boot:1", 101)

    if boundary == :handoff do
      {:ok, claim} = Store.claim_lifx_power(store, "controller:1", 1, "op:rule", "boot:1", 101)
      claim.token
    end
  end

  defp rule_boundary(:admission, store, credential, _token),
    do: Store.admit_held_power(store, credential, 1, "op:rule", "boot:1", 101)

  defp rule_boundary(:claim, store, _credential, _token),
    do: Store.claim_lifx_power(store, "controller:1", 1, "op:rule", "boot:1", 101)

  defp rule_boundary(:handoff, store, _credential, token),
    do: Store.handoff_claimed_power(store, "controller:1", 1, "op:rule", token, 101)

  defp prepare_invariant_boundary(:admission, _store, _credential), do: nil

  defp prepare_invariant_boundary(boundary, store, credential) do
    assert {:ok, %{disposition: :queued}} =
             Store.admit_held_power(store, credential, 1, "op:guarded", "boot:1", 101)

    if boundary == :handoff do
      {:ok, claim} = Store.claim_lifx_power(store, "controller:1", 1, "op:guarded", "boot:1", 101)
      claim.token
    end
  end

  defp invariant_boundary(:admission, store, credential, _token),
    do: Store.admit_held_power(store, credential, 1, "op:guarded", "boot:1", 101)

  defp invariant_boundary(:claim, store, _credential, _token),
    do: Store.claim_lifx_power(store, "controller:1", 1, "op:guarded", "boot:1", 101)

  defp invariant_boundary(:handoff, store, _credential, token),
    do: Store.handoff_claimed_power(store, "controller:1", 1, "op:guarded", token, 101)

  defp assert_observation_clock_is_not_rate_clock(:admission, store, credential) do
    assert {:error, :attempt_rate_exhausted} =
             Store.admit_held_power(store, credential, 1, "op:attempt", "boot:1", 1_001)
  end

  defp assert_observation_clock_is_not_rate_clock(_boundary, _store, _credential), do: :ok

  defp reservation_revision_for(:admission, revision), do: revision
  defp reservation_revision_for(_boundary, _revision), do: 7

  defp prepare_attempt_boundary(:admission, _store, _credential), do: {:held, nil}

  defp prepare_attempt_boundary(boundary, store, credential)
       when boundary in [:claim, :handoff] do
    assert {:ok, %{disposition: :queued}} =
             Store.admit_held_power(store, credential, 1, "op:attempt", "boot:1", 101)

    if boundary == :claim do
      {:queued, nil}
    else
      assert {:ok, claim} =
               Store.claim_lifx_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

      {:claimed, claim.token}
    end
  end

  defp attempt_boundary(:admission, store, credential, _token),
    do: Store.admit_held_power(store, credential, 1, "op:attempt", "boot:1", 101)

  defp attempt_boundary(:claim, store, _credential, _token),
    do: Store.claim_lifx_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

  defp attempt_boundary(:handoff, store, _credential, token),
    do: Store.handoff_claimed_power(store, "controller:1", 1, "op:attempt", token, 101)

  defp seed_attempt_history(path, store, thing) do
    # Synthetic terminal history makes each guard independently observable, even
    # when prior queued/claimed work would normally serialize later attempts.
    # This is a trusted fault fixture, not real device or single-writer evidence.
    epoch = :sys.get_state(store).clock_epoch
    {:ok, base} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    [[evidence_ref]] = rows(db, "SELECT evidence_ref FROM profile_qualifications")

    for n <- 1..32 do
      handoff = base + n * 2 - 1

      :ok =
        Sqlite3.execute(db, """
        INSERT INTO request_receipts VALUES ('controller:1', 1, 'history:#{n}', 0,
          '#{thing.id}', 'power', 'boolean', '1', NULL, '#{thing.profile_ref}', 'observed', NULL, #{handoff + 1});
        INSERT INTO request_causal_roots (principal_id, authority_epoch, operation_id, origin, created_revision, reserved_effects, reservation_revision) VALUES
          ('controller:1', 1, 'history:#{n}', 'legacy_request', NULL, 1, NULL);
        INSERT INTO request_execution
          (principal_id, authority_epoch, operation_id, target_id, effect_domain, profile_ref,
           profile_evidence_ref, resource_revision, rule_generation, baseline_revision, admission_revision,
           planned_value, state, claim_token, claim_boot_epoch, handoff_revision, attempts, revision,
           handoff_store_boot_epoch, handoff_store_monotonic_ms)
          VALUES ('controller:1', 1, 'history:#{n}', '#{thing.id}', '#{thing.id}', '#{thing.profile_ref}',
            '#{evidence_ref}', 0, 0, 5, #{handoff}, x'0101', 'observed', zeroblob(32), 'boot:history',
            #{handoff}, 1, #{handoff + 1}, '#{epoch}', #{(n - 1) * 250});
        INSERT INTO request_journal VALUES (#{handoff}, 'controller:1', 1, 'history:#{n}', 'dispatching', NULL);
        INSERT INTO request_journal VALUES (#{handoff + 1}, 'controller:1', 1, 'history:#{n}', 'observed', NULL);
        """)
    end

    :ok = Sqlite3.execute(db, "UPDATE meta SET value=#{base + 64} WHERE key='revision'; COMMIT")
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  defp operation_timing_or_absent(path, operation_id) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      case rows(
             db,
             "SELECT handoff_revision, handoff_store_boot_epoch, handoff_store_monotonic_ms FROM request_execution WHERE operation_id='#{operation_id}'"
           ) do
        [] -> [nil, nil, nil]
        [timing] -> timing
      end
    after
      :ok = Sqlite3.close(db)
    end
  end

  defp causal_root(path, operation_id) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, [root]} =
        WotexHome.Durable.Store.SQL.query(
          db,
          "SELECT origin, created_revision, reserved_effects, reservation_revision FROM request_causal_roots WHERE operation_id=?",
          [operation_id]
        )

      root
    after
      :ok = Sqlite3.close(db)
    end
  end

  # Fixture-only monotonic advancement: no production clock override is exposed.
  defp advance_store_clock(store, milliseconds) do
    :sys.replace_state(store, fn state ->
      %{state | clock_origin: state.clock_origin - milliseconds}
    end)
  end

  defp handoff_timing(path, operation_id) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, statement} =
        Sqlite3.prepare(
          db,
          "SELECT handoff_revision, handoff_store_boot_epoch, handoff_store_monotonic_ms FROM request_execution WHERE operation_id=?"
        )

      try do
        :ok = Sqlite3.bind(statement, [operation_id])
        {:ok, [timing]} = Sqlite3.fetch_all(db, statement)
        timing
      after
        :ok = Sqlite3.release(db, statement)
      end
    after
      :ok = Sqlite3.close(db)
    end
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
