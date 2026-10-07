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
  @modes ~w(happy lost-approval lost-approval-refused lost-preparation lost-selection lost-cancellation expired missing-bytes)

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
        Enum.reduce_while(
          for(mode <- @modes, recovery <- [false, true], do: {mode, recovery}),
          :ok,
          fn {mode, recovery}, :ok ->
            case check(project, executable, root, mode, recovery) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
            end
          end
        )
      end
    after
      File.rm_rf!(root)
    end
  end

  defp compile(project, executable) do
    sources =
      ~w(LocalHealthClient.swift SignedSetupPeer.swift NativeSetupSocket.swift NativeBrokerClient.swift PortableProfilesPanel.swift NativeSetupWire.swift NativeTargetWire.swift NativeCoreConnection.swift NativeNetworkPreferences.swift NativePrivateDocuments.swift NativeRuleOperationWire.swift NativeRuleClient.swift NativePendingCodec.swift NativePendingStorage.swift NativePendingCoordinator.swift NativePendingRecoveryOperations.swift)
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

  defp check(project, executable, root, mode, recovery) do
    directory = Path.join(root, mode <> if(recovery, do: "-recovery", else: ""))
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

    parent = self()

    proxy =
      Task.async(fn ->
        proxy_loop(listener, socket, mode, artifact_path, %{
          dropped: false,
          selected: false,
          deleted: false,
          store: store,
          parent: parent,
          original: nil,
          held: nil,
          journal: Path.join(directory, "journal")
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
             Command.run(
               executable,
               [proxy_path, mode, preview] ++ if(recovery, do: ["recovery"], else: []),
               65_536,
               30_000,
               [],
               input
             ),
           {:ok, result} <- JSON.decode(String.trim(output)),
           true <- result["complete"] == true,
           :ok <-
             check_result(authority, store, operator, Map.put(result, "recovery", recovery), mode),
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

  defp check_result(authority, store, operator, %{"recovered_review" => true} = result, _) do
    with {:ok, %{action: "approve"}} <-
           Authority.profile_operation_status(authority, operator, 1, result["approval_id"]),
         :not_found <-
           Authority.profile_operation_status(authority, operator, 1, result["pending_id"]),
         {:ok, %{status: :absent}} <-
           Authority.profile_target(authority, operator, result["target_id"]),
         {:ok, %{writable: true, dispatch_enabled: false, active_things: 0}} <-
           Store.health(store),
         do: :ok,
         else: (_ ->
                  {:error, "recovered held review created a selection or lost approval history"})
  end

  defp check_result(authority, store, operator, result, "lost-approval-refused") do
    with true <- result["retained"] == true and result["pending_id"] == result["approval_id"],
         {:ok, :unauthorized} <- refused_evidence(result["approval_id"], result["recovery"]),
         {:error, :unauthorized} <-
           Authority.profile_operation_status(authority, operator, 1, result["approval_id"]),
         {:ok, %{writable: true, dispatch_enabled: false, active_things: 0}} <-
           Store.health(store) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "refused retry evidence failed: #{reason}"}

      _ ->
        {:error, "refused retry did not retain the committed original"}
    end
  end

  defp check_result(authority, store, operator, result, mode)
       when mode in ["expired", "lost-cancellation"] do
    with true <- result["retained"] == true,
         {:ok, %{action: "approve"}} <-
           Authority.profile_operation_status(authority, operator, 1, result["approval_id"]),
         :not_found <-
           Authority.profile_operation_status(authority, operator, 1, result["pending_id"]),
         {:ok, %{status: :absent}} <-
           Authority.profile_target(authority, operator, "light:native:profile"),
         {:ok, %{writable: true, dispatch_enabled: false, active_things: 0}} <-
           Store.health(store) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "retained proposal evidence failed: #{reason}"}

      {:ok, %{status: status}} when is_atom(status) ->
        {:error, "retained proposal target status: #{status}"}

      _ ->
        {:error, "expired or cancelled original was replaced"}
    end
  end

  defp check_result(authority, store, operator, result, _) do
    with {:ok, %{action: "approve"}} <-
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
           Store.health(store) do
      :ok
    else
      _ -> {:error, "native panel/Store correspondence differed"}
    end
  end

  defp refused_evidence(operation, recovery) do
    receive do
      {:profile_original_retained,
       %{
         "outcome" => "ok",
         "profile_receipt" => %{"operation_id" => ^operation, "action" => "approve"}
       }, revision} ->
        if recovery do
          with :ok <- refused_identity(revision),
               :ok <- refused_identity(revision),
               :ok <- refused_identity(revision),
               do: {:ok, :unauthorized}
        else
          with :ok <- refused_frame(), :ok <- refused_frame() do
            receive do
              {:profile_lookup_retained, true, %{"reason" => "unauthorized"}, ^revision} ->
                {:ok, :unauthorized}
            after
              1_000 -> {:error, :lookup_evidence_missing}
            end
          end
        end
    after
      1_000 -> {:error, :commit_evidence_missing}
    end
  end

  defp refused_identity(revision) do
    receive do
      {:profile_identity_retained, true, %{"reason" => "unauthorized"}, ^revision} -> :ok
      {:profile_retry_retained, _, _} -> {:error, :mutation_after_revoked_identity}
    after
      1_000 -> {:error, :identity_refusal_missing}
    end
  end

  defp refused_frame do
    receive do
      {:profile_retry_retained, true, %{"outcome" => "error", "reason" => "unauthorized"}} ->
        :ok

      {:profile_retry_retained, same, response} ->
        {:error, {:retry_difference, same, response["reason"]}}
    after
      1_000 -> {:error, :retry_evidence_missing}
    end
  end

  defp verify_journal(state, request) do
    with {:ok,
          [
            "wotex-home.native-pending.v1",
            _,
            [
              [
                "profile",
                [_, _, epoch, "operator:native:profiles"],
                ["manual", verifier],
                input,
                phase
              ]
            ]
          ]} <-
           JSON.decode(File.read!(Path.join(state.journal, "native-pending-v1.json"))),
         {:ok, bytes} <- Base.url_decode64(request["credential"], padding: false),
         true <- verifier == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
         true <- journal_input?(request, input, phase, epoch, state.held) do
      :ok
    else
      _ -> raise "exact original profile input/intent was not published before delivery"
    end
  end

  defp journal_input?(
         %{"operation" => "profile_review_cancel", "review_token" => token},
         input,
         phase,
         epoch,
         held
       ) do
    held != nil and phase == ["cancel_pending", token, held["review_digest"]] and
      token == held["review_token"] and
      Enum.at(input, 1) == "select" and Enum.at(input, 2) == epoch
  end

  defp journal_input?(request, input, phase, epoch, held) do
    fields = request["selection"] || request["change"]

    names =
      ~w(action authority_epoch operation_id expected_revision artifact_digest expected_trust_revision) ++
        case fields["action"] do
          "select" ->
            ~w(target_id expected_resource_revision expected_binding_revision expected_selection_generation expected_policy_generation expected_rule_generation session_ref candidate_ref review_ref)

          "revoke_selection" ->
            ~w(target_id expected_resource_revision expected_selection_generation)

          _ ->
            []
        end

    values = Enum.map(names, &fields[&1])

    cond do
      request["operation"] == "profile_prepare" ->
        input == ["profile_prepare" | values] and phase == ["pending"] and
          epoch == fields["authority_epoch"]

      fields["action"] == "select" ->
        held != nil and input == ["profile_prepare" | values] and
          phase == ["commit_pending", held["review_token"], held["review_digest"]] and
          epoch == fields["authority_epoch"]

      true ->
        input == ["profile_change" | values] and phase == ["pending"] and
          epoch == fields["authority_epoch"]
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
              if request["operation"] in [
                   "profile_prepare",
                   "profile_change",
                   "profile_review_cancel"
                 ],
                 do: verify_journal(state, request)

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
                      ((mode in ["lost-approval", "lost-approval-refused"] and action == "approve") or
                         (mode == "lost-selection" and action == "select") or
                         (mode == "lost-preparation" and request["operation"] == "profile_prepare") or
                         (mode == "lost-cancellation" and
                            request["operation"] == "profile_review_cancel"))

                  if mode == "lost-approval-refused" do
                    cond do
                      drop ->
                        {:ok, revision} =
                          Store.revoke_principal(state.store, "operator:native:profiles")

                        send(state.parent, {:profile_original_retained, response, revision})

                      request["operation"] == "profile_change" and state.dropped ->
                        {:ok, original} = Frame.decode_request(state.original)

                        send(
                          state.parent,
                          {:profile_retry_retained, request == original, response}
                        )

                      request["operation"] == "profile_operation_status" and state.dropped ->
                        {:ok, original} = Frame.decode_request(state.original)
                        {:ok, revision} = Store.revision(state.store)

                        send(
                          state.parent,
                          {:profile_lookup_retained,
                           request["credential"] == original["credential"], response, revision}
                        )

                      request["operation"] == "controller_identity" and state.dropped ->
                        {:ok, original} = Frame.decode_request(state.original)
                        {:ok, revision} = Store.revision(state.store)

                        send(
                          state.parent,
                          {:profile_identity_retained,
                           request["credential"] == original["credential"], response, revision}
                        )

                      true ->
                        :ok
                    end
                  end

                  unless drop do
                    {:ok, frame} = Frame.encode_response(response)
                    :ok = :gen_tcp.send(peer, frame)
                  end

                  %{
                    state
                    | selected: selected,
                      dropped: state.dropped or drop,
                      deleted: state.deleted or deleted,
                      original: if(drop, do: bytes, else: state.original),
                      held: response["profile_review"] || state.held
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
          "native profiles passed sixteen real Store model/shared-recovery workflows; no device packets or Keychain changes"
        )

      {:error, reason} ->
        Mix.raise("native profile panel smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.profiles.panel.smoke")
end
