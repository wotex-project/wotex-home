defmodule Woh.Tool.NativeBrokerSocketSmoke do
  @moduledoc false
  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-broker-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "broker-smoke")

    try do
      python = System.find_executable("python3")

      if is_binary(python) do
        script = Path.join(directory, "inert_core.py")

        File.write!(script, ~S"""
        import os, sys
        value = sys.stdin.buffer.read(1)
        if value:
          with open(os.environ['WOTEX_HOME_DATA_DIR'] + '/core-request','wb') as file: file.write(b'called')
        """)

        File.chmod!(script, 0o600)
        shim = Path.join(directory, "core-shim")
        File.write!(shim, "#!/bin/sh\nexec #{quote_shell(python)} #{quote_shell(script)}\n")
        File.chmod!(shim, 0o700)

        sources = [
          "LocalHealthClient",
          "NativeSetupWire",
          "SignedSetupPeer",
          "NativeCoreConnection",
          "NativeNetworkPreferences",
          "NativeKeychainCustodian",
          "NativeSetupSocket",
          "NativeCredentialBroker",
          "NativeBrokerClient"
        ]

        args =
          [
            "-parse-as-library",
            "-warnings-as-errors",
            "-swift-version",
            "6",
            "-module-cache-path",
            Path.join(directory, "cache"),
            "-target",
            "arm64-apple-macos15.0",
            "-framework",
            "Security",
            "-framework",
            "LocalAuthentication",
            "-framework",
            "CryptoKit"
          ] ++
            Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
            [
              Path.join(project, "native/macos/Tests/NativeBrokerSocketSmoke.swift"),
              "-o",
              executable
            ]

        with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
             {:ok, output} <- Command.run(executable, [directory], 16_384, 15_000),
             true <-
               String.contains?(
                 output,
                 "native broker socket ownership and unsigned refusal passed"
               ),
             do: :ok
      else
        {:error, "Python inert child unavailable"}
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

defmodule Mix.Tasks.Woh.Native.Broker.Socket.Smoke do
  @moduledoc "Checks owned native setup sockets and real unsigned refusal; no signed success or SecItem operation."
  @shortdoc "Check private native broker socket ownership"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeBrokerSocketSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native broker socket ownership and unsigned refusal passed")
      {:error, reason} -> Mix.raise("native broker socket smoke failed: #{reason}")
      _ -> Mix.raise("native broker socket fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.broker.socket.smoke")
end
