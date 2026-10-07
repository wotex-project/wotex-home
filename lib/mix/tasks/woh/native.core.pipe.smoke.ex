defmodule Woh.Tool.NativeCorePipeSmoke do
  @moduledoc false
  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-core-pipe-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "core-pipe-smoke")

    try do
      with {:ok, _} <- compile(project, directory, executable),
           :ok <- actual(project, directory, executable),
           :ok <- adversarial(directory, executable),
           do: :ok
    after
      File.rm_rf!(directory)
    end
  end

  defp compile(project, directory, executable) do
    Command.run(
      "swiftc",
      [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        Path.join(directory, "swift-module-cache"),
        "-target",
        "arm64-apple-macos15.0",
        Path.join(project, "native/macos/Sources/NativeSetupWire.swift"),
        Path.join(project, "native/macos/Sources/NativeCoreConnection.swift"),
        Path.join(project, "native/macos/Tests/NativeCoreConnectionSmoke.swift"),
        "-o",
        executable
      ],
      1_048_576,
      60_000
    )
  end

  defp actual(project, directory, executable) do
    root = private_directory(directory, "actual")
    elixir = System.find_executable("elixir")
    erl = System.find_executable("erl")
    mix = System.find_executable("mix")

    if is_binary(elixir) and is_binary(erl) and is_binary(mix) do
      path = Path.dirname(elixir) <> ":" <> Path.dirname(erl) <> ":/usr/bin:/bin:/usr/sbin:/sbin"

      shim = """
      #!/bin/sh
      set -eu
      test "$#" -eq 2
      test "$1" = eval
      test "$2" = 'WotexHome.NativeSetup.CoreHost.main()'
      test -z "${ERL_AFLAGS+x}"
      test -z "${ELIXIR_ERL_OPTIONS+x}"
      test -z "${RELEASE_ROOT+x}"
      test -z "${WOTEX_HOME_PHYSICAL_DISPATCH+x}"
      cd #{quote_shell(project)}
      export PATH=#{quote_shell(path)} MIX_ENV=test WOTEX_HOME_GIT_DEPS=1
      exec #{quote_shell(elixir)} #{quote_shell(mix)} run --no-start --no-compile --no-deps-check bin/native_core_host.exs
      """

      write_shim(root, shim)
      run_fixture(executable, root, "actual")
    else
      {:error, "locked Elixir/OTP executables unavailable"}
    end
  end

  defp adversarial(directory, executable) do
    python = System.find_executable("python3")

    if is_binary(python) do
      Enum.reduce_while(
        [
          "oversized",
          "partial",
          "drip",
          "silent",
          "death",
          "extra-reply",
          "capacity",
          "wrong-receipt",
          "expired"
        ],
        :ok,
        fn mode, :ok ->
          root = private_directory(directory, mode)
          script = Path.join(root, "peer.py")
          File.write!(script, python_peer())
          File.chmod!(script, 0o600)

          write_shim(
            root,
            "#!/bin/sh\nexec #{quote_shell(python)} #{quote_shell(script)} #{quote_shell(mode)}\n"
          )

          case run_fixture(executable, root, mode) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end
      )
    else
      {:error, "Python pipe fixture unavailable"}
    end
  end

  defp python_peer do
    ~S"""
    import json, os, struct, sys, time
    root = os.environ['WOTEX_HOME_DATA_DIR']
    assert sys.argv[1] in ('oversized','partial','drip','silent','death','extra-reply','capacity','wrong-receipt','expired')
    assert all(key not in os.environ for key in ('ERL_AFLAGS','ELIXIR_ERL_OPTIONS','RELEASE_ROOT','WOTEX_HOME_PHYSICAL_DISPATCH'))
    with open(root + '/child-pid','w') as file: file.write(str(os.getpid()))
    header = sys.stdin.buffer.read(4)
    if len(header) != 4: sys.exit(0)
    size = struct.unpack('>I', header)[0]
    assert 1 <= size <= 4096
    body = sys.stdin.buffer.read(size)
    assert len(body) == size
    with open(root + '/request-seen','w') as file: file.write('seen')
    mode = sys.argv[1]
    if mode == 'death': sys.exit(0)
    if mode == 'oversized': sys.stdout.buffer.write(struct.pack('>I',4097)); sys.stdout.buffer.flush()
    if mode == 'partial': sys.stdout.buffer.write(struct.pack('>I',100) + b'['); sys.stdout.buffer.flush()
    if mode == 'extra-reply':
      reply = json.dumps(['wotex-home.native-setup-authority.v1','identity','a'*64,'b'*64,1,0],separators=(',',':')).encode()
      frame = struct.pack('>I',len(reply)) + reply
      sys.stdout.buffer.write(frame + frame); sys.stdout.buffer.flush()
    if mode == 'wrong-receipt':
      reply = json.dumps(['wotex-home.native-setup-authority.v1','ensured','a'*64,'b'*64,1,'transfer','native-setup-v1:1:transfer',1],separators=(',',':')).encode()
      sys.stdout.buffer.write(struct.pack('>I',len(reply)) + reply); sys.stdout.buffer.flush()
    if mode == 'drip':
      for byte in struct.pack('>I',100):
        try: sys.stdout.buffer.write(bytes([byte])); sys.stdout.buffer.flush()
        except BrokenPipeError: sys.exit(0)
        time.sleep(.3)
    if mode == 'capacity': time.sleep(2)
    sys.stdin.buffer.read(1)
    """
  end

  defp run_fixture(executable, root, mode) do
    case Command.run(executable, [root, mode], 16_384, 15_000) do
      {:ok, output} ->
        if String.contains?(output, "native core pipe #{mode} passed"),
          do: :ok,
          else: {:error, "native core pipe fixture did not complete"}

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

  defp write_shim(root, bytes) do
    path = Path.join(root, "core-shim")
    File.write!(path, bytes)
    File.chmod!(path, 0o700)
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

defmodule Mix.Tasks.Woh.Native.Core.Pipe.Smoke do
  @moduledoc "Checks native pipe ownership against an actual core and adversarial children; opens no broker or Keychain."
  @shortdoc "Check native core child pipe ownership"
  @requirements ["app.config"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("compile")

    case Woh.Tool.NativeCorePipeSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native core pipe ownership and actual receipt recovery passed")
      {:error, reason} -> Mix.raise("native core pipe smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.core.pipe.smoke")
end
