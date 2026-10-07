defmodule Woh.Tool.NativeProfilesPanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.{Authority, Host}
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, Transport}
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Profiles.{Artifact, Custody, ReviewSession}
  @custody __MODULE__.Custody
  @reviews __MODULE__.Reviews
  @modes ~w(happy lost-approval lost-preparation lost-selection lost-cancellation expired missing-bytes)

  defmodule Peer do
    @moduledoc false
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
          2 -> {3, <<1, 56_700::little-32>>}
          32 -> {33, <<1::little-32, 22::little-32, 0::32>>}
          14 -> {15, <<1_700_000_000::little-64, 0::64, 22::little-16, 1::little-16>>}
        end

      target = if type == 2, do: <<0xD0, 0x73, 0xD5, 0, 0, 1>>, else: target
      size = 36 + byte_size(payload)

      reply =
        <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48,
          0::8, sequence::8, 0::64, reply_type::little-16, 0::16, payload::binary>>

      Process.put(:native_profile_replies, Process.get(:native_profile_replies, []) ++ [reply])
      :ok
    end

    @impl true
    def recv(_, _) do
      case Process.get(:native_profile_replies, []) do
        [reply | rest] ->
          Process.put(:native_profile_replies, rest)
          {:ok, "192.0.2.10:56700", reply}

        [] ->
          {:error, :timeout}
      end
    end
  end

  def run(project) do
    root =
      Path.join(
        "/private/tmp",
        "wh-profile-panel-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "profile-panel-smoke")

    try do
      with :ok <- compile(project, executable) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(project, executable, root, mode) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp compile(project, executable) do
    sources =
      ~w(LocalHealthClient.swift PortableProfilesPanel.swift)
      |> Enum.map(&Path.join(project, "native/macos/Sources/#{&1}"))

    args =
      [
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
        "-framework",
        "SwiftUI",
        "-framework",
        "AppKit"
      ] ++
        sources ++
        [Path.join(project, "native/macos/Tests/LiveProfilesPanelSmoke.swift"), "-o", executable]

    case Command.run("swiftc", args, 1_048_576, 60_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "native panel compilation failed: #{reason}"}
    end
  end

  defp check(project, executable, root, mode) do
    directory = Path.join(root, mode)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    profiles = Path.join(directory, "profiles")
    File.mkdir!(profiles)
    File.chmod!(profiles, 0o700)

    {:ok, store} =
      Store.start_link(
        path: Path.join(directory, "home.sqlite"),
        profile_custody: @custody,
        profile_reviews: @reviews
      )

    {:ok, custody} = Custody.start_link(root: profiles, name: @custody, store_owner: store)

    {:ok, reviews} =
      ReviewSession.start_link(
        custody: custody,
        name: @reviews,
        ttl_ms: if(mode == "expired", do: 600, else: 60_000)
      )

    {:ok, scope} = IPv4Scope.new({192, 0, 2, 2}, 24)

    {:ok, capture} =
      CaptureSession.start_link(interface_id: "en0", scope: scope, transport: {Peer, :fixture})

    authority =
      Authority.new(
        store: store,
        profile_custody: custody,
        profile_reviews: reviews,
        capture: capture
      )

    {:ok, operator, _} =
      Store.provision_principal(
        store,
        "operator:native:profiles",
        ["profile:manage", "enroll:review"],
        []
      )

    {:ok, manager, _} =
      Store.provision_principal(store, "manager:native:profiles", ["profile:manage"], [])

    {:ok, maintainer, revision} =
      Store.provision_principal(store, "maintenance:native:profiles", ["host:maintain"], [])

    {:ok, _} =
      Authority.begin_maintenance(
        authority,
        maintainer,
        1,
        "maintenance:native:profiles",
        revision
      )

    socket = Path.join(directory, "host.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    proxy_path = Path.join(directory, "client.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ifaddr: {:local, String.to_charlist(proxy_path)}
      ])

    File.chmod!(proxy_path, 0o600)
    bytes = File.read!(Path.join(project, "test/support/profiles/lifx-power.json"))
    artifact_path = Path.join(profiles, Artifact.digest(bytes) <> ".json")

    proxy =
      Task.async(fn ->
        proxy_loop(listener, socket, mode, artifact_path, %{
          dropped: false,
          selected: false,
          deleted: false
        })
      end)

    input =
      JSON.encode!(%{
        "operator" => Base.url_encode64(operator, padding: false),
        "manager" => Base.url_encode64(manager, padding: false)
      }) <> "\n"

    preview = Path.join(project, "_build/native/profiles-panel-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    try do
      with {:ok, output} <-
             Command.run(executable, [proxy_path, mode, preview], 65_536, 30_000, [], input),
           {:ok, result} <- JSON.decode(String.trim(output)),
           true <- result["complete"] == true,
           {:ok, %{action: "approve"}} <-
             Authority.profile_operation_status(authority, operator, 1, result["approval_id"]),
           {:ok, %{action: "select", changed_targets: 1}} <-
             Authority.profile_operation_status(authority, operator, 1, result["selection_id"]),
           {:ok, %{action: "revoke_selection", changed_targets: 1}} <-
             Authority.profile_operation_status(authority, operator, 1, result["revocation_id"]),
           {:ok,
            %{
              selection_generation: 2,
              selection_state: "revoked",
              resource_revision: 2,
              qualification_head: nil
            }} <- Authority.profile_target(authority, operator, result["target_id"]),
           {:error, :permission_denied} <-
             Store.lifx_refresh_basis(store, operator, result["target_id"]),
           {:ok, %{writable: true, dispatch_enabled: false, active_things: 1}} <-
             Store.health(store),
           nil <- Host.store() do
        :ok
      else
        {:error, reason} -> {:error, inspect(reason)}
        _ -> {:error, "native panel/Store correspondence differed"}
      end
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)

      Enum.each([server, capture, reviews, custody, store], fn pid ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  # Same-user test proxy drops complete replies only after the real private API
  # has returned. It never invents a receipt, evidence, declaration or credential.
  defp proxy_loop(listener, socket, mode, artifact_path, state) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        next =
          try do
            with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 10_000),
                 true <- size in 1..65_536,
                 {:ok, bytes} <- :gen_tcp.recv(peer, size, 10_000),
                 {:ok, request} <- Frame.decode_request(bytes) do
              deleted =
                mode == "missing-bytes" and state.selected and not state.deleted and
                  request["operation"] == "profile_target"

              if deleted, do: File.rm!(artifact_path)

              case Client.request(socket, request, 15_000) do
                {:ok, response} ->
                  action = get_in(request, ["change", "action"])

                  selected =
                    state.selected or (action == "select" and response["outcome"] == "ok")

                  drop =
                    not state.dropped and
                      ((mode == "lost-approval" and action == "approve") or
                         (mode == "lost-selection" and action == "select") or
                         (mode == "lost-preparation" and request["operation"] == "profile_prepare") or
                         (mode == "lost-cancellation" and
                            request["operation"] == "profile_review_cancel"))

                  unless drop do
                    {:ok, frame} = Frame.encode_response(response)
                    :ok = :gen_tcp.send(peer, frame)
                  end

                  %{
                    state
                    | selected: selected,
                      dropped: state.dropped or drop,
                      deleted: state.deleted or deleted
                  }

                _ ->
                  state
              end
            else
              _ -> state
            end
          after
            :gen_tcp.close(peer)
          end

        proxy_loop(listener, socket, mode, artifact_path, next)

      {:error, _} ->
        :ok
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Profiles.Panel.Smoke do
  @moduledoc "Check the actual native profile window model against one private Store and scripted host capture, including lost replies, credential changes, expiry and missing bytes."
  @shortdoc "Smoke-test native profile operator workflow"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeProfilesPanelSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native profile window model passed seven live Store/capture/recovery workflows; no device packets or Keychain changes"
        )

      {:error, reason} ->
        Mix.raise("native profile panel smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.profiles.panel.smoke")
end
