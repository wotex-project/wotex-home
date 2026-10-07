defmodule WotexHome.RecoveryClockOwnerTest do
  use ExUnit.Case
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Recovery.{ClockCodec, ClockOwner, Owner, PrivateFile}

  setup do
    Process.flag(:trap_exit, true)
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-clock-owner-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    reviews = Path.join(root, "reviews")
    File.mkdir!(reviews)
    File.chmod!(reviews, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    owner_file = Path.join(root, "owner.json")
    {:ok, _} = Owner.create(owner_file)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      issuer_id: "clock:synthetic",
      public_key: public,
      generation: 1,
      procedure_ref: "procedure:synthetic-utc",
      policy_digest: digest("a"),
      maximum_response_ms: 10_000,
      maximum_age_ms: 60_000,
      maximum_error_ms: 5
    }

    {:ok, document} = ClockCodec.policy_document(policy)
    policy_file = Path.join(root, "clock-policy.json")
    :ok = PrivateFile.write(policy_file, document, 4_096)
    runtime = start_supervised!({Agent, fn -> {:ok, digest("b")} end})

    options = [
      root: reviews,
      operator: self(),
      owner_file: owner_file,
      policy_file: policy_file,
      runtime: fn -> Agent.get(runtime, & &1) end
    ]

    %{
      root: root,
      reviews: reviews,
      policy: policy,
      policy_file: policy_file,
      owner_file: owner_file,
      runtime: runtime,
      options: options,
      private: private
    }
  end

  test "private original challenge creates a conservative interval independent of OS UTC", c do
    clock = start_supervised!({ClockOwner, c.options})
    assert %{confidence: :unknown} = ClockOwner.current(clock)
    assert {:ok, request} = ClockOwner.request(clock)
    assert request.state == :pending and request.authority_granted == false
    assert {:ok, bytes} = PrivateFile.read(request.request_file, 4_096)
    assert Artifact.digest(bytes) == request.request_digest
    package = response(c, request)
    assert {:ok, %{state: :accepted}} = ClockOwner.approve(clock, request.request_digest, package)
    state = :sys.get_state(clock)
    before = System.monotonic_time(:millisecond)

    assert %{confidence: :trusted, earliest_utc_ms: earliest, latest_utc_ms: latest} =
             ClockOwner.current(clock)

    after_time = System.monotonic_time(:millisecond)
    assert earliest >= 10_000 + (before - state.received) - 5
    assert latest <= 10_000 + (after_time - state.started) + 5
    assert latest - earliest == state.received - state.started + 10
    Process.sleep(5)
    assert %{confidence: :trusted, earliest_utc_ms: advanced} = ClockOwner.current(clock)
    assert advanced >= earliest + 5
    assert {:ok, %{state: :accepted}} = ClockOwner.approve(clock, request.request_digest, package)
    assert :sys.get_state(clock).started == state.started
    assert :sys.get_state(clock).received == state.received
    assert :sys.get_state(clock).age_deadline == state.age_deadline

    assert {:error, :recovery_clock_conflict} =
             ClockOwner.approve(clock, request.request_digest, package <> " ")

    assert %{confidence: :trusted} = ClockOwner.current(clock)
  end

  test "only the configured foreground caller can request or approve", c do
    clock = start_supervised!({ClockOwner, c.options})
    {:ok, request} = ClockOwner.request(clock)
    package = response(c, request)

    assert {:error, :recovery_clock_forbidden} =
             Task.async(fn -> ClockOwner.request(clock) end) |> Task.await()

    assert {:error, :recovery_clock_forbidden} =
             Task.async(fn ->
               ClockOwner.approve(clock, request.request_digest, package)
             end)
             |> Task.await()

    assert %{confidence: :unknown} = ClockOwner.current(clock)
    assert {:ok, _} = ClockOwner.approve(clock, request.request_digest, package)
  end

  test "wrong request digest does not replace the challenge and a bad signature consumes it", c do
    clock = start_supervised!({ClockOwner, c.options})
    {:ok, request} = ClockOwner.request(clock)
    package = response(c, request)
    assert {:error, :recovery_clock_conflict} = ClockOwner.approve(clock, digest("c"), package)
    assert {:ok, %{state: :pending}} = ClockOwner.request(clock)
    {:ok, parsed} = ClockCodec.decode(package)
    {:ok, bad} = ClockCodec.encode(parsed.record, <<0::512>>)

    assert {:error, :recovery_clock_response_unavailable} =
             ClockOwner.approve(clock, request.request_digest, bad)

    assert %{confidence: :unknown} = ClockOwner.current(clock)

    assert {:error, :recovery_clock_expired} =
             ClockOwner.approve(clock, request.request_digest, package)
  end

  test "a fresh boot cannot restore the old challenge from its immutable files", c do
    clock = start_supervised!({ClockOwner, c.options})
    {:ok, original} = ClockOwner.request(clock)
    package = response(c, original)
    assert {:ok, _} = ClockOwner.approve(clock, original.request_digest, package)
    :ok = stop_supervised(ClockOwner)
    fresh = start_supervised!({ClockOwner, c.options})
    {:ok, request} = ClockOwner.request(fresh)
    refute request.request_digest == original.request_digest
    assert File.exists?(original.request_file)

    assert {:error, :recovery_clock_response_unavailable} =
             ClockOwner.approve(fresh, request.request_digest, package)

    assert %{confidence: :unknown} = ClockOwner.current(fresh)
  end

  test "changed runtime consumes confidence rather than regaining it after restoration", c do
    clock = start_supervised!({ClockOwner, c.options})
    {:ok, request} = ClockOwner.request(clock)
    {:ok, _} = ClockOwner.approve(clock, request.request_digest, response(c, request))
    Agent.update(c.runtime, fn _ -> {:ok, digest("d")} end)
    assert %{confidence: :unknown} = ClockOwner.current(clock)
    Agent.update(c.runtime, fn _ -> {:ok, digest("b")} end)
    assert %{confidence: :unknown} = ClockOwner.current(clock)
    assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
  end

  test "identical-byte owner, policy, request and signed-response replacements withdraw confidence",
       c do
    for target <- [:owner, :policy, :request, :response] do
      clock = start_supervised!({ClockOwner, c.options})
      {:ok, request} = ClockOwner.request(clock)
      {:ok, _} = ClockOwner.approve(clock, request.request_digest, response(c, request))

      path =
        case target do
          :owner -> c.owner_file
          :policy -> c.policy_file
          :request -> request.request_file
          :response -> Path.join(Path.dirname(request.request_file), "clock-response.json")
        end

      bytes = File.read!(path)
      File.rename!(path, path <> ".original")
      :ok = PrivateFile.write(path, bytes, 4_096)
      assert %{confidence: :unknown} = ClockOwner.current(clock)
      :ok = stop_supervised(ClockOwner)
      File.rm!(path)
      File.rename!(path <> ".original", path)
    end
  end

  test "original response and whole-age deadlines expire without being renewed by status", c do
    policy = %{c.policy | maximum_response_ms: 200, maximum_age_ms: 500, maximum_error_ms: 0}
    replace_policy(c, policy)
    clock = start_supervised!({ClockOwner, c.options})
    {:ok, request} = ClockOwner.request(clock)
    package = response(%{c | policy: policy}, request)
    Process.sleep(220)
    assert {:ok, %{state: :expired}} = ClockOwner.request(clock)

    assert {:error, :recovery_clock_expired} =
             ClockOwner.approve(clock, request.request_digest, package)

    :ok = stop_supervised(ClockOwner)
    clock = start_supervised!({ClockOwner, c.options})
    {:ok, request} = ClockOwner.request(clock)

    {:ok, _} =
      ClockOwner.approve(clock, request.request_digest, response(%{c | policy: policy}, request))

    Process.sleep(520)
    assert %{confidence: :unknown} = ClockOwner.current(clock)
    assert {:ok, %{state: :expired}} = ClockOwner.request(clock)
  end

  test "negative or overflowing UTC intervals never create confidence", c do
    policy = %{c.policy | maximum_error_ms: 1_000}
    replace_policy(c, policy)
    c = %{c | policy: policy}

    for utc <- [0, 9_223_372_036_854_175_807] do
      clock = start_supervised!({ClockOwner, c.options})
      {:ok, request} = ClockOwner.request(clock)

      assert {:error, :recovery_clock_response_unavailable} =
               ClockOwner.approve(clock, request.request_digest, response(c, request, utc))

      assert %{confidence: :unknown} = ClockOwner.current(clock)
      :ok = stop_supervised(ClockOwner)
    end
  end

  test "missing policy and root substitutions are refused and status is redacted", c do
    missing = Keyword.put(c.options, :policy_file, Path.join(c.root, "absent-policy.json"))
    assert {:error, :recovery_clock_custody_unavailable} = ClockOwner.start_link(missing)
    clock = start_supervised!({ClockOwner, c.options})
    assert inspect(:sys.get_status(clock), limit: :infinity) =~ "private_recovery_clock"
    File.rename!(c.reviews, c.reviews <> ".original")
    File.mkdir!(c.reviews)
    File.chmod!(c.reviews, 0o700)
    assert %{confidence: :unknown} = ClockOwner.current(clock)
    assert {:ok, request} = ClockOwner.request(clock)

    assert {:error, :recovery_clock_response_unavailable} =
             ClockOwner.approve(
               clock,
               request.request_digest,
               response(c, %{
                 request
                 | request_file:
                     String.replace(
                       request.request_file,
                       c.reviews <> "/",
                       c.reviews <> ".original/"
                     )
               })
             )
  end

  test "operator death closes the private clock without restoring confidence", c do
    operator =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    clock =
      start_supervised!(
        Supervisor.child_spec({ClockOwner, Keyword.put(c.options, :operator, operator)},
          restart: :temporary
        )
      )

    ref = Process.monitor(clock)
    send(operator, :finish)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert [_] = File.ls!(c.reviews)
  end

  test "the shared private receiving-root capacity refuses a new challenge without pruning", c do
    for number <- 1..64, do: File.mkdir!(Path.join(c.reviews, "retained-#{number}"))
    assert {:error, :recovery_clock_custody_unavailable} = ClockOwner.start_link(c.options)
    assert length(File.ls!(c.reviews)) == 64
  end

  defp response(c, request, utc \\ 10_000) do
    {:ok, document} = PrivateFile.read(request.request_file, 4_096)
    {:ok, scope} = ClockCodec.decode_request(document)

    record =
      Map.merge(scope, %{"procedure_ref" => c.policy.procedure_ref, "observed_utc_ms" => utc})

    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(
        record,
        :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519])
      )

    package
  end

  defp replace_policy(c, policy) do
    File.rm!(c.policy_file)
    {:ok, document} = ClockCodec.policy_document(policy)
    :ok = PrivateFile.write(c.policy_file, document, 4_096)
  end

  defp digest(character), do: String.duplicate(character, 64)
end
