defmodule WotexHome.CLITest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias WotexHome.CLI
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Server

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "read-only CLI uses a private credential file and returns scoped responses", %{
    directory: directory
  } do
    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))

    assert {:ok, credential, _revision} =
             Store.provision_principal(store, "reader:cli", ["read"], [])

    socket = Path.join(directory, "ipc/home.sock")
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket)

    credential_file = Path.join(directory, "credential")
    File.write!(credential_file, Base.url_encode64(credential, padding: false) <> "\n")
    File.chmod!(credential_file, 0o600)
    flags = ["--socket", socket, "--credential-file", credential_file]

    output =
      capture_io(fn ->
        assert 0 == CLI.main(flags ++ ["health"])
      end)

    assert %{"outcome" => "ok", "health" => %{"dispatch_enabled" => false}} =
             JSON.decode!(output)

    output =
      capture_io(fn ->
        assert 4 == CLI.main(flags ++ ["receipt", "1", "op:missing"])
      end)

    assert %{"outcome" => "not_found"} = JSON.decode!(output)

    File.chmod!(credential_file, 0o644)

    error =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main(flags ++ ["health"])
      end)

    assert error =~ "invalid_credential_file"
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end
end
