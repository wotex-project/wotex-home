defmodule WotexHome.HostTest do
  use ExUnit.Case
  import Bitwise

  alias WotexHome.Host
  alias WotexHome.Durable.Store

  setup do
    root = Path.join(System.tmp_dir!(), "wotex-home-host-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "opt-in host owns a private store and local socket lifecycle", %{root: root} do
    data_dir = Path.join(root, "home")
    assert {:ok, host} = Host.start_link(data_dir: data_dir)
    assert is_pid(Host.store())
    assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())

    assert {:ok, data_stat} = File.stat(data_dir)
    assert (data_stat.mode &&& 0o777) == 0o700
    assert {:ok, db_stat} = File.stat(Path.join(data_dir, "home.sqlite"))
    assert (db_stat.mode &&& 0o777) == 0o600
    assert File.exists?(Path.join(data_dir, "ipc/home.sock"))

    :ok = Supervisor.stop(host)
    assert Host.store() == nil
    refute File.exists?(Path.join(data_dir, "ipc/home.sock"))
  end

  test "host rejects an existing nonprivate data directory", %{root: root} do
    data_dir = Path.join(root, "public")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o755)
    Process.flag(:trap_exit, true)
    assert {:error, :invalid_host_directory} = Host.start_link(data_dir: data_dir)
  end

  test "store crash restarts the owned store and socket together", %{root: root} do
    data_dir = Path.join(root, "home")
    assert {:ok, host} = Host.start_link(data_dir: data_dir)
    first_store = Host.store()
    assert is_pid(first_store)
    Process.exit(first_store, :kill)

    assert_eventually(fn ->
      restarted = Host.store()

      is_pid(restarted) and restarted != first_store and
        match?({:ok, _}, Store.health(restarted)) and
        File.exists?(Path.join(data_dir, "ipc/home.sock"))
    end)

    :ok = Supervisor.stop(host)
  end

  defp assert_eventually(predicate, attempts \\ 40)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
