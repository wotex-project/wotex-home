defmodule WotexHome.LifxInterviewPathTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Lifx.{InterviewPath, Ledger, Transport}

  defmodule LoopbackTransport do
    @moduledoc false

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
    @moduledoc false

    @behaviour Transport

    @impl true
    def send(_handle, _endpoint, _packet), do: {:error, :send_failed}

    @impl true
    def recv(_handle, _timeout_ms), do: {:error, :timeout}
  end

  defmodule LateTransport do
    @moduledoc false

    @behaviour Transport

    @impl true
    def send(handle, _endpoint, packet) do
      packets = Process.get({__MODULE__, handle}, [])
      Process.put({__MODULE__, handle}, [packet | packets])
      :ok
    end

    @impl true
    def recv(handle, _timeout_ms) do
      count = Process.get({__MODULE__, handle, :count}, 0)
      Process.put({__MODULE__, handle, :count}, count + 1)
      if count == 0, do: Process.sleep(20)
      packets = Process.get({__MODULE__, handle})
      packet = if count == 0, do: Enum.at(packets, 1), else: Enum.at(packets, 0)

      <<_::binary-size(4), source::little-32, target::binary-size(6), _::binary-size(9),
        sequence::8, _::binary>> = packet

      {type, payload} =
        if count == 0,
          do: {33, <<1::little-32, 27::little-32, 0::32>>},
          else: {15, <<1_700_000_000::little-64, 0::64, 60::little-16, 3::little-16>>}

      size = 36 + byte_size(payload)

      reply =
        <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48,
          0::8, sequence::8, 0::64, type::little-16, 0::16, payload::binary>>

      {:ok, handle, reply}
    end
  end

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  test "independent loopback peer returns correlated numeric identity" do
    elixir = System.find_executable("elixir")
    assert is_binary(elixir)
    script = Path.expand("../../test_support/lifx_peer.ex", __DIR__)

    port =
      Port.open({:spawn_executable, elixir}, [:binary, :exit_status, args: [script, "interview"]])

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

  test "malformed option lists fail closed before keyword access" do
    assert {:ok, ledger} = Ledger.new(2)

    assert {:error, :invalid_interview_path, ^ledger} =
             InterviewPath.run(candidate("127.0.0.1:56700"), @target, ledger, [123])
  end

  test "a transport returning replies after its deadline cannot complete an interview" do
    assert {:ok, ledger} = Ledger.new(2)
    endpoint = "127.0.0.1:56700"

    assert {:error, :interview_timeout, issued} =
             InterviewPath.run(candidate(endpoint), @target, ledger,
               transport: {LateTransport, endpoint},
               clock: fn -> {1_100, 1_000_000} end,
               timeout_ms: 1
             )

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
