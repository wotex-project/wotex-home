defmodule WotexHome.LocalAPIPeerIdentityTest do
  use ExUnit.Case

  alias WotexHome.LocalAPI.PeerIdentity

  test "kernel peer UID matches the socket owner and rejects a different UID" do
    directory =
      Path.join(System.tmp_dir!(), "wotex-peer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "peer.sock")

    assert {:ok, listener} =
             :gen_tcp.listen(0, [
               :binary,
               {:ifaddr, {:local, String.to_charlist(path)}},
               {:active, false}
             ])

    client =
      Task.async(fn ->
        :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary], 1_000)
      end)

    assert {:ok, server_socket} = :gen_tcp.accept(listener, 1_000)
    assert {:ok, client_socket} = Task.await(client)
    assert {:ok, stat} = File.lstat(path)
    assert {:ok, stat.uid} == PeerIdentity.effective_uid(server_socket)
    assert :ok == PeerIdentity.verify(server_socket, stat.uid)
    assert {:error, :wrong_peer} == PeerIdentity.verify(server_socket, stat.uid + 1)

    :ok = :gen_tcp.close(client_socket)
    :ok = :gen_tcp.close(server_socket)
    :ok = :gen_tcp.close(listener)
  end
end
