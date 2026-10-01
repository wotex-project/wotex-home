defmodule Woh.Tool.NativeCliParitySmoke do
  @moduledoc false

  alias Woh.Tool.{Command, HostProcess}

  @operation_id "op:parity:1"
  @receipt_fields ~w(authority_epoch operation_id disposition reason revision)

  def run(project) do
    directory =
      Path.join("/tmp", "wh-parity-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    data = Path.join(directory, "private")
    credential_file = Path.join(directory, "credential")
    executable = Path.join(directory, "native-cli-parity")

    try do
      with :ok <- bootstrap(data, credential_file),
           {:ok, credential} <- credential(credential_file),
           :ok <- compile(project, executable),
           {:ok, host} <- HostProcess.start(data) do
        try do
          socket = Path.join(data, "ipc/home.sock")

          with :ok <- HostProcess.await_socket(host, socket, 60_000),
               {:ok, staged} <- native_result(executable, socket, "stage", credential),
               {:ok, seen_by_cli} <-
                 cli_result(socket, credential_file, ["receipt", "1", @operation_id]),
               true <-
                 receipt(staged) == receipt(seen_by_cli) and
                   receipt(staged)["disposition"] == "held",
               {:ok, cancelled} <-
                 cli_result(socket, credential_file, ["cancel", "1", @operation_id]),
               {:ok, seen_by_native} <- native_result(executable, socket, "status", credential),
               true <-
                 receipt(cancelled) == receipt(seen_by_native) and
                   receipt(cancelled)["disposition"] == "rejected" and
                   receipt(cancelled)["reason"] == "cancelled" do
            {:ok, "native and CLI live held/cancelled receipt parity passed"}
          else
            false -> {:error, "Swift and CLI disagree on held or cancelled receipt"}
            {:error, reason} -> {:error, reason}
          end
        after
          HostProcess.stop(host)
        end
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp bootstrap(data, credential_file) do
    args = [
      "-u",
      "WOTEX_HOME_DATA_DIR",
      "mix",
      "run",
      "--no-start",
      "bin/bootstrap_native_cli_parity.exs",
      data,
      credential_file
    ]

    case Command.run("env", args, 1_048_576, 90_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "parity bootstrap failed: #{reason}"}
    end
  end

  defp credential(path) do
    case File.read(path) do
      {:ok, credential} when byte_size(credential) == 43 -> {:ok, credential}
      _ -> {:error, "fixture credential is malformed"}
    end
  end

  defp compile(project, executable) do
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
      Path.join(project, "native/macos/Tests/LiveCLIParitySmoke.swift"),
      "-o",
      executable
    ]

    case Command.run("swiftc", args, 1_048_576, 60_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Swift parity compilation failed: #{reason}"}
    end
  end

  defp native_result(executable, socket, operation, credential) do
    result_json(executable, [socket, operation], credential <> "\n")
  end

  defp cli_result(socket, credential_file, operation_args) do
    args = [
      "-u",
      "WOTEX_HOME_DATA_DIR",
      "mix",
      "run",
      "--no-start",
      "--no-compile",
      "-e",
      "System.halt(WotexHome.CLI.main(System.argv()))",
      "--",
      "--socket",
      socket,
      "--credential-file",
      credential_file
      | operation_args
    ]

    result_json("env", args, nil)
  end

  defp result_json(executable, args, input) do
    case Command.run(executable, args, 1_048_576, 20_000, [], input) do
      {:ok, output} ->
        lines = output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "{"))

        case lines do
          [line] ->
            case JSON.decode(line) do
              {:ok, value} when is_map(value) -> {:ok, value}
              _ -> {:error, "parity client returned invalid JSON"}
            end

          _ ->
            {:error, "parity client returned no single JSON result"}
        end

      {:error, reason} ->
        {:error, "parity client failed: #{reason}"}
    end
  end

  defp receipt(result) do
    item = Map.get(result, "receipt", result)

    if is_map(item) and Enum.all?(@receipt_fields, &Map.has_key?(item, &1)) do
      Map.take(item, @receipt_fields)
    else
      %{}
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Cli.Parity.Smoke do
  @moduledoc """
  Compares Swift and CLI receipts against the same live private Home host.

  Run `mix woh.native.cli.parity.smoke` to stage one held ordinary request with
  the Swift client, read it through the CLI, cancel it through the CLI and
  confirm the cancelled result in Swift. The task uses an isolated temporary
  Store and credential, then stops the foreground host.
  """

  @shortdoc "Smoke-test live Swift and CLI receipt parity"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeCliParitySmoke.run(File.cwd!()) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, reason} -> Mix.raise("native CLI parity smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.cli.parity.smoke")
end
