defmodule WotexHome.LifxPowerExecutionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Receipt
  alias WotexHome.Lifx.{Ledger, Packet, PowerClaim, PowerExecution}
  alias WotexHome.Mutation
  alias WotexHome.Semantics.Thing

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>
  @stable_id "lifx:d073d5001337"
  @endpoint "192.168.1.10:56701"

  defmodule ScriptedTransport do
    @moduledoc false
    @behaviour WotexHome.Lifx.Transport

    alias WotexHome.Lifx.Packet

    @impl true
    def send({test, mode}, endpoint, bytes) do
      {:ok, packet} = Packet.decode(bytes)
      Kernel.send(test, {:sent, endpoint, packet})

      case {mode, packet.type} do
        {:set_error, 117} ->
          {:error, :send_failed}

        {mode, 117} when mode in [:match, :read_timeout] ->
          Kernel.send(test, {:datagram, endpoint, reply(packet, 45, <<>>)})
          :ok

        {:mismatch_without_ack, 117} ->
          :ok

        {:match, 116} ->
          Kernel.send(test, {:datagram, endpoint, reply(packet, 118, <<65_535::little-16>>)})
          :ok

        {:mismatch_without_ack, 116} ->
          Kernel.send(test, {:datagram, endpoint, reply(packet, 118, <<0::little-16>>)})
          :ok

        {:read_timeout, 116} ->
          :ok
      end
    end

    @impl true
    def recv(_handle, timeout_ms) do
      receive do
        {:datagram, endpoint, bytes} -> {:ok, endpoint, bytes}
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

  defmodule UnsupportedRouteTransport do
    @moduledoc false
    @behaviour WotexHome.Lifx.Transport

    @impl true
    def preflight(_handle, _endpoint, :unicast), do: {:error, :unsupported_unicast_endpoint}

    @impl true
    def send(_handle, _endpoint, _bytes), do: raise("preflight must reject before send")

    @impl true
    def recv(_handle, _timeout), do: raise("preflight must reject before receive")
  end

  test "a device ACK remains intermediate until a matching readback settles observed" do
    assert {:ok, ledger} = Ledger.new(42)

    assert {:ok, %{disposition: :observed, reason: nil}, settled_ledger} =
             PowerExecution.run(
               hooks(self(), true),
               candidate(),
               @target,
               ledger,
               options(self(), :match)
             )

    assert_receive {:hook, :claim}
    assert_receive {:hook, :handoff}
    assert_receive {:sent, @endpoint, %Packet{type: 117}}
    assert_receive {:hook, :ack}
    assert_receive {:sent, @endpoint, %Packet{type: 116}}
    assert_receive {:hook, {:settle, true}}
    assert map_size(settled_ledger.pending) == 0
  end

  test "a readback can contradict without an ACK" do
    assert {:ok, ledger} = Ledger.new(42)

    assert {:ok, %{disposition: :contradicted, reason: "readback_mismatch"}, _ledger} =
             PowerExecution.run(
               hooks(self(), true),
               candidate(),
               @target,
               ledger,
               options(self(), :mismatch_without_ack)
             )

    assert_receive {:hook, :claim}
    assert_receive {:hook, :handoff}
    refute_receive {:hook, :ack}
    assert_receive {:hook, {:settle, false}}
  end

  test "send uncertainty and readback timeout close the handed-off receipt as unknown" do
    for {mode, expected_reason} <- [
          {:set_error, :set_send_uncertain},
          {:read_timeout, :readback_timeout}
        ] do
      assert {:ok, ledger} = Ledger.new(42)

      assert {:ok, %{disposition: :outcome_unknown}, _ledger} =
               PowerExecution.run(
                 hooks(self(), true),
                 candidate(),
                 @target,
                 ledger,
                 options(self(), mode)
               )

      assert_receive {:hook, :claim}
      assert_receive {:hook, :handoff}

      if mode == :read_timeout do
        assert_receive {:hook, :ack}
      end

      assert_receive {:hook, {:unknown, ^expected_reason}}
    end
  end

  test "a mismatched discovered identity never reaches handoff" do
    assert {:ok, ledger} = Ledger.new(42)
    mismatched = put_in(candidate().claimed_identifiers["stable_id"], "lifx:d073d5009999")

    assert {:error, :claim_candidate_mismatch, ^ledger} =
             PowerExecution.run(
               hooks(self(), true),
               mismatched,
               @target,
               ledger,
               options(self(), :match)
             )

    assert_receive {:hook, :claim}
    refute_receive {:hook, :handoff}
    refute_receive {:sent, _, _}
  end

  test "an unsupported adapter route is rejected before durable claim" do
    assert {:ok, ledger} = Ledger.new(42)

    opts =
      options(self(), :match)
      |> Keyword.put(:transport, {UnsupportedRouteTransport, nil})

    assert {:error, :unsupported_unicast_endpoint, ^ledger} =
             PowerExecution.run(hooks(self(), true), candidate(), @target, ledger, opts)

    refute_receive {:hook, :claim}
    refute_receive {:hook, :handoff}
    refute_receive {:sent, _, _}
  end

  test "unbound fade durations are rejected before claim, handoff or device I/O" do
    assert {:ok, ledger} = Ledger.new(42)
    opts = options(self(), :match)

    for duration <- [1, 5_000, 60_000, 60_001, -1, 0.0, "0", nil] do
      assert {:error, :invalid_power_execution, ^ledger} =
               PowerExecution.run(
                 hooks(self(), true),
                 candidate(),
                 @target,
                 ledger,
                 Keyword.put(opts, :duration_ms, duration)
               )
    end

    refute_receive {:hook, _}
    refute_receive {:sent, _, _}
  end

  defp hooks(test, desired) do
    claim = claim(desired)

    %{
      claim: fn _boot_epoch, _now_ms ->
        send(test, {:hook, :claim})
        {:ok, claim}
      end,
      handoff: fn ^claim, _now_ms ->
        send(test, {:hook, :handoff})
        {:ok, receipt(:dispatching, nil, 2)}
      end,
      ack: fn ^claim ->
        send(test, {:hook, :ack})
        {:ok, receipt(:protocol_accepted, nil, 3)}
      end,
      settle: fn ^claim, observation ->
        send(test, {:hook, {:settle, observation.value.data}})

        if observation.value.data == desired,
          do: {:ok, receipt(:observed, nil, 5)},
          else: {:ok, receipt(:contradicted, "readback_mismatch", 5)}
      end,
      unknown: fn ^claim, reason ->
        send(test, {:hook, {:unknown, reason}})
        {:ok, receipt(:outcome_unknown, "#{reason}_after_handoff", 4)}
      end
    }
  end

  defp claim(desired) do
    %PowerClaim{
      receipt: receipt(:claimed, nil, 1),
      token: :binary.copy(<<7>>, 32),
      stable_id: @stable_id,
      thing: thing(),
      mutation: mutation(desired),
      boot_epoch: "boot:1"
    }
  end

  defp receipt(disposition, reason, revision) do
    %Receipt{
      principal_id: "controller:1",
      authority_epoch: 1,
      operation_id: "op:power:1",
      disposition: disposition,
      reason: reason,
      revision: revision
    }
  end

  defp options(test, mode) do
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)

    [
      transport: {ScriptedTransport, {test, mode}},
      clock: fn -> Agent.get_and_update(clock, &{{&1, 1_700_000_000_000 + &1}, &1 + 1}) end,
      source_epoch: "lifx:source:1",
      source_sequence: 2,
      boot_epoch: "boot:1",
      ack_timeout_ms: 5,
      read_timeout_ms: 5,
      duration_ms: 0
    ]
  end

  defp candidate do
    assert {:ok, candidate} =
             Candidate.new(%{
               "interface_id" => "en0",
               "transport" => "udp",
               "source_endpoint" => @endpoint,
               "receive_epoch" => "scan:1",
               "received_monotonic_ms" => 100,
               "raw_ref" => "capture:1",
               "claimed_identifiers" => %{"stable_id" => @stable_id},
               "trust_class" => "untrusted_network"
             })

    candidate
  end

  defp thing do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [
                 %{
                   "thing_id" => "light:desk",
                   "role" => "Light",
                   "key" => "power",
                   "value_kind" => "boolean",
                   "unit" => "none",
                   "operations" => ["read", "write"],
                   "risk_class" => "ordinary",
                   "profile_ref" => "lifx.old:1",
                   "evidence_ref" => "fixture:power:1",
                   "freshness_ms" => 5_000,
                   "constraints" => %{},
                   "extensions" => %{}
                 }
               ]
             })

    thing
  end

  defp mutation(desired) do
    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:power:1",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => "light:desk",
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => desired}
             })

    mutation
  end
end
