defmodule Woh.Tool.Command do
  @moduledoc false

  def run(executable, args, max_bytes, timeout_ms) do
    case System.find_executable(executable) do
      nil -> {:error, "#{executable} is unavailable"}
      path -> run_path(path, args, max_bytes, timeout_ms)
    end
  end

  defp run_path(path, args, max_bytes, timeout_ms) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, [], 0, max_bytes, deadline)
  end

  defp collect(port, chunks, size, max_bytes, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= max_bytes ->
        collect(port, [data | chunks], size + byte_size(data), max_bytes, deadline)

      {^port, {:data, _data}} ->
        Port.close(port)
        {:error, "tool output exceeds development bound"}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, "tool exited with status #{status}"}
    after
      remaining ->
        Port.close(port)
        {:error, "tool timed out"}
    end
  end
end
