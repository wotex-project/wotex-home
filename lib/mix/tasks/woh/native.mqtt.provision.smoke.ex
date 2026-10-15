defmodule Woh.Tool.NativeMQTTProvisionSmoke do
  @moduledoc false

  alias Woh.Tool.Command

  def run(project) do
    root =
      Path.join("/private/tmp", "woh-native-mqtt-provision-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "fixture")

    try do
      sources =
        ~w(NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments SignedSetupPeer NativeKeychainCustodian NativeAuthoringFiles NativeMQTTProvisioning)

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-target",
          "arm64-apple-macos15.0",
          "-module-cache-path",
          Path.join(root, "cache"),
          "-framework",
          "Security",
          "-framework",
          "LocalAuthentication",
          "-framework",
          "CryptoKit"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [
            Path.join(project, "native/macos/Tests/NativeMQTTProvisioningSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           :ok <- actual(project, root, executable),
           :ok <- adverse(project, root, executable),
           do: :ok
    after
      File.rm_rf!(root)
    end
  end

  defp actual(project, root, executable) do
    Code.require_file("test/support/mqtt_fixture.exs", project)
    Application.ensure_all_started(:crypto)
    {a, s} = apply(WotexHome.TestSupport.MQTTFixture, :installation_documents, [])
    folder = directory(root, "actual")
    _ = directory(folder, "data")

    for {name, bytes} <- [{"authoring.json", a}, {"mqtt.json", s}],
        do:
          (
            File.write!(Path.join(folder, name), bytes)
            File.chmod!(Path.join(folder, name), 0o400)
          )

    elixir = System.find_executable("elixir")
    mix = System.find_executable("mix")
    erl = System.find_executable("erl")
    path = Path.dirname(elixir) <> ":" <> Path.dirname(erl) <> ":/usr/bin:/bin:/usr/sbin:/sbin"

    shim = """
    #!/bin/sh
    set -eu
    test "$#" -eq 2
    test "$1" = eval
    test "$2" = 'WotexHome.NativeSetup.MQTTProvisioning.main()'
    test -z "${ERL_AFLAGS+x}"
    test -z "${WOTEX_HOME_NATIVE_MQTT_BOOTSTRAP+x}"
    test -z "${WOTEX_HOME_LIFX_INTERFACE+x}"
    echo "$$" > #{quote_shell(Path.join(folder, "child-pid"))}
    cd #{quote_shell(project)}
    export PATH=#{quote_shell(path)} MIX_ENV=test WOTEX_HOME_GIT_DEPS=1
    exec #{quote_shell(elixir)} #{quote_shell(mix)} run --no-start --no-compile --no-deps-check -e 'WotexHome.NativeSetup.MQTTProvisioning.main()'
    """

    write_shim(folder, shim)

    case Command.run_diagnostic(executable, [folder, "actual"], 16384, 20000) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp adverse(project, root, executable) do
    python = System.find_executable("python3")

    Enum.reduce_while(~w(oversized extra death stderr silent), :ok, fn mode, _ ->
      folder = directory(root, mode)
      script = Path.join(folder, "peer.py")

      File.write!(script, ~S"""
      import json,os,struct,sys
      root=os.environ['WOTEX_HOME_DATA_DIR']
      assert all(k not in os.environ for k in ['ERL_AFLAGS','WOTEX_HOME_NATIVE_MQTT_BOOTSTRAP','WOTEX_HOME_LIFX_INTERFACE'])
      with open(root+'/child-pid','w') as f:f.write(str(os.getpid()))
      mode=sys.argv[1]
      size=struct.unpack('>I',sys.stdin.buffer.read(4))[0]; assert 1<=size<=4096
      assert len(sys.stdin.buffer.read(size))==size
      if mode=='oversized':sys.stdout.buffer.write(struct.pack('>I',4097));sys.stdout.buffer.flush()
      if mode=='extra':
        values=json.load(open(sys.argv[2]));body=values['prepared'].encode();frame=struct.pack('>I',len(body))+body
        sys.stdout.buffer.write(frame+frame);sys.stdout.buffer.flush()
      if mode=='stderr':sys.stderr.write('private-diagnostic-canary'*200);sys.stderr.flush()
      if mode=='death' or mode=='extra':sys.exit(0)
      sys.stdin.buffer.read(1)
      """)

      write_shim(
        folder,
        "#!/bin/sh\nexec #{quote_shell(python)} #{quote_shell(script)} #{quote_shell(mode)} #{quote_shell(Path.join(project, "test/fixtures/mqtt/native-provision.json"))}\n"
      )

      case Command.run_diagnostic(executable, [folder, mode], 16384, 20000) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp write_shim(root, body) do
    path = Path.join(root, "shim")
    File.write!(path, body)
    File.chmod!(path, 0o700)
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

defmodule Mix.Tasks.Woh.Native.Mqtt.Provision.Smoke do
  @moduledoc """
  Checks fixed native MQTT foreground preparation and immutable publication.

  Run `MIX_ENV=test mix woh.native.mqtt.provision.smoke` on Apple Silicon macOS
  with the locked cache. Swift 6 fixtures check frozen protocol vectors, private
  file modes, actual unsigned refusal and the real foreground producer/installer.
  Adversarial original pipes check frame bounds, extra output, diagnostic limits,
  death, the 15-second deadline and child reaping. No signing seal or successful
  Keychain custody is synthesized. Native Setup presentation and installed
  positive signing/custody require separate evidence.
  """

  @shortdoc "Check native MQTT foreground publication"
  @requirements ["loadpaths"]
  use Mix.Task
  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeMQTTProvisionSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native MQTT foreground, private files, original pipes and unsigned refusal passed"
        )

      {:error, reason} ->
        Mix.raise("native MQTT foreground smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.mqtt.provision.smoke")
end
