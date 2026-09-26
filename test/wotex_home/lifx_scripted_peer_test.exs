defmodule WotexHome.LifxScriptedPeerTest do
  use ExUnit.Case

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{Ledger, ReadSession}
  alias WotexHome.Semantics.Thing

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  test "independent loopback peer's GetColor reply becomes a durable reported observation" do
    python = System.find_executable("python3")
    assert is_binary(python)
    script = Path.expand("../support/lifx_read_peer.py", __DIR__)
    port = Port.open({:spawn_executable, python}, [:binary, :exit_status, args: [script]])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    peer_port =
      receive do
        {^port, {:data, data}} -> String.trim(data) |> String.to_integer()
      after
        5_000 -> flunk("scripted peer did not bind")
      end

    assert peer_port in 1..65_535
    endpoint = "127.0.0.1:#{peer_port}"

    assert {:ok, candidate} =
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
                   "evidence_ref" => "fixture:scripted:1",
                   "freshness_ms" => 5_000,
                   "constraints" => %{},
                   "extensions" => %{}
                 }
               ]
             })

    assert {:ok, session} = ReadSession.new(candidate, @target, thing)
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, packet, session, ledger} = ReadSession.issue(session, ledger, 1_000, 2_000)
    assert {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    assert :ok = :gen_udp.send(socket, {127, 0, 0, 1}, peer_port, packet)
    assert {:ok, {{127, 0, 0, 1}, ^peer_port, reply}} = :gen_udp.recv(socket, 0, 2_000)

    metadata = %{
      "source_epoch" => "device:1",
      "source_sequence" => 1,
      "boot_epoch" => "boot:1",
      "received_time_utc_ms" => 1_000_000,
      "received_monotonic_ms" => 1_100
    }

    assert {:ok, [report], _ledger} =
             ReadSession.accept(session, ledger, endpoint, reply, 1_100, metadata)

    assert report.trust == "unauthenticated_local"
    assert report.value.data == true

    directory =
      Path.join(System.tmp_dir!(), "wotex-lifx-peer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))
    assert {:ok, 1} = Store.enroll_thing(store, thing)
    assert {:ok, [2]} = Store.record_batch(store, thing, [report])
    assert {:ok, ^report, 2} = Store.current(store, thing.id, "power")
    :ok = GenServer.stop(store)

    assert_receive {^port, {:exit_status, 0}}, 2_000
  end
end
