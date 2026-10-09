defmodule WotexHome.LinuxInstallMaintenanceTest do
  @moduledoc false
  use ExUnit.Case

  alias Woh.Tool.LinuxInstallMaintenance

  test "closed maintenance results bind original identity and retain uncertainty" do
    request = %{
      "operation" => "begin_maintenance",
      "authority_epoch" => 1,
      "operation_id" => "update:original",
      "expected_revision" => 4
    }

    receipt = %{
      "principal_id" => "maintainer:fixture",
      "authority_epoch" => 1,
      "operation_id" => "update:original",
      "action" => "begin",
      "begin_revision" => 7,
      "revision" => 7,
      "rule_generation" => 1,
      "affected_requests" => 2,
      "unknown_outcomes" => 1,
      "state" => "maintenance"
    }

    response = %{"api_version" => 1, "outcome" => "ok", "maintenance_receipt" => receipt}
    assert {:ok, ^receipt} = LinuxInstallMaintenance.decode_response(response, request)

    for change <- [
          %{"authority_epoch" => 2},
          %{"operation_id" => "update:replacement"},
          %{"action" => "end"},
          %{"begin_revision" => 6},
          %{"revision" => 4},
          %{"unknown_outcomes" => 3},
          %{"rule_generation" => 0},
          %{"affected_requests" => 9_223_372_036_854_775_808},
          %{"credential" => "private fixture canary"}
        ] do
      changed = %{response | "maintenance_receipt" => Map.merge(receipt, change)}

      assert {:error, :invalid_maintenance_response} =
               LinuxInstallMaintenance.decode_response(changed, request)
    end

    status = %{
      "authority_epoch" => 1,
      "store_revision" => 9,
      "rule_generation" => 1,
      "begin_revision" => 7,
      "state" => "maintenance"
    }

    response = %{"api_version" => 1, "outcome" => "ok", "maintenance_status" => status}

    assert {:ok, ^status} =
             LinuxInstallMaintenance.decode_response(response, %{
               "operation" => "maintenance_status"
             })

    for change <- [%{"state" => "normal"}, %{"begin_revision" => 10}, %{"state" => "ready"}] do
      assert {:error, :invalid_maintenance_response} =
               LinuxInstallMaintenance.decode_response(
                 %{response | "maintenance_status" => Map.merge(status, change)},
                 %{"operation" => "maintenance_status"}
               )
    end

    update =
      Map.merge(status, %{
        "principal_id" => "maintainer:fixture",
        "store_schema_version" => 27,
        "writable" => true,
        "update_fence_enabled" => true
      })

    response = %{"api_version" => 1, "outcome" => "ok", "maintenance_update_status" => update}
    request = %{"operation" => "maintenance_update_status"}
    assert {:ok, ^update} = LinuxInstallMaintenance.decode_response(response, request)

    for change <- [
          %{"store_schema_version" => 0},
          %{"principal_id" => "bad id"},
          %{"writable" => "true"},
          %{"update_fence_enabled" => 1},
          %{"credential" => "private fixture"}
        ] do
      assert {:error, :invalid_maintenance_response} =
               LinuxInstallMaintenance.decode_response(
                 %{response | "maintenance_update_status" => Map.merge(update, change)},
                 request
               )
    end
  end

  test "bridge refuses arbitrary commands, maintenance end and invalid inputs before execution" do
    credential = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)

    for {uid, socket, command, encoded} <- [
          {0, "/private/home.sock", ["maintenance-status"], credential},
          {1000, "/private/home.sock", ["maintenance-status"], credential},
          {211, "/private/../home.sock", ["maintenance-status"], credential},
          {211, "/private/home.sock", ["maintenance-end", "1", "end:1", "7", "7"], credential},
          {211, "/private/home.sock", ["health"], credential},
          {211, "/private/home.sock", ["maintenance-status"], "invalid"}
        ] do
      assert {:error, :invalid_maintenance_client_input} =
               LinuxInstallMaintenance.request(uid, socket, command, encoded, "/missing-tool")
    end
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    alias Woh.Tool.{Command, LinuxInstallFiles}
    alias WotexHome.LocalAPI.Client
    @tool Path.expand("../native/linux/installer-files", __DIR__)

    test "native flat request guards reject malformed frames before opening a socket" do
      root = Path.join(System.tmp_dir!(), "woh-flat-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      File.chmod!(root, 0o755)
      state = Path.join(root, "state")
      assert :ok = LinuxInstallFiles.mkdir(state, 0o700, 211, 211, @tool)
      path = Path.join(state, "trap.sock")

      assert {:ok, listener} =
               :gen_tcp.listen(0, [
                 :binary,
                 active: false,
                 ifaddr: {:local, String.to_charlist(path)}
               ])

      File.chmod!(path, 0o600)
      File.chown!(path, 211)

      on_exit(fn ->
        :gen_tcp.close(listener)
        File.rm_rf!(root)
      end)

      credential = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)

      valid =
        JSON.encode!(%{
          "api_version" => 1,
          "operation" => "maintenance_status",
          "credential" => credential
        })

      invalid = [
        String.replace(valid, "\"api_version\":1", "\"api_version\":\"1\""),
        String.replace(valid, "\"api_version\":1", "\"api_version\":true"),
        String.replace(valid, "\"api_version\":1", "\"api_version\":1.0"),
        String.replace(valid, "\"api_version\":1", "\"api_version\":01"),
        String.replace(valid, "\"api_version\":1", "\"api_version\":1e0"),
        String.replace(valid, "maintenance_status", "end_maintenance"),
        String.replace(valid, "maintenance_status", "maintenance\\u005fstatus"),
        String.replace(valid, credential, String.duplicate("A", 42) <> "B"),
        String.replace(valid, "{", "{\"api_version\":1,"),
        String.trim_trailing(valid, "}") <> ",\"extra\":0}",
        String.trim_trailing(valid, "}") <> ",}",
        valid <> "{}",
        "[]",
        "{\"api_version\":{\"value\":1}}",
        JSON.encode!(%{
          "api_version" => 1,
          "operation" => "begin_maintenance",
          "credential" => credential,
          "authority_epoch" => 0,
          "operation_id" => "update:1",
          "expected_revision" => 1
        }),
        JSON.encode!(%{
          "api_version" => 1,
          "operation" => "begin_maintenance",
          "credential" => credential,
          "authority_epoch" => 1,
          "operation_id" => "update:1",
          "expected_revision" => "1"
        }),
        JSON.encode!(%{
          "api_version" => 1,
          "operation" => "begin_maintenance",
          "credential" => credential,
          "authority_epoch" => 1,
          "operation_id" => "update:1",
          "expected_revision" => 9_223_372_036_854_775_808
        })
      ]

      for body <- invalid do
        frame = <<byte_size(body)::32, body::binary>>
        assert {:error, _} = LinuxInstallFiles.maintenance(211, path, frame, @tool)
        assert {:error, :timeout} = :gen_tcp.accept(listener, 20)
      end

      # A valid generated request reaches the trap, where kernel peer UID 0
      # still refuses before transmitting any bearer bytes.
      frame = <<byte_size(valid)::32, valid::binary>>
      assert {:error, _} = LinuxInstallFiles.maintenance(211, path, frame, @tool)
      assert {:ok, peer} = :gen_tcp.accept(listener, 1000)
      assert {:error, :closed} = :gen_tcp.recv(peer, 1, 1000)
      :gen_tcp.close(peer)
    end

    setup context do
      if context[:requires_socket], do: fixture!(), else: :ok
    end

    defp fixture! do
      root = Path.join(System.tmp_dir!(), "woh-maint-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      File.chmod!(root, 0o755)
      state = Path.join(root, "state")
      assert :ok = LinuxInstallFiles.mkdir(state, 0o700, 211, 211, @tool)
      code = Path.join(root, "wotex_home")
      File.mkdir!(code)
      File.chmod!(code, 0o755)
      File.cp_r!(Path.join(Application.app_dir(:wotex_home), "ebin"), Path.join(code, "ebin"))
      File.chmod!(Path.join(code, "ebin"), 0o755)
      Enum.each(Path.wildcard(Path.join(code, "ebin/*")), &File.chmod!(&1, 0o644))
      File.ln_s!(Path.expand("../priv", __DIR__), Path.join(code, "priv"))

      dependencies =
        Path.wildcard(Path.expand("../_build/test/lib/*/ebin", __DIR__))
        |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "wotex_home"))

      script = Path.join(root, "server.exs")

      # Only synthetic fixture credentials exist in this private service-owned
      # directory. They are never printed or supplied in process arguments.
      File.write!(script, """
      Code.prepend_paths(#{inspect(dependencies)})
      Code.prepend_path(#{inspect(Path.join(code, "ebin"))})
      Application.ensure_all_started(:crypto)
      Application.ensure_all_started(:exqlite)
      {:ok, store} = WotexHome.Durable.Store.start_link(path: #{inspect(Path.join(state, "home.sqlite"))})
      authority = WotexHome.Authority.new(store: store)
      credential_path = #{inspect(Path.join(state, "credential"))}
      unless File.exists?(credential_path) do
        {:ok, credential, _} = WotexHome.Authority.provision_maintenance(authority)
        File.write!(credential_path, Base.url_encode64(credential, padding: false))
        File.chmod!(credential_path, 0o600)
      end
      {:ok, _} = WotexHome.LocalAPI.Server.start_link(authority: authority, socket_path: #{inspect(Path.join(state, "home.sock"))})
      IO.puts("FIXTURE_READY")
      Process.sleep(:infinity)
      """)

      File.chmod!(script, 0o644)

      port = start_server!(script)

      on_exit(fn ->
        stop_server(port)
        File.rm_rf!(root)
      end)

      %{root: root, state: state, port: port, script: script}
    end

    test "identity drop clears supplementary groups and parent death kills the waiting client" do
      port =
        Port.open({:spawn_executable, @tool}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "maintenance",
            "--lock-owner",
            System.pid(),
            System.fetch_env!("WOTEX_HOME_INSTALL_LOCK_FD"),
            System.fetch_env!("WOTEX_HOME_INSTALL_LOCK_PATH"),
            "211",
            "/private/home.sock",
            "64"
          ]
        ])

      {:os_pid, parent} = :erlang.port_info(port, :os_pid)

      on_exit(fn ->
        case :erlang.port_info(port, :os_pid) do
          {:os_pid, ^parent} ->
            System.cmd("/bin/kill", ["-KILL", to_string(parent)], stderr_to_stdout: true)

          _ ->
            :ok
        end
      end)

      child = await_child!(parent, 100)
      status = File.read!("/proc/#{child}/status")
      assert Regex.match?(~r/^Uid:\s+211\s+211\s+211\s+211$/m, status)
      assert Regex.match?(~r/^Gid:\s+211\s+211\s+211\s+211$/m, status)
      assert Regex.match?(~r/^Groups:[ \t]*$/m, status)
      assert Regex.match?(~r/^CapEff:\s+0000000000000000$/m, status)
      System.cmd("/bin/kill", ["-KILL", to_string(parent)], stderr_to_stdout: true)
      assert_dead!(child, 100)
    end

    defp await_child!(parent, attempts) when attempts > 0 do
      children = File.read!("/proc/#{parent}/task/#{parent}/children") |> String.split()

      case children do
        [child] ->
          # The helper first runs short-lived setup children such as uname.
          # A listed child may exit before its status is read; only the actual
          # waiting, privilege-dropped client satisfies this bounded probe.
          case File.read("/proc/#{child}/status") do
            {:ok, status} ->
              if Regex.match?(~r/^Uid:\s+211\s+211\s+211\s+211$/m, status) do
                child
              else
                Process.sleep(10)
                await_child!(parent, attempts - 1)
              end

            {:error, :enoent} ->
              Process.sleep(10)
              await_child!(parent, attempts - 1)

            _ ->
              flunk("maintenance child metadata unavailable")
          end

        [] ->
          Process.sleep(10)
          await_child!(parent, attempts - 1)
      end
    end

    defp await_child!(_, 0), do: flunk("maintenance child identity drop was not observed")

    defp assert_dead!(child, attempts) when attempts > 0 do
      case File.read("/proc/#{child}/status") do
        {:error, :enoent} ->
          :ok

        {:ok, status} ->
          if Regex.match?(~r/^State:\s+Z /m, status) do
            :ok
          else
            Process.sleep(10)
            assert_dead!(child, attempts - 1)
          end
      end
    end

    defp assert_dead!(_, 0), do: flunk("maintenance child survived its retaining parent")

    @tag :requires_socket
    test "service-UID bridge authenticates an actual Store, resolves lost begin and retains restart barrier",
         c do
      socket = Path.join(c.state, "home.sock")
      credential = File.read!(Path.join(c.state, "credential"))
      command = ["maintenance-begin", "1", "update:original", "1"]

      # Root itself is refused by the existing server peer guard.
      {:ok, request} = WotexHome.CLI.build_request(["maintenance-status"], credential)
      assert {:error, _} = Client.request(socket, request)

      assert {:ok, %{"state" => "normal", "store_revision" => 1}} =
               LinuxInstallMaintenance.request(
                 211,
                 socket,
                 ["maintenance-status"],
                 credential,
                 @tool
               )

      assert {:ok,
              %{
                "store_schema_version" => 27,
                "principal_id" => "maintenance:local",
                "writable" => true,
                "update_fence_enabled" => false
              }, peer_pid} =
               LinuxInstallMaintenance.request_peer(
                 211,
                 socket,
                 ["maintenance-update-status"],
                 credential,
                 @tool
               )

      assert peer_pid == c.port.pid

      assert {:error, {:maintenance_refused, "unauthorized"}} =
               LinuxInstallMaintenance.request(
                 211,
                 socket,
                 ["maintenance-status"],
                 Base.url_encode64(:binary.copy(<<7>>, 32), padding: false),
                 @tool
               )

      assert {:ok, original} =
               LinuxInstallMaintenance.request(211, socket, command, credential, @tool)

      # Treat the begin reply as lost; look up and retry only its original ID.
      assert {:ok, ^original} =
               LinuxInstallMaintenance.request(
                 211,
                 socket,
                 ["maintenance-operation-status", "1", "update:original"],
                 credential,
                 @tool
               )

      assert {:ok, ^original} =
               LinuxInstallMaintenance.request(211, socket, command, credential, @tool)

      assert :not_found =
               LinuxInstallMaintenance.request(
                 211,
                 socket,
                 ["maintenance-operation-status", "1", "update:other"],
                 credential,
                 @tool
               )

      stop_server(c.port)
      port = start_server!(c.script)
      on_exit(fn -> stop_server(port) end)

      assert {:ok, %{"state" => "maintenance", "begin_revision" => begin_revision}} =
               LinuxInstallMaintenance.request(
                 211,
                 socket,
                 ["maintenance-status"],
                 credential,
                 @tool
               )

      assert begin_revision == original["begin_revision"]

      assert {:ok, ^original} =
               LinuxInstallMaintenance.request(211, socket, command, credential, @tool)

      assert {:error, {:maintenance_refused, "maintenance_operation_conflict"}} =
               LinuxInstallMaintenance.request(
                 211,
                 socket,
                 ["maintenance-begin", "1", "update:original", "2"],
                 credential,
                 @tool
               )
    end

    @tag :requires_socket
    test "wrong UID and linked socket parents refuse, and an unlocked helper cannot connect", c do
      socket = Path.join(c.state, "home.sock")
      credential = File.read!(Path.join(c.state, "credential"))

      assert {:error, :maintenance_client_unavailable} =
               LinuxInstallMaintenance.request(
                 212,
                 socket,
                 ["maintenance-status"],
                 credential,
                 @tool
               )

      linked = Path.join(c.root, "linked")
      File.ln_s!(c.state, linked)

      assert {:error, :maintenance_client_unavailable} =
               LinuxInstallMaintenance.request(
                 211,
                 Path.join(linked, "home.sock"),
                 ["maintenance-status"],
                 credential,
                 @tool
               )

      {:ok, request} = WotexHome.CLI.build_request(["maintenance-status"], credential)
      {:ok, frame} = WotexHome.LocalAPI.Frame.encode_request(request)

      assert {:error, _} =
               Command.run(
                 @tool,
                 ["maintenance", "211", socket, to_string(byte_size(frame))],
                 4096,
                 5000,
                 [],
                 frame
               )

      substituted = Path.join(c.state, "substituted.sock")

      assert {:ok, listener} =
               :gen_tcp.listen(0, [
                 :binary,
                 {:active, false},
                 {:ifaddr, {:local, String.to_charlist(substituted)}}
               ])

      File.chmod!(substituted, 0o600)
      File.chown!(substituted, 211)
      on_exit(fn -> :gen_tcp.close(listener) end)

      # Filesystem metadata agrees, but the actual listening peer is root.
      # Refusal precedes transmitting credential-bearing bytes.
      assert {:error, :maintenance_client_unavailable} =
               LinuxInstallMaintenance.request(
                 211,
                 substituted,
                 ["maintenance-status"],
                 credential,
                 @tool
               )

      assert {:ok, connected} = :gen_tcp.accept(listener, 1000)
      assert {:error, :closed} = :gen_tcp.recv(connected, 1, 1000)
      :gen_tcp.close(connected)
    end

    defp start_server!(script) do
      port =
        Port.open({:spawn_executable, System.find_executable("setpriv")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "--reuid=211",
            "--regid=211",
            "--clear-groups",
            "--no-new-privs",
            System.find_executable("elixir"),
            script
          ],
          env: [{~c"ERL_FLAGS", ~c"+S 2:2 +SDcpu 1 +SDio 1"}, {~c"ERL_CRASH_DUMP", ~c"/dev/null"}]
        ])

      {:os_pid, pid} = :erlang.port_info(port, :os_pid)
      server = %{port: port, pid: pid, script: script}
      ready!(server, "", System.monotonic_time(:millisecond) + 15_000)
      server
    end

    defp ready!(%{port: port} = server, bytes, deadline) do
      receive do
        {^port, {:data, next}} ->
          bytes = bytes <> next

          if String.contains?(bytes, "FIXTURE_READY\n"),
            do: :ok,
            else: ready!(server, bytes, deadline)

        {^port, {:exit_status, status}} ->
          flunk("private fixture server failed (#{status}): #{bytes}")
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          stop_server(server)
          flunk("private fixture server startup timed out")
      end
    end

    defp stop_server(%{port: port, pid: pid, script: script}) do
      case File.read("/proc/#{pid}/cmdline") do
        {:ok, command} ->
          if :binary.match(command, script <> <<0>>) != :nomatch,
            do: System.cmd("/bin/kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)

          receive do
            {^port, {:exit_status, _}} -> :ok
          after
            1000 -> :ok
          end

        _ ->
          :ok
      end
    rescue
      ArgumentError -> :ok
    end
  end
end
