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
                   receipt(cancelled)["reason"] == "cancelled",
               :ok <- rule_parity(executable, socket, credential_file, credential),
               :ok <- maintenance_parity(executable, socket, credential_file, credential),
               :ok <- profile_parity(executable, socket, credential_file, credential, project) do
            {:ok,
             "native and CLI live request/cancel/rule/maintenance/profile receipt parity passed"}
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

  defp profile_parity(executable, socket, credential_file, credential, project) do
    source = Path.join(Path.dirname(credential_file), "profile.json")
    bytes = File.read!(Path.join(project, "test/support/profiles/lifx-power.json"))
    File.write!(source, bytes)
    File.chmod!(source, 0o600)

    with {:ok, native_import} <- native_result(executable, socket, "profile-import", credential),
         {:ok, cli_import} <- cli_result(socket, credential_file, ["profile-import", source]),
         true <-
           native_import == cli_import["profile_artifact"] and
             native_import["authority_changed"] == false,
         {:ok, _} <- native_result(executable, socket, "profile-maintenance", credential),
         {:ok, approved} <- native_result(executable, socket, "profile-approve", credential),
         {:ok, cli_receipt} <-
           cli_result(socket, credential_file, [
             "profile-operation-status",
             "1",
             "profile:parity:approve"
           ]),
         {:ok, native_receipt} <- native_result(executable, socket, "profile-receipt", credential),
         true <- approved == cli_receipt["profile_receipt"] and approved == native_receipt,
         :ok <- profile_read_parity(executable, socket, credential_file, credential),
         {:ok, revoked} <- native_result(executable, socket, "profile-revoke", credential),
         {:ok, cli_revoked} <-
           cli_result(socket, credential_file, [
             "profile-operation-status",
             "1",
             "profile:parity:revoke"
           ]),
         true <- revoked == cli_revoked["profile_receipt"] and revoked["changed_targets"] == 0,
         {:ok, historical} <- native_result(executable, socket, "profile-receipt", credential),
         true <- historical == approved,
         :ok <- profile_read_parity(executable, socket, credential_file, credential),
         {:ok, cli_collection} <- cli_result(socket, credential_file, ["profiles-collect"]),
         {:ok, native_collection} <-
           native_result(executable, socket, "profile-collect", credential),
         true <-
           cli_collection["profile_collection"] == native_collection and
             native_collection["removed_objects"] == 0 do
      :ok
    else
      false -> {:error, "Swift and CLI disagree on profile trust/status/original receipts"}
      error -> error
    end
  end

  defp profile_read_parity(executable, socket, credential_file, credential) do
    with {:ok, native} <- native_result(executable, socket, "profile-catalogue", credential),
         {:ok, cli} <- cli_result(socket, credential_file, ["profiles"]),
         true <- native == cli["profile_catalogue"],
         {:ok, native_target} <- native_result(executable, socket, "profile-target", credential),
         {:ok, cli_target} <-
           cli_result(socket, credential_file, ["profile-target", "light:profile:parity"]),
         true <- native_target == cli_target["profile_target"] do
      :ok
    else
      false -> {:error, "Swift and CLI disagree on profile catalogue/target snapshot"}
      error -> error
    end
  end

  defp maintenance_parity(executable, socket, credential_file, credential) do
    with {:ok, staged} <- native_result(executable, socket, "stage-maintenance", credential),
         true <- staged["disposition"] == "held",
         {:ok, begun} <- native_result(executable, socket, "maintenance-begin", credential),
         {:ok, cli_receipt} <-
           cli_result(socket, credential_file, [
             "maintenance-operation-status",
             "1",
             "maintenance:parity:begin"
           ]),
         {:ok, native_receipt} <-
           native_result(executable, socket, "maintenance-receipt", credential),
         true <- begun == cli_receipt["maintenance_receipt"] and begun == native_receipt,
         true <- begun["affected_requests"] == 1 and begun["unknown_outcomes"] == 0,
         :ok <-
           maintenance_status_parity(
             executable,
             socket,
             credential_file,
             credential,
             "maintenance"
           ),
         {:ok, %{"blocked" => true}} <-
           native_result(executable, socket, "maintenance-blocked", credential),
         {:ok, invalidated} <-
           cli_result(socket, credential_file, ["receipt", "1", "op:parity:2"]),
         true <-
           receipt(invalidated)["disposition"] == "rejected" and
             receipt(invalidated)["reason"] == "rule_generation_fenced",
         {:ok, ended} <- native_result(executable, socket, "maintenance-end", credential),
         {:ok, cli_ended} <-
           cli_result(socket, credential_file, [
             "maintenance-operation-status",
             "1",
             "maintenance:parity:end"
           ]),
         true <-
           ended == cli_ended["maintenance_receipt"] and
             ended["begin_revision"] == begun["revision"],
         {:ok, historical} <- native_result(executable, socket, "maintenance-receipt", credential),
         true <- historical == begun,
         :ok <-
           maintenance_status_parity(executable, socket, credential_file, credential, "normal"),
         {:ok, policy} <- native_result(executable, socket, "rule-policy", credential),
         true <- policy["state"] == "inactive" and policy["rule_generation"] == 2 do
      :ok
    else
      false -> {:error, "Swift and CLI disagree on maintenance barrier/immutable receipts"}
      error -> error
    end
  end

  defp maintenance_status_parity(executable, socket, credential_file, credential, state) do
    with {:ok, cli_status} <- cli_result(socket, credential_file, ["maintenance-status"]),
         {:ok, native_status} <-
           native_result(executable, socket, "maintenance-status", credential),
         true <-
           native_status == cli_status["maintenance_status"] and native_status["state"] == state and
             native_status["rule_generation"] == 2 do
      :ok
    else
      false -> {:error, "Swift and CLI disagree on current maintenance status"}
      error -> error
    end
  end

  defp rule_parity(executable, socket, credential_file, credential) do
    with {:ok, suspended} <- native_result(executable, socket, "suspend-rules", credential),
         {:ok, cli_receipt} <-
           cli_result(socket, credential_file, ["rule-operation-status", "1", "rule:parity:1"]),
         {:ok, native_receipt} <- native_result(executable, socket, "rule-receipt", credential),
         true <-
           suspended == native_receipt and
             suspended == Map.take(cli_receipt["rule_receipt"], Map.keys(suspended)),
         {:ok, cli_status} <- cli_result(socket, credential_file, ["rule-status"]),
         {:ok, native_status} <- native_result(executable, socket, "rule-policy", credential),
         true <-
           native_status == cli_status["rule_status"] and native_status["state"] == "inactive" and
             native_status["rule_generation"] == 1 do
      :ok
    else
      false -> {:error, "Swift and CLI disagree on rule suspension/status"}
      error -> error
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
    case result_json(executable, [socket, operation], credential <> "\n") do
      {:error, reason} -> {:error, "native #{operation}: #{reason}"}
      result -> result
    end
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
  confirm the cancelled result in Swift, suspend the rule generation and compare
  immutable rule receipts/current status through both adapters. It also begins/ends maintenance,
  checks pending-work invalidation, rejects new staging at the barrier and compares historical
  receipts after end. Profile checks compare exact byte import, approval/revocation,
  current catalogue/target snapshots, immutable original receipts and Store-owned collection.
  No capture or device effect is performed. The task uses an isolated temporary
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
