defmodule Woh.Tool.NativeLiveHostSmoke do
  @moduledoc false

  alias Woh.Tool.{Command, HostProcess}

  def run(project) do
    directory =
      Path.join("/tmp", "wh-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    data = Path.join(directory, "private")
    executable = Path.join(directory, "live-health")

    try do
      with {:ok, credential} <- bootstrap(project, data),
           :ok <- compile(project, executable),
           {:ok, host} <- HostProcess.start(data) do
        try do
          socket = Path.join(data, "ipc/home.sock")

          with :ok <- HostProcess.await_socket(host, socket, 30_000),
               {:ok, _} <-
                 Command.run(executable, [socket], 16_384, 10_000, [], credential <> "\n") do
            {:ok, "native client authenticated to the live private Home host"}
          else
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

  defp bootstrap(project, data) do
    {output, status} =
      System.cmd("mix", ["run", "bin/bootstrap_health.exs"],
        cd: project,
        env: [{"WOTEX_HOME_DATA_DIR", data}],
        stderr_to_stdout: true
      )

    credentials =
      output
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, &1))

    case {status, credentials} do
      {0, [credential]} -> {:ok, credential}
      _ -> {:error, "health bootstrap did not produce one diagnostic credential"}
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
      Path.join(project, "native/macos/Tests/LiveHealthSmoke.swift"),
      "-o",
      executable
    ]

    case Command.run("swiftc", args, 1_048_576, 60_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Swift live health compilation failed: #{reason}"}
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Live.Host.Smoke do
  @moduledoc """
  Checks the Swift read-only client against a real private Home host.

  Run `mix woh.native.live.host.smoke` to bootstrap a temporary diagnostic
  credential, start the foreground Elixir host and use the compiled Swift
  client to read health, catalogue and snapshot routes. The credential stays
  in process input and temporary local state; the task cleans up the host.
  """

  @shortdoc "Smoke-test Swift reads against a live Home host"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeLiveHostSmoke.run(File.cwd!()) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, reason} -> Mix.raise("native live host smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.live.host.smoke")
end
