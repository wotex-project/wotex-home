defmodule Mix.Tasks.Woh.Native.Generation.Workspace.Smoke do
  @moduledoc """
  Checks native generation workspace originals and private publication.

  Run `mix woh.native.generation.workspace.smoke` on the supported macOS
  toolchain. Independent Python v1/v2 roots check complete preparation/attempt links
  and canonical bytes. The compiled Swift fixture then checks private file modes,
  unsafe-file refusal, bounded records, cancellation intent and archival.

  Four separate-process races per version cover root creation, attempt append,
  intent change and archive; a fresh process reloads retained roots for restart.
  v2 also checks paired custody, strict v1 refusal and monotone mixed-root upgrade.
  The task creates a private temporary root, uses finite compilation/execution
  deadlines and removes its fixture state when the run ends.

  This is client metadata custody evidence. It sends no pending operation,
  mutates no Store and opens no credential, model or Keychain. First-decision
  submission, installed signing and storage power-loss qualification have
  separate acceptance cases.
  """

  use Mix.Task
  alias Woh.Tool.Command
  @requirements ["loadpaths"]
  @shortdoc "Check generation workspace custody and concurrent publication"

  def run([]) do
    root =
      Path.join(
        "/private/tmp",
        "gen-workspace-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "workspace")

    sources =
      ~w(LocalHealthClient NativeSetupWire NativeTargetWire NativeCoreConnection NativePrivateDocuments NativeNetworkPreferences NativeRuleOperationWire NativeRuleClient NativeScheduleWire NativeScheduleClient NativeAuthoringReadClient NativeAuthoringOriginalWire NativePendingAuthoring NativeGenerationOriginalWire NativeExternalProfileClient NativeExternalProfileOriginalWire NativePendingCodec NativeGenerationWorkspace)

    args =
      [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-whole-module-optimization",
        "-Onone",
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(root, "cache")
      ] ++
        Enum.map(sources, &Path.expand("native/macos/Sources/#{&1}.swift")) ++
        [Path.expand("native/macos/Tests/NativeGenerationWorkspaceSmoke.swift"), "-o", executable]

    try do
      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000) do
        for prefix <- ["", "paired-"] do
          {:ok, output} =
            Command.run_diagnostic(
              executable,
              [directory(root, prefix <> "suite"), prefix <> "suite"],
              16_384,
              20_000
            )

          unless String.trim(output) ==
                   "workspace independent originals, private CAS, intent and bounds passed",
                 do: Mix.raise("workspace fixture did not complete")

          for mode <- ~w(race append-race intent-race archive-race) do
            race(executable, directory(root, prefix <> mode), prefix <> mode)
          end

          restart = directory(root, prefix <> "restart")

          for mode <- ~w(seed load) do
            {:ok, _} =
              Command.run_diagnostic(executable, [restart, prefix <> mode], 16_384, 10_000)
          end
        end

        Mix.shell().info(
          "native generation v1/v2 workspace originals, private CAS, eight process races and restart passed"
        )
      else
        {:error, reason} -> Mix.raise("native generation workspace smoke failed: #{reason}")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.generation.workspace.smoke")

  defp race(executable, root, mode) do
    if mode not in ~w(race paired-race),
      do:
        {:ok, _} =
          Command.run_diagnostic(
            executable,
            [root, if(String.starts_with?(mode, "paired-"), do: "paired-seed", else: "seed")],
            16_384,
            10_000
          )

    script = ~S"""
    import os, subprocess, sys, time
    executable, root, mode = sys.argv[1:]
    children = [subprocess.Popen([executable,root,mode,str(i)],stdout=subprocess.PIPE,stderr=subprocess.PIPE) for i in range(2)]
    try:
      until = time.monotonic() + 6
      while not all(os.path.exists(root + '/ready-' + str(i)) for i in range(2)):
        assert time.monotonic() < until and all(c.poll() is None for c in children)
        time.sleep(.01)
      fd = os.open(root+'/go',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600); os.close(fd)
      outputs = [c.communicate(timeout=8) for c in children]
      assert all(c.returncode == 0 for c in children), outputs
      assert sum(b'race_committed' in out for out,_ in outputs) == 1, outputs
      assert sum(b'race_refused' in out for out,_ in outputs) == 1, outputs
      subprocess.run([executable,root,'paired-load' if mode.startswith('paired-') else 'load'],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8)
    finally:
      for c in children:
        if c.poll() is None: c.kill(); c.communicate(timeout=5)
    print('workspace race passed')
    """

    case Command.run_diagnostic("python3", ["-c", script, executable, root, mode], 16_384, 35_000) do
      {:ok, output} when is_binary(output) ->
        unless String.trim(output) == "workspace race passed",
          do: Mix.raise("workspace race did not complete")

      {:error, reason} ->
        Mix.raise("workspace #{mode} failed: #{reason}")
    end
  end

  defp directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end
