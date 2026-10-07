defmodule Mix.Tasks.Woh.Native.Pending.Storage.Smoke do
  @moduledoc "Checks private native journal publication, CAS, unsafe files and process restart without credentials or API calls."
  @shortdoc "Check native pending journal storage"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  @impl Mix.Task
  def run([]) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-pending-store-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "pending-storage-smoke")
    project = File.cwd!()

    try do
      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-module-cache-path",
          Path.join(directory, "cache"),
          "-target",
          "arm64-apple-macos15.0"
        ] ++
          Enum.map(
            ~w(LocalHealthClient NativeSetupWire NativeTargetWire NativeCoreConnection NativePrivateDocuments NativeNetworkPreferences NativeRuleOperationWire NativeRuleClient NativePendingCodec NativePendingStorage),
            &Path.join(project, "native/macos/Sources/#{&1}.swift")
          ) ++
          [
            Path.join(project, "native/macos/Tests/NativePendingStorageSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           :ok <- run_fixture(executable, private_directory(directory, "suite"), "suite"),
           :ok <- restart(executable, private_directory(directory, "restart")),
           :ok <- race(executable, private_directory(directory, "race"), false),
           :ok <- race(executable, private_directory(directory, "upgrade-race"), true),
           :ok <- race(executable, private_directory(directory, "rule-upgrade-race"), :rules) do
        Mix.shell().info(
          "native pending storage private guards, CAS, process crash/restart and concurrent publication passed"
        )
      else
        {:error, reason} -> Mix.raise("native pending storage smoke failed: #{reason}")
        _ -> Mix.raise("native pending storage fixture did not complete")
      end
    after
      File.rm_rf!(directory)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.pending.storage.smoke")

  defp restart(executable, root) do
    file = Path.join(root, "native-pending-v1.json")

    with {:ok, _} <- Command.run(executable, [root, "before-crash"], 16_384, 10_000),
         false <- File.exists?(file),
         {:ok, _} <- Command.run(executable, [root, "after-crash"], 16_384, 10_000),
         bytes <- File.read!(file),
         :ok <- run_fixture(executable, root, "loaded"),
         true <- File.read!(file) == bytes,
         :ok <- run_fixture(executable, root, "resolve"),
         :ok <- run_fixture(executable, root, "loaded-empty"),
         true <- File.exists?(file),
         do: :ok
  end

  defp race(executable, root, upgrade) do
    script = ~S"""
    import os, subprocess, sys, time
    root = sys.argv[2]
    mode = sys.argv[3]
    if mode == 'upgrade-race':
      subprocess.run([sys.argv[1],root,'after-crash'],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8)
    elif mode == 'rule-upgrade-race':
      subprocess.run([sys.argv[1],root,'seed-rule-race'],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8)
    children = [subprocess.Popen([sys.argv[1],root,mode,str(index)],stdout=subprocess.PIPE,stderr=subprocess.PIPE) for index in range(2)]
    try:
      deadline = time.monotonic() + 6
      while not all(os.path.exists(root + '/ready-' + str(index)) for index in range(2)):
        assert time.monotonic() < deadline and all(child.poll() is None for child in children)
        time.sleep(.01)
      descriptor = os.open(root + '/go',os.O_WRONLY | os.O_CREAT | os.O_EXCL,0o600); os.close(descriptor)
      outputs = []
      for child in children:
        output, diagnostics = child.communicate(timeout=8)
        assert child.returncode == 0 and len(output) <= 1024 and len(diagnostics) <= 1024
        outputs.append(output)
      assert sum(b'race_committed' in output for output in outputs) == 1
      assert sum(b'race_refused' in output for output in outputs) == 1
    finally:
      for child in children:
        if child.poll() is None: child.kill(); child.communicate(timeout=5)
    print('native pending concurrent publication passed')
    """

    mode =
      case upgrade do
        true -> "upgrade-race"
        false -> "race"
        :rules -> "rule-upgrade-race"
      end

    check_mode = "check-" <> mode

    with {:ok, output} <-
           Command.run("python3", ["-c", script, executable, root, mode], 16_384, 20_000),
         true <- String.contains?(output, "native pending concurrent publication passed"),
         :ok <- run_fixture(executable, root, check_mode),
         do: :ok
  end

  defp run_fixture(executable, root, mode) do
    case Command.run(executable, [root, mode], 16_384, 15_000) do
      {:ok, output} ->
        if String.contains?(output, "native pending storage #{mode} passed"),
          do: :ok,
          else: {:error, "native journal fixture did not complete"}

      error ->
        error
    end
  end

  defp private_directory(directory, name) do
    path = Path.join(directory, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end
