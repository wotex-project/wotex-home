defmodule Woh.Tool.NativeFixture do
  @moduledoc false

  alias Woh.Tool.Command

  @max_frame 65_536
  @credential Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)

  def credential, do: @credential

  def run(project, swift_test, cases) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "wotex-native-fixture-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "native-smoke")

    try do
      with :ok <- compile(project, swift_test, executable) do
        Enum.reduce_while(cases, :ok, fn case_data, _ ->
          case run_case(executable, directory, case_data) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp compile(project, swift_test, executable) do
    args = [
      "-parse-as-library",
      "-warnings-as-errors",
      "-swift-version",
      "6",
      "-module-cache-path",
      Path.join(Path.dirname(executable), "swift-module-cache"),
      "-target",
      "arm64-apple-macos15.0",
      "-framework",
      "Security",
      Path.join(project, "native/macos/Sources/LocalHealthClient.swift"),
      Path.join(project, "native/macos/Tests/#{swift_test}"),
      "-o",
      executable
    ]

    case Command.run("swiftc", args, 1_048_576, 60_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Swift fixture compilation failed: #{reason}"}
    end
  end

  defp run_case(executable, directory, %{mode: mode, exchanges: []}) do
    missing = Path.join(directory, "missing.sock")

    case Command.run(executable, [missing, mode], 16_384, 10_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "native #{mode} failed: #{reason}"}
    end
  end

  defp run_case(executable, directory, %{mode: mode, exchanges: exchanges}) do
    path = Path.join(directory, "home.sock")

    with {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             active: false,
             ifaddr: {:local, String.to_charlist(path)}
           ]),
         :ok <- File.chmod(path, 0o600) do
      server = Task.async(fn -> serve(listener, exchanges) end)

      try do
        client = Command.run(executable, [path, mode], 16_384, 10_000)
        server_result = Task.yield(server, 11_000) || Task.shutdown(server, :brutal_kill)

        case {client, server_result} do
          {{:ok, _}, {:ok, :ok}} -> :ok
          {{:error, reason}, _} -> {:error, "native #{mode} failed: #{reason}"}
          {_, {:ok, {:error, reason}}} -> {:error, "fixture #{mode} failed: #{reason}"}
          _ -> {:error, "fixture #{mode} did not complete"}
        end
      after
        :gen_tcp.close(listener)
        File.rm(path)
      end
    else
      {:error, reason} -> {:error, "cannot start native fixture peer: #{inspect(reason)}"}
    end
  end

  defp serve(listener, exchanges) do
    Enum.reduce_while(exchanges, :ok, fn {expected, response}, _ ->
      with {:ok, peer} <- :gen_tcp.accept(listener, 10_000) do
        result =
          try do
            with {:ok, <<size::unsigned-big-32>>} <- :gen_tcp.recv(peer, 4, 10_000),
                 true <- size > 0 and size <= @max_frame,
                 {:ok, bytes} <- :gen_tcp.recv(peer, size, 10_000),
                 {:ok, ^expected} <- JSON.decode(bytes),
                 :ok <- reply(peer, response) do
              :ok
            else
              _ -> {:error, "request frame or exact payload differed"}
            end
          after
            :gen_tcp.close(peer)
          end

        case result do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        _ -> {:halt, {:error, "client did not connect"}}
      end
    end)
  end

  defp reply(peer, {:drip, bytes}) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.reduce_while(:ok, fn byte, _ ->
      case :gen_tcp.send(peer, <<byte>>) do
        :ok ->
          Process.sleep(1_100)
          {:cont, :ok}

        {:error, reason} when reason in [:closed, :epipe, :econnreset] ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, "drip send failed: #{inspect(reason)}"}}
      end
    end)
  end

  defp reply(_peer, :close), do: :ok

  defp reply(peer, response) when is_map(response) do
    body = JSON.encode!(response)
    :gen_tcp.send(peer, <<byte_size(body)::unsigned-big-32, body::binary>>)
  end
end
