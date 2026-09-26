defmodule WotexHome.LifxDiscoveryPathTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias WotexHome.Lifx.{DiscoveryPath, IPv4Scope, Transport}

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  defmodule ScriptedTransport do
    @behaviour Transport

    @impl true
    def send(test_pid, endpoint, packet) do
      send(test_pid, {:broadcast, endpoint, packet})
      :ok
    end

    @impl true
    def recv(_test_pid, _timeout_ms) do
      receive do
        {:datagram, endpoint, bytes} -> {:ok, endpoint, bytes}
      after
        0 -> {:error, :timeout}
      end
    end
  end

  defmodule FailingTransport do
    @behaviour Transport

    @impl true
    def send(_handle, _endpoint, _packet), do: {:error, :send_failed}

    @impl true
    def recv(_handle, _timeout_ms), do: {:error, :timeout}
  end

  defmodule SpamTransport do
    @behaviour Transport

    @impl true
    def send(_handle, _endpoint, _packet), do: :ok

    @impl true
    def recv(_handle, _timeout_ms), do: {:ok, "192.168.1.10:56700", <<0>>}
  end

  defmodule LateTransport do
    @behaviour Transport

    @impl true
    def send(handle, _endpoint, packet) do
      Process.put({__MODULE__, handle}, packet)
      :ok
    end

    @impl true
    def recv(handle, _timeout_ms) do
      Process.sleep(120)

      <<_::binary-size(4), source::little-32, _::binary-size(15), sequence::8, _::binary>> =
        Process.get({__MODULE__, handle})

      target = <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>
      payload = <<1, 56_700::little-32>>

      reply =
        <<41::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
          sequence::8, 0::64, 3::little-16, 0::16, payload::binary>>

      {:ok, "192.168.1.10:56700", reply}
    end
  end

  test "selected-prefix broadcast accepts only matching in-scope service replies" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 25)
    send(self(), {:datagram, "192.168.1.10:49999", service_reply(2, 7, 56_701, 3)})
    send(self(), {:datagram, "192.168.1.127:49999", service_reply(2, 7, 56_700, 3)})
    send(self(), {:datagram, "192.168.1.10:49999", service_reply(2, 7, 56_701, 45)})
    send(self(), {:datagram, "192.168.1.10:49999", service_reply(2, 7, 56_701, 3)})

    assert {:ok, [candidate], window} =
             DiscoveryPath.run("en0", "boot:1", scope, 2, 7,
               transport: {ScriptedTransport, self()},
               clock: fn -> {1_100, 1_000_000} end,
               duration_ms: 1_000
             )

    assert candidate.source_endpoint == "192.168.1.10:56701"
    assert candidate.claimed_identifiers == %{"stable_id" => "lifx:d073d5001337"}
    assert length(WotexHome.Lifx.DiscoveryWindow.candidates(window)) == 1

    assert_receive {:broadcast, "192.168.1.127:56700", packet}
    assert byte_size(packet) == 36
    assert <<36::little-16, frame::little-16, 2::little-32, 0::48, _::binary>> = packet
    assert (frame &&& 0x1000) == 0x1000
    assert <<2::little-16>> == binary_part(packet, 32, 2)
  end

  test "send failure is explicit and exposes no candidate" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)

    assert {:error, :send_failed, window} =
             DiscoveryPath.run("en0", "boot:1", scope, 2, 7,
               transport: {FailingTransport, nil},
               clock: fn -> {1_100, 1_000_000} end,
               duration_ms: 1_000
             )

    assert WotexHome.Lifx.DiscoveryWindow.candidates(window) == []
  end

  test "unrelated datagrams exhaust a finite receive budget" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)

    assert {:error, :datagram_budget_exhausted, window} =
             DiscoveryPath.run("en0", "boot:1", scope, 2, 7,
               transport: {SpamTransport, nil},
               clock: fn -> {1_100, 1_000_000} end,
               duration_ms: 10_000
             )

    assert WotexHome.Lifx.DiscoveryWindow.candidates(window) == []
  end

  test "a transport returning a late service reply cannot add a candidate" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)

    assert {:ok, [], window} =
             DiscoveryPath.run("en0", "boot:1", scope, 2, 7,
               transport: {LateTransport, :late},
               clock: fn -> {1_100, 1_000_000} end,
               duration_ms: 100
             )

    assert WotexHome.Lifx.DiscoveryWindow.candidates(window) == []
  end

  defp service_reply(source, sequence, port, type) do
    payload = if type == 3, do: <<1, port::little-32>>, else: <<>>
    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, @target::binary, 0::16, 0::48, 0::8,
      sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
  end
end
