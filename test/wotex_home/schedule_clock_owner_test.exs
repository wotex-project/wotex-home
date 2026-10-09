defmodule WotexHome.ScheduleClockOwnerTest do
  use ExUnit.Case
  alias WotexHome.Durable.Store
  alias WotexHome.Recovery.PrivateFile
  alias WotexHome.Schedules.{ClockCodec, ClockOwner, ClockSample, Codec}

  setup do
    Process.flag(:trap_exit, true)

    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "woh-temporal-owner-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    requests = Path.join(root, "requests")
    File.mkdir!(requests)
    File.chmod!(requests, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    {:ok, runtime} = ClockOwner.runtime_digest()

    runtime_agent =
      start_supervised!(Supervisor.child_spec({Agent, fn -> {:ok, runtime} end}, id: :runtime))

    wall_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :wall))
    mono_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :monotonic))
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      source_id: "clock:synthetic",
      issuer_id: "issuer:synthetic",
      public_key: public,
      issuer_generation: 1,
      procedure_ref: "procedure:synthetic-temporal",
      qualification_digest: String.duplicate("a", 64),
      runtime_digest: runtime,
      maximum_response_ms: 10_000,
      maximum_age_ms: 60_000,
      maximum_error_ms: 5,
      drift_ppm: 10,
      maximum_discontinuity_ms: 50,
      monotonic_policy: "invalidate_on_discontinuity"
    }

    {:ok, document} = ClockCodec.policy_document(policy)
    policy_file = Path.join(root, "policy.json")
    :ok = PrivateFile.write(policy_file, document, 4_096)

    options = [
      store: store,
      operator: self(),
      root: requests,
      policy_file: policy_file,
      runtime: fn -> Agent.get(runtime_agent, & &1) end,
      wall: fn -> System.system_time(:millisecond) + Agent.get(wall_agent, & &1) end,
      monotonic: fn -> System.monotonic_time(:millisecond) + Agent.get(mono_agent, & &1) end
    ]

    %{
      root: root,
      requests: requests,
      path: path,
      store: store,
      runtime: runtime,
      runtime_agent: runtime_agent,
      wall_agent: wall_agent,
      mono_agent: mono_agent,
      policy: policy,
      policy_file: policy_file,
      private: private,
      options: options
    }
  end

  test "default Store clock is explicitly unqualified and changes no authority revision", c do
    assert {:ok,
            %{scope: scope, sample: sample, interval: nil, reason: :temporal_clock_unavailable}} =
             Store.temporal_clock_snapshot(c.store)

    assert sample["wall_confidence"] == "unqualified" && sample["qualification_digest"] == nil
    assert sample["utc_lower_ms"] == nil && sample["utc_upper_ms"] == nil
    assert sample["monotonic_continuous"] == false && scope["clock_generation"] == 1
    assert {:ok, _} = ClockSample.encode(sample)

    assert {:error, :clock_uncertain} =
             ClockSample.advance(sample, sample["boot_epoch"], 1, sample["sampled_monotonic_ms"])

    assert {:ok, 0} = Store.revision(c.store)
    assert {:ok, %{dispatch_enabled: false, held_requests: 0}} = Store.health(c.store)
  end

  test "original private accepted source attaches only to the actual Store boot and retains bounded uncertainty",
       c do
    clock = clock(c.options)

    assert {:ok, %{state: :pending, authority_granted: false} = request} =
             ClockOwner.request(clock)

    assert {:error, :schedule_clock_unavailable} = Store.attach_temporal_clock(c.store, clock)
    package = response(c, request)
    assert {:ok, %{state: :accepted}} = ClockOwner.approve(clock, request.request_digest, package)
    assert :ok = Store.attach_temporal_clock(c.store, clock)

    assert {:ok,
            %{sample: sample, interval: {lower, upper}, now_ms: now, scope: scope, reason: nil}} =
             Store.temporal_clock_snapshot(c.store)

    assert sample["source_id"] == c.policy.source_id &&
             sample["qualification_digest"] == c.policy.qualification_digest

    assert scope["store_boot_epoch"] == sample["boot_epoch"] &&
             scope["clock_generation"] == sample["generation"]

    assert sample["sampled_monotonic_ms"] <= now && lower <= upper

    assert {:ok, {^lower, ^upper}} =
             ClockSample.advance(sample, sample["boot_epoch"], sample["generation"], now)

    original = :sys.get_state(clock)
    assert {:ok, %{state: :accepted}} = ClockOwner.approve(clock, request.request_digest, package)

    assert :sys.get_state(clock).started == original.started &&
             :sys.get_state(clock).lease == original.lease

    assert {:error, :schedule_clock_owner_conflict} = Store.attach_temporal_clock(c.store, clock)
    assert {:ok, 0} = Store.revision(c.store)
  end

  test "only the original foreground operator may approve and only the Store may obtain a source sample",
       c do
    clock = clock(c.options)
    {:ok, request} = ClockOwner.request(clock)
    package = response(c, request)

    assert {:error, :schedule_clock_forbidden} =
             Task.async(fn -> ClockOwner.request(clock) end) |> Task.await()

    assert {:error, :schedule_clock_forbidden} =
             Task.async(fn -> ClockOwner.approve(clock, request.request_digest, package) end)
             |> Task.await()

    assert {:error, :schedule_clock_forbidden} = ClockOwner.current(clock, %{})
    assert {:error, :schedule_clock_forbidden} = ClockOwner.binding(clock)
    assert {:ok, _} = ClockOwner.approve(clock, request.request_digest, package)
    assert :ok = Store.attach_temporal_clock(c.store, clock)
  end

  test "a wrong digest retains the pending challenge but invalid signature permanently consumes it",
       c do
    clock = clock(c.options)
    {:ok, request} = ClockOwner.request(clock)
    package = response(c, request)

    assert {:error, :schedule_clock_conflict} =
             ClockOwner.approve(clock, String.duplicate("b", 64), package)

    assert {:ok, %{state: :pending}} = ClockOwner.request(clock)
    {:ok, parsed} = ClockCodec.decode(package)
    {:ok, bad} = ClockCodec.encode(parsed.record, <<0::512>>)

    assert {:error, :schedule_clock_response_unavailable} =
             ClockOwner.approve(clock, request.request_digest, bad)

    assert {:error, :schedule_clock_expired} =
             ClockOwner.approve(clock, request.request_digest, package)

    assert {:error, :schedule_clock_unavailable} = Store.attach_temporal_clock(c.store, clock)
    assert {:ok, %{interval: nil}} = Store.temporal_clock_snapshot(c.store)
  end

  test "identical-byte policy/request/response replacements withdraw without confidence restoration",
       c do
    for target <- [:policy, :request, :response] do
      clock = clock(c.options)
      {:ok, request} = ClockOwner.request(clock)
      {:ok, _} = ClockOwner.approve(clock, request.request_digest, response(c, request))
      :ok = Store.attach_temporal_clock(c.store, clock)

      path =
        case target do
          :policy -> c.policy_file
          :request -> request.request_file
          :response -> Path.join(Path.dirname(request.request_file), "response.json")
        end

      bytes = File.read!(path)
      File.rename!(path, path <> ".held")
      :ok = PrivateFile.write(path, bytes, 4_096)
      assert {:ok, %{interval: nil, scope: scope}} = Store.temporal_clock_snapshot(c.store)
      assert scope["clock_generation"] > 1
      File.rm!(path)
      File.rename!(path <> ".held", path)
      assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
      assert {:ok, %{interval: nil, scope: ^scope}} = Store.temporal_clock_snapshot(c.store)
      :ok = stop_supervised(ClockOwner)
    end

    assert {:ok, 0} = Store.revision(c.store)
  end

  test "runtime change and restoration cannot renew an accepted source", c do
    clock = clock(c.options)
    {:ok, request} = ClockOwner.request(clock)
    {:ok, _} = ClockOwner.approve(clock, request.request_digest, response(c, request))
    :ok = Store.attach_temporal_clock(c.store, clock)
    Agent.update(c.runtime_agent, fn _ -> {:ok, String.duplicate("b", 64)} end)
    assert {:ok, %{interval: nil, scope: scope}} = Store.temporal_clock_snapshot(c.store)
    Agent.update(c.runtime_agent, fn _ -> {:ok, c.runtime} end)
    assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
    assert {:ok, %{interval: nil, scope: ^scope}} = Store.temporal_clock_snapshot(c.store)
  end

  test "wall correction or monotonic rollback withdraws the old generation irreversibly", c do
    for source <- [:wall, :monotonic] do
      clock = clock(c.options)
      {:ok, request} = ClockOwner.request(clock)
      {:ok, _} = ClockOwner.approve(clock, request.request_digest, response(c, request))
      :ok = Store.attach_temporal_clock(c.store, clock)
      agent = if source == :wall, do: c.wall_agent, else: c.mono_agent
      Agent.update(agent, fn _ -> if(source == :wall, do: 10_000, else: -100_000) end)
      assert {:ok, %{interval: nil, scope: scope}} = Store.temporal_clock_snapshot(c.store)
      Agent.update(agent, fn _ -> 0 end)
      assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
      assert {:ok, %{interval: nil, scope: ^scope}} = Store.temporal_clock_snapshot(c.store)
      :ok = stop_supervised(ClockOwner)
    end
  end

  test "trusted wake withdrawal requires a new original challenge in the new generation", c do
    clock = clock(c.options)
    {:ok, original} = ClockOwner.request(clock)
    package = response(c, original)
    {:ok, _} = ClockOwner.approve(clock, original.request_digest, package)
    :ok = Store.attach_temporal_clock(c.store, clock)
    :ok = Store.invalidate_temporal_clock(c.store)
    assert {:ok, %{interval: nil, scope: scope}} = Store.temporal_clock_snapshot(c.store)
    assert scope["clock_generation"] == 2
    assert {:error, :schedule_clock_owner_conflict} = Store.attach_temporal_clock(c.store, clock)
    :ok = stop_supervised(ClockOwner)
    fresh = clock(c.options)
    {:ok, request} = ClockOwner.request(fresh)
    refute request.request_digest == original.request_digest

    assert {:error, :schedule_clock_response_unavailable} =
             ClockOwner.approve(fresh, request.request_digest, package)

    assert File.exists?(original.request_file)
  end

  test "several individually small wall changes cannot hide their cumulative discontinuity", c do
    clock = clock(c.options)
    {:ok, request} = ClockOwner.request(clock)
    {:ok, _} = ClockOwner.approve(clock, request.request_digest, response(c, request))
    :ok = Store.attach_temporal_clock(c.store, clock)
    Agent.update(c.wall_agent, fn _ -> 40 end)

    assert {:ok, %{reason: nil, sample: sample, scope: original}} =
             Store.temporal_clock_snapshot(c.store)

    assert sample["utc_upper_ms"] - sample["utc_lower_ms"] >=
             2 * (c.policy.maximum_error_ms + c.policy.maximum_discontinuity_ms)

    Agent.update(c.wall_agent, fn _ -> 80 end)
    assert {:ok, %{interval: nil, scope: withdrawn}} = Store.temporal_clock_snapshot(c.store)
    assert withdrawn["clock_generation"] == original["clock_generation"] + 1
    Agent.update(c.wall_agent, fn _ -> 0 end)
    assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
  end

  test "whole-age expiry blocks temporal samples without disabling unrelated manual storage", c do
    File.rm!(c.policy_file)
    policy = %{c.policy | maximum_response_ms: 200, maximum_age_ms: 500, maximum_error_ms: 0}
    {:ok, document} = ClockCodec.policy_document(policy)
    :ok = PrivateFile.write(c.policy_file, document, 4_096)
    clock = clock(c.options)
    {:ok, request} = ClockOwner.request(clock)

    {:ok, _} =
      ClockOwner.approve(clock, request.request_digest, response(%{c | policy: policy}, request))

    :ok = Store.attach_temporal_clock(c.store, clock)
    assert {:ok, %{reason: nil}} = Store.temporal_clock_snapshot(c.store)
    Process.sleep(520)
    assert {:ok, %{interval: nil}} = Store.temporal_clock_snapshot(c.store)
    assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
    assert {:ok, _, 1} = Store.provision_principal(c.store, "reader:manual", ["read"], [])
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(c.store)
  end

  test "accepted owner survives foreground caller exit while pending approval is withdrawn", c do
    for accepted <- [false, true] do
      parent = self()

      operator =
        spawn(fn ->
          receive do
            {:source, clock} ->
              {:ok, request} = ClockOwner.request(clock)

              if accepted,
                do: ClockOwner.approve(clock, request.request_digest, response(c, request))

              send(parent, {:ready, self()})

              receive do
                :stop -> :ok
              end
          end
        end)

      reference = Process.monitor(operator)
      clock = clock(Keyword.put(c.options, :operator, operator))
      send(operator, {:source, clock})
      assert_receive {:ready, ^operator}, 3_000
      if accepted, do: assert(:ok == Store.attach_temporal_clock(c.store, clock))
      send(operator, :stop)
      assert_receive {:DOWN, ^reference, :process, ^operator, :normal}, 1_000
      assert {:ok, %{reason: reason}} = Store.temporal_clock_snapshot(c.store)
      assert is_nil(reason) == accepted
      :ok = stop_supervised(ClockOwner)
      if accepted, do: Store.temporal_clock_snapshot(c.store)
    end
  end

  test "actual Store death stops the owner and restart cannot consume its retained original response",
       c do
    clock = clock(c.options)
    {:ok, original} = ClockOwner.request(clock)
    package = response(c, original)
    {:ok, _} = ClockOwner.approve(clock, original.request_digest, package)
    :ok = Store.attach_temporal_clock(c.store, clock)
    reference = Process.monitor(clock)
    :ok = stop_supervised(Store)
    assert_receive {:DOWN, ^reference, :process, ^clock, :normal}, 3_000
    assert {:error, :not_found} = stop_supervised(ClockOwner)
    store = start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary))
    assert {:ok, %{interval: nil}} = Store.temporal_clock_snapshot(store)
    fresh = clock(Keyword.put(c.options, :store, store))
    {:ok, request} = ClockOwner.request(fresh)
    {:ok, original_bytes} = PrivateFile.read(original.request_file, 4_096)
    {:ok, old_scope} = ClockCodec.decode_request(original_bytes)
    {:ok, fresh_bytes} = PrivateFile.read(request.request_file, 4_096)
    {:ok, new_scope} = ClockCodec.decode_request(fresh_bytes)

    assert old_scope["deployment_id"] == new_scope["deployment_id"] &&
             old_scope["owner_id"] == new_scope["owner_id"]

    refute old_scope["store_boot_epoch"] == new_scope["store_boot_epoch"]

    assert {:error, :schedule_clock_response_unavailable} =
             ClockOwner.approve(fresh, request.request_digest, package)

    assert {:ok, 0} = Store.revision(store)
  end

  test "an accepted source cannot attach to a different actual Store or replace an installed owner",
       c do
    first = clock(c.options)
    {:ok, request} = ClockOwner.request(first)
    {:ok, _} = ClockOwner.approve(first, request.request_digest, response(c, request))

    other =
      start_supervised!(
        Supervisor.child_spec({Store, path: Path.join(c.root, "other.sqlite")},
          id: :other_store,
          restart: :temporary
        )
      )

    assert {:error, :schedule_clock_forbidden} = Store.attach_temporal_clock(other, first)
    assert :ok = Store.attach_temporal_clock(c.store, first)

    second =
      start_supervised!(
        Supervisor.child_spec({ClockOwner, c.options}, id: :other_clock, restart: :temporary)
      )

    {:ok, request} = ClockOwner.request(second)
    {:ok, _} = ClockOwner.approve(second, request.request_digest, response(c, request))
    assert {:error, :schedule_clock_owner_conflict} = Store.attach_temporal_clock(c.store, second)
    assert {:ok, %{reason: nil}} = Store.temporal_clock_snapshot(c.store)
    assert {:ok, %{interval: nil}} = Store.temporal_clock_snapshot(other)
    assert {:ok, 0} = Store.revision(other)
  end

  test "replacing and restoring the entire private request directory withdraws its original source",
       c do
    clock = clock(c.options)
    {:ok, request} = ClockOwner.request(clock)
    {:ok, _} = ClockOwner.approve(clock, request.request_digest, response(c, request))
    :ok = Store.attach_temporal_clock(c.store, clock)
    File.rename!(c.requests, c.requests <> ".held")
    File.mkdir!(c.requests)
    File.chmod!(c.requests, 0o700)
    assert {:ok, %{interval: nil, scope: scope}} = Store.temporal_clock_snapshot(c.store)
    File.rmdir!(c.requests)
    File.rename!(c.requests <> ".held", c.requests)
    assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
    assert {:ok, %{interval: nil, scope: ^scope}} = Store.temporal_clock_snapshot(c.store)
  end

  test "missing/unsafe private policy and a changed runtime refuse clock construction", c do
    File.chmod!(c.policy_file, 0o600)
    assert {:error, :schedule_clock_custody_unavailable} = ClockOwner.start_link(c.options)
    File.chmod!(c.policy_file, 0o400)
    Agent.update(c.runtime_agent, fn _ -> {:ok, String.duplicate("b", 64)} end)
    assert {:error, :schedule_clock_custody_unavailable} = ClockOwner.start_link(c.options)
    Agent.update(c.runtime_agent, fn _ -> {:ok, c.runtime} end)
    File.rm!(c.policy_file)
    assert {:error, :schedule_clock_custody_unavailable} = ClockOwner.start_link(c.options)
    assert {:ok, %{interval: nil}} = Store.temporal_clock_snapshot(c.store)
  end

  test "pending original response deadline expires without replacing its private request", c do
    File.rm!(c.policy_file)
    policy = %{c.policy | maximum_response_ms: 100, maximum_age_ms: 500, maximum_error_ms: 0}
    {:ok, document} = ClockCodec.policy_document(policy)
    :ok = PrivateFile.write(c.policy_file, document, 4_096)
    clock = clock(c.options)
    {:ok, request} = ClockOwner.request(clock)
    package = response(%{c | policy: policy}, request)
    Process.sleep(120)
    assert {:ok, %{state: :expired, request_digest: digest}} = ClockOwner.request(clock)
    assert digest == request.request_digest
    assert {:error, :schedule_clock_expired} = ClockOwner.approve(clock, digest, package)
    assert {:error, :schedule_clock_unavailable} = Store.attach_temporal_clock(c.store, clock)
    assert File.exists?(request.request_file)
  end

  defp clock(options),
    do: start_supervised!(Supervisor.child_spec({ClockOwner, options}, restart: :temporary))

  defp response(c, request) do
    {:ok, document} = PrivateFile.read(request.request_file, 4_096)
    assert Codec.hash(document) == request.request_digest
    {:ok, input} = ClockCodec.decode_request(document)

    record =
      Map.merge(input, %{
        "procedure_ref" => c.policy.procedure_ref,
        "observed_utc_ms" => 1_000_000
      })

    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(record, :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519]))

    package
  end
end
