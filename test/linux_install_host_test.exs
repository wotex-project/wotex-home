defmodule WotexHome.LinuxInstallHostTest do
  use ExUnit.Case, async: true
  alias Woh.Tool.LinuxInstallHost

  test "local and NSS account occupancy cannot be adopted" do
    lookup = fn database, id ->
      send(self(), {database, id})
      {:ok, if(id == "102", do: :present, else: :absent)}
    end

    assert {:ok, 103} =
             LinuxInstallHost.choose_account_id(
               "existing:x:100:100::/:/usr/sbin/nologin\n",
               "existing:x:101:\n",
               lookup
             )

    assert_received {"passwd", "102"}
    assert_received {"group", "102"}
    assert_received {"passwd", "103"}
    assert_received {"group", "103"}
    refute_received {_, "100"}
    refute_received {_, "101"}
  end

  test "resolver failures stop before a second identity lookup" do
    lookup = fn database, id ->
      send(self(), {database, id})
      {:error, "private fixture timeout"}
    end

    assert {:error, "system account resolver unavailable"} =
             LinuxInstallHost.choose_account_id("", "", lookup)

    assert_received {"passwd", "100"}
    refute_received {_, _}
  end

  test "an occupied remote namespace has a finite query budget" do
    lookup = fn database, id ->
      send(self(), {database, id})
      {:ok, :present}
    end

    assert {:error, _} = LinuxInstallHost.choose_account_id("", "", lookup)

    for id <- 100..115, database <- ["passwd", "group"] do
      name = to_string(id)
      assert_received {^database, ^name}
    end

    refute_received {_, _}
  end

  test "effective units request empty properties and reject malformed or shadowed fragments" do
    fragments = %{
      "wotex-home.service" => {"/etc/systemd/system/wotex-home.service", ""},
      "run-wotexhomejournal.mount" => {"/etc/systemd/system/run-wotexhomejournal.mount", ""},
      "systemd-journald@wotex-home.service" =>
        {"/usr/lib/systemd/system/systemd-journald@.service",
         "/etc/systemd/system/systemd-journald@wotex-home.service.d/home-budget.conf"}
    }

    query = fn path, args, bound, deadline ->
      assert path == "/usr/bin/systemctl" and bound == 8192 and deadline == 5000
      assert "--all" in args
      {fragment, dropin} = Map.fetch!(fragments, List.last(args))
      {:ok, "DropInPaths=#{dropin}\nFragmentPath=#{fragment}\n"}
    end

    assert :ok = LinuxInstallHost.effective_units(query)

    for output <- [
          "FragmentPath=/etc/systemd/system/wotex-home.service\n",
          "FragmentPath=/etc/systemd/system/wotex-home.service\nDropInPaths=\nDropInPaths=\n",
          "FragmentPath=/etc/systemd/system/wotex-home.service\nDropInPaths=/foreign.conf\n",
          "FragmentPath=/foreign.service\nDropInPaths=\n",
          "malformed\nDropInPaths=\n",
          "FragmentPath=/etc/systemd/system/wotex-home.service\nDropInPaths=\nExtra=expanded\n"
        ] do
      assert {:error, _} = LinuxInstallHost.effective_units(fn _, _, _, _ -> {:ok, output} end)
    end
  end

  test "controller status accepts only loaded owned stable process states" do
    assert {:ok, %{state: :running, pid: 42}} =
             LinuxInstallHost.decode_controller_status(status("active", "running", "42"))

    assert {:ok, %{state: :stopped, pid: 0}} =
             LinuxInstallHost.decode_controller_status(status("inactive", "dead", "0"))

    running = status("active", "running", "42")

    for output <- [
          status("inactive", "dead", "42"),
          status("active", "running", "0"),
          status("activating", "start", "42"),
          status("deactivating", "stop", "42"),
          status("failed", "failed", "0"),
          String.replace(running, "LoadState=loaded", "LoadState=not-found"),
          String.replace(running, "ControlPID=0", "ControlPID=43"),
          String.replace(running, "DropInPaths=\n", "DropInPaths=/foreign.conf\n"),
          String.replace(
            running,
            "FragmentPath=/etc/systemd/system/wotex-home.service",
            "FragmentPath=/foreign"
          ),
          running <> "MainPID=42\n",
          String.replace(running, "DropInPaths=\n", ""),
          String.trim_trailing(running, "\n"),
          String.duplicate("x", 8193)
        ] do
      assert {:error, _} = LinuxInstallHost.decode_controller_status(output)
    end

    for pid <- ["1", "00", "042", "+42", "-42", "4.2", "true", "2147483648", " 42"] do
      assert {:error, _} =
               LinuxInstallHost.decode_controller_status(status("active", "running", pid))
    end
  end

  test "stop requires the original main PID and a separate stopped observation" do
    query =
      query([{:ok, status("active", "running", "42")}, {:ok, status("inactive", "dead", "0")}])

    assert :ok = LinuxInstallHost.stop_controller(42, query: query, change: change())
    assert_received {:change, "/usr/bin/systemctl", ["--system", "stop", "wotex-home.service"]}
    refute_received {:change, _, _}

    for output <- [status("active", "running", "43"), status("failed", "failed", "0")] do
      assert {:error, _} =
               LinuxInstallHost.stop_controller(42,
                 query: query([{:ok, output}]),
                 change: change()
               )

      refute_received {:change, _, _}
    end

    assert :ok =
             LinuxInstallHost.stop_controller(42,
               query: query([{:ok, status("inactive", "dead", "0")}]),
               change: change()
             )

    refute_received {:change, _, _}
    assert {:error, _} = LinuxInstallHost.stop_controller(0, query: query([]), change: change())
  end

  test "uncertain stop never reports completion or tries another command" do
    query =
      query([{:ok, status("active", "running", "42")}, {:ok, status("active", "running", "43")}])

    assert {:error, "Home controller stop unconfirmed"} =
             LinuxInstallHost.stop_controller(42, query: query, change: change())

    assert_received {:change, _, ["--system", "stop", "wotex-home.service"]}
    refute_received {:change, _, _}

    assert {:error, "Home controller stop unconfirmed"} =
             LinuxInstallHost.stop_controller(42,
               query: query([{:ok, status("active", "running", "42")}]),
               change: fn _, _ -> {:error, "private fixture diagnostic"} end
             )
  end

  test "start requires a stopped owned service and preserves enablement and restart limits" do
    query =
      query([{:ok, status("inactive", "dead", "0")}, {:ok, status("active", "running", "43")}])

    assert {:ok, 43} = LinuxInstallHost.start_controller(query: query, change: change())
    assert_received {:change, "/usr/bin/systemctl", ["--system", "start", "wotex-home.service"]}
    refute_received {:change, _, _}

    for output <- [status("active", "running", "42"), status("failed", "failed", "0")] do
      assert {:error, "Home controller start unconfirmed"} =
               LinuxInstallHost.start_controller(query: query([{:ok, output}]), change: change())

      refute_received {:change, _, _}
    end
  end

  test "a lost start result remains uncertain and cannot cause a fallback start" do
    query =
      query([{:ok, status("inactive", "dead", "0")}, {:error, "private fixture diagnostic"}])

    assert {:error, "Home controller start unconfirmed"} =
             LinuxInstallHost.start_controller(query: query, change: change())

    assert_received {:change, _, ["--system", "start", "wotex-home.service"]}
    refute_received {:change, _, _}

    assert {:error, _} =
             LinuxInstallHost.start_controller(
               query: query([{:ok, status("active", "running", "43")}]),
               change: change()
             )

    refute_received {:change, _, _}
  end

  defp status(active, substate, pid),
    do:
      "LoadState=loaded\nActiveState=#{active}\nSubState=#{substate}\nMainPID=#{pid}\nControlPID=0\nFragmentPath=/etc/systemd/system/wotex-home.service\nDropInPaths=\n"

  defp query(outputs) do
    key = make_ref()
    Process.put(key, outputs)

    fn path, args, bound, deadline ->
      assert path == "/usr/bin/systemctl" and bound == 4096 and deadline == 5000
      assert "--all" in args and List.last(args) == "wotex-home.service"
      assert [output | remaining] = Process.get(key)
      Process.put(key, remaining)
      output
    end
  end

  defp change do
    fn path, args ->
      send(self(), {:change, path, args})
      :ok
    end
  end
end
