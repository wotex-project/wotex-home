Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))
Code.require_file(Path.expand("../support/calendar_trace_inputs.exs", __DIR__))
Code.require_file(Path.expand("../support/lifx_power_route_fixture.exs", __DIR__))

defmodule WotexHome.DurableEnrollmentTest do
  @moduledoc false

  use ExUnit.Case

  # Private software clock peer for the actual Store call. It owns no Store
  # reference, DB handle, bearer or transport, and establishes no host trust.
  defmodule FinalClockFixture do
    use GenServer
    def start_link(options), do: GenServer.start_link(__MODULE__, options)

    def init(options),
      do:
        {:ok,
         %{
           sample: Keyword.fetch!(options, :sample),
           reported_ms: Keyword.fetch!(options, :reported_ms),
           qualification_file: Keyword.get(options, :qualification_file),
           runtime_file: Keyword.get(options, :runtime_file),
           loss_at: Keyword.get(options, :loss_at, 3),
           interval: {100_001, 100_001},
           follow_origin: nil,
           observer: nil,
           count: 0,
           monotonic_only: Keyword.get(options, :monotonic_only, false),
           loss: :none
         }}

    def handle_call({:reset, loss}, _from, state),
      do: {:reply, :ok, %{state | count: 0, loss: loss}}

    def handle_call(:count, _from, state), do: {:reply, state.count, state}

    def handle_call({:observe, observer}, _from, state),
      do: {:reply, :ok, %{state | observer: observer}}

    def handle_call({:time, lower, upper}, _from, state),
      do:
        {:reply, :ok,
         %{state | interval: {lower, upper}, follow_origin: nil, count: 0, loss: :none}}

    def handle_call({:follow_time, lower, origin}, _from, state),
      do:
        {:reply, :ok,
         %{state | interval: {lower, lower}, follow_origin: origin, count: 0, loss: :none}}

    def handle_call({:current, context}, _from, state) do
      count = state.count + 1
      loss = if count < state.loss_at, do: :none, else: state.loss

      if count == state.loss_at - 1 and state.loss == :qualification_loss do
        :ok = File.rename(state.qualification_file, state.qualification_file <> ".held")
      end

      if count == state.loss_at - 1 and state.loss == :runtime_loss do
        :ok = File.rename(state.runtime_file, state.runtime_file <> ".held")
      end

      if loss == :report_age do
        # Cross the actual Store receipt deadline only at this third read.
        # Priming below ensures this remains within ClockOwner's call timeout.
        delay = max(0, 5_001 - (context.now_ms - state.reported_ms))
        true = delay <= 4_500
        Process.sleep(delay)
      end

      {lower, upper} =
        case loss do
          :expiry ->
            {110_000, 110_000}

          :early ->
            {99_000, 99_000}

          :uncertain ->
            {100_000, 102_001}

          _ ->
            {lower, upper} = state.interval

            elapsed =
              if state.follow_origin, do: max(0, context.now_ms - state.follow_origin), else: 0

            {lower + elapsed, upper + elapsed}
        end

      sample = %{
        state.sample
        | "sampled_monotonic_ms" => context.now_ms,
          "boot_epoch" => context.scope["store_boot_epoch"],
          "generation" => context.scope["clock_generation"],
          "utc_lower_ms" => lower,
          "utc_upper_ms" => upper
      }

      sample =
        if state.monotonic_only,
          do: %{
            sample
            | "wall_confidence" => "unqualified",
              "utc_lower_ms" => nil,
              "utc_upper_ms" => nil
          },
          else: sample

      result =
        if loss == :clock_loss, do: {:error, :temporal_clock_unavailable}, else: {:ok, sample}

      if is_pid(state.observer), do: send(state.observer, {:route_clock, lower, count})

      {:reply, result, %{state | count: count}}
    end
  end

  defmodule NoSendFixture do
    @behaviour WotexHome.Lifx.Transport
    @impl true
    def send(test, endpoint, bytes) do
      Kernel.send(test, {:unexpected_power_packet, endpoint, bytes})
      :ok
    end

    @impl true
    def recv(_test, _timeout), do: {:error, :timeout}
  end

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

  defmodule DeliveryTransport do
    @behaviour Transport
    def send({device, observer}, _endpoint, bytes) do
      {:ok, packet} = Packet.decode(bytes)
      send(observer, {:delivery_packet, packet.type})

      if Agent.get(device, & &1.pause) == packet.type do
        send(observer, {:delivery_paused, self()})

        receive do
          :delivery_continue -> :ok
        after
          2_000 -> raise "delivery fixture pause expired"
        end
      end

      response =
        Agent.get_and_update(device, fn state ->
          case packet.type do
            2 ->
              {reply(packet, 3, <<1, 56_700::little-32>>), state}

            101 ->
              payload =
                <<0::16, 0::16, 65_535::little-16, 3_500::little-16, 0::16,
                  state.level::little-16, "Fixture", 0::size(25)-unit(8), 0::64>>

              {reply(packet, 107, payload), state}

            116 ->
              cond do
                state.set and state.readback == :missing ->
                  {nil, state}

                state.set and state.readback == :contradicted ->
                  {reply(packet, 118, <<0::16>>), state}

                true ->
                  {reply(packet, 118, <<state.level::little-16>>), state}
              end

            117 ->
              <<level::little-16, _::32>> = packet.payload
              response = if state.ack, do: reply(packet, 45, <<>>), else: nil
              {response, %{state | level: level, set: true}}
          end
        end)

      if is_binary(response), do: send(self(), {:delivery_datagram, response})
      :ok
    end

    def recv(_, _timeout) do
      receive do
        {:delivery_datagram, bytes} -> {:ok, "192.0.2.10:56700", bytes}
      after
        0 -> {:error, :timeout}
      end
    end

    defp reply(packet, type, payload) do
      size = 36 + byte_size(payload)
      target = <<0xD0, 0x73, 0xD5, 0x00, 0x00, 0x01>>

      <<size::little-16, 0x1400::little-16, packet.source::little-32, target::binary, 0::16,
        0::48, 0::8, packet.sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
    end
  end

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
      Path.join(
        System.tmp_dir!(),
        "wotex-home-enrollment-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
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
    assert [[27]] = rows(db, "PRAGMA user_version")
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

  @tag explicit_advancement: true
  test "original explicit advancement preserves restart identity and credential withdrawal", %{
    path: path
  } do
    {store, credential, _thing} = attempt_fixture(path)
    authority = Authority.new(store: store)

    assert {:ok, %{principal_id: "controller:1", disposition: :queued} = queued} =
             Authority.advance_explicit_power(
               authority,
               "controller:1",
               1,
               "op:attempt",
               "boot:1",
               101
             )

    assert {:ok, ^queued} =
             Authority.advance_explicit_power(
               authority,
               "controller:1",
               1,
               "op:attempt",
               "boot:1",
               9_999
             )

    assert ["explicit_request", 4, 1, reservation] = causal_root(path, "op:attempt")
    assert reservation == queued.revision
    state = :sys.get_state(store)
    keys = Keyword.new(Map.take(state, [:qualification_case_keys, :qualification_decision_keys]))
    :ok = GenServer.stop(store)
    assert {:ok, reopened} = Store.start_link([path: path] ++ keys)
    assert {:ok, ^queued} = Store.request_status(reopened, credential, 1, "op:attempt")

    assert {:ok, ^queued} =
             Store.advance_explicit_power(
               reopened,
               "controller:1",
               1,
               "op:attempt",
               "boot:1",
               9_999
             )

    assert {:ok, %{dispatch_enabled: false, queued_requests: 1}} = Store.health(reopened)
    assert [nil, nil, nil] == operation_timing_or_absent(path, "op:attempt")
    assert {:ok, replacement, _} = Store.rotate_principal_credential(reopened, "controller:1")
    assert {:error, :unauthorized} = Store.request_status(reopened, credential, 1, "op:attempt")

    assert {:ok, %{disposition: :rejected}} =
             Store.request_status(reopened, replacement, 1, "op:attempt")

    assert {:error, :request_not_held} =
             Store.advance_explicit_power(
               reopened,
               "controller:1",
               1,
               "op:attempt",
               "boot:1",
               101
             )

    assert ["explicit_request", 4, 1, ^reservation] = causal_root(path, "op:attempt")
    :ok = GenServer.stop(reopened)
  end

  @tag explicit_advancement: true
  test "original advancement closes an already reported value with unavailable qualification", %{
    path: path
  } do
    {store, credential, thing} = attempt_fixture(path)
    {:ok, report} = power_report(thing.capabilities["power"], true)

    assert {:ok, _} =
             Store.record(store, %{report | source_sequence: 2}, thing.capabilities["power"])

    file = final_qualification_file(path)
    assert :ok = File.rename(file, file <> ".held")

    try do
      assert {:ok, %{disposition: :rejected, reason: "already_reported_no_send"} = receipt} =
               Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

      assert {:ok, ^receipt} = Store.request_status(store, credential, 1, "op:attempt")
      assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
      assert {:ok, %{queued_requests: 0, held_requests: 0, writable: true}} = Store.health(store)
      assert [nil, nil, nil] == operation_timing_or_absent(path, "op:attempt")
    after
      assert :ok = File.rename(file <> ".held", file)
      :ok = GenServer.stop(store)
    end
  end

  for {boot, now} <- [{"boot:other", 101}, {"boot:1", 99}, {"boot:1", 5_101}] do
    @tag explicit_advancement: true
    test "original advancement rejects report clock #{boot}/#{now}", %{path: path} do
      {store, credential, _thing} = attempt_fixture(path)
      assert {:ok, before} = Store.revision(store)

      assert {:error, :observation_unavailable} =
               Store.advance_explicit_power(
                 store,
                 "controller:1",
                 1,
                 "op:attempt",
                 unquote(boot),
                 unquote(now)
               )

      assert {:ok, ^before} = Store.revision(store)

      assert {:ok, %{disposition: :held}} =
               Store.request_status(store, credential, 1, "op:attempt")

      assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
      assert {:ok, %{writable: true, queued_requests: 0}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  @tag explicit_advancement: true
  test "original advancement requires current physical qualification custody before queue", %{
    path: path
  } do
    {store, credential, _thing} = attempt_fixture(path)
    file = final_qualification_file(path)
    assert :ok = File.rename(file, file <> ".held")
    assert {:ok, before} = Store.revision(store)

    try do
      assert {:error, :qualification_artifact_unavailable} =
               Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

      assert {:ok, ^before} = Store.revision(store)

      assert {:ok, %{disposition: :held}} =
               Store.request_status(store, credential, 1, "op:attempt")

      assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
      assert {:ok, %{writable: true, queued_requests: 0}} = Store.health(store)
    after
      assert :ok = File.rename(file <> ".held", file)
      :ok = GenServer.stop(store)
    end
  end

  @tag explicit_advancement: true
  test "original advancement cannot borrow another principal or manufacture request identity", %{
    path: path
  } do
    {store, _credential, thing} = attempt_fixture(path)

    assert {:ok, _, _} =
             Store.provision_principal(store, "controller:other", ["control:ordinary"], [thing.id])

    assert {:ok, before} = Store.revision(store)

    for {principal, epoch, operation} <- [
          {"controller:other", 1, "op:attempt"},
          {"controller:1", 2, "op:attempt"},
          {"controller:1", 1, "op:absent"}
        ] do
      assert {:error, :not_found} =
               Store.advance_explicit_power(store, principal, epoch, operation, "boot:1", 101)
    end

    assert {:error, :invalid_guard_input} =
             Store.advance_explicit_power(store, nil, 1, "op:attempt", "boot:1", 101)

    assert {:error, :invalid_guard_input} =
             Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", -1)

    assert {:ok, ^before} = Store.revision(store)
    assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
    assert {:ok, %{writable: true, held_requests: 1, queued_requests: 0}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  for loss <- [:principal, :target_grant, :credential_rotation] do
    @tag explicit_advancement: true
    test "original advancement respects current #{loss} withdrawal", %{path: path} do
      {store, _credential, thing} = attempt_fixture(path)

      case unquote(loss) do
        :principal ->
          assert {:ok, _} = Store.revoke_principal(store, "controller:1")

        :target_grant ->
          assert {:ok, _} = Store.revoke_target_grant(store, "controller:1", thing.id)

        :credential_rotation ->
          assert {:ok, _, _} = Store.rotate_principal_credential(store, "controller:1")
      end

      assert {:ok, before} = Store.revision(store)

      expected =
        unquote(if loss == :principal, do: :principal_unavailable, else: :request_not_held)

      assert {:error, ^expected} =
               Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

      assert {:ok, ^before} = Store.revision(store)
      assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
      assert {:ok, %{writable: true, queued_requests: 0}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  @tag explicit_advancement: true
  test "original advancement retains explicit rule override guards", %{path: path} do
    {store, credential, _manager, thing} = active_rule_fixture(path)
    authority = Authority.new(store: store)

    assert {:ok, %{disposition: :held}} =
             Authority.invoke_rule(authority, credential, 1, "op:rule", 1, "rule:power")

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

    assert {:ok, before} = Store.revision(store)

    assert {:error, :operator_override_active} =
             Authority.advance_explicit_power(
               authority,
               "controller:1",
               1,
               "op:rule",
               "boot:1",
               101
             )

    assert {:ok, ^before} = Store.revision(store)
    assert ["explicit_request", _, 0, nil] = causal_root(path, "op:rule")
    assert {:ok, _} = Store.revoke_override_operation_live(store, credential, 1, "override:rule")

    assert {:ok, %{disposition: :queued}} =
             Authority.advance_explicit_power(
               authority,
               "controller:1",
               1,
               "op:rule",
               "boot:1",
               101
             )

    :ok = GenServer.stop(store)
  end

  @tag explicit_advancement: true
  @tag explicit_capture: true
  test "original advancement refuses a retained temporal root without consuming its window", %{
    path: path
  } do
    {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
    assert {:ok, original, _snapshot} = temporal_consider_fixture(store, activation, 100_001)
    assert {:ok, before} = Store.revision(store)

    assert {:error, :not_explicit_request} =
             Store.advance_explicit_power(
               store,
               "manager:schedule",
               1,
               original.occurrence_id,
               "boot:1",
               101
             )

    assert {:ok, ^before} = Store.revision(store)

    assert {:ok, %{disposition: :held}} =
             Store.request_status(store, manager, 1, original.occurrence_id)

    assert ["schedule_occurrence", _, 0, nil] = causal_root(path, original.occurrence_id)
    assert {:ok, %{requests: pending}} = Store.pending_explicit_power(store)
    refute Enum.any?(pending, &(&1.operation_id == original.occurrence_id))

    assert {:error, :not_explicit_request} =
             Store.explicit_power_refresh_basis(
               store,
               "manager:schedule",
               1,
               original.occurrence_id
             )

    assert {:ok, %{writable: true, queued_requests: 0}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  for phase <- [:queue, :no_send],
      {loss, sql, reason} <- [
        {:principal, "UPDATE principals SET status='revoked' WHERE principal_id='controller:1'",
         :principal_unavailable},
        {:grant, "DELETE FROM principal_targets WHERE principal_id='controller:1'",
         :target_unavailable}
      ] do
    @tag explicit_advancement: true
    test "final original #{phase} author guard restores tentative work on #{loss} loss", %{
      path: path
    } do
      {store, credential, thing} = attempt_fixture(path)

      if unquote(phase == :no_send) do
        {:ok, report} = power_report(thing.capabilities["power"], true)

        assert {:ok, _} =
                 Store.record(store, %{report | source_sequence: 2}, thing.capabilities["power"])
      end

      assert {:ok, before} = Store.revision(store)
      disposition = unquote(if phase == :queue, do: "queued", else: "rejected")
      {:ok, db} = Sqlite3.open(path)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER original_author_loss AFTER INSERT ON request_journal WHEN NEW.operation_id='op:attempt' AND NEW.disposition='#{disposition}' BEGIN #{unquote(sql)}; END"
               )

      assert {:error, unquote(reason)} =
               Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER original_author_loss")
      assert {:ok, ^before} = Store.revision(store)

      assert {:ok, %{disposition: :held, revision: 4}} =
               Store.request_status(store, credential, 1, "op:attempt")

      assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")

      assert [[0, 0]] =
               rows(
                 db,
                 "SELECT (SELECT COUNT(*) FROM request_execution),(SELECT COUNT(*) FROM request_journal WHERE disposition='queued' OR reason='already_reported_no_send')"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      assert {:ok, %{writable: true}} = Store.health(store)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  for table <- ["request_execution", "request_journal"] do
    @tag explicit_advancement: true
    test "original advancement rolls back all queue publication on #{table} failure", %{
      path: path
    } do
      {store, credential, _thing} = attempt_fixture(path)
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER original_queue_fault BEFORE INSERT ON #{unquote(table)} BEGIN SELECT RAISE(ABORT,'injected original queue failure'); END"
               )

      assert {:error, :store_unavailable} =
               Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER original_queue_fault")
      assert {:ok, ^before} = Store.revision(store)

      assert {:ok, %{disposition: :held, revision: 4}} =
               Store.request_status(store, credential, 1, "op:attempt")

      assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      assert {:ok, %{writable: false, queued_requests: 0}} = Store.health(store)
      state = :sys.get_state(store)

      keys =
        Keyword.new(Map.take(state, [:qualification_case_keys, :qualification_decision_keys]))

      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
      assert {:ok, reopened} = Store.start_link([path: path] ++ keys)

      assert {:ok, %{disposition: :held, revision: 4}} =
               Store.request_status(reopened, credential, 1, "op:attempt")

      assert {:ok, %{writable: true}} = Store.health(reopened)
      :ok = GenServer.stop(reopened)
    end
  end

  @tag explicit_capture: true
  test "controller selection pages retained explicit power originals by immutable creation", %{
    path: path
  } do
    {store, credential, thing} = attempt_fixture(path)

    for index <- 1..18 do
      {:ok, mutation} =
        Mutation.new(%{
          "api_version" => 1,
          "authority_epoch" => 1,
          "operation_id" => "op:pending:#{index}",
          "expected_revision" => 0,
          "target_id" => thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true}
        })

      assert {:ok, %{disposition: :held}} = Store.submit_request(store, credential, mutation)
    end

    assert {:ok, before} = Store.revision(store)
    authority = Authority.new(store: store)

    assert {:ok, %{requests: first, next_revision: cursor, has_more: true}} =
             Authority.pending_explicit_power(authority)

    assert length(first) == 16

    assert hd(first) == %{
             principal_id: "controller:1",
             authority_epoch: 1,
             operation_id: "op:attempt",
             created_revision: 4
           }

    assert {:ok, %{requests: last, next_revision: final, has_more: false}} =
             Authority.pending_explicit_power(authority, cursor)

    assert length(last) == 3
    all = first ++ last
    assert length(Enum.uniq_by(all, & &1.operation_id)) == 19
    revisions = Enum.map(all, & &1.created_revision)
    assert revisions == Enum.sort(revisions)

    assert {:ok, %{requests: [], next_revision: ^final, has_more: false}} =
             Store.pending_explicit_power(store, final)

    assert {:error, :invalid_guard_input} = Store.pending_explicit_power(store, -1)
    assert {:ok, ^before} = Store.revision(store)

    assert {:ok, %{disposition: :queued}} =
             Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

    assert {:ok, %{requests: ^first, next_revision: ^cursor, has_more: true}} =
             Store.pending_explicit_power(store)

    assert {:error, :request_not_held} =
             Store.explicit_power_refresh_basis(store, "controller:1", 1, "op:attempt")

    assert {:ok, %{disposition: :claimed}, token} =
             Store.claim_queued_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

    assert {:ok, %{requests: pending}} = Store.pending_explicit_power(store)
    refute Enum.any?(pending, &(&1.operation_id == "op:attempt"))

    assert {:ok, %{disposition: :dispatching}} =
             Store.handoff_claimed_power(store, "controller:1", 1, "op:attempt", token, 101)

    assert {:ok, %{requests: pending}} = Store.pending_explicit_power(store)
    refute Enum.any?(pending, &(&1.operation_id == "op:attempt"))

    :ok = GenServer.stop(store)
  end

  @tag explicit_capture: true
  test "fresh explicit read scope rechecks original enrollment and Store-stamps reports without a bearer",
       %{path: path} do
    {store, credential, thing} = attempt_fixture(path)

    assert {:ok,
            %{
              receipt: %{
                principal_id: "controller:1",
                operation_id: "op:attempt",
                disposition: :held
              },
              thing: ^thing
            } = basis} =
             Store.explicit_power_refresh_basis(store, "controller:1", 1, "op:attempt")

    {:ok, report} = power_report(thing.capabilities["power"], false)

    fresh = %{
      report
      | source_epoch: "capture:fresh",
        boot_epoch: "capture:fresh",
        source_sequence: 0,
        received_monotonic_ms: 1_000
    }

    assert {:ok, before} = Store.revision(store)

    for changed <- [
          %{basis | stable_id: "lifx:000000000000"},
          %{basis | binding_revision: basis.binding_revision + 1},
          %{basis | resource_revision: basis.resource_revision + 1}
        ] do
      assert {:error, :stale_refresh_basis} =
               Store.commit_explicit_power_refresh(store, changed, [fresh])
    end

    assert {:error, :invalid_guard_input} =
             Store.explicit_power_refresh_basis(store, nil, 1, "op:attempt")

    assert {:error, :not_found} =
             Store.explicit_power_refresh_basis(store, "controller:other", 1, "op:attempt")

    assert {:ok, ^before} = Store.revision(store)
    assert {:ok, [revision]} = Store.commit_explicit_power_refresh(store, basis, [fresh])
    assert revision == before + 1
    state = :sys.get_state(store)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [["capture:fresh", "capture:fresh", 1_000, stored_boot, stored_ms]] =
             rows(
               db,
               "SELECT source_epoch,boot_epoch,received_monotonic_ms,received_store_boot_epoch,received_store_monotonic_ms FROM observation_current"
             )

    assert stored_boot == state.clock_epoch
    assert is_integer(stored_ms) and stored_ms >= 0
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM source_epoch_grants")
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.request_status(store, credential, 1, "op:attempt")

    assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
    assert {:ok, %{queued_requests: 0, dispatch_enabled: false}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  @tag explicit_capture: true
  test "pending selection fails closed on damaged original creation history", %{path: path} do
    {store, credential, _thing} = attempt_fixture(path)
    assert {:ok, before} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "UPDATE request_causal_roots SET created_revision=5 WHERE operation_id='op:attempt'"
             )

    assert {:error, {:schema_inconsistent, _}} =
             WotexHome.Durable.Store.Integrity.validate_snapshot(db)

    assert {:error, :store_unavailable} = Store.pending_explicit_power(store)
    assert {:ok, ^before} = Store.revision(store)

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.request_status(store, credential, 1, "op:attempt")

    assert {:ok, %{writable: false, dispatch_enabled: false}} = Store.health(store)

    assert {:error, :store_unavailable} =
             Store.explicit_power_refresh_basis(store, "controller:1", 1, "op:attempt")

    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  for loss <- [:principal, :grant, :credential] do
    @tag explicit_capture: true
    test "explicit report commit refuses #{loss} withdrawal during capture", %{path: path} do
      {store, _credential, thing} = attempt_fixture(path)

      assert {:ok, basis} =
               Store.explicit_power_refresh_basis(store, "controller:1", 1, "op:attempt")

      case unquote(loss) do
        :principal ->
          assert {:ok, _} = Store.revoke_principal(store, "controller:1")

        :grant ->
          assert {:ok, _} = Store.revoke_target_grant(store, "controller:1", thing.id)

        :credential ->
          assert {:ok, _, _} = Store.rotate_principal_credential(store, "controller:1")
      end

      assert {:ok, before} = Store.revision(store)
      {:ok, report} = power_report(thing.capabilities["power"], false)
      reason = unquote(if loss == :principal, do: :principal_unavailable, else: :request_not_held)

      assert {:error, ^reason} =
               Store.commit_explicit_power_refresh(store, basis, [%{report | source_sequence: 2}])

      assert {:ok, ^before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path, mode: :readonly)
      assert [[5]] = rows(db, "SELECT revision FROM observation_current")
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      assert {:ok, %{writable: true, queued_requests: 0}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  for {loss, sql, reason} <- [
        {:principal, "UPDATE principals SET status='revoked' WHERE principal_id='controller:1'",
         :principal_unavailable},
        {:grant, "DELETE FROM principal_targets WHERE principal_id='controller:1'",
         :permission_denied}
      ] do
    @tag explicit_capture: true
    test "final explicit read scope repeats #{loss} after report publication", %{path: path} do
      {store, credential, thing} = attempt_fixture(path)

      assert {:ok, basis} =
               Store.explicit_power_refresh_basis(store, "controller:1", 1, "op:attempt")

      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER explicit_read_loss AFTER INSERT ON journal WHEN NEW.thing_id='light:desk' BEGIN #{unquote(sql)}; END"
               )

      {:ok, report} = power_report(thing.capabilities["power"], false)

      assert {:error, unquote(reason)} =
               Store.commit_explicit_power_refresh(store, basis, [%{report | source_sequence: 2}])

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER explicit_read_loss")
      assert {:ok, ^before} = Store.revision(store)
      assert [[5]] = rows(db, "SELECT revision FROM observation_current")
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)

      assert {:ok, %{disposition: :held}} =
               Store.request_status(store, credential, 1, "op:attempt")

      assert {:ok, %{writable: true}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  @tag explicit_capture: true
  test "explicit read publication failure rolls back facts and source custody and disables writes",
       %{path: path} do
    {store, _credential, thing} = attempt_fixture(path)

    assert {:ok, basis} =
             Store.explicit_power_refresh_basis(store, "controller:1", 1, "op:attempt")

    assert {:ok, before} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER explicit_read_fault AFTER UPDATE ON observation_current BEGIN SELECT RAISE(ABORT,'injected explicit read fault'); END"
             )

    {:ok, report} = power_report(thing.capabilities["power"], false)

    assert {:error, :store_unavailable} =
             Store.commit_explicit_power_refresh(store, basis, [
               %{report | source_epoch: "capture:new", source_sequence: 0}
             ])

    assert :ok = Sqlite3.execute(db, "DROP TRIGGER explicit_read_fault")
    assert {:ok, ^before} = Store.revision(store)
    assert [["device:1", 5]] = rows(db, "SELECT source_epoch,revision FROM observation_current")
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM source_epoch_grants")
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    assert {:ok, %{writable: false}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  for {readback, ack, disposition} <- [
        {:matching, true, :observed},
        {:matching, false, :observed},
        {:contradicted, true, :contradicted},
        {:missing, true, :outcome_unknown}
      ] do
    @tag explicit_delivery: true
    test "private explicit delivery settles #{readback}/#{ack} as #{disposition} without a bearer",
         %{path: path} do
      {store, credential, _thing} = attempt_fixture(path)

      {authority, opts, _capture} =
        delivery_fixture(store, readback: unquote(readback), ack: unquote(ack))

      assert {:ok, %{disposition: unquote(disposition)} = receipt} =
               Authority.deliver_explicit_power(authority, "controller:1", 1, "op:attempt", opts)

      assert {:ok, ^receipt} = Store.request_status(store, credential, 1, "op:attempt")
      assert_receive {:delivery_packet, 2}
      assert_receive {:delivery_packet, 101}
      assert_receive {:delivery_packet, 117}
      assert_receive {:delivery_packet, 116}
      assert_receive :delivery_transport_closed
      refute_receive {:delivery_packet, 117}, 20
      assert ["explicit_request", 4, 1, _] = causal_root(path, "op:attempt")
      assert {:ok, %{requests: []}} = Authority.pending_explicit_power(authority)
      {:ok, db} = Sqlite3.open(path, mode: :readonly)

      assert [[1]] =
               rows(db, "SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching'")

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  @tag explicit_delivery: true
  test "private delivery of a matching report closes without opening a power transport", %{
    path: path
  } do
    {store, _credential, _thing} = attempt_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store, level: 65_535)

    assert {:ok, %{disposition: :rejected, reason: "already_reported_no_send"}} =
             Authority.deliver_explicit_power(authority, "controller:1", 1, "op:attempt", opts)

    assert_receive {:delivery_packet, 2}
    assert_receive {:delivery_packet, 101}
    refute_receive :delivery_transport_opened, 20
    refute_receive {:delivery_packet, 117}, 20
    assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
    :ok = GenServer.stop(store)
  end

  @tag explicit_delivery: true
  test "default dispatch and caller-supplied routing cannot start private capture", %{path: path} do
    {store, _credential, _thing} = attempt_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store)

    assert {:error, :dispatch_disabled} =
             Authority.deliver_explicit_power(
               %{authority | power_dispatch: false},
               "controller:1",
               1,
               "op:attempt",
               opts
             )

    assert {:error, :invalid_power_delivery} =
             Authority.deliver_explicit_power(
               authority,
               "controller:1",
               1,
               "op:attempt",
               Keyword.put(opts, :boot_epoch, "boot:caller")
             )

    refute_receive {:delivery_packet, _}, 20
    assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
    :ok = GenServer.stop(store)
  end

  @tag explicit_delivery: true
  test "private capture cannot queue without current qualification custody", %{path: path} do
    {store, _credential, _thing} = attempt_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store)
    file = final_qualification_file(path)
    :ok = File.rename(file, file <> ".held")

    try do
      assert {:error, :qualification_artifact_unavailable} =
               Authority.deliver_explicit_power(authority, "controller:1", 1, "op:attempt", opts)

      assert_receive {:delivery_packet, 2}
      assert_receive {:delivery_packet, 101}
      refute_receive :delivery_transport_opened, 20
      assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
      assert {:ok, %{held_requests: 1, writable: true}} = Store.health(store)
    after
      :ok = File.rename(file <> ".held", file)
      :ok = GenServer.stop(store)
    end
  end

  @tag explicit_delivery: true
  test "queued recovery discovers routing without replacing its sealed old-boot report", %{
    path: path
  } do
    {store, credential, _thing} = attempt_fixture(path)

    assert {:ok, %{disposition: :queued} = queued} =
             Store.advance_explicit_power(store, "controller:1", 1, "op:attempt", "boot:1", 101)

    {authority, opts, _capture} = delivery_fixture(store)

    assert {:error, :observation_unavailable} =
             Authority.deliver_explicit_power(authority, "controller:1", 1, "op:attempt", opts)

    assert_receive {:delivery_packet, 2}
    refute_receive {:delivery_packet, 116}, 20
    refute_receive {:delivery_packet, 117}, 20
    assert {:ok, ^queued} = Store.request_status(store, credential, 1, "op:attempt")
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[5, 5]] =
             rows(
               db,
               "SELECT (SELECT revision FROM observation_current),baseline_revision FROM request_execution"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag explicit_delivery: true
  test "controller consumer delivers an original after clients are absent and never retries uncertain work",
       %{path: path} do
    {store, credential, _thing} = attempt_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store, readback: :missing)

    consumer =
      start_supervised!(
        {WotexHome.Lifx.PowerDelivery,
         authority: authority, interval_ms: 100, delivery_opts: opts}
      )

    assert_receive {:delivery_packet, 117}, 2_000
    assert_receive :delivery_transport_closed, 2_000

    assert {:ok, %{disposition: :outcome_unknown}} =
             Store.request_status(store, credential, 1, "op:attempt")

    Process.sleep(350)
    refute_receive {:delivery_packet, 117}, 20
    state = :sys.get_state(consumer)
    assert state.deferred == %{}
    assert state.last_result == :idle
    :ok = GenServer.stop(store)
  end

  @tag explicit_delivery: true
  test "revoking the original author while capture is in flight prevents publication and dispatch",
       %{path: path} do
    {store, _credential, _thing} = attempt_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store, pause: 101)

    task =
      Task.async(fn ->
        Authority.deliver_explicit_power(authority, "controller:1", 1, "op:attempt", opts)
      end)

    assert_receive {:delivery_paused, capture}, 2_000
    assert {:ok, _} = Store.revoke_principal(store, "controller:1")
    send(capture, :delivery_continue)
    assert {:error, :principal_unavailable} = Task.await(task)
    refute_receive :delivery_transport_opened, 20
    assert ["explicit_request", 4, 0, nil] == causal_root(path, "op:attempt")
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[5]] = rows(db, "SELECT revision FROM observation_current")
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag explicit_delivery: true
  test "same-boot queued recovery preserves the sealed report and uses a distinct readback sequence",
       %{path: path} do
    {store, _credential, thing} = attempt_fixture(path)
    {authority, opts, capture} = delivery_fixture(store)

    assert {:ok, basis} =
             Store.explicit_power_refresh_basis(store, "controller:1", 1, "op:attempt")

    assert {:ok, route} =
             WotexHome.Lifx.CaptureSession.power_route_auto(
               capture,
               basis.stable_id,
               thing,
               :held
             )

    assert {:ok, [baseline]} = Store.commit_explicit_power_refresh(store, basis, route.reports)
    {now, _} = route.clock.()

    assert {:ok, %{disposition: :queued}} =
             Store.advance_explicit_power(
               store,
               "controller:1",
               1,
               "op:attempt",
               route.boot_epoch,
               now
             )

    assert_receive {:delivery_packet, 2}
    assert_receive {:delivery_packet, 101}

    assert {:ok, %{disposition: :observed}} =
             Authority.deliver_explicit_power(authority, "controller:1", 1, "op:attempt", opts)

    assert_receive {:delivery_packet, 2}
    assert_receive {:delivery_packet, 117}
    assert_receive {:delivery_packet, 116}
    refute_receive {:delivery_packet, 101}, 20
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[^baseline, 2]] =
             rows(
               db,
               "SELECT baseline_revision,(SELECT source_sequence FROM observation_current) FROM request_execution"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag explicit_delivery: true
  test "consumer ends a finite scan despite new arrivals and defers an unavailable original",
       %{path: path} do
    {store, credential, thing} = attempt_fixture(path)
    pool = start_supervised!(Task.Supervisor)
    authority = Authority.new(store: store, power_supervisor: pool, power_dispatch: true)

    consumer =
      start_supervised!({WotexHome.Lifx.PowerDelivery, authority: authority, interval_ms: 30_000})

    send(consumer, :poll)
    first = :sys.get_state(consumer)
    assert first.last_result == :capture_unavailable
    assert first.cursor == 4
    assert Map.keys(first.deferred) == [4]

    {:ok, mutation} =
      Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "op:arrival",
        "expected_revision" => 0,
        "target_id" => thing.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:ok, %{disposition: :held, revision: arrival}} =
             Store.submit_request(store, credential, mutation)

    assert arrival > first.cycle_end
    send(consumer, :poll)
    assert %{cursor: 0, cycle_end: nil, last_result: :idle} = :sys.get_state(consumer)
    send(consumer, :poll)
    next = :sys.get_state(consumer)
    assert next.cursor == arrival
    assert next.last_result == :capture_unavailable
    assert next.deferred[4] == first.deferred[4]
    assert Map.has_key?(next.deferred, arrival)
    :ok = GenServer.stop(consumer)
    :ok = GenServer.stop(store)
  end

  defp delivery_fixture(store, options \\ []) do
    device =
      start_supervised!(
        {Agent,
         fn ->
           %{
             level: Keyword.get(options, :level, 0),
             set: false,
             ack: Keyword.get(options, :ack, true),
             readback: Keyword.get(options, :readback, :matching),
             pause: Keyword.get(options, :pause)
           }
         end}
      )

    observer = self()
    {:ok, scope} = WotexHome.Lifx.IPv4Scope.new({192, 0, 2, 2}, 24)

    capture =
      start_supervised!(
        {WotexHome.Lifx.CaptureSession,
         interface_id: "en0", scope: scope, transport: {DeliveryTransport, {device, observer}}}
      )

    pool = start_supervised!(Task.Supervisor)

    authority =
      Authority.new(store: store, capture: capture, power_supervisor: pool, power_dispatch: true)

    factory = fn ->
      send(observer, :delivery_transport_opened)

      {:ok, {DeliveryTransport, {device, observer}},
       fn -> send(observer, :delivery_transport_closed) end}
    end

    {authority, [transport_factory: factory, ack_timeout_ms: 10, read_timeout_ms: 10], capture}
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
    assert [[27]] = rows(db, "PRAGMA user_version")
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
    assert [[27]] = rows(db, "PRAGMA user_version")
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

  test "a temporal occurrence follows actual queue, claim and handoff with its own spent root", %{
    path: path
  } do
    {store, manager, thing, _clock, _activation} = temporal_fixture(path, 96_000)
    Process.sleep(4_300)
    refresh_temporal_report(store, thing, 3)

    assert {:ok,
            %{
              state: :held,
              effect: %{request_revision: request_revision},
              occurrence_id: operation
            } = occurrence} = Store.consider_schedule(store)

    assert {:ok, %{disposition: :queued}} =
             Store.admit_held_power(store, manager, 1, operation, "boot:1", 101)

    assert {:ok, %{disposition: :claimed}, token} =
             Store.claim_queued_power(store, "manager:schedule", 1, operation, "boot:1", 101)

    assert {:ok, %{disposition: :dispatching} = handed} =
             Store.handoff_claimed_power(store, "manager:schedule", 1, operation, token, 101)

    assert {:ok, ^occurrence} = Store.original_schedule_occurrence(store, manager, operation)
    assert {:ok, %{state: :idle}} = Store.consider_schedule(store)
    assert {:ok, %{dispatch_enabled: false}} = Store.health(store)
    {:ok, db} = Sqlite3.open(path)

    assert [["schedule_occurrence", request_revision, 1, request_revision + 2]] ==
             rows(
               db,
               "SELECT origin,created_revision,reserved_effects,reservation_revision FROM request_causal_roots WHERE operation_id='#{operation}'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
    # A handed occurrence remains unknown after restart and keeps its spend.
    {_, keys, _} = Process.get(:temporal_fixture_details)
    {:ok, restarted} = Store.start_link([path: path] ++ keys)

    assert {:ok, %{disposition: :outcome_unknown, revision: revision}} =
             Store.request_status(restarted, manager, 1, operation)

    assert revision > handed.revision
    assert {:ok, ^occurrence} = Store.original_schedule_occurrence(restarted, manager, operation)
    :ok = GenServer.stop(restarted)
  end

  test "independent temporal boundary oracle executes the real queue and final handoff guards", %{
    path: path
  } do
    {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
    {:ok, occurrence, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    operation = occurrence.occurrence_id

    for {lower, width, expected} <- [
          {99_999, 0, :occurrence_early},
          {99_999, 1, :clock_uncertain},
          {100_000, 2_001, :clock_uncertain},
          {109_999, 1, :clock_uncertain},
          {110_000, 0, :occurrence_expired}
        ] do
      assert {:error, {:policy, ^expected}} =
               temporal_effect_fixture(store, manager, operation, :queue, snapshot, lower, width)

      assert {:ok, %{disposition: :held}} = Store.request_status(store, manager, 1, operation)
    end

    assert {:ok, {:ok, %{disposition: :queued}}} =
             temporal_effect_fixture(store, manager, operation, :queue, snapshot, 100_001, 0)

    for {lower, width, expected} <- [
          {99_999, 0, :occurrence_early},
          {109_999, 1, :clock_uncertain},
          {110_000, 0, :occurrence_expired}
        ] do
      assert {:error, {:policy, ^expected}} =
               temporal_effect_fixture(store, manager, operation, :claim, snapshot, lower, width)

      assert {:ok, %{disposition: :queued}} = Store.request_status(store, manager, 1, operation)
    end

    assert {:ok, {_claimed, claim}} =
             temporal_effect_fixture(store, manager, operation, :claim, snapshot, 100_002, 0)

    for {lower, width, expected} <- [
          {99_999, 0, :occurrence_early},
          {109_999, 1, :clock_uncertain},
          {110_000, 0, :occurrence_expired}
        ] do
      assert {:error, {:policy, ^expected}} =
               temporal_effect_fixture(
                 store,
                 manager,
                 operation,
                 {:handoff, claim.token},
                 snapshot,
                 lower,
                 width
               )

      assert {:ok, %{disposition: :claimed}} = Store.request_status(store, manager, 1, operation)
    end

    assert {:ok, %{disposition: :dispatching}} =
             temporal_effect_fixture(
               store,
               manager,
               operation,
               {:handoff, claim.token},
               snapshot,
               109_999,
               0
             )

    {:ok, db} = Sqlite3.open(path)

    assert [[1]] ==
             rows(
               db,
               "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  test "clock generation change, cancellation and fencing never renew an occurrence",
       %{path: path} do
    {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
    {:ok, occurrence, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    operation = occurrence.occurrence_id

    changed = %{
      snapshot
      | scope: Map.put(snapshot.scope, "clock_generation", 2),
        sample: Map.put(snapshot.sample, "generation", 2)
    }

    assert {:error, {:policy, :temporal_basis_changed}} =
             temporal_effect_fixture(store, manager, operation, :queue, changed, 100_001, 0)

    assert {:ok, {:ok, %{disposition: :queued}}} =
             temporal_effect_fixture(store, manager, operation, :queue, snapshot, 100_001, 0)

    assert {:ok, %{disposition: :rejected, reason: "cancelled_before_claim"}} =
             Store.cancel_request(store, manager, 1, operation)

    assert {:ok, ^occurrence} = Store.original_schedule_occurrence(store, manager, operation)
    assert {:ok, current_revision} = Store.revision(store)
    assert {:ok, _} = Store.fence_rule_generation(store, current_revision, 1)
    assert {:ok, %{state: :inactive}} = Store.consider_schedule(store)
    {:ok, db} = Sqlite3.open(path)

    assert [[1]] ==
             rows(
               db,
               "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  test "Store-owned schedule admission queues once without a bearer or caller timestamp", %{
    path: path
  } do
    {store, manager, thing, _clock, _activation} = temporal_fixture(path, 96_000)
    Process.sleep(4_300)
    refresh_temporal_report(store, thing, 3)
    assert {:ok, %{state: :held} = original} = Store.consider_schedule(store)

    assert {:ok,
            %{
              receipts: [%{disposition: :queued, principal_id: "manager:schedule"} = queued],
              has_more: false
            }} = Store.advance_schedule(store)

    assert queued.operation_id == original.occurrence_id
    assert {:ok, %{receipts: [^queued], has_more: false}} = Store.advance_schedule(store)
    assert {:ok, queued.revision} == Store.revision(store)

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(store, manager, queued.operation_id)

    assert {:ok, %{dispatch_enabled: false}} = Store.health(store)
    {:ok, db} = Sqlite3.open(path)

    assert [[1]] ==
             rows(
               db,
               "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  test "scheduled admission refuses old-boot reports despite fresh caller device timestamps and never retries",
       %{path: path} do
    {store, manager, thing, _clock, activation} = temporal_fixture(path, 90_000, false)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)

    assert {:error, {:policy, :observation_unavailable}} =
             temporal_effect_fixture(
               store,
               manager,
               original.occurrence_id,
               :queue,
               snapshot,
               100_001,
               0
             )

    assert {:ok,
            {:ok,
             %{
               receipts: [
                 %{disposition: :rejected, reason: "schedule_blocked:observation_unavailable"}
               ],
               has_more: false
             }}} = temporal_advance_fixture(store, snapshot)

    refresh_temporal_report(store, thing, 2)

    assert {:ok, {:ok, %{receipts: [], has_more: false}}} =
             temporal_advance_fixture(store, snapshot)

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(store, manager, original.occurrence_id)

    {:ok, db} = Sqlite3.open(path)

    assert [[0]] ==
             rows(
               db,
               "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  for phase <- [:queued, :claimed, :dispatching] do
    @tag temporal_phase: phase
    test "temporal expiry conserves uncertainty and causal spend at #{phase}", %{
      path: path,
      temporal_phase: phase
    } do
      {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      operation = original.occurrence_id

      assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
               temporal_advance_fixture(store, snapshot)

      if phase in [:claimed, :dispatching] do
        assert {:ok, {_receipt, claim}} =
                 temporal_effect_fixture(store, manager, operation, :claim, snapshot, 100_002, 0)

        if phase == :dispatching do
          assert {:ok, %{disposition: :dispatching}} =
                   temporal_effect_fixture(
                     store,
                     manager,
                     operation,
                     {:handoff, claim.token},
                     snapshot,
                     100_003,
                     0
                   )
        end
      end

      expired = %{
        snapshot
        | interval: {110_000, 110_000},
          sample: %{snapshot.sample | "utc_lower_ms" => 110_000, "utc_upper_ms" => 110_000}
      }

      assert {:ok, {:ok, result}} = temporal_advance_fixture(store, expired)

      if phase == :dispatching do
        assert result.receipts == []

        assert {:ok, %{disposition: :dispatching}} =
                 Store.request_status(store, manager, 1, operation)
      else
        assert [%{disposition: :rejected, reason: "schedule_blocked:occurrence_expired"}] =
                 result.receipts

        assert {:ok, {:ok, %{receipts: []}}} = temporal_advance_fixture(store, snapshot)
      end

      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      {:ok, db} = Sqlite3.open(path)

      assert [[1]] ==
               rows(
                 db,
                 "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  test "failure after causal reservation rolls back the entire scheduled admission pass", %{
    path: path
  } do
    {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TRIGGER schedule_queue_fault BEFORE INSERT ON request_journal WHEN NEW.disposition='queued' BEGIN SELECT RAISE(ABORT,'injected_queue_fault'); END"
      )

    Sqlite3.close(db)
    assert {:error, _} = temporal_advance_fixture(store, snapshot)
    assert {:ok, original.revision} == Store.revision(store)

    assert {:ok, %{disposition: :held}} =
             Store.request_status(store, manager, 1, original.occurrence_id)

    {:ok, db} = Sqlite3.open(path)

    assert [[0, 0]] ==
             rows(
               db,
               "SELECT (SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'),(SELECT COUNT(*) FROM request_execution)"
             )

    :ok = Sqlite3.execute(db, "DROP TRIGGER schedule_queue_fault")
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)

    assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
             temporal_advance_fixture(store, snapshot)

    :ok = GenServer.stop(store)
  end

  test "expiry during queue publication rolls back its savepoint before terminally closing held work",
       %{path: path} do
    {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    key = make_ref()

    assert {:ok,
            {:ok,
             %{
               receipts: [
                 %{disposition: :rejected, reason: "schedule_blocked:occurrence_expired"}
               ]
             }}} =
             temporal_sql_fixture(store, fn state ->
               Process.put(key, snapshot)
               reads = make_ref()
               Process.put(reads, 0)

               {:ok, clock} =
                 WotexHome.Durable.Store.ClockContext.new(
                   fn ->
                     current = Process.get(key)
                     {current.scope["store_boot_epoch"], current.now_ms}
                   end,
                   fn ->
                     count = Process.get(reads) + 1
                     Process.put(reads, count)

                     current =
                       if count == 1,
                         do: snapshot,
                         else: %{
                           snapshot
                           | now_ms: snapshot.now_ms + 10_000,
                             interval: {110_000, 110_000},
                             sample: %{
                               snapshot.sample
                               | "sampled_monotonic_ms" => snapshot.now_ms + 10_000,
                                 "utc_lower_ms" => 110_000,
                                 "utc_upper_ms" => 110_000
                             }
                         }

                     Process.put(key, current)
                     {:ok, current}
                   end,
                   fn _ -> {:ok, nil} end
                 )

               result =
                 WotexHome.Durable.Store.SQL.transaction(
                   state.db,
                   &WotexHome.Durable.Store.ScheduleEffects.advance(
                     &1,
                     clock,
                     Map.take(state, [
                       :qualification_claim_root,
                       :qualification_case_keys,
                       :qualification_decision_keys
                     ])
                   )
                 )

               Process.delete(key)
               Process.delete(reads)
               result
             end)

    {:ok, db} = Sqlite3.open(path)

    assert [[0, 0]] ==
             rows(
               db,
               "SELECT (SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'),(SELECT COUNT(*) FROM request_execution)"
             )

    assert [[0]] == rows(db, "SELECT COUNT(*) FROM request_journal WHERE disposition='queued'")
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(store, manager, original.occurrence_id)

    assert {:ok, %{writable: true}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  test "ordinary restart terminalizes old-boot unsent work without renewing its occurrence", %{
    path: path
  } do
    {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
    {:ok, original, _snapshot} = temporal_consider_fixture(store, activation, 100_001)
    {_, keys, _} = Process.get(:temporal_fixture_details)
    :ok = GenServer.stop(store)
    {:ok, restarted} = Store.start_link([path: path] ++ keys)

    assert {:ok,
            %{
              receipts: [
                %{disposition: :rejected, reason: "schedule_blocked:temporal_basis_changed"}
              ]
            }} = Store.advance_schedule(restarted)

    assert {:ok, %{receipts: []}} = Store.advance_schedule(restarted)

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(restarted, manager, original.occurrence_id)

    {:ok, db} = Sqlite3.open(path)

    assert [[0]] ==
             rows(
               db,
               "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(restarted)
  end

  for stage <- [:claim, :handoff], loss <- [:expiry, :report_age] do
    test "#{loss} after #{stage} publication rolls back the complete transition", %{path: path} do
      stage = unquote(stage)
      loss = unquote(loss)
      {store, manager, _thing, _clock, activation} = temporal_fixture(path, 90_000)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      operation = original.occurrence_id

      assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
               temporal_advance_fixture(store, snapshot)

      transition = temporal_prepare_transition(store, manager, operation, stage, snapshot)

      {:ok, before} = Store.health(store)

      reason =
        unquote(if loss == :expiry, do: :occurrence_expired, else: :observation_unavailable)

      assert {:error, {:policy, ^reason}} =
               temporal_effect_fixture(
                 store,
                 manager,
                 operation,
                 transition,
                 snapshot,
                 100_001,
                 0,
                 loss
               )

      {:ok, after_health} = Store.health(store)
      assert after_health.store_revision == before.store_revision
      {:ok, db} = Sqlite3.open(path)
      retained = unquote(if stage == :claim, do: "queued", else: "claimed")

      assert [[^retained, ^retained, 1]] =
               rows(
                 db,
                 "SELECT r.disposition,e.state,c.reserved_effects FROM request_receipts r JOIN request_execution e USING(principal_id,authority_epoch,operation_id) JOIN request_causal_roots c USING(principal_id,authority_epoch,operation_id) WHERE r.operation_id=?",
                 [operation]
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      :ok = GenServer.stop(store)
    end
  end

  for loss <- [nil, :expiry] do
    test "scheduled no-send closure repeats the post-publication window with #{inspect(loss)}", %{
      path: path
    } do
      loss = unquote(loss)
      {store, manager, thing, _clock, activation} = temporal_fixture(path, 90_000)
      {:ok, capability} = Thing.capability(thing, "power")
      {:ok, observation} = power_report(capability, true)
      assert {:ok, _} = Store.record(store, %{observation | source_sequence: 3}, capability)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      operation = original.occurrence_id
      {:ok, before} = Store.health(store)

      if loss do
        assert {:error, {:policy, :occurrence_expired}} =
                 temporal_effect_fixture(
                   store,
                   manager,
                   operation,
                   :queue,
                   snapshot,
                   100_001,
                   0,
                   loss
                 )

        {:ok, after_health} = Store.health(store)
        assert after_health.store_revision == before.store_revision
      else
        assert {:ok,
                {:ok,
                 %{receipts: [%{disposition: :rejected, reason: "already_reported_no_send"}]}}} =
                 temporal_advance_fixture(store, snapshot)

        assert {:ok, {:ok, %{receipts: []}}} = temporal_advance_fixture(store, snapshot)
      end

      {:ok, db} = Sqlite3.open(path)
      retained = if loss, do: "held", else: "rejected"

      assert [[^retained, 0, 0]] =
               rows(
                 db,
                 "SELECT r.disposition,c.reserved_effects,(SELECT COUNT(*) FROM request_execution) FROM request_receipts r JOIN request_causal_roots c USING(principal_id,authority_epoch,operation_id) WHERE r.operation_id=?",
                 [operation]
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:claim, :handoff],
      loss <- [:expiry, :early, :uncertain, :clock_loss, :report_age, :qualification_loss] do
    test "#{loss} at the final enclosing #{phase} guard leaves no tentative transition", %{
      path: path
    } do
      phase = unquote(phase)
      loss = unquote(loss)
      {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      operation = original.occurrence_id

      assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
               temporal_advance_fixture(store, snapshot)

      {reported_ms, _age} = final_report_age(store)
      qualification_file = final_qualification_file(path)

      clock =
        start_supervised!(
          {FinalClockFixture,
           sample: snapshot.sample,
           reported_ms: reported_ms,
           qualification_file: qualification_file}
        )

      :sys.replace_state(store, fn state -> %{state | temporal_clock_owner: clock} end)
      token = final_phase_token(store, phase, operation)
      assert :ok = GenServer.call(clock, {:reset, loss})
      prepare_report_age(store, loss)
      assert {:ok, before} = Store.revision(store)

      reason =
        unquote(
          case loss do
            :expiry -> :occurrence_expired
            :early -> :occurrence_early
            :uncertain -> :clock_uncertain
            :clock_loss -> :temporal_clock_unavailable
            :report_age -> :observation_unavailable
            :qualification_loss -> :qualification_artifact_unavailable
          end
        )

      assert {:error, ^reason} = final_phase_call(store, phase, operation, token)

      assert unquote(if loss == :qualification_loss, do: 2, else: 3) ==
               GenServer.call(clock, :count)

      if unquote(loss == :qualification_loss) do
        assert :ok = File.rename(qualification_file <> ".held", qualification_file)
      end

      assert {:ok, ^before} = Store.revision(store)
      retained = unquote(if phase == :claim, do: :queued, else: :claimed)
      assert {:ok, %{disposition: ^retained}} = Store.request_status(store, manager, 1, operation)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
      {:ok, db} = Sqlite3.open(path)

      assert [[1, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:claim, :handoff], sql_fault <- [false, true] do
    test "an enclosing #{phase} withdrawal #{if sql_fault, do: "rolls back on SQL failure", else: "undoes the tentative transition and commits its barrier"}",
         %{path: path} do
      phase = unquote(phase)
      {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      operation = original.occurrence_id

      assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
               temporal_advance_fixture(store, snapshot)

      # This synchronous suite temporarily removes one already-loaded Home
      # artifact, then restores it before any later Store call or compilation.
      # The disappearance remains external to the SQL savepoint, as real
      # current-runtime custody loss would. No source or module code changes.
      runtime_file = :code.which(WotexHome.Schedules.Window) |> List.to_string()

      on_exit(fn ->
        if File.exists?(runtime_file <> ".held"),
          do: File.rename(runtime_file <> ".held", runtime_file)
      end)

      {reported_ms, _} = final_report_age(store)

      clock =
        start_supervised!(
          {FinalClockFixture,
           sample: snapshot.sample, reported_ms: reported_ms, runtime_file: runtime_file}
        )

      :sys.replace_state(store, fn state -> %{state | temporal_clock_owner: clock} end)
      token = final_phase_token(store, phase, operation)
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      if unquote(sql_fault) do
        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER final_withdrawal_fault BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' BEGIN SELECT RAISE(ABORT,'injected_final_withdrawal_fault'); END"
                 )
      end

      assert :ok = GenServer.call(clock, {:reset, :runtime_loss})

      result =
        try do
          final_phase_call(store, phase, operation, token)
        after
          if File.exists?(runtime_file <> ".held") do
            :ok = File.rename(runtime_file <> ".held", runtime_file)
          end
        end

      assert 2 == GenServer.call(clock, :count)

      if unquote(sql_fault) do
        assert {:error, :store_unavailable} = result
        assert {:ok, ^before} = Store.revision(store)
        retained = unquote(if phase == :claim, do: :queued, else: :claimed)

        assert {:ok, %{disposition: ^retained}} =
                 Store.request_status(store, manager, 1, operation)

        assert [[0]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{writable: false}} = Store.health(store)
        assert :ok = Sqlite3.execute(db, "DROP TRIGGER final_withdrawal_fault")
      else
        assert {:error, :execution_basis_changed} = result

        assert {:ok, %{state: :suspended, reason: "stale_schedule_admission"}} =
                 Store.schedule_status(store, manager)

        assert {:ok, %{disposition: :rejected}} =
                 Store.request_status(store, manager, 1, operation)

        assert [[1]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, after_revision} = Store.revision(store)
        assert after_revision > before
        assert {:ok, %{writable: true}} = Store.health(store)
        assert %{} == :sys.get_state(store).claim_owners
      end

      assert [[1, 0, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching'),(SELECT COUNT(*) FROM request_execution WHERE state='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      :ok = GenServer.stop(store)
    end
  end

  test "schedule suspension preserves a previously committed handoff and validates its exact unknown reason",
       %{path: path} do
    {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    operation = original.occurrence_id

    assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
             temporal_advance_fixture(store, snapshot)

    {reported_ms, _} = final_report_age(store)

    clock =
      start_supervised!({FinalClockFixture, sample: snapshot.sample, reported_ms: reported_ms})

    :sys.replace_state(store, fn state -> %{state | temporal_clock_owner: clock} end)
    token = final_phase_token(store, :handoff, operation)

    assert {:ok, %{disposition: :dispatching}} =
             final_phase_call(store, :handoff, operation, token)

    assert {:ok, before} = Store.revision(store)

    {:ok, document} =
      WotexHome.Schedules.OperationInput.encode("suspend", %{
        "authority_epoch" => 1,
        "operation_id" => "schedule:suspend-handed",
        "expected_revision" => before
      })

    assert {:ok, suspended} = Store.change_schedule(store, manager, document)
    assert %{state: :suspended, affected_requests: 1, unknown_outcomes: 1} = suspended

    assert {:ok, %{disposition: :outcome_unknown, reason: "rule_generation_fenced_after_handoff"}} =
             Store.request_status(store, manager, 1, operation)

    assert {:ok, ^suspended} = Store.original_schedule_status(store, manager, document)
    assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
    {:ok, db} = Sqlite3.open(path)

    assert [[1, 1]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)

    assert :ok =
             Sqlite3.execute(
               db,
               "UPDATE request_journal SET reason='rule_generation_fenced' WHERE disposition='outcome_unknown'"
             )

    assert {:error, :corrupt_schedule_lifecycle} =
             WotexHome.Durable.Store.ScheduleLifecycle.validate_if_current(db)

    assert :ok =
             Sqlite3.execute(
               db,
               "UPDATE request_journal SET reason='rule_generation_fenced_after_handoff' WHERE disposition='outcome_unknown'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
    assert {:ok, restarted} = Store.start_link(path: path)
    assert {:ok, ^suspended} = Store.original_schedule_status(restarted, manager, document)
    assert {:ok, ^original} = Store.original_schedule_occurrence(restarted, manager, operation)

    assert {:ok, %{disposition: :outcome_unknown}} =
             Store.request_status(restarted, manager, 1, operation)

    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(restarted)
    :ok = GenServer.stop(restarted)
  end

  test "a final Store handoff refusal prevents the actual power executor from sending", %{
    path: path
  } do
    {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    operation = original.occurrence_id

    assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
             temporal_advance_fixture(store, snapshot)

    {reported_ms, _} = final_report_age(store)

    clock =
      start_supervised!({FinalClockFixture, sample: snapshot.sample, reported_ms: reported_ms})

    :sys.replace_state(store, fn state -> %{state | temporal_clock_owner: clock} end)
    parent = self()

    hooks = %{
      claim: fn boot, now ->
        Store.claim_lifx_power(store, "manager:schedule", 1, operation, boot, now)
      end,
      handoff: fn claim, now ->
        :ok = GenServer.call(clock, {:reset, :expiry})
        send(parent, :attempted_final_handoff)
        Store.handoff_claimed_power(store, "manager:schedule", 1, operation, claim.token, now)
      end,
      ack: fn _ -> flunk("refused handoff cannot receive an ACK") end,
      settle: fn _, _ -> flunk("refused handoff cannot settle a report") end,
      unknown: fn _, _ -> flunk("refused handoff creates no transport uncertainty") end
    }

    {:ok, candidate} = Candidate.new(@candidate)
    {:ok, ledger} = Ledger.new(42)

    assert {:error, :occurrence_expired, ^ledger} =
             WotexHome.Lifx.PowerExecution.run(
               hooks,
               candidate,
               <<0xD0, 0x73, 0xD5, 0x00, 0x00, 0x01>>,
               ledger,
               transport: {NoSendFixture, self()},
               clock: fn -> {101, 1_700_000_000_101} end,
               source_epoch: "lifx:final-commit",
               source_sequence: 3,
               boot_epoch: "boot:1",
               ack_timeout_ms: 5,
               read_timeout_ms: 5,
               duration_ms: 0
             )

    assert_receive :attempted_final_handoff
    refute_receive {:unexpected_power_packet, _, _}
    assert 3 == GenServer.call(clock, :count)
    assert {:ok, %{disposition: :claimed}} = Store.request_status(store, manager, 1, operation)
    assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
    {:ok, db} = Sqlite3.open(path)

    assert [[1, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  defp final_qualification_file(path) do
    root = Path.join(Path.dirname(path), "qualification_claims")
    [file] = File.ls!(root)
    full = Path.join(root, file)

    on_exit(fn ->
      if File.exists?(full <> ".held"), do: File.rename(full <> ".held", full)
    end)

    full
  end

  defp prepare_report_age(store, :report_age) do
    {_reported_ms, age} = final_report_age(store)
    Process.sleep(max(0, 600 - age))
  end

  defp prepare_report_age(_, _), do: :ok

  for phase <- [:queue, :no_send, :advance_queue, :advance_no_send],
      loss <- [:expiry, :early, :uncertain, :clock_loss, :report_age] do
    test "#{loss} at the enclosing #{phase} boundary preserves an honest admission result", %{
      path: path
    } do
      phase = unquote(phase)
      loss = unquote(loss)
      {store, manager, thing, _owner, activation} = temporal_fixture(path, 90_000)

      prepare_admission_value(store, thing, phase)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      clock = final_admission_clock(store, snapshot)
      assert :ok = GenServer.call(clock, {:reset, loss})
      prepare_report_age(store, loss)
      assert {:ok, before} = Store.revision(store)

      reason =
        unquote(
          case loss do
            :expiry -> :occurrence_expired
            :early -> :occurrence_early
            :uncertain -> :clock_uncertain
            :clock_loss -> :temporal_clock_unavailable
            :report_age -> :observation_unavailable
          end
        )

      result = final_admission_call(store, manager, original.occurrence_id, phase)
      assert_final_admission_result(result, phase, reason)
      assert 3 == GenServer.call(clock, :count)

      if unquote(phase in [:queue, :no_send]) do
        assert {:ok, ^before} = Store.revision(store)

        assert {:ok, %{disposition: :held}} =
                 Store.request_status(store, manager, 1, original.occurrence_id)
      else
        assert {:ok, after_revision} = Store.revision(store)
        assert after_revision == before + 1
        assert {:ok, %{receipts: [], has_more: false}} = Store.advance_schedule(store)
      end

      assert_no_tentative_admission(path)

      assert {:ok, ^original} =
               Store.original_schedule_occurrence(store, manager, original.occurrence_id)

      assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:queue, :advance_queue] do
    test "qualification custody loss at enclosing #{phase} restores the unspent held root", %{
      path: path
    } do
      phase = unquote(phase)
      {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      qualification_file = final_qualification_file(path)
      clock = final_admission_clock(store, snapshot, qualification_file: qualification_file)
      assert :ok = GenServer.call(clock, {:reset, :qualification_loss})

      result =
        try do
          final_admission_call(store, manager, original.occurrence_id, phase)
        after
          if File.exists?(qualification_file <> ".held"),
            do: File.rename(qualification_file <> ".held", qualification_file)
        end

      assert_final_admission_result(result, phase, :qualification_artifact_unavailable)
      assert 2 == GenServer.call(clock, :count)
      assert_no_tentative_admission(path)

      assert {:ok, ^original} =
               Store.original_schedule_occurrence(store, manager, original.occurrence_id)

      assert {:ok, %{writable: true}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:admit_no_send, :no_send, :advance_no_send] do
    test "the enclosing #{phase} guard closes an actual reported value without control qualification",
         %{path: path} do
      phase = unquote(phase)
      {store, manager, thing, _owner, activation} = temporal_fixture(path, 90_000)
      prepare_admission_value(store, thing, phase)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      clock = final_admission_clock(store, snapshot)
      qualification_file = final_qualification_file(path)
      assert :ok = File.rename(qualification_file, qualification_file <> ".held")

      result =
        try do
          final_admission_call(store, manager, original.occurrence_id, phase)
        after
          assert :ok = File.rename(qualification_file <> ".held", qualification_file)
        end

      if unquote(phase == :advance_no_send) do
        assert {:ok, %{receipts: [%{disposition: :rejected, reason: "already_reported_no_send"}]}} =
                 result
      else
        assert {:ok, %{disposition: :rejected, reason: "already_reported_no_send"}} = result
      end

      assert 3 == GenServer.call(clock, :count)
      {:ok, db} = Sqlite3.open(path)

      assert [[0, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_execution) FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)

      assert {:ok, ^original} =
               Store.original_schedule_occurrence(store, manager, original.occurrence_id)

      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:queue, :no_send, :advance_queue, :advance_no_send], sql_fault <- [false, true] do
    test "an enclosing #{phase} admission withdrawal #{if sql_fault, do: "rolls back on publication failure", else: "retains its barrier without a tentative admission"}",
         %{path: path} do
      phase = unquote(phase)
      {store, manager, thing, _owner, activation} = temporal_fixture(path, 90_000)
      prepare_admission_value(store, thing, phase)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      runtime_file = :code.which(WotexHome.Schedules.Window) |> List.to_string()

      on_exit(fn ->
        if File.exists?(runtime_file <> ".held"),
          do: File.rename(runtime_file <> ".held", runtime_file)
      end)

      clock = final_admission_clock(store, snapshot, runtime_file: runtime_file)
      assert :ok = GenServer.call(clock, {:reset, :runtime_loss})
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      if unquote(sql_fault) do
        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER admission_withdrawal_fault BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' BEGIN SELECT RAISE(ABORT,'injected_admission_withdrawal_fault'); END"
                 )
      end

      result =
        try do
          final_admission_call(store, manager, original.occurrence_id, phase)
        after
          if File.exists?(runtime_file <> ".held"),
            do: File.rename(runtime_file <> ".held", runtime_file)
        end

      assert 2 == GenServer.call(clock, :count)

      if unquote(sql_fault) do
        assert {:error, :store_unavailable} = result
        assert {:ok, ^before} = Store.revision(store)

        assert {:ok, %{disposition: :held}} =
                 Store.request_status(store, manager, 1, original.occurrence_id)

        assert {:ok, %{writable: false}} = Store.health(store)
        assert :ok = Sqlite3.execute(db, "DROP TRIGGER admission_withdrawal_fault")
      else
        if unquote(phase in [:queue, :no_send]) do
          assert {:error,
                  unquote(
                    if phase == :queue,
                      do: :execution_basis_changed,
                      else: :schedule_basis_changed
                  )} = result
        else
          assert {:ok,
                  %{
                    receipts: [%{disposition: :rejected, reason: "rule_generation_fenced"}],
                    has_more: false
                  }} = result
        end

        assert {:ok, %{state: :suspended, reason: "stale_schedule_admission"}} =
                 Store.schedule_status(store, manager)

        assert {:ok, %{disposition: :rejected, reason: "rule_generation_fenced"}} =
                 Store.request_status(store, manager, 1, original.occurrence_id)

        assert {:ok, %{writable: true}} = Store.health(store)
      end

      Sqlite3.close(db)
      assert_no_tentative_admission(path)

      assert {:ok, ^original} =
               Store.original_schedule_occurrence(store, manager, original.occurrence_id)

      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:queue, :no_send, :advance_queue, :advance_no_send, :claim, :handoff],
      sql_fault <- [false, true] do
    @tag restored_withdrawal: true
    test "a detected #{phase} withdrawal survives custody restored inside the call#{if sql_fault, do: " or rolls back its failed replay", else: ""}",
         %{path: path} do
      phase = unquote(phase)
      {store, manager, thing, _owner, activation} = temporal_fixture(path, 90_000)
      prepare_admission_value(store, thing, phase)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      operation = original.occurrence_id

      if unquote(phase in [:claim, :handoff]) do
        assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
                 temporal_advance_fixture(store, snapshot)
      end

      runtime_file = :code.which(WotexHome.Schedules.Window) |> List.to_string()

      on_exit(fn ->
        if File.exists?(runtime_file <> ".held"),
          do: File.rename(runtime_file <> ".held", runtime_file)
      end)

      clock = final_admission_clock(store, snapshot, runtime_file: runtime_file)

      token =
        final_phase_token(
          store,
          unquote(if phase == :handoff, do: :handoff, else: :claim),
          operation
        )

      assert :ok = GenServer.call(clock, {:reset, :runtime_loss})
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)
      restore_runtime_during_withdrawal(store, db, runtime_file)

      if unquote(sql_fault) do
        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER restored_withdrawal_fault BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' AND NEW.expected_revision=#{before} BEGIN SELECT RAISE(ABORT,'injected_restored_withdrawal_fault'); END"
                 )
      end

      result =
        try do
          restored_withdrawal_call(store, manager, operation, phase, token)
        after
          if File.exists?(runtime_file <> ".held"),
            do: File.rename(runtime_file <> ".held", runtime_file)
        end

      assert_receive :runtime_restored_during_withdrawal, 1_000
      assert File.exists?(runtime_file)
      assert 2 == GenServer.call(clock, :count)

      if unquote(sql_fault) do
        assert {:error, :store_unavailable} = result
        assert {:ok, ^before} = Store.revision(store)

        retained =
          unquote(
            if phase == :claim,
              do: :queued,
              else: if(phase == :handoff, do: :claimed, else: :held)
          )

        assert {:ok, %{disposition: ^retained}} =
                 Store.request_status(store, manager, 1, operation)

        assert [[0]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{writable: false}} = Store.health(store)
        assert :ok = Sqlite3.execute(db, "DROP TRIGGER restored_withdrawal_fault")
      else
        if unquote(phase in [:advance_queue, :advance_no_send]) do
          assert {:ok,
                  %{
                    receipts: [%{disposition: :rejected, reason: "rule_generation_fenced"}],
                    has_more: false
                  }} = result
        else
          assert {:error, reason} = result
          assert reason in [:execution_basis_changed, :schedule_basis_changed]
        end

        assert {:ok, %{state: :suspended, reason: "stale_schedule_admission"}} =
                 Store.schedule_status(store, manager)

        assert {:ok, %{disposition: :rejected, reason: "rule_generation_fenced"}} =
                 Store.request_status(store, manager, 1, operation)

        assert [[1, 1, 0]] =
                 rows(
                   db,
                   "SELECT COUNT(*),SUM(affected_requests),SUM(unknown_outcomes) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
        assert %{} == :sys.get_state(store).claim_owners
      end

      spent = unquote(if phase in [:claim, :handoff], do: 1, else: 0)

      assert [[^spent, 0, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching'),(SELECT COUNT(*) FROM request_execution WHERE state='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER restored_withdrawal_delay")
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      :ok = GenServer.stop(store)
    end
  end

  # The hook observes only the actual generation publication, without a Store
  # reference or SQLite handle. A bounded SQL fixture delays the subsequent
  # lifecycle insert so restoration completes before its final guard/replay.
  defp restore_runtime_during_withdrawal(store, db, runtime_file) do
    [[generation_row]] = rows(db, "SELECT rowid FROM meta WHERE key='rule_generation'")
    test = self()

    observer =
      spawn_link(fn ->
        receive do
          {:update, "main", "meta", ^generation_row} ->
            :ok = File.rename(runtime_file <> ".held", runtime_file)
            send(test, :runtime_restored_during_withdrawal)
        after
          10_000 -> exit(:withdrawal_not_observed)
        end
      end)

    :sys.replace_state(store, fn state ->
      :ok = Sqlite3.set_update_hook(state.db, observer)
      state
    end)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER restored_withdrawal_delay BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' BEGIN SELECT count(*) FROM (WITH RECURSIVE delay(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM delay WHERE n<2000000) SELECT n FROM delay); END"
             )
  end

  defp restored_withdrawal_call(store, _, operation, phase, token)
       when phase in [:claim, :handoff],
       do: final_phase_call(store, phase, operation, token)

  defp restored_withdrawal_call(store, manager, operation, phase, _token),
    do: final_admission_call(store, manager, operation, phase)

  for phase <- [:queue, :no_send, :claim, :handoff], sql_fault <- [false, true] do
    test "an initial #{phase} runtime refusal #{if sql_fault, do: "rolls back a failed withdrawal", else: "retains a sticky withdrawal"}",
         %{path: path} do
      phase = unquote(phase)
      {store, manager, thing, _owner, activation} = temporal_fixture(path, 90_000)
      prepare_admission_value(store, thing, phase)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
      operation = original.occurrence_id

      if unquote(phase in [:claim, :handoff]) do
        assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
                 temporal_advance_fixture(store, snapshot)
      end

      final_admission_clock(store, snapshot)

      token =
        final_phase_token(
          store,
          unquote(if phase == :handoff, do: :handoff, else: :claim),
          operation
        )

      assert {:ok, before} = Store.revision(store)
      runtime_file = :code.which(WotexHome.Schedules.Window) |> List.to_string()

      on_exit(fn ->
        if File.exists?(runtime_file <> ".held"),
          do: File.rename(runtime_file <> ".held", runtime_file)
      end)

      {:ok, db} = Sqlite3.open(path)

      if unquote(sql_fault) do
        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER initial_withdrawal_fault BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' BEGIN SELECT RAISE(ABORT,'injected_initial_withdrawal_fault'); END"
                 )
      end

      assert :ok = File.rename(runtime_file, runtime_file <> ".held")

      result =
        try do
          initial_power_call(store, manager, operation, phase, token)
        after
          assert :ok = File.rename(runtime_file <> ".held", runtime_file)
        end

      if unquote(sql_fault) do
        assert {:error, :store_unavailable} = result
        assert {:ok, ^before} = Store.revision(store)

        retained =
          unquote(
            if phase == :claim,
              do: :queued,
              else: if(phase == :handoff, do: :claimed, else: :held)
          )

        assert {:ok, %{disposition: ^retained}} =
                 Store.request_status(store, manager, 1, operation)

        assert [[0]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{writable: false}} = Store.health(store)
        assert :ok = Sqlite3.execute(db, "DROP TRIGGER initial_withdrawal_fault")
      else
        assert {:error, refusal} = result
        assert refusal in [:runtime_artifact_unavailable, :stale_schedule_admission]

        assert {:ok, %{state: :suspended, reason: "stale_schedule_admission"}} =
                 Store.schedule_status(store, manager)

        assert {:ok, %{disposition: :rejected, reason: "rule_generation_fenced"}} =
                 Store.request_status(store, manager, 1, operation)

        assert [[1]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, after_revision} = Store.revision(store)
        assert after_revision > before
        assert {:ok, %{receipts: []}} = Store.advance_schedule(store)
        assert {:ok, ^after_revision} = Store.revision(store)
        assert {:ok, %{writable: true}} = Store.health(store)
        assert %{} == :sys.get_state(store).claim_owners
      end

      spent = unquote(if phase in [:claim, :handoff], do: 1, else: 0)

      assert [[^spent, 0, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching'),(SELECT COUNT(*) FROM request_journal WHERE reason='already_reported_no_send') FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      :ok = GenServer.stop(store)
    end
  end

  defp initial_power_call(store, _manager, operation, phase, token)
       when phase in [:claim, :handoff],
       do: final_phase_call(store, phase, operation, token)

  defp initial_power_call(store, manager, operation, phase, _token),
    do: final_admission_call(store, manager, operation, phase)

  test "failure while terminalizing a final advancement refusal rolls back every tentative admission",
       %{path: path} do
    {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    clock = final_admission_clock(store, snapshot)
    assert :ok = GenServer.call(clock, {:reset, :expiry})
    assert {:ok, before} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER final_closure_fault BEFORE INSERT ON request_journal WHEN NEW.disposition='rejected' AND NEW.reason LIKE 'schedule_blocked:%' BEGIN SELECT RAISE(ABORT,'injected_final_closure_fault'); END"
             )

    assert {:error, :store_unavailable} = Store.advance_schedule(store)
    assert 3 == GenServer.call(clock, :count)
    assert {:ok, ^before} = Store.revision(store)

    assert {:ok, %{disposition: :held}} =
             Store.request_status(store, manager, 1, original.occurrence_id)

    assert {:ok, %{writable: false}} = Store.health(store)
    assert :ok = Sqlite3.execute(db, "DROP TRIGGER final_closure_fault")
    Sqlite3.close(db)
    assert_no_tentative_admission(path)

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(store, manager, original.occurrence_id)

    :ok = GenServer.stop(store)
  end

  defp final_admission_clock(store, snapshot, extra \\ []) do
    {reported_ms, _} = final_report_age(store)

    clock =
      start_supervised!(
        {FinalClockFixture, [sample: snapshot.sample, reported_ms: reported_ms] ++ extra}
      )

    :sys.replace_state(store, fn state -> %{state | temporal_clock_owner: clock} end)
    clock
  end

  for phase <- [:queued, :claimed], loss <- [:qualification_loss, :report_age] do
    test "an otherwise unchanged pass closes #{phase} on #{loss} without refunding its spent root",
         %{path: path} do
      phase = unquote(phase)
      loss = unquote(loss)
      {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)

      assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
               temporal_advance_fixture(store, snapshot)

      final_admission_clock(store, snapshot)
      prepare_retained_claim(store, phase, original.occurrence_id)
      qualification_file = final_qualification_file(path)
      prepare_pending_loss(store, loss, qualification_file)

      reason =
        unquote(
          if loss == :qualification_loss,
            do: "schedule_blocked:qualification_artifact_unavailable",
            else: "schedule_blocked:observation_unavailable"
        )

      result =
        try do
          Store.advance_schedule(store)
        after
          if File.exists?(qualification_file <> ".held"),
            do: File.rename(qualification_file <> ".held", qualification_file)
        end

      assert {:ok, %{receipts: [%{disposition: :rejected, reason: ^reason}], has_more: false}} =
               result

      assert {:ok, %{receipts: []}} = Store.advance_schedule(store)
      assert %{} == :sys.get_state(store).claim_owners

      assert {:ok, ^original} =
               Store.original_schedule_occurrence(store, manager, original.occurrence_id)

      {:ok, db} = Sqlite3.open(path)

      assert [[1, 0, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_execution),(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:queued, :claimed] do
    test "final #{phase} refusal restores the other tentative closure and preserves prior spend",
         %{path: path} do
      phase = unquote(phase)
      {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
      {:ok, first, snapshot} = temporal_consider_fixture(store, activation, 100_001)

      assert {:ok, {:ok, %{receipts: [%{disposition: :queued}]}}} =
               temporal_advance_fixture(store, snapshot)

      clock = final_admission_clock(store, snapshot, loss_at: 4)
      prepare_retained_claim(store, phase, first.occurrence_id)
      # A second canonical coordinate is retained through the borrowed software
      # clock fixture. It is early at this pass and cannot create an effect.
      # This synthetic trace qualifies neither a correcting clock nor a host.
      {:ok, second, _} = temporal_consider_fixture(store, activation, 160_001)
      assert :ok = GenServer.call(clock, {:reset, :expiry})

      assert {:ok, %{receipts: [closed, held], has_more: false}} = Store.advance_schedule(store)

      assert %{
               operation_id: operation,
               disposition: :rejected,
               reason: "schedule_blocked:occurrence_expired"
             } = closed

      assert operation == first.occurrence_id
      assert %{operation_id: operation, disposition: :held} = held
      assert operation == second.occurrence_id
      assert 4 == GenServer.call(clock, :count)
      {:ok, db} = Sqlite3.open(path)

      assert [[1, 0], [0, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal j WHERE j.principal_id=c.principal_id AND j.authority_epoch=c.authority_epoch AND j.operation_id=c.operation_id AND j.disposition='dispatching') FROM request_causal_roots c WHERE origin='schedule_occurrence' ORDER BY created_revision"
               )

      assert [[0]] =
               rows(
                 db,
                 "SELECT COUNT(*) FROM request_journal WHERE operation_id=? AND disposition='rejected'",
                 [second.occurrence_id]
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)

      assert {:ok, ^first} =
               Store.original_schedule_occurrence(store, manager, first.occurrence_id)

      assert {:ok, ^second} =
               Store.original_schedule_occurrence(store, manager, second.occurrence_id)

      assert {:ok,
              %{
                receipts: [%{disposition: :rejected, reason: "schedule_blocked:occurrence_early"}]
              }} = Store.advance_schedule(store)

      assert {:ok, %{receipts: []}} = Store.advance_schedule(store)
      :ok = GenServer.stop(store)
    end
  end

  defp prepare_retained_claim(store, :claimed, operation),
    do: final_phase_token(store, :handoff, operation)

  defp prepare_retained_claim(_, _, _), do: :ok

  for phase <- [:held, :queued, :claimed, :dispatching, :protocol_accepted, :observed] do
    @tag countdown_execution: true
    @tag countdown_phase: phase
    test "countdown restart fences #{phase} and retains original causal history", %{
      path: path,
      countdown_phase: phase
    } do
      {store, manager, thing, _owner, activation} =
        temporal_fixture(path, 90_000, true, :countdown)

      {:ok, snapshot} = Store.temporal_clock_snapshot(store)
      final_admission_clock(store, snapshot, monotonic_only: true)
      advance_store_clock(store, 60_000)
      refresh_temporal_report(store, thing, 3)

      assert {:ok, %{state: :held} = original} =
               Authority.consider_schedule(Authority.new(store: store))

      operation = original.occurrence_id

      if phase != :held do
        assert {:ok, %{receipts: [%{disposition: :queued}]}} = Store.advance_schedule(store)
      end

      token =
        if phase in [:claimed, :dispatching, :protocol_accepted, :observed] do
          assert {:ok, %{disposition: :claimed}, token} =
                   Store.claim_queued_power(
                     store,
                     "manager:schedule",
                     1,
                     operation,
                     "boot:1",
                     101
                   )

          token
        end

      if phase in [:dispatching, :protocol_accepted, :observed] do
        assert {:ok, %{disposition: :dispatching}} =
                 Store.handoff_claimed_power(store, "manager:schedule", 1, operation, token, 101)
      end

      if phase in [:protocol_accepted, :observed] do
        assert {:ok, %{disposition: :protocol_accepted}} =
                 Store.accept_power_ack(store, "manager:schedule", 1, operation, token)
      end

      if phase == :observed do
        {:ok, capability} = Thing.capability(thing, "power")
        {:ok, report} = power_report(capability, true)

        assert {:ok, %{disposition: :observed}} =
                 Store.settle_power_readback(store, "manager:schedule", 1, operation, token, %{
                   report
                   | source_sequence: 4
                 })
      end

      originals =
        temporal_sql_fixture(store, fn state ->
          {rows(state.db, "SELECT * FROM schedule_considerations"),
           rows(state.db, "SELECT * FROM request_causal_roots")}
        end)

      {_old_store, keys, _thing} = Process.get(:temporal_fixture_details)
      :ok = GenServer.stop(store)
      {:ok, restarted} = Store.start_link([path: path] ++ keys)

      assert {:ok, %{state: :suspended, reason: "countdown_missed:old_boot", rule_generation: 2}} =
               Store.schedule_status(restarted, manager)

      assert {:ok, ^original} = Store.original_schedule_occurrence(restarted, manager, operation)
      {:ok, db} = Sqlite3.open(path)

      expected =
        case phase do
          :observed -> "observed"
          handed when handed in [:dispatching, :protocol_accepted] -> "outcome_unknown"
          _ -> "rejected"
        end

      assert [[^expected]] =
               rows(db, "SELECT disposition FROM request_receipts WHERE operation_id=?", [
                 operation
               ])

      assert {rows(db, "SELECT * FROM schedule_considerations"),
              rows(db, "SELECT * FROM request_causal_roots")} == originals

      assert [[1]] =
               rows(
                 db,
                 "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
               )

      assert [[count]] =
               rows(
                 db,
                 "SELECT COUNT(*) FROM request_journal WHERE operation_id=? AND disposition='dispatching'",
                 [operation]
               )

      assert count == if(phase in [:dispatching, :protocol_accepted, :observed], do: 1, else: 0)
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)

      assert {:ok, ^activation} =
               Store.original_schedule_status(
                 restarted,
                 manager,
                 temporal_activation_input(activation)
               )

      assert {:ok, %{state: :inactive}} = Store.consider_schedule(restarted)
      assert {:ok, %{dispatch_enabled: false}} = Store.health(restarted)
      :ok = GenServer.stop(restarted)
    end
  end

  defp temporal_activation_input(activation) do
    {:ok, document} =
      WotexHome.Schedules.OperationInput.encode("activate", %{
        "authority_epoch" => 1,
        "operation_id" => "schedule:activate",
        "expected_revision" => activation.barrier_revision - 1,
        "admission_revision" => activation.admission_revision
      })

    document
  end

  for loss_at <- [6, 7], sql_fault <- [false, true] do
    @tag countdown_execution: true
    @tag countdown_poll_loss: loss_at
    @tag countdown_fault: sql_fault
    test "countdown poll read #{loss_at} loses its clock without retaining tentative intent#{if sql_fault, do: " when expiry fails", else: ""}",
         %{path: path, countdown_poll_loss: loss_at, countdown_fault: sql_fault} do
      {store, manager, thing, _owner, _activation} =
        temporal_fixture(path, 90_000, true, :countdown)

      {:ok, snapshot} = Store.temporal_clock_snapshot(store)
      clock = final_admission_clock(store, snapshot, monotonic_only: true, loss_at: loss_at)
      advance_store_clock(store, 60_000)
      refresh_temporal_report(store, thing, 3)
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      if sql_fault do
        :ok =
          Sqlite3.execute(
            db,
            "CREATE TRIGGER countdown_poll_fault BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' BEGIN SELECT RAISE(ABORT,'injected countdown poll fault'); END"
          )
      end

      assert :ok = GenServer.call(clock, {:reset, :clock_loss})
      result = Authority.consider_schedule(Authority.new(store: store))
      assert loss_at == GenServer.call(clock, :count)

      assert [[0, 0, 0, 0, 0]] =
               rows(
                 db,
                 "SELECT (SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM schedule_watermarks),(SELECT COUNT(*) FROM schedule_effect_operations),(SELECT COUNT(*) FROM request_receipts WHERE operation_id LIKE 'occ:%'),(SELECT COUNT(*) FROM request_causal_roots WHERE origin='schedule_occurrence')"
               )

      if sql_fault do
        assert {:error, :store_unavailable} = result
        assert {:ok, ^before} = Store.revision(store)

        assert [[0]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{writable: false}} = Store.health(store)
        :ok = Sqlite3.execute(db, "DROP TRIGGER countdown_poll_fault")
      else
        assert {:error, :temporal_clock_unavailable} = result

        assert [["countdown_missed:clock_unavailable", 0, 0]] =
                 rows(
                   db,
                   "SELECT reason,affected_requests,unknown_outcomes FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{state: :suspended, reason: "countdown_missed:clock_unavailable"}} =
                 Store.schedule_status(store, manager)

        assert {:ok, %{writable: true}} = Store.health(store)
      end

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:queue, :claim, :handoff], sql_fault <- [false, true] do
    @tag countdown_execution: true
    @tag countdown_phase: phase
    @tag countdown_fault: sql_fault
    test "final countdown #{phase} clock loss retains the restored phase#{if sql_fault, do: " when expiry publication fails", else: " through its missed barrier"}",
         %{path: path, countdown_phase: phase, countdown_fault: sql_fault} do
      {store, manager, thing, _owner, _activation} =
        temporal_fixture(path, 90_000, true, :countdown)

      {:ok, snapshot} = Store.temporal_clock_snapshot(store)
      clock = final_admission_clock(store, snapshot, monotonic_only: true)
      advance_store_clock(store, 60_000)
      refresh_temporal_report(store, thing, 3)

      assert {:ok, %{state: :held} = original} =
               Authority.consider_schedule(Authority.new(store: store))

      operation = original.occurrence_id

      if phase in [:claim, :handoff] do
        assert {:ok, %{receipts: [%{disposition: :queued}]}} = Store.advance_schedule(store)
      end

      token = if phase == :handoff, do: final_phase_token(store, :handoff, operation)

      before =
        temporal_sql_fixture(store, fn state ->
          {rows(state.db, "SELECT disposition FROM request_receipts WHERE operation_id=?", [
             operation
           ]), rows(state.db, "SELECT * FROM request_causal_roots"),
           rows(state.db, "SELECT value FROM meta WHERE key='revision'")}
        end)

      {:ok, db} = Sqlite3.open(path)

      if sql_fault do
        :ok =
          Sqlite3.execute(
            db,
            "CREATE TRIGGER countdown_final_fault BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' BEGIN SELECT RAISE(ABORT,'injected countdown final fault'); END"
          )
      end

      assert :ok = GenServer.call(clock, {:reset, :clock_loss})

      result =
        case phase do
          :queue ->
            Store.admit_held_power(store, manager, 1, operation, "boot:1", 101)

          :claim ->
            Store.claim_queued_power(store, "manager:schedule", 1, operation, "boot:1", 101)

          :handoff ->
            Store.handoff_claimed_power(store, "manager:schedule", 1, operation, token, 101)
        end

      assert 3 == GenServer.call(clock, :count)
      {old_phase, original_roots, original_revision} = before
      assert rows(db, "SELECT * FROM request_causal_roots") == original_roots

      assert [[0]] =
               rows(db, "SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching'")

      if sql_fault do
        assert {:error, :store_unavailable} = result

        assert rows(db, "SELECT disposition FROM request_receipts WHERE operation_id=?", [
                 operation
               ]) == old_phase

        assert rows(db, "SELECT value FROM meta WHERE key='revision'") == original_revision

        assert [[0]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{writable: false}} = Store.health(store)
        :ok = Sqlite3.execute(db, "DROP TRIGGER countdown_final_fault")
      else
        assert {:error, :schedule_basis_changed} = result

        assert [["rejected", "rule_generation_fenced"]] =
                 rows(
                   db,
                   "SELECT disposition,reason FROM request_receipts WHERE operation_id=?",
                   [operation]
                 )

        assert [["countdown_missed:clock_unavailable", 0]] =
                 rows(
                   db,
                   "SELECT reason,unknown_outcomes FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert {:ok, %{writable: true}} = Store.health(store)
      end

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      :ok = GenServer.stop(store)
    end
  end

  @durable_vectors Path.expand("../fixtures/schedules/durable_trace_vectors.json", __DIR__)
                   |> File.read!()
                   |> JSON.decode!()

  for %{"id" => id, "steps" => steps} <- @durable_vectors["vectors"] do
    @tag durable_trace: true
    @tag durable_trace_id: id
    test "independent durable trace #{id} agrees with the actual Authority and Store", %{
      path: path
    } do
      fixture = temporal_fixture(path, 90_000)
      steps = unquote(Macro.escape(steps))
      {context, activation_clock} = durable_trace_setup(path, fixture, steps)

      {:ok, model} =
        WotexHome.Schedules.DurableModel.new(%{
          anchor: 100_000,
          period: 60_000,
          late: 10_000,
          tolerance: 1_000,
          watermark: elem(durable_trace_interval(activation_clock), 1)
        })

      durable_trace_run(context, model, steps, unquote(id), 100_000)
    end
  end

  @calendar_sources Path.expand(
                      "../fixtures/schedules/calendar_durable_trace_vectors.json",
                      __DIR__
                    )
                    |> File.read!()
                    |> JSON.decode!()
                    |> Map.fetch!("vectors")
                    |> Map.new(&{&1["id"], &1})
  @calendar_execution Path.expand(
                        "../fixtures/schedules/calendar_execution_trace_vectors.json",
                        __DIR__
                      )
                      |> File.read!()
                      |> JSON.decode!()
                      |> Map.fetch!("vectors")

  for vector <- @calendar_execution do
    @tag calendar_execution_trace: true
    @tag calendar_execution_id: vector["id"]
    test "independent calendar execution #{vector["id"]} agrees with the actual Authority and Store",
         %{path: path} do
      vector = unquote(Macro.escape(vector))
      source = Map.fetch!(@calendar_sources, vector["source"])
      calendar = WotexHome.TestSupport.CalendarTraceInputs.installed(source, Path.dirname(path))
      fixture = temporal_fixture(path, source["watermark"] - 10_000, true, calendar)
      {context, activation_clock} = durable_trace_setup(path, fixture, vector["steps"])
      context = Map.put(context, :calendar_instants, calendar.instants)

      {:ok, model} =
        WotexHome.Schedules.DurableModel.new_calendar(%{
          instants: calendar.instants,
          finish: source["finish"],
          late: 10_000,
          tolerance: 1_000,
          watermark: elem(durable_trace_interval(activation_clock), 1)
        })

      durable_trace_run(context, model, vector["steps"], vector["id"], vector["coordinate"])
    end
  end

  @countdown_execution Path.expand(
                         "../fixtures/schedules/countdown_execution_trace_vectors.json",
                         __DIR__
                       )
                       |> File.read!()
                       |> JSON.decode!()
                       |> Map.fetch!("vectors")

  for vector <- @countdown_execution do
    @tag countdown_execution_trace: true
    @tag countdown_execution_id: vector["id"]
    test "independent countdown execution #{vector["id"]} agrees with the actual Authority and Store",
         %{path: path} do
      vector = unquote(Macro.escape(vector))
      fixture = temporal_fixture(path, 90_000, true, {:countdown, vector["duration"]})

      {context, activation_clock} =
        durable_trace_setup(path, fixture, vector["steps"],
          monotonic_only: vector["wall"] == "unqualified",
          loss_at: 1
        )

      {:ok, model} =
        WotexHome.Schedules.DurableModel.new_countdown(%{
          start: context.countdown.start,
          duration: vector["duration"],
          clock_generation: context.countdown.generation,
          late: 10_000,
          watermark: durable_trace_monotonic(activation_clock)
        })

      durable_trace_run(context, model, vector["steps"], vector["id"], model.anchor)
    end
  end

  defp durable_trace_setup(
         path,
         {store, manager, thing, _owner, activation},
         steps,
         options \\ []
       ) do
    assert :ok = File.chmod(Path.dirname(path), 0o700)

    maintainer =
      if Enum.any?(steps, fn step ->
           step in ["maintenance_begin", "maintenance_end"] or
             match?(["fault", "maintenance_begin"], step) or
             match?(["fault", "maintenance_end"], step)
         end) do
        {:ok, credential, _} =
          Store.provision_principal(store, "maintainer:trace", ["host:maintain"], [])

        credential
      end

    {snapshot, activation_clock} =
      temporal_sql_fixture(store, fn state ->
        {:ok, retained} =
          WotexHome.Durable.Store.ScheduleLifecycle.retained_activation(
            state.db,
            activation.revision
          )

        {:ok, snapshot, _} = WotexHome.Schedules.ActivationClock.decode(retained.clock_document)
        {snapshot, retained.clock_document}
      end)

    clock = final_admission_clock(store, snapshot, options)
    {_, keys, _} = Process.get(:temporal_fixture_details)
    qualification_file = final_qualification_file(path)

    on_exit(fn ->
      if File.exists?(qualification_file <> ".held"),
        do: File.rename(qualification_file <> ".held", qualification_file)
    end)

    context = %{
      store: store,
      path: path,
      manager: manager,
      thing: thing,
      activation: activation,
      clock: clock,
      keys: keys,
      qualification_file: qualification_file,
      maintainer: maintainer,
      maintenance_begin: 0,
      override_operation: nil,
      sequence: 2,
      step: 0,
      tokens: %{},
      operations: %{},
      originals: %{},
      historical_rows: %{},
      event_snapshots: [],
      clock_input: nil
    }

    context =
      case Process.get(:temporal_fixture_trigger) do
        ["countdown", _boot, generation, start, duration] ->
          Map.put(context, :countdown, %{
            start: start,
            duration: duration,
            generation: generation,
            wall:
              if(Keyword.get(options, :monotonic_only, false),
                do: "unqualified",
                else: "qualified"
              )
          })

        _ ->
          context
      end

    {context, activation_clock}
  end

  defp durable_trace_run(context, model, steps, id, trace_due) do
    context = Map.put(context, :trace_due, trace_due)

    {context, final_model} =
      Enum.reduce(
        steps,
        {context, model},
        fn raw, {context, model} ->
          event = durable_trace_event(raw, trace_due)
          assert {:ok, before} = Store.revision(context.store)

          context =
            context
            |> Map.put(:refusal, nil)
            |> Map.put(:step, context.step + 1)
            |> durable_trace_call(event)

          model_event = if event == :poll_lost_reply, do: :poll, else: event

          model_input =
            if model_event in [:poll, :activate] and context.clock_input do
              if model.countdown do
                [_, _, sample, _, _] = JSON.decode!(context.clock_input)
                assert Enum.at(sample, 10) == context.countdown.wall

                if context.countdown.wall == "unqualified",
                  do: assert(Enum.slice(sample, 6, 2) == [nil, nil])

                now = durable_trace_monotonic(context.clock_input)
                WotexHome.Schedules.DurableModel.step(model, {:monotonic, now})
              else
                {lower, upper} = durable_trace_interval(context.clock_input)
                WotexHome.Schedules.DurableModel.step(model, {:time, lower, upper})
              end
            else
              model
            end

          expected = WotexHome.Schedules.DurableModel.step(model_input, model_event)
          assert %WotexHome.Schedules.DurableModel{} = expected
          assert {:ok, after_revision} = Store.revision(context.store)
          {projection, snapshot} = durable_trace_projection(context)

          context = %{
            context
            | event_snapshots: [{snapshot, after_revision} | context.event_snapshots]
          }

          assert projection == WotexHome.Schedules.DurableModel.projection(expected),
                 "trace #{id}, step #{context.step}: #{inspect(event)}, refusal: #{inspect(context.refusal)}\nactual: #{inspect(projection)}\nexpected: #{inspect(WotexHome.Schedules.DurableModel.projection(expected))}"

          if event in [:poll, :advance] and
               projection == WotexHome.Schedules.DurableModel.projection(model) do
            assert after_revision == before
          end

          if match?({:fault, _}, event), do: assert(after_revision == before)

          for operation <- Map.keys(context.originals) do
            {:ok, db} = Sqlite3.open(context.path, mode: :readonly)

            try do
              assert durable_trace_original_rows(db, operation) ==
                       context.historical_rows[operation]
            after
              assert :ok = Sqlite3.close(db)
            end
          end

          {context, expected}
        end
      )

    # Capture each committed event's complete SQLite image during the sequence.
    # Validate those exact images afterwards so independent full-history checks
    # do not spend the production report-age window between execution phases.
    # No queued report, source coordinate, deadline or guard is changed.
    for {snapshot, revision} <- Enum.reverse(context.event_snapshots) do
      {:ok, db} = Sqlite3.open(snapshot, mode: :readonly)

      try do
        assert rows(db, "SELECT value FROM meta WHERE key='revision'") == [[revision]]
        assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      after
        assert :ok = Sqlite3.close(db)
      end
    end

    # Repeating an identical authenticated original lookup between queue/claim/
    # handoff also spends that window. Resolve originals after the sequence.
    for {operation, original} <- context.originals do
      result = Store.original_schedule_occurrence(context.store, context.manager, operation)

      if final_model.author_active,
        do: assert({:ok, ^original} = result),
        else: assert({:error, :unauthorized} = result)
    end

    assert {:ok, %{dispatch_enabled: false}} = Store.health(context.store)
    :ok = GenServer.stop(context.store)
  end

  defp durable_trace_event(["time", lower, upper], _due), do: {:time, lower, upper}
  defp durable_trace_event(["monotonic", offset], due), do: {:monotonic, due + offset}
  defp durable_trace_event(["fault", action], _due), do: {:fault, String.to_existing_atom(action)}

  defp durable_trace_event(action, due)
       when action in ["claim", "handoff", "ack", "observed", "cancel"],
       do: {String.to_existing_atom(action), due}

  defp durable_trace_event(action, _due), do: String.to_existing_atom(action)

  defp durable_trace_call(context, {:time, lower, upper}) do
    assert :ok = GenServer.call(context.clock, {:time, lower, upper})

    :sys.replace_state(context.store, fn state ->
      %{state | temporal_clock_owner: context.clock}
    end)

    context
  end

  defp durable_trace_call(context, {:monotonic, now}) do
    state = :sys.get_state(context.store)
    current = max(0, System.monotonic_time(:millisecond) - state.clock_origin)
    # Parametric source coordinates use actual Store elapsed time. Only forward
    # fixture advancement is allowed; no source, report or deadline is changed.
    assert now >= current
    advance_store_clock(context.store, now - current)
    durable_trace_call(context, :clock_restored)
  end

  defp durable_trace_call(context, :clock_lost) do
    assert :ok = GenServer.call(context.clock, {:reset, :clock_loss})
    context
  end

  defp durable_trace_call(context, :clock_restored) do
    assert :ok = GenServer.call(context.clock, {:reset, :none})

    :sys.replace_state(context.store, fn state ->
      %{state | temporal_clock_owner: context.clock}
    end)

    context
  end

  defp durable_trace_call(context, :clock_withdrawn) do
    result = Store.invalidate_temporal_clock(context.store)
    assert result == :ok or match?({:error, _}, result)
    context
  end

  defp durable_trace_call(context, :poll) do
    result = Authority.consider_schedule(Authority.new(store: context.store))

    context = %{context | clock_input: nil}

    context =
      case result do
        {:ok, %{revision: revision} = receipt} ->
          # Blocked/missed considerations have no effect row and report their
          # own revision. Held intent also names its consideration separately.
          revision = Map.get(receipt, :consideration_revision, revision)
          {:ok, db} = Sqlite3.open(context.path, mode: :readonly)

          [[document]] =
            rows(db, "SELECT clock_document FROM schedule_considerations WHERE revision=?", [
              revision
            ])

          assert :ok = Sqlite3.close(db)
          %{context | clock_input: document}

        _ ->
          context
      end

    case result do
      {:ok, %{occurrence_id: operation} = original} when is_binary(operation) ->
        {:ok, db} = Sqlite3.open(context.path, mode: :readonly)

        [[document]] =
          rows(
            db,
            "SELECT occurrence_document FROM schedule_considerations WHERE occurrence_id=?",
            [operation]
          )

        historical_rows = durable_trace_original_rows(db, operation)
        assert :ok = Sqlite3.close(db)
        due = durable_trace_coordinate(document)

        %{
          context
          | originals: Map.put(context.originals, operation, original),
            historical_rows: Map.put(context.historical_rows, operation, historical_rows),
            operations: Map.put(context.operations, due, operation)
        }

      {:ok, _} ->
        context

      {:error, _} ->
        context
    end
  end

  defp durable_trace_call(context, :poll_lost_reply) do
    {:ok, before} = Store.revision(context.store)
    store = context.store

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, %{state: :held}} = Authority.consider_schedule(Authority.new(store: store))
        # The calculating caller exits without delivering its committed receipt.
        :ok
      end)

    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 20_000
    {:ok, db} = Sqlite3.open(context.path, mode: :readonly)

    {operation, clock_document, occurrence_document, historical_rows} =
      try do
        [[operation, clock_document, occurrence_document]] =
          rows(
            db,
            "SELECT occurrence_id,clock_document,occurrence_document FROM schedule_considerations WHERE revision>?",
            [before]
          )

        {operation, clock_document, occurrence_document,
         durable_trace_original_rows(db, operation)}
      after
        assert :ok = Sqlite3.close(db)
      end

    assert {:ok, original} =
             Store.original_schedule_occurrence(context.store, context.manager, operation)

    due = durable_trace_coordinate(occurrence_document)

    %{
      context
      | clock_input: clock_document,
        originals: Map.put(context.originals, operation, original),
        historical_rows: Map.put(context.historical_rows, operation, historical_rows),
        operations: Map.put(context.operations, due, operation)
    }
  end

  defp durable_trace_call(context, :advance) do
    result = Authority.advance_schedule(Authority.new(store: context.store))
    assert match?({:ok, _}, result) or match?({:error, _}, result)
    context
  end

  defp durable_trace_call(context, {:claim, due}) do
    {_, report_age_before} = final_report_age(context.store)

    case Store.claim_queued_power(
           context.store,
           "manager:schedule",
           1,
           context.operations[due],
           "boot:1",
           101
         ) do
      {:ok, _, token} ->
        %{context | tokens: Map.put(context.tokens, due, token)}

      {:error, reason} ->
        {_, report_age_after} = final_report_age(context.store)

        Map.put(context, :refusal, %{
          reason: reason,
          report_age_before_ms: report_age_before,
          report_age_after_ms: report_age_after
        })
    end
  end

  defp durable_trace_call(context, {:handoff, due}) do
    {_, report_age_before} = final_report_age(context.store)

    result =
      Store.handoff_claimed_power(
        context.store,
        "manager:schedule",
        1,
        context.operations[due],
        context.tokens[due],
        101
      )

    case result do
      {:ok, _} ->
        context

      {:error, reason} ->
        {_, report_age_after} = final_report_age(context.store)

        Map.put(context, :refusal, %{
          reason: reason,
          report_age_before_ms: report_age_before,
          report_age_after_ms: report_age_after
        })
    end
  end

  defp durable_trace_call(context, {:ack, due}) do
    assert {:ok, %{disposition: :protocol_accepted}} =
             Store.accept_power_ack(
               context.store,
               "manager:schedule",
               1,
               context.operations[due],
               context.tokens[due]
             )

    context
  end

  defp durable_trace_call(context, {:observed, due}) do
    {:ok, capability} = Thing.capability(context.thing, "power")
    {:ok, report} = power_report(capability, true)
    sequence = context.sequence + 1

    assert {:ok, %{disposition: :observed}} =
             Store.settle_power_readback(
               context.store,
               "manager:schedule",
               1,
               context.operations[due],
               context.tokens[due],
               %{report | source_sequence: sequence}
             )

    %{context | sequence: sequence}
  end

  defp durable_trace_call(context, {:cancel, due}) do
    result = Store.cancel_request(context.store, context.manager, 1, context.operations[due])
    assert match?({:ok, _}, result) or match?({:error, _}, result)
    context
  end

  defp durable_trace_call(context, :qualification_lost) do
    assert :ok = File.rename(context.qualification_file, context.qualification_file <> ".held")
    context
  end

  defp durable_trace_call(context, :grant_lost) do
    result = Store.revoke_target_grant(context.store, "manager:schedule", context.thing.id)
    assert match?({:ok, _}, result) or match?({:error, _}, result)
    context
  end

  defp durable_trace_call(context, :grant_restored) do
    assert {:ok, manager, _revision} =
             Store.grant_target_and_rotate(context.store, "manager:schedule", context.thing.id)

    %{context | manager: manager}
  end

  defp durable_trace_call(context, :author_lost) do
    result = Store.revoke_principal(context.store, "manager:schedule")
    assert match?({:ok, _}, result) or match?({:error, _}, result)
    context
  end

  defp durable_trace_call(context, :override_on) do
    operation = "override:trace:#{context.step}"

    result =
      Store.issue_override_operation_live(
        context.store,
        context.manager,
        1,
        operation,
        context.thing.id,
        0,
        60_000
      )

    assert match?({:ok, _}, result) or match?({:error, _}, result)
    if match?({:ok, _}, result), do: %{context | override_operation: operation}, else: context
  end

  defp durable_trace_call(context, :override_off) do
    assert {:ok, _} =
             Store.revoke_override_operation_live(
               context.store,
               context.manager,
               1,
               context.override_operation
             )

    context
  end

  defp durable_trace_call(context, :maintenance_begin) do
    {:ok, revision} = Store.revision(context.store)

    case Authority.begin_maintenance(
           Authority.new(store: context.store),
           context.maintainer,
           1,
           "maintenance:trace:#{context.step}",
           revision
         ) do
      {:ok, receipt} -> %{context | maintenance_begin: receipt.revision}
      {:error, _} -> context
    end
  end

  defp durable_trace_call(context, :maintenance_end) do
    {:ok, revision} = Store.revision(context.store)

    result =
      Authority.end_maintenance(
        Authority.new(store: context.store),
        context.maintainer,
        1,
        "maintenance:trace:#{context.step}",
        revision,
        context.maintenance_begin
      )

    assert match?({:ok, _}, result) or match?({:error, _}, result)
    context
  end

  defp durable_trace_call(context, event) when event in [:report_matches, :refresh_report] do
    {:ok, capability} = Thing.capability(context.thing, "power")
    {:ok, current, _} = Store.current(context.store, context.thing.id, "power")
    sequence = context.sequence + 1

    {:ok, report} =
      power_report(capability, if(event == :report_matches, do: true, else: current.value.data))

    assert {:ok, _} =
             Store.record(context.store, %{report | source_sequence: sequence}, capability)

    %{context | sequence: sequence}
  end

  defp durable_trace_call(context, event) when event in [:suspend, :activate] do
    {:ok, revision} = Store.revision(context.store)

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "schedule:trace:#{context.step}",
      "expected_revision" => revision
    }

    input =
      if event == :activate,
        do: Map.put(input, "admission_revision", context.activation.admission_revision),
        else: input

    {:ok, document} = WotexHome.Schedules.OperationInput.encode(Atom.to_string(event), input)
    result = Store.change_schedule(context.store, context.manager, document)
    assert match?({:ok, _}, result) or match?({:error, _}, result)

    case {event, result} do
      {:activate, {:ok, %{revision: revision}}} ->
        {:ok, db} = Sqlite3.open(context.path, mode: :readonly)

        [[clock_document]] =
          rows(db, "SELECT clock_document FROM schedule_lifecycle_operations WHERE revision=?", [
            revision
          ])

        assert :ok = Sqlite3.close(db)
        %{context | clock_input: clock_document}

      _ ->
        %{context | clock_input: nil}
    end
  end

  defp durable_trace_call(context, :restart) do
    :ok = GenServer.stop(context.store)
    assert {:ok, store} = Store.start_link([path: context.path] ++ context.keys)
    %{context | store: store}
  end

  defp durable_trace_call(context, {:fault, action}) do
    {table, predicate, event} =
      case action do
        :poll ->
          {"schedule_effect_operations", "1", :poll}

        :advance ->
          {"request_journal", "NEW.disposition='queued'", :advance}

        :claim ->
          {"request_journal", "NEW.disposition='claimed'", {:claim, context.trace_due}}

        :handoff ->
          {"request_journal", "NEW.disposition='dispatching'", {:handoff, context.trace_due}}

        :suspend ->
          {"schedule_lifecycle_operations", "NEW.kind='suspend'", :suspend}

        :clock_withdrawn ->
          {"schedule_lifecycle_operations", "NEW.kind='withdraw'", :clock_withdrawn}

        :grant_lost ->
          {"schedule_lifecycle_operations", "NEW.kind='withdraw'", :grant_lost}

        :author_lost ->
          {"schedule_lifecycle_operations", "NEW.kind='withdraw'", :author_lost}

        :override_on ->
          {"operator_override_operations", "1", :override_on}

        :maintenance_begin ->
          {"host_maintenance_operations", "NEW.action='begin'", :maintenance_begin}

        :maintenance_end ->
          {"host_maintenance_operations", "NEW.action='end'", :maintenance_end}
      end

    {:ok, db} = Sqlite3.open(context.path)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER trace_fault BEFORE INSERT ON #{table} WHEN #{predicate} BEGIN SELECT RAISE(ABORT,'injected_trace_fault'); END"
             )

    try do
      durable_trace_call(context, event)
    after
      assert :ok = Sqlite3.execute(db, "DROP TRIGGER trace_fault")
      assert :ok = Sqlite3.close(db)
    end
  end

  defp durable_trace_projection(context) do
    assert {:ok, %{writable: writable}} = Store.health(context.store)
    {:ok, db} = Sqlite3.open(context.path, mode: :readonly)

    try do
      [[generation]] = rows(db, "SELECT value FROM meta WHERE key='rule_generation'")

      [[target_granted]] =
        rows(db, "SELECT COUNT(*) FROM principal_targets WHERE principal_id=? AND thing_id=?", [
          "manager:schedule",
          context.thing.id
        ])

      [[author_status]] =
        rows(db, "SELECT status FROM principals WHERE principal_id=?", ["manager:schedule"])

      [[kind, activation_epoch, activation_generation]] =
        rows(
          db,
          "SELECT kind,authority_epoch,generation FROM schedule_lifecycle_operations ORDER BY revision DESC LIMIT 1"
        )

      [[epoch, maintenance]] =
        rows(
          db,
          "SELECT (SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='maintenance_revision')"
        )

      state = :sys.get_state(context.store)
      now = max(0, System.monotonic_time(:millisecond) - state.clock_origin)

      [[override]] =
        rows(
          db,
          "SELECT COUNT(*) FROM operator_override_leases l JOIN principals p ON p.principal_id=l.operator_id JOIN enrolled_things t ON t.thing_id=l.target_id JOIN principal_targets g ON g.principal_id=l.operator_id AND g.thing_id=l.target_id WHERE l.target_id=? AND l.authority_epoch=? AND l.boot_epoch=? AND l.start_ms<=? AND l.expires_ms>? AND p.status='active' AND t.status='active' AND t.resource_revision=l.basis_revision",
          [context.thing.id, epoch, state.clock_epoch, now, now]
        )

      [[watermark]] =
        rows(
          db,
          "SELECT COALESCE(w.considered_through,l.initial_watermark) FROM schedule_lifecycle_operations l LEFT JOIN schedule_watermarks w ON w.activation_revision=l.revision WHERE l.kind='activate' ORDER BY l.revision DESC LIMIT 1"
        )

      [[considerations, missed_ranges]] =
        rows(
          db,
          "SELECT COUNT(*),COALESCE(SUM(missed_lower IS NOT NULL),0) FROM schedule_considerations"
        )

      missed =
        rows(
          db,
          "SELECT missed_lower,missed_upper FROM schedule_considerations WHERE missed_lower IS NOT NULL"
        )
        |> Enum.reduce(0, fn [lower, upper], count ->
          case Map.get(context, :calendar_instants) do
            instants when is_list(instants) ->
              count + Enum.count(instants, &(&1 > lower and &1 <= upper))

            nil ->
              first = 100_000 + div(max(0, lower + 1 - 100_000) + 59_999, 60_000) * 60_000
              count + if(first <= upper, do: 1 + div(upper - first, 60_000), else: 0)
          end
        end)

      records =
        rows(
          db,
          "SELECT s.occurrence_document,COALESCE(r.disposition,'blocked'),CASE WHEN r.principal_id IS NULL THEN COALESCE(e.reason,s.reason) ELSE r.reason END,c.reserved_effects,EXISTS(SELECT 1 FROM request_journal j WHERE j.operation_id=s.occurrence_id AND j.disposition='dispatching') FROM schedule_considerations s LEFT JOIN schedule_effect_operations e ON e.consideration_revision=s.revision LEFT JOIN request_receipts r ON r.principal_id=e.principal_id AND r.authority_epoch=e.authority_epoch AND r.operation_id=e.operation_id LEFT JOIN request_causal_roots c ON c.principal_id=e.principal_id AND c.authority_epoch=e.authority_epoch AND c.operation_id=e.operation_id WHERE s.occurrence_document IS NOT NULL"
        )
        |> Map.new(fn [document, phase, reason, spent, handed] ->
          due = durable_trace_coordinate(document)

          {due,
           %{
             phase: String.to_existing_atom(phase),
             reason: reason,
             spent: spent,
             handed: handed == 1
           }}
        end)

      snapshot = Path.join(Path.dirname(context.path), "trace-event-#{context.step}.sqlite")
      assert not File.exists?(snapshot)
      assert rows(db, "VACUUM INTO ?", [snapshot]) == []
      assert :ok = File.chmod(snapshot, 0o600)
      assert %{type: :regular, size: size} = File.lstat!(snapshot)
      assert size in 1..33_554_432

      projection = %{
        active:
          kind == "activate" and activation_epoch == epoch and activation_generation == generation,
        target_granted: target_granted == 1,
        author_active: author_status == "active",
        override: override == 1,
        maintenance: maintenance > 0,
        writable: writable,
        generation: generation,
        watermark: watermark,
        considerations: considerations,
        missed: missed,
        missed_ranges: missed_ranges,
        records: records
      }

      projection =
        if Map.has_key?(context, :countdown) do
          reasons =
            rows(
              db,
              "SELECT reason FROM schedule_lifecycle_operations WHERE reason LIKE 'countdown_missed:%'"
            )

          assert length(reasons) <= 1

          Map.merge(projection, %{
            clock_generation: state.temporal_clock_generation,
            expiry_reason: if(reasons == [], do: nil, else: hd(hd(reasons)))
          })
        else
          projection
        end

      {projection, snapshot}
    after
      assert :ok = Sqlite3.close(db)
    end
  end

  defp durable_trace_original_rows(db, operation) do
    {
      rows(db, "SELECT * FROM schedule_considerations WHERE occurrence_id=?", [operation]),
      rows(db, "SELECT * FROM schedule_effect_operations WHERE operation_id=?", [operation])
    }
  end

  defp durable_trace_coordinate(document) do
    [_, _, _, _, _, _, coordinate] = JSON.decode!(document)

    case coordinate do
      ["utc", due] -> due
      ["countdown", _boot, _generation, due] -> due
    end
  end

  defp durable_trace_monotonic(document) do
    [format, _scope, _sample, now, _watermark] = JSON.decode!(document)

    assert format in [
             "wotex-home.schedule-activation-clock.v1",
             "wotex-home.schedule-activation-monotonic-clock.v1"
           ]

    now
  end

  # Read only clock inputs from the published wire record. Compute elapsed
  # time and integer drift independently; never read its watermark prediction.
  defp durable_trace_interval(document) do
    ["wotex-home.schedule-activation-clock.v1", _scope, sample, now, _watermark] =
      JSON.decode!(document)

    [
      "wotex-home.schedule-clock.v1",
      _source,
      _qualification,
      _boot,
      _generation,
      sampled,
      lower,
      upper,
      _age,
      drift,
      "qualified",
      true
    ] = sample

    elapsed = now - sampled
    assert elapsed >= 0
    error = div(elapsed * drift + 999_999, 1_000_000)
    {lower + elapsed - error, upper + elapsed + error}
  end

  defp prepare_pending_loss(_store, :qualification_loss, file) do
    assert :ok = File.rename(file, file <> ".held")
  end

  defp prepare_pending_loss(store, :report_age, _file) do
    {_reported, age} = final_report_age(store)
    Process.sleep(max(0, 5_001 - age))
  end

  defp prepare_admission_value(store, thing, phase)
       when phase in [:no_send, :admit_no_send, :advance_no_send] do
    {:ok, capability} = Thing.capability(thing, "power")
    {:ok, observation} = power_report(capability, true)
    assert {:ok, _} = Store.record(store, %{observation | source_sequence: 3}, capability)
  end

  defp prepare_admission_value(_, _, _), do: :ok

  defp final_admission_call(store, manager, operation, phase)
       when phase in [:queue, :admit_no_send],
       do: Store.admit_held_power(store, manager, 1, operation, "boot:1", 101)

  defp final_admission_call(store, manager, operation, :no_send),
    do: Store.settle_held_power_noop(store, manager, 1, operation, "boot:1", 101)

  defp final_admission_call(store, _, _, phase) when phase in [:advance_queue, :advance_no_send],
    do: Store.advance_schedule(store)

  defp assert_final_admission_result(result, phase, reason) when phase in [:queue, :no_send] do
    assert {:error, ^reason} = result
  end

  defp assert_final_admission_result(result, _, reason) do
    message = "schedule_blocked:" <> Atom.to_string(reason)

    assert {:ok, %{receipts: [%{disposition: :rejected, reason: ^message}], has_more: false}} =
             result
  end

  defp assert_no_tentative_admission(path) do
    {:ok, db} = Sqlite3.open(path)

    assert [[0, 0, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_execution),(SELECT COUNT(*) FROM request_journal WHERE disposition='queued' OR reason='already_reported_no_send') FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
  end

  defp final_report_age(store) do
    temporal_sql_fixture(store, fn state ->
      [[reported]] = rows(state.db, "SELECT received_store_monotonic_ms FROM observation_current")
      now = max(0, System.monotonic_time(:millisecond) - state.clock_origin)
      {reported, now - reported}
    end)
  end

  defp final_phase_token(_store, :claim, _operation), do: nil

  defp final_phase_token(store, :handoff, operation) do
    assert {:ok, %{disposition: :claimed}, token} =
             Store.claim_queued_power(store, "manager:schedule", 1, operation, "boot:1", 101)

    token
  end

  defp final_phase_call(store, :claim, operation, _token),
    do: Store.claim_queued_power(store, "manager:schedule", 1, operation, "boot:1", 101)

  defp final_phase_call(store, :handoff, operation, token),
    do: Store.handoff_claimed_power(store, "manager:schedule", 1, operation, token, 101)

  defp temporal_prepare_transition(_store, _manager, _operation, :claim, _snapshot), do: :claim

  defp temporal_prepare_transition(store, manager, operation, :handoff, snapshot) do
    assert {:ok, {_, claim}} =
             temporal_effect_fixture(store, manager, operation, :claim, snapshot, 100_001, 0)

    {:handoff, claim.token}
  end

  defp temporal_advance_fixture(store, snapshot) do
    temporal_sql_fixture(store, fn state ->
      WotexHome.Durable.Store.SQL.transaction(
        state.db,
        &WotexHome.Durable.Store.ScheduleEffects.advance(
          &1,
          temporal_context(snapshot),
          Map.take(state, [
            :qualification_claim_root,
            :qualification_case_keys,
            :qualification_decision_keys
          ])
        )
      )
    end)
  end

  defp refresh_temporal_report(store, thing, sequence) do
    {:ok, capability} = Thing.capability(thing, "power")
    {:ok, observation} = power_report(capability, false)
    assert {:ok, _} = Store.record(store, %{observation | source_sequence: sequence}, capability)
  end

  @tag scheduled_original: true
  test "selected temporal original queues beyond the batch limit without advancing older occurrences",
       %{path: path} do
    {store, manager, thing, _owner, activation} = temporal_fixture(path, 90_000)

    originals =
      for index <- 0..16 do
        {:ok, original, snapshot} =
          temporal_consider_fixture(store, activation, 100_001 + index * 60_000)

        {original, snapshot}
      end

    {selected, snapshot} = List.last(originals)
    clock = final_admission_clock(store, snapshot)
    assert :ok = GenServer.call(clock, {:time, 1_060_001, 1_060_001})
    refresh_temporal_report(store, thing, 3)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    immutable = rows(db, "SELECT * FROM schedule_considerations ORDER BY revision")
    Sqlite3.close(db)

    assert {:ok, %{disposition: :queued, operation_id: operation} = queued} =
             Store.advance_scheduled_power(store, "manager:schedule", 1, selected.occurrence_id)

    assert operation == selected.occurrence_id
    assert {:ok, ^queued} = Store.advance_scheduled_power(store, "manager:schedule", 1, operation)
    assert {:ok, queued.revision} == Store.revision(store)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert immutable == rows(db, "SELECT * FROM schedule_considerations ORDER BY revision")

    assert [[16, 1, 1]] =
             rows(
               db,
               "SELECT SUM(disposition='held'),SUM(disposition='queued'),(SELECT SUM(reserved_effects) FROM request_causal_roots WHERE origin='schedule_occurrence') FROM request_receipts WHERE operation_id IN (SELECT operation_id FROM request_causal_roots WHERE origin='schedule_occurrence')"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)

    for {original, _} <- originals do
      assert {:ok, ^original} =
               Store.original_schedule_occurrence(store, manager, original.occurrence_id)
    end

    :ok = GenServer.stop(store)
  end

  @tag scheduled_original: true
  test "selected temporal advancement rejects substituted or malformed identity without mutation",
       %{path: path} do
    {store, _manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    assert {:ok, before} = Store.revision(store)

    for {principal, epoch, requested, reason} <- [
          {"controller:1", 1, "op:attempt", :not_scheduled_request},
          {"manager:other", 1, operation, :not_found},
          {"manager:schedule", 2, operation, :not_found},
          {"manager:schedule", 1, "missing:operation", :not_found},
          {nil, 1, operation, :invalid_guard_input},
          {"manager:schedule", 0, operation, :invalid_guard_input},
          {"manager:schedule", 1, nil, :invalid_guard_input}
        ] do
      assert {:error, ^reason} =
               Store.advance_scheduled_power(store, principal, epoch, requested)
    end

    assert {:ok, ^before} = Store.revision(store)
    assert {:ok, %{writable: true}} = Store.health(store)
    assert_no_tentative_admission(path)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_original: true
  test "selected matching power closes without qualification or causal spend and preserves retry",
       %{path: path} do
    {store, manager, thing, operation, _clock} = scheduled_capture_fixture(path)
    prepare_admission_value(store, thing, :advance_no_send)
    file = final_qualification_file(path)
    assert :ok = File.rename(file, file <> ".held")
    assert {:ok, original} = Store.original_schedule_occurrence(store, manager, operation)

    assert {:ok, %{reason: "already_reported_no_send"} = receipt} =
             Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

    assert {:ok, ^receipt} =
             Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

    assert {:ok, receipt.revision} == Store.revision(store)
    assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[0, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_execution) FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  for phase <- [:claimed, :dispatching] do
    @tag scheduled_original: true
    test "selected advancement returns actual #{phase} work without recall or a second admission",
         %{path: path} do
      {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)

      assert {:ok, %{disposition: :queued}} =
               Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

      token = final_phase_token(store, :handoff, operation)

      if unquote(phase == :dispatching),
        do: assert({:ok, _} = final_phase_call(store, :handoff, operation, token))

      assert {:ok, retained} = Store.request_status(store, manager, 1, operation)
      assert retained.disposition == unquote(phase)
      assert {:ok, before} = Store.revision(store)

      assert {:ok, ^retained} =
               Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

      assert {:ok, ^before} = Store.revision(store)
      assert map_size(:sys.get_state(store).claim_owners) == 1
      {:ok, db} = Sqlite3.open(path, mode: :readonly)

      assert [[1, 1]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='queued') FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  @tag scheduled_original: true
  test "selected advancement returns cancelled original unchanged without consuming it again",
       %{path: path} do
    {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    assert {:ok, cancelled} = Store.cancel_request(store, manager, 1, operation)
    assert {:ok, before} = Store.revision(store)

    assert {:ok, ^cancelled} =
             Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

    assert {:ok, ^before} = Store.revision(store)
    assert_no_tentative_admission(path)
    :ok = GenServer.stop(store)
  end

  for loss <- [:expiry, :qualification_loss] do
    @tag scheduled_original: true
    test "selected advancement restores tentative queue on final #{loss}", %{path: path} do
      {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
      {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)

      options =
        if unquote(loss == :qualification_loss),
          do: [qualification_file: final_qualification_file(path)],
          else: []

      clock = final_admission_clock(store, snapshot, options)
      assert :ok = GenServer.call(clock, {:reset, unquote(loss)})
      assert {:ok, before} = Store.revision(store)

      assert {:ok, %{disposition: :rejected}} =
               Store.advance_scheduled_power(store, "manager:schedule", 1, original.occurrence_id)

      assert {:ok, after_revision} = Store.revision(store)
      assert after_revision == before + 1
      assert_no_tentative_admission(path)

      assert {:ok, ^original} =
               Store.original_schedule_occurrence(store, manager, original.occurrence_id)

      :ok = GenServer.stop(store)
    end
  end

  for {loss, sql} <- [
        {:principal,
         "UPDATE principals SET status='revoked' WHERE principal_id='manager:schedule'"},
        {:grant, "DELETE FROM principal_targets WHERE principal_id='manager:schedule'"}
      ],
      phase <- [:queue, :no_send],
      sql_fault <- [false, true] do
    @tag scheduled_original: true
    test "selected advancement preserves final #{loss} withdrawal after restoring tentative #{phase}#{if sql_fault, do: " or rolls back failed replay", else: ""}",
         %{path: path} do
      {store, manager, thing, operation, _clock} = scheduled_capture_fixture(path)
      if unquote(phase == :no_send), do: prepare_admission_value(store, thing, :advance_no_send)
      assert {:ok, original} = Store.original_schedule_occurrence(store, manager, operation)
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER selected_author_loss AFTER INSERT ON request_journal WHEN #{unquote(if phase == :queue, do: "NEW.disposition='queued'", else: "NEW.reason='already_reported_no_send'")} BEGIN #{unquote(sql)}; END"
               )

      if unquote(sql_fault) do
        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER selected_replay_fault BEFORE INSERT ON schedule_lifecycle_operations WHEN NEW.kind='withdraw' AND #{unquote(if phase == :queue, do: "(SELECT SUM(reserved_effects) FROM request_causal_roots WHERE origin='schedule_occurrence')=0", else: "EXISTS(SELECT 1 FROM request_receipts WHERE reason='rule_generation_fenced')")} BEGIN SELECT RAISE(ABORT,'injected_selected_replay_fault'); END"
                 )
      end

      result = Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER selected_author_loss")

      if unquote(sql_fault) do
        assert {:error, :store_unavailable} = result
        assert {:ok, ^before} = Store.revision(store)
        assert {:ok, %{disposition: :held}} = Store.request_status(store, manager, 1, operation)
        assert {:ok, %{writable: false}} = Store.health(store)

        assert [[0]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )

        assert :ok = Sqlite3.execute(db, "DROP TRIGGER selected_replay_fault")
      else
        assert {:ok, %{disposition: :rejected} = rejected} = result

        assert {:ok, ^rejected} =
                 Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

        assert [[1]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='withdraw'"
                 )
      end

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      Sqlite3.close(db)
      assert_no_tentative_admission(path)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      :ok = GenServer.stop(store)
    end
  end

  for table <- ["request_execution", "request_journal"] do
    @tag scheduled_original: true
    test "selected #{table} publication failure rolls back all admission and disables the writer",
         %{path: path} do
      {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER selected_queue_fault BEFORE INSERT ON #{unquote(table)} BEGIN SELECT RAISE(ABORT,'injected_selected_queue_fault'); END"
               )

      assert {:error, :store_unavailable} =
               Store.advance_scheduled_power(store, "manager:schedule", 1, operation)

      assert {:ok, ^before} = Store.revision(store)
      assert {:ok, %{disposition: :held}} = Store.request_status(store, manager, 1, operation)
      assert {:ok, %{writable: false}} = Store.health(store)
      assert :ok = Sqlite3.execute(db, "DROP TRIGGER selected_queue_fault")
      Sqlite3.close(db)
      assert_no_tentative_admission(path)
      :ok = GenServer.stop(store)
    end
  end

  @tag scheduled_original: true
  test "selected final refusal publication failure restores original held receipt and causal budget",
       %{path: path} do
    {store, manager, _thing, _owner, activation} = temporal_fixture(path, 90_000)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    clock = final_admission_clock(store, snapshot)
    assert :ok = GenServer.call(clock, {:reset, :expiry})
    assert {:ok, before} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER selected_refusal_fault BEFORE INSERT ON request_journal WHEN NEW.disposition='rejected' BEGIN SELECT RAISE(ABORT,'injected_selected_refusal_fault'); END"
             )

    assert {:error, :store_unavailable} =
             Store.advance_scheduled_power(store, "manager:schedule", 1, original.occurrence_id)

    assert {:ok, ^before} = Store.revision(store)

    assert {:ok, %{disposition: :held}} =
             Store.request_status(store, manager, 1, original.occurrence_id)

    assert {:ok, %{writable: false}} = Store.health(store)
    assert :ok = Sqlite3.execute(db, "DROP TRIGGER selected_refusal_fault")
    Sqlite3.close(db)
    assert_no_tentative_admission(path)

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(store, manager, original.occurrence_id)

    :ok = GenServer.stop(store)
  end

  @tag scheduled_capture: true
  test "scheduled report scope derives its original author and rejects explicit or substituted scope",
       %{path: path} do
    {store, _manager, thing, operation, _clock} = scheduled_capture_fixture(path)

    assert {:ok, basis} =
             Store.scheduled_power_refresh_basis(store, "manager:schedule", 1, operation)

    assert {:error, :not_explicit_request} =
             Store.explicit_power_refresh_basis(store, "manager:schedule", 1, operation)

    assert {:error, :not_scheduled_request} =
             Store.scheduled_power_refresh_basis(store, "controller:1", 1, "op:attempt")

    assert {:error, :not_found} =
             Store.scheduled_power_refresh_basis(store, "manager:other", 1, operation)

    assert {:error, :invalid_guard_input} =
             Store.scheduled_power_refresh_basis(store, nil, 1, operation)

    assert {:ok, before} = Store.revision(store)
    {:ok, report} = power_report(thing.capabilities["power"], false)

    fresh = %{
      report
      | source_epoch: "capture:temporal",
        source_sequence: 0,
        boot_epoch: "capture:temporal"
    }

    assert {:error, :stale_refresh_basis} =
             Store.commit_scheduled_power_refresh(
               store,
               %{basis | binding_revision: basis.binding_revision + 1},
               [fresh]
             )

    assert {:ok, ^before} = Store.revision(store)
    assert {:ok, [revision]} = Store.commit_scheduled_power_refresh(store, basis, [fresh])
    assert revision == before + 1
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    state = :sys.get_state(store)

    assert [["capture:temporal", stored_boot, now]] =
             rows(
               db,
               "SELECT source_epoch,received_store_boot_epoch,received_store_monotonic_ms FROM observation_current"
             )

    assert stored_boot == state.clock_epoch
    assert is_integer(now) and now >= 0

    assert [[0]] =
             rows(
               db,
               "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  for {loss, reason} <- [
        {:expiry, :occurrence_expired},
        {:clock_loss, :temporal_clock_unavailable},
        {:uncertain, :clock_uncertain}
      ] do
    @tag scheduled_capture: true
    test "scheduled report publication repeats #{loss} at the enclosing commit boundary", %{
      path: path
    } do
      {store, _manager, thing, operation, clock} = scheduled_capture_fixture(path)

      assert {:ok, basis} =
               Store.scheduled_power_refresh_basis(store, "manager:schedule", 1, operation)

      assert {:ok, before} = Store.revision(store)
      assert :ok = GenServer.call(clock, {:reset, unquote(loss)})
      {:ok, report} = power_report(thing.capabilities["power"], false)

      assert {:error, unquote(reason)} =
               Store.commit_scheduled_power_refresh(store, basis, [
                 %{report | source_epoch: "capture:rolled-back", source_sequence: 0}
               ])

      assert {:ok, ^before} = Store.revision(store)
      assert GenServer.call(clock, :count) >= 2
      {:ok, db} = Sqlite3.open(path, mode: :readonly)
      refute [["capture:rolled-back"]] == rows(db, "SELECT source_epoch FROM observation_current")

      assert [[0]] =
               rows(
                 db,
                 "SELECT COUNT(*) FROM source_epoch_grants WHERE new_epoch='capture:rolled-back'"
               )

      assert [[0]] =
               rows(
                 db,
                 "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      assert {:ok, %{writable: true}} = Store.health(store)
      :ok = GenServer.stop(store)
    end
  end

  for {label, sql, reason} <- [
        {:principal,
         "UPDATE principals SET status='revoked' WHERE principal_id='manager:schedule'",
         :principal_unavailable},
        {:grant, "DELETE FROM principal_targets WHERE principal_id='manager:schedule'",
         :request_not_held}
      ] do
    @tag scheduled_capture: true
    test "scheduled report publication rolls back final #{label} withdrawal", %{path: path} do
      {store, _manager, thing, operation, _clock} = scheduled_capture_fixture(path)

      assert {:ok, basis} =
               Store.scheduled_power_refresh_basis(store, "manager:schedule", 1, operation)

      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER scheduled_capture_loss AFTER INSERT ON journal WHEN NEW.thing_id='light:desk' BEGIN #{unquote(sql)}; END"
               )

      {:ok, report} = power_report(thing.capabilities["power"], false)

      assert {:error, unquote(reason)} =
               Store.commit_scheduled_power_refresh(store, basis, [%{report | source_sequence: 3}])

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER scheduled_capture_loss")
      assert {:ok, ^before} = Store.revision(store)
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  @tag scheduled_capture: true
  test "queued scheduled delivery keeps its sealed baseline and cannot use held refresh", %{
    path: path
  } do
    {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)

    assert {:ok, %{disposition: :queued} = receipt} =
             Store.admit_held_power(store, manager, 1, operation, "boot:1", 101)

    assert {:error, :request_not_held} =
             Store.scheduled_power_refresh_basis(store, "manager:schedule", 1, operation)

    assert {:ok, %{receipt: ^receipt}} =
             Store.scheduled_power_delivery_basis(store, "manager:schedule", 1, operation)

    assert {:ok, %{requests: [%{operation_id: ^operation}]}} =
             Authority.pending_scheduled_power(Authority.new(store: store))

    assert {:ok, %{disposition: :claimed}, _} =
             Store.claim_queued_power(store, "manager:schedule", 1, operation, "boot:1", 101)

    assert {:ok, %{requests: []}} = Store.pending_scheduled_power(store)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_capture: true
  test "scheduled report SQL failure rolls back the full fact transaction and disables writes", %{
    path: path
  } do
    {store, _manager, thing, operation, _clock} = scheduled_capture_fixture(path)

    assert {:ok, basis} =
             Store.scheduled_power_refresh_basis(store, "manager:schedule", 1, operation)

    assert {:ok, before} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER scheduled_capture_fault AFTER UPDATE ON observation_current BEGIN SELECT RAISE(ABORT,'injected scheduled report fault'); END"
             )

    {:ok, report} = power_report(thing.capabilities["power"], false)

    assert {:error, :store_unavailable} =
             Store.commit_scheduled_power_refresh(store, basis, [
               %{report | source_epoch: "capture:aborted", source_sequence: 0}
             ])

    assert :ok = Sqlite3.execute(db, "DROP TRIGGER scheduled_capture_fault")
    assert {:ok, ^before} = Store.revision(store)
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    assert {:ok, %{writable: false}} = Store.health(store)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_capture: true
  test "scheduled selection rejects damaged creation provenance and fails the writer closed", %{
    path: path
  } do
    {store, _manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    assert {:ok, before} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "UPDATE request_causal_roots SET created_revision=created_revision+1 WHERE origin='schedule_occurrence'"
             )

    assert {:error, :store_unavailable} = Store.pending_scheduled_power(store)
    assert {:ok, ^before} = Store.revision(store)
    assert {:ok, %{writable: false}} = Store.health(store)

    assert {:error, :store_unavailable} =
             Store.scheduled_power_refresh_basis(store, "manager:schedule", 1, operation)

    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  for {readback, ack, disposition} <- [
        {:matching, true, :observed},
        {:matching, false, :observed},
        {:contradicted, true, :contradicted},
        {:missing, true, :outcome_unknown}
      ] do
    @tag scheduled_delivery: true
    test "scheduled private delivery settles #{readback}/#{ack} through original temporal guards",
         %{path: path} do
      {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
      assert {:ok, original} = Store.original_schedule_occurrence(store, manager, operation)

      {authority, opts, _capture} =
        delivery_fixture(store, readback: unquote(readback), ack: unquote(ack))

      assert {:ok, %{disposition: unquote(disposition)} = settled} =
               Authority.deliver_scheduled_power(
                 authority,
                 "manager:schedule",
                 1,
                 operation,
                 opts
               )

      assert {:ok, ^settled} = Store.request_status(store, manager, 1, operation)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      for type <- [2, 101, 117, 116], do: assert_receive({:delivery_packet, ^type})
      assert_receive :delivery_transport_closed
      assert {:ok, %{requests: []}} = Store.pending_scheduled_power(store)
      {:ok, db} = Sqlite3.open(path, mode: :readonly)

      assert [[1, 1]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  @tag scheduled_delivery: true
  test "scheduled matching report closes without a power transport or causal spend", %{path: path} do
    {store, _manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store, level: 65_535)

    assert {:ok, %{disposition: :rejected, reason: "already_reported_no_send"}} =
             Authority.deliver_scheduled_power(authority, "manager:schedule", 1, operation, opts)

    refute_receive :delivery_transport_opened, 20
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[0]] =
             rows(
               db,
               "SELECT reserved_effects FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_delivery: true
  test "scheduled qualification refusal terminalizes its original without opening a power transport",
       %{path: path} do
    {store, _manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store)
    file = final_qualification_file(path)
    :ok = File.rename(file, file <> ".held")

    try do
      assert {:ok,
              %{
                disposition: :rejected,
                reason: "schedule_blocked:qualification_artifact_unavailable"
              }} =
               Authority.deliver_scheduled_power(
                 authority,
                 "manager:schedule",
                 1,
                 operation,
                 opts
               )

      refute_receive :delivery_transport_opened, 20
      assert {:ok, %{requests: []}} = Store.pending_scheduled_power(store)
    after
      :ok = File.rename(file <> ".held", file)
      :ok = GenServer.stop(store)
    end
  end

  @tag scheduled_delivery: true
  test "scheduled window expiry after queue prevents claim and every SetLightPower", %{path: path} do
    {store, manager, _thing, operation, clock} = scheduled_capture_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store)
    factory = Keyword.fetch!(opts, :transport_factory)

    opts =
      Keyword.put(opts, :transport_factory, fn ->
        :ok = GenServer.call(clock, {:time, 110_000, 110_000})
        factory.()
      end)

    assert {:error, :occurrence_expired} =
             Authority.deliver_scheduled_power(authority, "manager:schedule", 1, operation, opts)

    refute_receive {:delivery_packet, 117}, 20
    assert_receive :delivery_transport_closed
    assert {:ok, %{disposition: :queued}} = Store.request_status(store, manager, 1, operation)

    assert {:ok, %{receipts: [%{reason: "schedule_blocked:occurrence_expired"}]}} =
             Authority.advance_schedule(authority)

    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[1, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_delivery: true
  test "queued scheduled recovery resolves routing and leaves its sealed report unchanged", %{
    path: path
  } do
    {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    {authority, opts, capture} = delivery_fixture(store)

    assert {:ok, basis} =
             Store.scheduled_power_refresh_basis(store, "manager:schedule", 1, operation)

    assert {:ok, route} =
             WotexHome.Lifx.CaptureSession.power_route_auto(
               capture,
               basis.stable_id,
               basis.thing,
               :held
             )

    assert {:ok, [_]} = Store.commit_scheduled_power_refresh(store, basis, route.reports)
    assert_receive {:delivery_packet, 2}
    assert_receive {:delivery_packet, 101}
    assert {:ok, %{receipts: [%{disposition: :queued}]}} = Store.advance_schedule(store)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    [[baseline]] = rows(db, "SELECT baseline_revision FROM request_execution")
    :ok = Sqlite3.close(db)

    assert {:ok, %{disposition: :observed}} =
             Authority.deliver_scheduled_power(authority, "manager:schedule", 1, operation, opts)

    assert_receive {:delivery_packet, 2}
    assert_receive {:delivery_packet, 117}
    assert_receive {:delivery_packet, 116}
    refute_receive {:delivery_packet, 101}, 20
    assert {:ok, %{disposition: :observed}} = Store.request_status(store, manager, 1, operation)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[^baseline]] = rows(db, "SELECT baseline_revision FROM request_execution")
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_delivery: true
  test "queued scheduled recovery refuses a changed report producer before opening a power transport",
       %{path: path} do
    {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    assert {:ok, %{receipts: [%{disposition: :queued} = queued]}} = Store.advance_schedule(store)
    assert {:ok, before} = Store.revision(store)
    {authority, opts, _capture} = delivery_fixture(store)

    assert {:error, :observation_unavailable} =
             Authority.deliver_scheduled_power(authority, "manager:schedule", 1, operation, opts)

    assert_receive {:delivery_packet, 2}
    refute_receive :delivery_transport_opened, 20
    refute_receive {:delivery_packet, 117}, 20
    assert {:ok, ^before} = Store.revision(store)
    assert {:ok, ^queued} = Store.request_status(store, manager, 1, operation)
    :ok = GenServer.stop(store)
  end

  for phase <- [:held, :queued],
      {reason, retained_reason} <- [
        {:observation_unavailable, "schedule_blocked:observation_unavailable"},
        {:capture_owner_down, "schedule_blocked:delivery_unavailable"}
      ] do
    @tag scheduled_refusal: true
    test "delivery refusal closes #{phase} on #{reason} once without refunding its original",
         %{path: path} do
      {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
      assert {:ok, original} = Store.original_schedule_occurrence(store, manager, operation)

      if unquote(phase == :queued) do
        assert {:ok, %{receipts: [%{disposition: :queued}]}} = Store.advance_schedule(store)
      end

      assert {:ok, %{disposition: :rejected, reason: unquote(retained_reason)} = rejected} =
               Authority.block_scheduled_power(
                 Authority.new(store: store),
                 "manager:schedule",
                 1,
                 operation,
                 unquote(reason)
               )

      assert {:ok, revision} = Store.revision(store)

      assert {:ok, ^rejected} =
               Store.block_scheduled_power(
                 store,
                 "manager:schedule",
                 1,
                 operation,
                 :clock_uncertain
               )

      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, ^rejected} = Store.request_status(store, manager, 1, operation)
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
      assert {:ok, %{requests: []}} = Store.pending_scheduled_power(store)
      {:ok, db} = Sqlite3.open(path, mode: :readonly)
      spent = unquote(if phase == :queued, do: 1, else: 0)

      assert [[^spent, 0, 0]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_execution WHERE operation_id=?),(SELECT COUNT(*) FROM request_journal WHERE operation_id=? AND disposition='dispatching') FROM request_causal_roots WHERE operation_id=?",
                 [operation, operation, operation]
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  for phase <- [:claimed, :dispatching] do
    @tag scheduled_refusal: true
    test "delivery refusal cannot recall #{phase} work owned by a live claimant", %{path: path} do
      {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
      assert {:ok, %{receipts: [%{disposition: :queued}]}} = Store.advance_schedule(store)
      token = final_phase_token(store, :handoff, operation)

      if unquote(phase == :dispatching) do
        assert {:ok, %{disposition: :dispatching}} =
                 final_phase_call(store, :handoff, operation, token)
      end

      assert {:ok, revision} = Store.revision(store)
      assert {:ok, receipt} = Store.request_status(store, manager, 1, operation)

      assert {:error, :request_not_unsent} =
               Store.block_scheduled_power(
                 store,
                 "manager:schedule",
                 1,
                 operation,
                 :delivery_unavailable
               )

      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, ^receipt} = Store.request_status(store, manager, 1, operation)
      assert map_size(:sys.get_state(store).claim_owners) == 1
      {:ok, db} = Sqlite3.open(path, mode: :readonly)
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  @tag scheduled_refusal: true
  test "delivery refusal rejects substituted roots and malformed identities without mutation", %{
    path: path
  } do
    {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    assert {:ok, revision} = Store.revision(store)

    assert {:error, :not_scheduled_request} =
             Store.block_scheduled_power(
               store,
               "controller:1",
               1,
               "op:attempt",
               :delivery_unavailable
             )

    assert {:error, :not_found} =
             Store.block_scheduled_power(
               store,
               "manager:schedule",
               1,
               "missing:operation",
               :delivery_unavailable
             )

    assert {:error, :invalid_guard_input} =
             Store.block_scheduled_power(
               store,
               "manager:schedule",
               -1,
               operation,
               :delivery_unavailable
             )

    assert {:error, :invalid_guard_input} =
             Store.block_scheduled_power(
               store,
               "manager:schedule",
               1,
               operation,
               "untrusted reason"
             )

    assert {:ok, ^revision} = Store.revision(store)
    assert {:ok, %{disposition: :held}} = Store.request_status(store, manager, 1, operation)
    assert {:ok, %{writable: true}} = Store.health(store)
    :ok = GenServer.stop(store)
  end

  for phase <- [:held, :queued] do
    @tag scheduled_refusal: true
    test "delivery refusal journal failure restores #{phase} work and fails the writer closed", %{
      path: path
    } do
      {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)

      if unquote(phase == :queued) do
        assert {:ok, %{receipts: [%{disposition: :queued}]}} = Store.advance_schedule(store)
      end

      assert {:ok, receipt} = Store.request_status(store, manager, 1, operation)
      assert {:ok, revision} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER delivery_closure_fault BEFORE INSERT ON request_journal WHEN NEW.disposition='rejected' AND NEW.reason LIKE 'schedule_blocked:%' BEGIN SELECT RAISE(ABORT,'injected delivery closure fault'); END"
               )

      assert {:error, :store_unavailable} =
               Store.block_scheduled_power(
                 store,
                 "manager:schedule",
                 1,
                 operation,
                 :observation_unavailable
               )

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER delivery_closure_fault")
      assert {:ok, ^revision} = Store.revision(store)
      assert {:ok, ^receipt} = Store.request_status(store, manager, 1, operation)
      assert {:ok, %{writable: false}} = Store.health(store)
      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  for {readback, outcome} <- [{:matching, :observed}, {:missing, :outcome_unknown}] do
    @tag scheduled_owner: true
    test "temporal owner consumes due work without a client and never repeats #{outcome}", %{
      path: path
    } do
      {store, manager, _thing, _clock, _activation} = temporal_fixture(path, 90_000)
      assert {:ok, snapshot} = Store.temporal_clock_snapshot(store)
      clock = final_admission_clock(store, snapshot)
      assert :ok = GenServer.call(clock, {:time, 100_001, 100_001})

      {authority, opts, _capture} =
        delivery_fixture(store, pause: 101, readback: unquote(readback))

      owner =
        start_supervised!(
          {WotexHome.Schedules.Delivery, authority: authority, delivery_opts: opts}
        )

      assert_receive {:delivery_paused, capture_worker}, 5_000
      {:ok, db} = Sqlite3.open(path, mode: :readonly)

      [[operation]] =
        rows(
          db,
          "SELECT operation_id FROM request_causal_roots WHERE origin='schedule_occurrence'"
        )

      assert {:ok, original} = Store.original_schedule_occurrence(store, manager, operation)
      assert {:ok, %{disposition: :held}} = Store.request_status(store, manager, 1, operation)
      send(capture_worker, :delivery_continue)

      assert_eventually(fn ->
        match?(
          {:ok, %{disposition: unquote(outcome)}},
          Store.request_status(store, manager, 1, operation)
        )
      end)

      assert_receive {:delivery_packet, 117}
      assert_receive {:delivery_packet, 116}
      assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)

      assert [[1, 1, 1]] =
               rows(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching'),(SELECT COUNT(*) FROM schedule_considerations) FROM request_causal_roots WHERE origin='schedule_occurrence'"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)

      assert :sys.get_state(store).schedule_poll == nil

      assert Map.keys(:sys.get_state(owner)) |> Enum.sort() ==
               Enum.sort([
                 :authority,
                 :interval,
                 :delivery,
                 :cursor,
                 :cycle_end,
                 :last_poll,
                 :last_result
               ])

      assert :ok = stop_supervised(WotexHome.Schedules.Delivery)
      start_supervised!({WotexHome.Schedules.Delivery, authority: authority, delivery_opts: opts})
      refute_receive {:delivery_packet, 117}, 300
      assert {:ok, %{requests: []}} = Store.pending_scheduled_power(store)
      assert :ok = Sqlite3.close(db)
      :ok = GenServer.stop(store)
    end
  end

  @tag scheduled_owner: true
  test "temporal owner closes a failed capture once instead of retrying the original", %{
    path: path
  } do
    {store, manager, _thing, operation, _clock} = scheduled_capture_fixture(path)
    pool = start_supervised!(Task.Supervisor)
    observer = self()

    authority =
      Authority.new(store: store, capture: nil, power_supervisor: pool, power_dispatch: true)

    factory = fn ->
      send(observer, :unexpected_power_transport)
      {:error, :offline}
    end

    start_supervised!(
      {WotexHome.Schedules.Delivery,
       authority: authority, delivery_opts: [transport_factory: factory]}
    )

    assert_eventually(fn ->
      match?({:ok, %{disposition: :rejected}}, Store.request_status(store, manager, 1, operation))
    end)

    assert {:ok, rejected} = Store.request_status(store, manager, 1, operation)
    assert {:ok, revision} = Store.revision(store)
    refute_receive :unexpected_power_transport, 300
    assert {:ok, ^rejected} = Store.request_status(store, manager, 1, operation)
    assert {:ok, ^revision} = Store.revision(store)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[0, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_execution WHERE operation_id=?) FROM request_causal_roots WHERE operation_id=?",
               [operation, operation]
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_owner: true
  test "temporal owner refuses expiry while capture is in flight without opening a power transport",
       %{path: path} do
    {store, manager, _thing, operation, clock} = scheduled_capture_fixture(path)
    {authority, opts, _capture} = delivery_fixture(store, pause: 101)
    start_supervised!({WotexHome.Schedules.Delivery, authority: authority, delivery_opts: opts})
    assert_receive {:delivery_paused, capture_worker}, 5_000
    assert :ok = GenServer.call(clock, {:time, 110_000, 110_000})
    send(capture_worker, :delivery_continue)

    assert_eventually(fn ->
      match?(
        {:ok, %{disposition: :rejected, reason: "schedule_blocked:occurrence_expired"}},
        Store.request_status(store, manager, 1, operation)
      )
    end)

    refute_receive :delivery_transport_opened, 100
    refute_receive {:delivery_packet, 117}, 100
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[0, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_owner: true
  test "disabled temporal owner neither considers a due tick nor touches capture", %{path: path} do
    {store, _manager, _thing, _clock, _activation} = temporal_fixture(path, 90_000)
    assert {:ok, snapshot} = Store.temporal_clock_snapshot(store)
    final_admission_clock(store, snapshot)
    {authority, opts, _capture} = delivery_fixture(store)
    assert {:ok, revision} = Store.revision(store)

    owner =
      start_supervised!(
        {WotexHome.Schedules.Delivery,
         authority: %{authority | power_dispatch: false}, delivery_opts: opts}
      )

    assert_eventually(fn -> :sys.get_state(owner).last_result == :disabled end)
    assert {:ok, ^revision} = Store.revision(store)
    refute_receive {:delivery_packet, _}, 100
    assert {:ok, %{requests: []}} = Store.pending_scheduled_power(store)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_owner: true
  test "inactive temporal owner remains idle and rejects caller clocks and unbounded waits", %{
    path: path
  } do
    assert {:ok, store} = Store.start_link(path: path)
    authority = Authority.new(store: store, power_dispatch: true)
    assert {:ok, revision} = Store.revision(store)
    owner = start_supervised!({WotexHome.Schedules.Delivery, authority: authority})
    assert_eventually(fn -> :sys.get_state(owner).last_poll == :inactive end)
    assert {:ok, ^revision} = Store.revision(store)
    Process.flag(:trap_exit, true)

    for opts <- [
          [interval_ms: 99],
          [interval_ms: 1_001],
          [delivery_opts: [clock: fn -> 0 end]],
          [delivery_opts: [read_timeout_ms: 5_001]],
          [delivery_opts: [ack_timeout_ms: 1, ack_timeout_ms: 2]]
        ] do
      assert {:error, :invalid_schedule_delivery_owner} =
               WotexHome.Schedules.Delivery.start_link([authority: authority] ++ opts)
    end

    :ok = GenServer.stop(store)
  end

  @tag scheduled_owner: true
  test "temporal owner closes its original on clock loss and cannot repeat it when time recovers",
       %{
         path: path
       } do
    {store, manager, _thing, operation, clock} = scheduled_capture_fixture(path)
    assert {:ok, original} = Store.original_schedule_occurrence(store, manager, operation)
    assert :ok = GenServer.call(clock, {:reset, :clock_loss})
    {authority, opts, _capture} = delivery_fixture(store)

    owner =
      start_supervised!({WotexHome.Schedules.Delivery, authority: authority, delivery_opts: opts})

    assert_eventually(fn ->
      match?({:ok, %{disposition: :rejected}}, Store.request_status(store, manager, 1, operation))
    end)

    assert {:ok, rejected} = Store.request_status(store, manager, 1, operation)
    assert :ok = GenServer.call(clock, {:reset, :none})
    assert_eventually(fn -> :sys.get_state(owner).last_poll == :idle end)
    assert {:ok, ^rejected} = Store.request_status(store, manager, 1, operation)
    assert {:ok, ^original} = Store.original_schedule_occurrence(store, manager, operation)
    refute_receive {:delivery_packet, _}, 100
    refute_receive :delivery_transport_opened, 100
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[0, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    assert {:ok, %{writable: true}} = Store.health(store)
    assert :sys.get_state(store).schedule_poll == nil
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_latency: true
  @tag requires_socket: true
  test "temporal owner hands off within the default moving window through an independent UDP peer",
       %{
         path: path
       } do
    {store, manager, _thing, _clock, _activation} = temporal_fixture(path, 90_000)

    {peer, transport, cleanup} = WotexHome.TestSupport.PowerRouteFixture.open("power", self())
    on_exit(cleanup)
    {:ok, scope} = WotexHome.Lifx.IPv4Scope.new({127, 0, 0, 2}, 8)

    capture =
      start_supervised!(
        {WotexHome.Lifx.CaptureSession,
         interface_id: "fixture:loopback", scope: scope, transport: transport}
      )

    pool = start_supervised!(Task.Supervisor)

    authority =
      Authority.new(store: store, capture: capture, power_supervisor: pool, power_dispatch: true)

    opts = [
      transport_factory: fn -> {:ok, transport, fn -> :ok end} end,
      ack_timeout_ms: 100,
      read_timeout_ms: 100
    ]

    assert {:ok, snapshot} = Store.temporal_clock_snapshot(store)
    clock = final_admission_clock(store, snapshot)
    assert :ok = GenServer.call(clock, {:observe, self()})
    origin = System.monotonic_time(:millisecond) - :sys.get_state(store).clock_origin
    assert :ok = GenServer.call(clock, {:follow_time, 100_001, origin})
    started = System.monotonic_time(:millisecond)

    owner =
      start_supervised!({WotexHome.Schedules.Delivery, authority: authority, delivery_opts: opts})

    receive do
      {^peer, {:data, "set\n"}} -> :ok
    after
      5_000 ->
        diagnostic = Map.take(:sys.get_state(owner), [:last_poll, :last_result])
        {:ok, db} = Sqlite3.open(path, mode: :readonly)

        retained =
          rows(
            db,
            "SELECT disposition,reason FROM request_receipts WHERE operation_id IN (SELECT operation_id FROM request_causal_roots WHERE origin='schedule_occurrence')"
          )

        Sqlite3.close(db)

        flunk(
          "No in-window handoff: #{inspect(diagnostic)}; #{inspect(retained)}; #{inspect(route_latency_events(started, []))}"
        )
    end

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 10_000
    IO.puts("Default moving-window handoff observed at #{elapsed} ms")
    assert_receive {^peer, {:exit_status, 0}}, 2_000
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    [[operation]] =
      rows(db, "SELECT operation_id FROM request_causal_roots WHERE origin='schedule_occurrence'")

    assert {:ok, %{disposition: :observed}} = Store.request_status(store, manager, 1, operation)

    assert [[1, 1, 1]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching'),(SELECT COUNT(*) FROM schedule_considerations) FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  @tag scheduled_latency: true
  @tag requires_socket: true
  test "a one-second occurrence expires before independent UDP report publication without a set",
       %{path: path} do
    {store, manager, _thing, _clock, activation} =
      temporal_fixture(path, 90_000, true, nil, 1_000)

    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)
    clock = final_admission_clock(store, snapshot)

    {peer, transport, cleanup} =
      WotexHome.TestSupport.PowerRouteFixture.open("route", self(), true)

    on_exit(cleanup)
    {:ok, scope} = WotexHome.Lifx.IPv4Scope.new({127, 0, 0, 2}, 8)

    capture =
      start_supervised!(
        {WotexHome.Lifx.CaptureSession,
         interface_id: "fixture:loopback", scope: scope, transport: transport}
      )

    pool = start_supervised!(Task.Supervisor)

    authority =
      Authority.new(store: store, capture: capture, power_supervisor: pool, power_dispatch: true)

    observer = self()

    factory = fn ->
      send(observer, :unexpected_route_power_transport)
      {:error, :offline}
    end

    start_supervised!(
      {WotexHome.Schedules.Delivery,
       authority: authority, delivery_opts: [transport_factory: factory]}
    )

    assert_receive {:before_route_report, owner}, 2_000
    assert :ok = GenServer.call(clock, {:time, 101_000, 101_000})
    send(owner, :accept_route_report)

    assert_eventually(fn ->
      match?(
        {:ok, %{disposition: :rejected, reason: "schedule_blocked:occurrence_expired"}},
        Store.request_status(store, manager, 1, original.occurrence_id)
      )
    end)

    refute_receive :unexpected_route_power_transport, 100
    assert_receive {^peer, {:exit_status, 0}}, 2_000

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(store, manager, original.occurrence_id)

    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert [[0, 0, 0]] =
             rows(
               db,
               "SELECT reserved_effects,(SELECT COUNT(*) FROM source_epoch_grants),(SELECT COUNT(*) FROM request_journal WHERE disposition='dispatching') FROM request_causal_roots WHERE origin='schedule_occurrence'"
             )

    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
  end

  defp route_latency_events(started, events) do
    receive do
      {:route_clock, lower, count} ->
        route_latency_events(started, events ++ [{:clock, count, lower - 100_001}])

      {:route_wire, type, at} ->
        route_latency_events(started, events ++ [{:wire, type, at - started}])
    after
      0 -> events
    end
  end

  defp scheduled_capture_fixture(path) do
    {store, manager, thing, _owner, activation} = temporal_fixture(path, 90_000)
    {:ok, original, snapshot} = temporal_consider_fixture(store, activation, 100_001)

    clock =
      start_supervised!({FinalClockFixture, sample: snapshot.sample, reported_ms: 0, loss_at: 2})

    :sys.replace_state(store, fn state -> %{state | temporal_clock_owner: clock} end)
    {store, manager, thing, original.occurrence_id, clock}
  end

  defp temporal_fixture(
         path,
         observed,
         fresh_report \\ true,
         calendar \\ nil,
         late_window_ms \\ 10_000
       ) do
    {store, _controller, thing} = attempt_fixture(path)

    {:ok, manager, revision} =
      Store.provision_principal(
        store,
        "manager:schedule",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    clock = temporal_clock(store, path, observed)

    trigger =
      case calendar do
        countdown when countdown == :countdown or is_tuple(countdown) ->
          {:ok, snapshot} = Store.temporal_clock_snapshot(store)
          duration = if countdown == :countdown, do: 60_000, else: elem(countdown, 1)

          [
            "countdown",
            snapshot.scope["store_boot_epoch"],
            snapshot.scope["clock_generation"],
            snapshot.now_ms,
            duration
          ]

        nil ->
          ["interval", 100_000, 60_000, 0, nil]

        calendar ->
          calendar.trigger
      end

    Process.put(:temporal_fixture_trigger, trigger)

    {:ok, rule} =
      WotexHome.Rules.OperationInput.source("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "rule:body",
        "expected_revision" => revision,
        "rule_id" => "rule:temporal",
        "source_revision" => 1,
        "target_id" => thing.id,
        "on" => true
      })

    {:ok, source} =
      WotexHome.Schedules.Codec.encode(%{
        "id" => "schedule:temporal",
        "source_revision" => 1,
        "author_id" => "manager:schedule",
        "rule_id" => "rule:temporal",
        "rule_source_digest" => WotexHome.Schedules.Codec.hash(rule),
        "target_id" => thing.id,
        "resource_revision" => 0,
        "late_window_ms" => late_window_ms,
        "uncertainty_tolerance_ms" => 1_000,
        "trigger" => trigger
      })

    {:ok, input} =
      WotexHome.Schedules.OperationInput.encode("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "schedule:admit",
        "expected_revision" => revision,
        "source_document" => source,
        "rule_document" => rule
      })

    {:ok, admitted} =
      Store.retain_schedule_content(
        store,
        manager,
        input,
        if(is_map(calendar), do: calendar.zone)
      )

    {:ok, activation_input} =
      WotexHome.Schedules.OperationInput.encode("activate", %{
        "authority_epoch" => 1,
        "operation_id" => "schedule:activate",
        "expected_revision" => admitted.revision,
        "admission_revision" => admitted.revision
      })

    {:ok, activation} = Store.change_schedule(store, manager, activation_input)
    # Stamp the test baseline after admission/activation setup. Once queued its
    # exact revision is sealed, so renewing it later would change the guard
    # basis rather than exercise the intended temporal commit boundary.
    if fresh_report, do: refresh_temporal_report(store, thing, 2)
    state = :sys.get_state(store)
    keys = Keyword.new(Map.take(state, [:qualification_case_keys, :qualification_decision_keys]))
    Process.put(:temporal_fixture_details, {store, keys, thing})
    {store, manager, thing, clock, activation}
  end

  # Actual borrowed SQLite transitions with controlled software clock intervals;
  # these fixtures establish correspondence, never installed clock qualification.
  defp temporal_consider_fixture(store, activation, lower) do
    temporal_sql_fixture(store, fn state ->
      {:ok, retained} =
        WotexHome.Durable.Store.ScheduleLifecycle.retained_activation(
          state.db,
          activation.revision
        )

      {:ok, original, _} = WotexHome.Schedules.ActivationClock.decode(retained.clock_document)

      now =
        max(original.now_ms + 1, max(0, System.monotonic_time(:millisecond) - state.clock_origin))

      snapshot = %{
        original
        | now_ms: now,
          interval: {lower, lower},
          sample: %{
            original.sample
            | "sampled_monotonic_ms" => now,
              "utc_lower_ms" => lower,
              "utc_upper_ms" => lower
          }
      }

      context = temporal_context(snapshot)

      {:ok, {:ok, occurrence}} =
        WotexHome.Durable.Store.SQL.transaction(
          state.db,
          &WotexHome.Durable.Store.ScheduleOccurrences.consider(&1, context)
        )

      {:ok, occurrence, snapshot}
    end)
  end

  defp temporal_effect_fixture(
         store,
         manager,
         operation,
         stage,
         snapshot,
         lower,
         width,
         loss \\ nil
       ) do
    snapshot = %{
      snapshot
      | interval: {lower, lower + width},
        sample: %{snapshot.sample | "utc_lower_ms" => lower, "utc_upper_ms" => lower + width}
    }

    temporal_sql_fixture(store, fn state ->
      context =
        if loss do
          published =
            case stage do
              :queue -> "rejected"
              :claim -> "claimed"
              {:handoff, _} -> "dispatching"
            end

          temporal_publication_context(state.db, operation, snapshot, published, loss)
        else
          temporal_context(snapshot)
        end

      {:ok, hash} = Registry.credential_hash(manager)

      qualification =
        Map.take(state, [
          :qualification_claim_root,
          :qualification_case_keys,
          :qualification_decision_keys
        ])

      WotexHome.Durable.Store.SQL.transaction(state.db, fn db ->
        case stage do
          :queue ->
            WotexHome.Durable.Store.ExecutionWriter.admit_held_power_tx(
              db,
              manager,
              hash,
              1,
              operation,
              "boot:1",
              101,
              qualification,
              context
            )

          :claim ->
            WotexHome.Durable.Store.ExecutionWriter.claim_queued_power_tx(
              db,
              "manager:schedule",
              1,
              operation,
              "boot:1",
              101,
              :binary.copy(<<7>>, 32),
              qualification,
              context
            )

          {:handoff, token} ->
            WotexHome.Durable.Store.ExecutionWriter.handoff_claimed_power_tx(
              db,
              "manager:schedule",
              1,
              operation,
              token,
              101,
              qualification,
              context
            )
        end
      end)
    end)
  end

  defp temporal_publication_context(db, operation, snapshot, published, loss) do
    current = fn ->
      if rows(db, "SELECT disposition FROM request_receipts WHERE operation_id=?", [operation]) ==
           [[published]] do
        now = snapshot.now_ms + 10_000
        utc = if loss == :expiry, do: 110_000, else: 100_001

        %{
          snapshot
          | now_ms: now,
            interval: {utc, utc},
            sample: %{
              snapshot.sample
              | "sampled_monotonic_ms" => now,
                "utc_lower_ms" => utc,
                "utc_upper_ms" => utc
            }
        }
      else
        snapshot
      end
    end

    {:ok, context} =
      WotexHome.Durable.Store.ClockContext.new(
        fn ->
          s = current.()
          {s.scope["store_boot_epoch"], s.now_ms}
        end,
        fn -> {:ok, current.()} end,
        fn _ -> {:ok, nil} end
      )

    context
  end

  defp temporal_context(snapshot) do
    {:ok, context} =
      WotexHome.Durable.Store.ClockContext.new(
        fn -> {snapshot.scope["store_boot_epoch"], snapshot.now_ms} end,
        fn -> {:ok, snapshot} end,
        fn _ -> {:ok, nil} end
      )

    context
  end

  defp temporal_sql_fixture(store, callback) do
    caller = self()
    reference = make_ref()

    :sys.replace_state(store, fn state ->
      send(caller, {reference, callback.(state)})
      state
    end)

    receive do
      {^reference, result} -> result
    after
      20_000 -> flunk("temporal SQLite fixture did not return")
    end
  end

  defp temporal_clock(store, _path, observed) do
    root =
      Path.join("/private/tmp", "woh-temporal-execution-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    c = %{store: store, root: root}
    id = :temporal_clock
    requests = Path.join(c.root, Atom.to_string(id))
    File.mkdir!(requests)
    File.chmod!(requests, 0o700)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, runtime} = WotexHome.Schedules.ClockOwner.runtime_digest()

    policy = %{
      source_id: "clock:software-fixture",
      issuer_id: "issuer:software-fixture",
      public_key: public,
      issuer_generation: 1,
      procedure_ref: "procedure:software-only",
      qualification_digest: String.duplicate("a", 64),
      runtime_digest: runtime,
      maximum_response_ms: 30_000,
      maximum_age_ms: 120_000,
      maximum_error_ms: 0,
      drift_ppm: 10,
      maximum_discontinuity_ms: 20,
      monotonic_policy: "invalidate_on_discontinuity"
    }

    {:ok, document} = WotexHome.Schedules.ClockCodec.policy_document(policy)
    file = Path.join(c.root, Atom.to_string(id) <> ".policy")
    :ok = WotexHome.Recovery.PrivateFile.write(file, document, 4_096)

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {WotexHome.Schedules.ClockOwner,
           store: c.store, operator: self(), root: requests, policy_file: file},
          id: id,
          restart: :temporary
        )
      )

    {:ok, request} = WotexHome.Schedules.ClockOwner.request(owner)
    {:ok, document} = WotexHome.Recovery.PrivateFile.read(request.request_file, 4_096)
    {:ok, input} = WotexHome.Schedules.ClockCodec.decode_request(document)

    record =
      Map.merge(input, %{
        "procedure_ref" => policy.procedure_ref,
        "observed_utc_ms" => observed
      })

    {:ok, payload} = WotexHome.Schedules.ClockCodec.signing_payload(record)

    {:ok, package} =
      WotexHome.Schedules.ClockCodec.encode(
        record,
        :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      )

    assert {:ok, _} =
             WotexHome.Schedules.ClockOwner.approve(owner, request.request_digest, package)

    assert :ok = Store.attach_temporal_clock(c.store, owner)
    owner
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

  defp rows(db, sql, values \\ []) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, values)
      {:ok, result} = Sqlite3.fetch_all(db, statement)
      result
    after
      :ok = Sqlite3.release(db, statement)
    end
  end
end
