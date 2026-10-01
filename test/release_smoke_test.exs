defmodule WotexHome.ReleaseSmokeTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.ReleaseSmoke

  test "payload-only check does not report a missing release as a host pass" do
    path =
      Path.join(System.tmp_dir!(), "woh-missing-#{System.unique_integer([:positive])}/bin/home")

    assert {:error, _} = ReleaseSmoke.check_payload(path)
    assert {:error, _} = ReleaseSmoke.check(path)
  end

  @tag requires_socket: true
  test "readiness requires private endpoint and database modes" do
    {directory, path, listener} = listen()
    database = Path.join(directory, "home.sqlite")
    File.write!(database, "sqlite")
    File.chmod!(database, 0o600)

    File.chmod!(path, 0o755)
    refute ReleaseSmoke.host_ready?(path, database)

    File.chmod!(path, 0o600)
    refute ReleaseSmoke.host_ready?(path, database)

    File.chmod!(database, 0o644)
    refute ReleaseSmoke.host_ready?(path, database)

    :ok = :gen_tcp.close(listener)
  end

  @tag requires_socket: true
  test "health probe reads a fragmented framed unauthorized response" do
    {_directory, path, listener} = listen()
    File.chmod!(path, 0o600)

    server =
      Task.async(fn ->
        {:ok, peer} = :gen_tcp.accept(listener, 2_000)
        {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(peer, 4, 2_000)
        {:ok, payload} = :gen_tcp.recv(peer, size, 2_000)
        assert %{"operation" => "health"} = JSON.decode!(payload)

        body =
          JSON.encode!(%{
            "api_version" => 1,
            "outcome" => "error",
            "reason" => "unauthorized"
          })

        frame = <<byte_size(body)::unsigned-big-32, body::binary>>
        <<first::binary-size(2), rest::binary>> = frame
        :ok = :gen_tcp.send(peer, first)
        Process.sleep(10)
        :ok = :gen_tcp.send(peer, rest)
        :gen_tcp.close(peer)
      end)

    assert ReleaseSmoke.host_responds?(path)
    Task.await(server, 2_000)
    :ok = :gen_tcp.close(listener)
  end

  defp listen do
    directory =
      Path.join(System.tmp_dir!(), "wotex-release-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    {directory, path, listener}
  end
end
