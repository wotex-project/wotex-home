defmodule Woh.Tool.HostProcess do
  @moduledoc false

  def start(data_dir) do
    case System.find_executable("mix") do
      nil ->
        {:error, "mix is unavailable"}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["run", "--no-compile", "--no-halt"],
            env: [{~c"WOTEX_HOME_DATA_DIR", String.to_charlist(data_dir)}]
          ])

        {:ok, port}
    end
  end

  def await_socket(port, path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_socket_until(port, path, deadline)
  end

  def stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        await_exit(port, 10_000)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
  end

  defp await_socket_until(port, path, deadline) do
    ready =
      case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 200) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        _ ->
          false
      end

    cond do
      ready ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, "foreground Home socket did not start"}

      true ->
        receive do
          {^port, {:exit_status, status}} ->
            {:error, "foreground Home host exited #{status} before socket startup"}

          {^port, {:data, _}} ->
            await_socket_until(port, path, deadline)
        after
          50 -> await_socket_until(port, path, deadline)
        end
    end
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
end
