defmodule WotexHome.LifxCaptureSessionTest do
  use ExUnit.Case

  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, Transport}

  defmodule ScriptedTransport do
    @behaviour Transport

    @impl true
    def send(_handle, _endpoint, packet) do
      Process.put(:capture_packets, [packet | Process.get(:capture_packets, [])])
      :ok
    end

    @impl true
    def recv(handle, _timeout_ms) do
      count = Process.get(:capture_receive_count, 0)
      Process.put(:capture_receive_count, count + 1)
      packets = Process.get(:capture_packets, [])

      case count do
        0 ->
          {:ok, "192.168.1.10:56700", response(hd(packets), 3, <<1, 56_700::little-32>>)}

        1 ->
          {:error, :timeout}

        2 ->
          {:ok, "192.168.1.10:56700",
           response(Enum.at(packets, 1), 33, <<1::little-32, 27::little-32, 0::32>>)}

        3 ->
          {:ok, "192.168.1.10:56700",
           response(
             hd(packets),
             15,
             <<1_700_000_000::little-64, 0::64, 60::little-16, 3::little-16>>
           )}

        _ ->
          {:error, handle}
      end
    end

    defp response(request, type, payload) do
      <<_::binary-size(4), source::little-32, target::binary-size(6), _::binary-size(9),
        sequence::8, _::binary>> = request

      target = if type == 3, do: <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>, else: target
      size = 36 + byte_size(payload)

      <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
        sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
    end
  end

  defmodule OversizeTransport do
    @behaviour Transport

    @impl true
    def send(_handle, _endpoint, _packet), do: :ok

    @impl true
    def recv(_handle, _timeout_ms), do: {:ok, "192.168.1.10:56700", :binary.copy(<<0>>, 1_025)}
  end

  test "only the host process can assemble a one-use correlated capture" do
    {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)

    {:ok, owner} =
      CaptureSession.start_link(
        interface_id: "en0",
        scope: scope,
        transport: {ScriptedTransport, :fixture}
      )

    assert {:ok, ref, [candidate]} = CaptureSession.discover(owner, 2, 7, 1_000)
    assert String.starts_with?(ref, "capture:")
    assert candidate.interface_id == "en0"
    assert candidate.receive_epoch =~ ~r/^boot:/

    assert {:error, :capture_missing} =
             CaptureSession.interview(owner, "capture:forged", candidate.raw_ref, 2, 1_000)

    assert {:error, :ambiguous_or_missing_candidate} =
             CaptureSession.interview(owner, ref, "fixture:forged", 2, 1_000)

    assert {:error, :interview_incomplete} = CaptureSession.checkout(owner, ref)

    assert {:ok, interview} = CaptureSession.interview(owner, ref, candidate.raw_ref, 2, 1_000)
    assert interview.stable_id == "lifx:d073d5001337"
    assert interview.manufacturer == "lifx.vendor.1"
    assert interview.model == "lifx.product.27"
    assert interview.firmware == "3.60"

    assert {:ok, evidence} = CaptureSession.checkout(owner, ref)
    assert evidence.selected_candidate_ref == candidate.raw_ref
    assert evidence.epoch == candidate.receive_epoch
    assert evidence.candidates == [candidate]
    assert evidence.interview == interview

    assert Enum.map(evidence.transcript, &elem(&1, 0)) ==
             [
               :outbound_accepted,
               :inbound,
               :outbound_accepted,
               :outbound_accepted,
               :inbound,
               :inbound
             ]

    assert Enum.all?(evidence.transcript, fn {direction, endpoint, bytes} ->
             direction in [:outbound_accepted, :inbound] and is_binary(endpoint) and
               byte_size(bytes) <= 1_024
           end)

    assert {:error, :capture_missing} = CaptureSession.checkout(owner, ref)
    GenServer.stop(owner)
  end

  test "a restart loses uncommitted evidence and large datagrams fail closed" do
    {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)
    opts = [interface_id: "en0", scope: scope, transport: {ScriptedTransport, :fixture}]
    {:ok, first} = CaptureSession.start_link(opts)
    assert {:ok, ref, [_]} = CaptureSession.discover(first, 2, 7, 1_000)
    GenServer.stop(first)

    {:ok, second} = CaptureSession.start_link(opts)
    assert {:error, :capture_missing} = CaptureSession.checkout(second, ref)
    GenServer.stop(second)

    {:ok, oversized} =
      CaptureSession.start_link(
        interface_id: "en0",
        scope: scope,
        transport: {OversizeTransport, nil}
      )

    assert {:error, :capture_budget_exceeded} = CaptureSession.discover(oversized, 2, 7, 1_000)
    assert {:error, :capture_missing} = CaptureSession.checkout(oversized, ref)
    GenServer.stop(oversized)
  end

  test "invalid transport ownership never starts a capture" do
    assert {:error, :invalid_capture_owner} =
             CaptureSession.start_link(transport: {ScriptedTransport, nil})

    assert {:error, :invalid_capture_owner} = CaptureSession.start_link([123])
  end

  test "an unclaimed capture expires in memory" do
    {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)

    {:ok, owner} =
      CaptureSession.start_link(
        interface_id: "en0",
        scope: scope,
        transport: {ScriptedTransport, :fixture},
        session_ttl_ms: 100
      )

    assert {:ok, ref, [_]} = CaptureSession.discover(owner, 2, 7, 1_000)
    Process.sleep(150)
    assert {:error, :capture_missing} = CaptureSession.checkout(owner, ref)
    GenServer.stop(owner)
  end
end
