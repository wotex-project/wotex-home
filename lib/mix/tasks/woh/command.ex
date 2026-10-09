defmodule Woh.Tool.Command do
  @moduledoc false

  def run(executable, args, max_bytes, timeout_ms, env \\ [], input \\ nil) do
    execute(executable, args, max_bytes, timeout_ms, env, input, false)
  end

  # Opt-in diagnostics for trusted compilers and inert fixtures with public
  # inputs only. Ordinary tools continue to discard failed output, which may
  # contain private custody or credential bytes.
  def run_diagnostic(executable, args, max_bytes, timeout_ms, synthetic_input \\ nil) do
    execute(executable, args, max_bytes, timeout_ms, [], synthetic_input, true)
  end

  defp execute(executable, args, max_bytes, timeout_ms, env, input, diagnostic) do
    case System.find_executable(executable) do
      nil -> {:error, "#{executable} is unavailable"}
      path -> run_path(path, args, max_bytes, timeout_ms, env, input, diagnostic)
    end
  end

  defp run_path(path, args, max_bytes, timeout_ms, env, input, diagnostic) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), String.to_charlist(value)}
          end)
      ])

    if is_binary(input), do: Port.command(port, input)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, [], 0, max_bytes, deadline, diagnostic)
  end

  defp collect(port, chunks, size, max_bytes, deadline, diagnostic) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= max_bytes ->
        collect(port, [data | chunks], size + byte_size(data), max_bytes, deadline, diagnostic)

      {^port, {:data, _data}} ->
        close(port)
        {:error, "tool output exceeds development bound"}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        reason = "tool exited with status #{status}"
        output = if diagnostic, do: chunks |> Enum.reverse() |> IO.iodata_to_binary(), else: ""
        {:error, if(output == "", do: reason, else: reason <> "\n" <> output)}
    after
      remaining ->
        close(port)
        {:error, "tool timed out"}
    end
  end

  # A short-lived process can exit before its queued data is rejected. Closing
  # an already terminated owned port must retain the bounded failure result.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
