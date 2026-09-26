defmodule WotexHome.LifxInterviewPathTest do
  use ExUnit.Case

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Lifx.{InterviewPath, Ledger, Transport}

  defmodule LoopbackTransport do
    @behaviour Transport

    @impl true
    def send(socket, endpoint, packet) do
      [address, port] = String.split(endpoint, ":")
      {:ok, ip} = :inet.parse_ipv4_address(String.to_charlist(address))
      :gen_udp.send(socket, ip, String.to_integer(port), packet)
    end

    @impl true
    def recv(socket, timeout_ms) do
      case :gen_udp.recv(socket, 0, timeout_ms) do
        {:ok, {ip, port, bytes}} -> {:ok, "#{:inet.ntoa(ip)}:#{port}", bytes}
        error -> error
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

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  test "independent loopback peer returns correlated numeric identity" do
    python = System.find_executable("python3")
    assert is_binary(python)
    script = Path.expand("../support/lifx_interview_peer.py", __DIR__)
    port = Port.open({:spawn_executable, python}, [:binary, :exit_status, args: [script]])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    peer_port =
      receive do
        {^port, {:data, data}} -> String.trim(data) |> String.to_integer()
      after
        5_000 -> flunk("scripted peer did not bind")
      end

    endpoint = "127.0.0.1:#{peer_port}"
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)

    assert {:ok, interview, issued} =
             InterviewPath.run(candidate(endpoint), @target, ledger,
               transport: {LoopbackTransport, socket},
               clock: fn -> {1_100, 1_000_000} end,
               timeout_ms: 2_000
             )

    assert interview.manufacturer == "lifx.vendor.1"
    assert interview.model == "lifx.product.27"
    assert interview.firmware == "3.60"
    assert interview.stable_id == "lifx:d073d5001337"
    assert map_size(issued.pending) == 0
    assert_receive {^port, {:exit_status, 0}}, 2_000
  end

  test "uncertain send failure retains both issued correlation keys" do
    assert {:ok, ledger} = Ledger.new(2)

    assert {:error, :send_failed, issued} =
             InterviewPath.run(candidate("127.0.0.1:56700"), @target, ledger,
               transport: {FailingTransport, nil},
               clock: fn -> {1_100, 1_000_000} end,
               timeout_ms: 2_000
             )

    assert ledger.next_sequence == 0
    assert issued.next_sequence == 2
    assert map_size(issued.pending) == 2
  end

  defp candidate(endpoint) do
    {:ok, candidate} =
      Candidate.new(%{
        "interface_id" => "loopback:1",
        "transport" => "udp",
        "source_endpoint" => endpoint,
        "receive_epoch" => "boot:1",
        "received_monotonic_ms" => 100,
        "raw_ref" => "fixture:loopback:1",
        "claimed_identifiers" => %{"stable_id" => "lifx:d073d5001337"},
        "trust_class" => "untrusted_network"
      })

    candidate
  end
end
