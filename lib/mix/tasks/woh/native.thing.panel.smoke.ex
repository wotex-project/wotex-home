defmodule Woh.Tool.NativeThingPanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, Transport}
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Semantics.Observation
  @target "light:fixture"
  @modes ~w(stored missing stale synthetic revoked owner-changed draft-changed wake probe lost-probe)

  defmodule Peer do
    @behaviour Transport
    @impl true
    def send(
          _,
          _,
          <<_::32, source::little-32, target::binary-size(6), _::72, sequence::8, _::64,
            type::little-16, _::16, _::binary>>
        ) do
      {reply_type, payload} =
        case type do
          2 ->
            {3, <<1, 56_700::little-32>>}

          32 ->
            {33, <<1::little-32, 22::little-32, 0::32>>}

          14 ->
            {15, <<1_700_000_000::little-64, 0::64, 22::little-16, 1::little-16>>}

          101 ->
            {107,
             <<0::16, 0::16, 65_535::little-16, 3_500::little-16, 0::16, 65_535::little-16,
               0::256, 0::64>>}
        end

      target = if type == 2, do: <<0xD0, 0x73, 0xD5, 0, 0, 1>>, else: target
      size = 36 + byte_size(payload)

      response =
        <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48,
          0::8, sequence::8, 0::64, reply_type::little-16, 0::16, payload::binary>>

      Process.put(:thing_panel_packets, Process.get(:thing_panel_packets, []) ++ [response])
      :ok
    end

    @impl true
    def recv(_, _) do
      case Process.get(:thing_panel_packets, []) do
        [packet | rest] ->
          Process.put(:thing_panel_packets, rest)
          {:ok, "192.0.2.10:56700", packet}

        [] ->
          {:error, :timeout}
      end
    end
  end

  def run(project) do
    root =
      directory("/private/tmp", "tp-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")

    executable = Path.join(root, "thing-panel")
    preview = Path.join(project, "_build/native")
    File.mkdir_p!(preview)

    try do
      sources =
        ~w(LocalHealthClient NativeThingClient NativeThingPanel SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments)

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
          "SwiftUI",
          "-framework",
          "AppKit",
          "-framework",
          "Security",
          "-framework",
          "CryptoKit"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [Path.join(project, "native/macos/Tests/NativeThingPanelSmoke.swift"), "-o", executable]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 90_000) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(executable, directory(root, mode), mode, preview) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp check(executable, root, mode, preview) do
    {:ok, store} = Store.start_link(path: Path.join(root, "home.sqlite"))

    {:ok, reviewer, 1} =
      Store.provision_principal(store, "reviewer:thing-fixture", ["enroll:review"], [])

    {:ok, scope} = IPv4Scope.new({192, 0, 2, 2}, 24)

    {:ok, capture} =
      CaptureSession.start_link(
        interface_id: "fixture",
        scope: scope,
        transport: {Peer, :fixture}
      )

    authority = Authority.new(store: store, capture: capture)
    {:ok, session, [candidate]} = Authority.lifx_discover(authority, reviewer)
    {:ok, _, _} = Authority.lifx_interview(authority, reviewer, session, candidate.raw_ref)

    {:ok, _} =
      Authority.lifx_enroll(
        authority,
        reviewer,
        session,
        candidate.raw_ref,
        "lifx.product-22:1.0.0",
        @target,
        "review:thing-fixture"
      )

    {:ok, credential, 3} =
      Store.provision_principal(store, "reader:thing-fixture", ["read"], [@target])

    initialize(store, credential, mode)
    socket = Path.join(root, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(root, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    {:ok, evidence} =
      Agent.start_link(fn -> %{operations: [], identities: 0, dropped: false, error: false} end)

    proxy = Task.async(fn -> proxy(listener, socket, evidence, mode) end)

    try do
      with {:ok, output} <-
             Command.run(
               executable,
               [path, mode, preview],
               16_384,
               30_000,
               [],
               Base.url_encode64(credential, padding: false) <> "\n"
             ),
           {:ok, %{"complete" => true}} <- JSON.decode(String.trim(output)),
           state <- Agent.get(evidence, & &1),
           false <- state.error,
           true <-
             Enum.all?(
               state.operations,
               &(&1 in ~w(controller_identity thing_current lifx_refresh))
             ),
           true <-
             Enum.count(state.operations, &(&1 == "lifx_refresh")) ==
               if(String.contains?(mode, "probe"), do: 1, else: 0),
           {:ok, %{writable: true, dispatch_enabled: false, store_revision: revision}} <-
             Store.health(store),
           true <- revision == if(mode == "missing", do: 3, else: 4),
           do: :ok,
           else: (
             {:ok, %{"complete" => false, "line" => line}} ->
               {:error, "fixture assertion #{line}"}

             {:error, reason} when is_binary(reason) ->
               {:error, reason}

             _ ->
               {:error, "scoped read, probe count or revision differed"}
           )
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)
      for pid <- [evidence, server, capture, store], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp initialize(store, _credential, "revoked"),
    do: Store.revoke_principal(store, "reader:thing-fixture")

  defp initialize(_store, _credential, mode) when mode in ~w(missing probe lost-probe), do: :ok

  defp initialize(store, credential, mode) do
    {:ok, basis} = Store.lifx_refresh_basis(store, credential, @target)
    capability = basis.thing.capabilities["power"]

    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => @target,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true},
          "quality" => "reported",
          "trust" => if(mode == "synthetic", do: "synthetic_lab", else: "unauthenticated_local"),
          "source_epoch" => "source:thing-fixture",
          "source_sequence" => 1,
          "boot_epoch" => "adapter:thing-fixture",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_700_000_000_000,
          "received_monotonic_ms" => 999_999_999
        },
        capability
      )

    {:ok, 4} = Store.record(store, report, capability)

    if mode == "stale",
      do: :sys.replace_state(store, &%{&1 | clock_origin: &1.clock_origin - 5_001})

    :ok
  end

  defp proxy(listener, socket, evidence, mode) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 5_000),
               true <- size in 1..65_536,
               {:ok, body} <- :gen_tcp.recv(peer, size, 5_000),
               {:ok, request} <- Frame.decode_request(body),
               {:ok, response} <- Client.request(socket, request) do
            operation = request["operation"]

            state =
              Agent.get_and_update(evidence, fn state ->
                {state,
                 %{
                   state
                   | operations: state.operations ++ [operation],
                     identities:
                       state.identities + if(operation == "controller_identity", do: 1, else: 0),
                     dropped: state.dropped or operation == "lifx_refresh"
                 }}
              end)

            response =
              if mode == "owner-changed" and operation == "controller_identity" and
                   state.identities == 1,
                 do:
                   put_in(
                     response,
                     ["controller_identity", "owner_id"],
                     String.duplicate("a", 64)
                   ),
                 else: response

            unless mode == "lost-probe" and operation == "lifx_refresh" and !state.dropped do
              {:ok, frame} = Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
            end
          else
            _ -> Agent.update(evidence, &%{&1 | error: true})
          end
        rescue
          _ -> Agent.update(evidence, &%{&1 | error: true})
        after
          :gen_tcp.close(peer)
        end

        proxy(listener, socket, evidence, mode)

      {:error, _} ->
        :ok
    end
  end

  defp directory(parent, name) do
    path = Path.join(parent, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

defmodule Mix.Tasks.Woh.Native.Thing.Panel.Smoke do
  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Verify actual Store native Thing inspection and explicit read workflows"
  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeThingPanelSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native Thing panel ten private Store/capture workflows passed")
      {:error, reason} -> Mix.raise("native Thing panel failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.thing.panel.smoke")
end
