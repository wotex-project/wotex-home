defmodule Woh.Tool.ReleaseSmoke do
  @moduledoc false

  import Bitwise

  alias Woh.Tool.{Command, MaudePayload, ReleaseLegal}
  alias WotexHome.LocalAPI.Client

  @max_output 1_048_576
  @check_verifier ~S"""
  if Node.alive?(), do: raise "release unexpectedly enabled distributed Erlang"
  path = ExMaude.Binary.find()
  root = System.fetch_env!("WOTEX_EXPECT_RELEASE_ROOT")
  unless is_binary(path) and String.starts_with?(Path.expand(path), root <> "/") do
    raise "Maude binary is not inside the release"
  end
  rules = [%{id: "r1", thing_id: "light:desk", trigger: {:always},
             actions: [{:set_prop, "light:desk", "power", true}], priority: 1}]
  case ExMaude.IoT.detect_conflicts_with_receipt(rules,
         conflict_types: [:state_conflict], timeout: 5_000) do
    {:ok, %{execution: %{completion: :bounded_complete, findings: []}}} ->
      IO.puts("VERIFIER_OK")
    other ->
      raise "bundled verifier did not complete: #{inspect(other)}"
  end
  """

  def check(release) do
    with {:ok, _payload} <- check_payload(release),
         release = Path.expand(release),
         root = release |> Path.dirname() |> Path.dirname(),
         :ok <- host_check(release, root) do
      {:ok, "release verifier, private host startup, and shutdown passed"}
    end
  end

  @doc "Packaged payload/CLI/verifier checks only; this does not verify the host or socket."
  def check_payload(release) do
    release = Path.expand(release)
    root = release |> Path.dirname() |> Path.dirname()

    with :ok <- regular_file(release, "release executable missing"),
         {:ok, priv} <- maude_private(root),
         :ok <- maude_files(priv),
         :ok <- legal_inputs(root, priv),
         :ok <- cli_check(release),
         :ok <- verifier_check(release, root) do
      {:ok, "packaged legal inputs, CLI and verifier passed; host/socket NOT verified"}
    end
  end

  def host_ready?(socket, database) do
    private?(socket, :socket, 0o600) and private?(database, :regular, 0o600) and
      host_responds?(socket)
  end

  def host_responds?(socket) do
    request = %{
      "api_version" => 1,
      "operation" => "health",
      "credential" => String.duplicate("A", 43)
    }

    Client.request(socket, request, 500) ==
      {:ok, %{"api_version" => 1, "outcome" => "error", "reason" => "unauthorized"}}
  end

  defp regular_file(path, reason) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _ -> {:error, "#{reason}: #{path}"}
    end
  end

  defp maude_private(root) do
    case Path.wildcard(Path.join(root, "lib/ex_maude-*/priv")) do
      [priv] -> {:ok, priv}
      _ -> {:error, "release has no selected arm64 Maude backend"}
    end
  end

  defp maude_files(priv) do
    directory = Path.join(priv, "maude/bin")

    with :ok <-
           regular_file(
             Path.join(directory, "maude-darwin-arm64"),
             "release has no selected arm64 Maude backend"
           ),
         false <-
           Enum.any?(
             ~w(maude/bin/maude-darwin-x64 maude/bin/maude-linux-x64 maude_bridge),
             &File.exists?(Path.join(priv, &1))
           ),
         {:ok, 14} <- MaudePayload.check_directory(directory, true) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "release contains an unusable native backend"}
    end
  end

  defp legal_inputs(root, priv) do
    cond do
      not ReleaseLegal.matches?(Path.join(priv, "maude/COPYING"), ReleaseLegal.maude_license()) ->
        {:error, "release has no exact Maude license text"}

      not ReleaseLegal.matches?(
        Path.join(priv, "maude/THIRD_PARTY_NOTICES.md"),
        ReleaseLegal.maude_notice(),
        4_096
      ) ->
        {:error, "release has no exact Maude third-party notice"}

      not wotex_udp_legal_inputs?(root) ->
        {:error, "release has no exact WoTEx UDP license and notice"}

      true ->
        Enum.reduce_while(~w(db_connection-2.10.2 rustler_precompiled-0.9.0), :ok, fn package,
                                                                                      _ ->
          path = Path.join([root, "lib", package, "priv/LICENSE"])

          if ReleaseLegal.matches?(path, ReleaseLegal.apache_license()),
            do: {:cont, :ok},
            else: {:halt, {:error, "release has no exact Apache license text for #{package}"}}
        end)
    end
  end

  defp wotex_udp_legal_inputs?(root) do
    case Path.wildcard(Path.join(root, "lib/wotex_udp-*/priv")) do
      [priv] ->
        ReleaseLegal.matches?(Path.join(priv, "LICENSE"), ReleaseLegal.wotex_udp_license()) and
          ReleaseLegal.matches?(
            Path.join(priv, "NOTICE"),
            ReleaseLegal.wotex_udp_notice(),
            4_096
          )

      _ ->
        false
    end
  end

  defp cli_check(release) do
    cli = Path.join(Path.dirname(release), "wotex_home_cli")

    with :ok <- regular_file(cli, "packaged Home CLI is missing"),
         {:ok, output} <- Command.run(cli, ["--help"], @max_output, 15_000),
         true <- String.contains?(output, "usage: wotex_home_cli"),
         recovery = Path.join(Path.dirname(release), "wotex_home_recovery"),
         :ok <- regular_file(recovery, "packaged Home recovery command is missing"),
         {:ok, recovery_output} <- Command.run(recovery, ["--help"], @max_output, 15_000),
         true <- String.contains?(recovery_output, "usage: wotex_home_recovery") do
      :ok
    else
      _ -> {:error, "packaged Home CLI did not start"}
    end
  end

  defp verifier_check(release, root) do
    case Command.run(release, ["eval", @check_verifier], @max_output, 15_000, [
           {"WOTEX_EXPECT_RELEASE_ROOT", root}
         ]) do
      {:ok, output} ->
        if String.contains?(output, "VERIFIER_OK"),
          do: :ok,
          else: {:error, "release verifier failed: #{output}"}

      {:error, reason} ->
        {:error, "release verifier failed: #{reason}"}
    end
  end

  defp host_check(release, root) do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-release-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    socket = Path.join(directory, "ipc/home.sock")
    database = Path.join(directory, "home.sqlite")

    try do
      port =
        Port.open({:spawn_executable, release}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["start"],
          env:
            Enum.map(
              [
                {"WOTEX_EXPECT_RELEASE_ROOT", root},
                {"WOTEX_HOME_DATA_DIR", directory}
              ],
              fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end
            )
        ])

      result =
        try do
          deadline = System.monotonic_time(:millisecond) + 60_000

          with {:ok, _log} <- await_host(port, socket, database, deadline, ""),
               true <- private?(directory, :directory, 0o700),
               true <- private?(Path.dirname(socket), :directory, 0o700),
               true <- host_ready?(socket, database) do
            :ok
          else
            {:error, reason} -> {:error, reason}
            false -> {:error, "release host did not become private and ready"}
          end
        after
          terminate_host(port)
        end

      if socket_gone?(socket, 2_000),
        do: result,
        else: {:error, "release shutdown left its socket behind"}
    after
      File.rm_rf!(directory)
    end
  end

  defp await_host(port, socket, database, deadline, log) do
    cond do
      host_ready?(socket, database) ->
        {:ok, log}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error,
         "release host did not become private and ready (#{host_state(socket, database)}): " <>
           String.slice(log, 0, 4_096)}

      true ->
        receive do
          {^port, {:data, bytes}} ->
            updated =
              if byte_size(log) + byte_size(bytes) <= @max_output, do: log <> bytes, else: log

            await_host(port, socket, database, deadline, updated)

          {^port, {:exit_status, status}} ->
            {:error, "release host exited #{status}: #{String.slice(log, 0, 4_096)}"}
        after
          100 -> await_host(port, socket, database, deadline, log)
        end
    end
  end

  defp terminate_host(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        await_exit(port, 10_000)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
  end

  defp await_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> await_exit(port, timeout_ms)
    after
      timeout_ms ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} ->
            System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

          _ ->
            :ok
        end
    end
  end

  defp socket_gone?(socket, remaining_ms) when remaining_ms <= 0, do: not File.exists?(socket)

  defp socket_gone?(socket, remaining_ms) do
    if File.exists?(socket) do
      Process.sleep(100)
      socket_gone?(socket, remaining_ms - 100)
    else
      true
    end
  end

  defp private?(path, type, mode) do
    case File.lstat(path) do
      {:ok, info} ->
        type_match =
          case type do
            :socket -> info.type == :other and (info.mode &&& 0o170000) == 0o140000
            other -> info.type == other
          end

        type_match and (info.mode &&& 0o777) == mode

      _ ->
        false
    end
  end

  defp host_state(socket, database) do
    Enum.map_join([socket: socket, database: database], ", ", fn {name, path} ->
      case File.lstat(path) do
        {:ok, info} -> "#{name}=#{info.type} mode=#{Integer.to_string(info.mode &&& 0o777, 8)}"
        _ -> "#{name}=missing"
      end
    end)
  end
end

defmodule Mix.Tasks.Woh.Release.Smoke do
  @moduledoc """
  Smoke-tests an assembled local OTP release on the build host.

  Run `mix woh.release.smoke PATH_TO_RELEASE_BIN` after `mix release`. The task
  checks the pinned Maude and legal bytes, exercises the bundled verifier,
  starts the private host and confirms its socket and database modes before
  shutdown. This does not qualify a clean-machine install or a physical device.
  """

  @shortdoc "Smoke-test an assembled Home release"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([release]) do
    case Woh.Tool.ReleaseSmoke.check(release) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, reason} -> Mix.raise("release smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.release.smoke PATH_TO_RELEASE_BIN")
end
