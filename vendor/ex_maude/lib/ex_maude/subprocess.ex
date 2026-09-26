defmodule ExMaude.Subprocess do
  @moduledoc false

  @doc false
  @spec run(Path.t(), [String.t()], pos_integer(), pos_integer()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def run(executable, args, timeout, max_bytes) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: args
      ])

    try do
      collect(port, System.monotonic_time(:millisecond) + timeout, max_bytes, [], 0)
    after
      stop(port)
    end
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp collect(port, deadline, limit, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= limit ->
        collect(port, deadline, limit, [data | chunks], size + byte_size(data))

      {^port, {:data, _}} ->
        {:error, :output_too_large}

      {^port, {:exit_status, status}} ->
        output =
          chunks
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:ok, output, status}
    after
      remaining -> {:error, :timeout}
    end
  end

  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        Port.close(port)

        case :os.type() do
          {:win32, _} -> System.cmd("taskkill", ["/F", "/PID", Integer.to_string(pid)])
          _ -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
