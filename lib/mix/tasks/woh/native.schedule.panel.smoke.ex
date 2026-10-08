defmodule Woh.Tool.NativeSchedulePanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias Woh.Tool.NativeScheduleRecoverySmoke, as: Fixture
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Schedules.{Codec, OperationInput}
  @principal "manager:schedule-fixture"
  @mutations ~w(schedule_review schedule_admit schedule_activate schedule_suspend)
  @modes ~w(interval-lifecycle utc-lifecycle once-fold daily-gap weekdays-fold lost-reply first-refused publication changed-custody changed-controller edited reload-activate reload-rotated reload-calendar reload-missing reload-revoked reload-changed-custody reload-changed-controller reload-selector-edited reload-session-fence reload-lost-read)

  def run(project) do
    root =
      directory("/private/tmp", "sp-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")

    executable = Path.join(root, "panel")
    preview = Path.join(project, "_build/native/schedule-panel-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    try do
      sources =
        ~w(LocalHealthClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativeRuleOperationWire NativeRuleClient NativeScheduleWire NativeScheduleClient NativePendingCodec NativePendingStorage NativePendingCoordinator NativePendingRecoveryOperations NativePendingPanel NativeSchedulePanel)

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
          [
            Path.join(project, "native/macos/Tests/NativeSchedulePanelSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 90_000) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(project, executable, directory(root, mode), mode, preview) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp check(project, executable, root, mode, preview) do
    journal = directory(root, "journal")
    {:ok, store} = Store.start_link(path: Path.join(root, "home.sqlite"))
    {:ok, thing} = Fixture.thing()
    {:ok, 1} = Store.enroll_thing(store, thing)
    permissions = ~w(read rule:review rule:manage control:ordinary)
    {:ok, original, 2} = Store.provision_principal(store, @principal, permissions, [thing.id])

    {:ok, other, 3} =
      Store.provision_principal(store, "manager:schedule-other", permissions, [thing.id])

    {:ok, gate} = WotexHome.Authority.ReviewGate.start_link(limit: 1)
    zones = directory(root, "zones")
    directory(zones, "Fixture")

    fixture =
      JSON.decode!(
        File.read!(Path.join(project, "test/fixtures/schedules/timezone_vectors.json"))
      )["zones"]
      |> hd()

    zone_path = Path.join(zones, fixture["name"])
    File.write!(zone_path, Base.decode64!(fixture["data_base64"]))
    File.chmod!(zone_path, 0o600)

    authority =
      Authority.new(
        store: store,
        review_gate: gate,
        timezone_options:
          if(mode == "utc-lifecycle",
            do: [],
            else: [root: zones, owner_uid: File.stat!(root).uid]
          )
      )

    clock =
      if mode in ~w(interval-lifecycle utc-lifecycle once-fold reload-activate reload-rotated),
        do: Fixture.attach_clock(root, store)

    socket = Path.join(root, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(root, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    {:ok, evidence} =
      Agent.start_link(fn ->
        %{
          requests: [],
          originals: [],
          error: false,
          identities: 0,
          source_reads: 0,
          dropped: false
        }
      end)

    proxy = Task.async(fn -> proxy(listener, socket, journal, store, evidence, mode) end)

    input =
      JSON.encode!(%{
        "original" => Base.url_encode64(original, padding: false),
        "other" => Base.url_encode64(other, padding: false)
      }) <> "\n"

    try do
      current =
        if String.starts_with?(mode, "reload-") and mode != "reload-missing" do
          seed_mode =
            if mode == "reload-calendar", do: "reload-calendar-seed", else: "reload-seed"

          {:ok, output} =
            Command.run(
              executable,
              [path, journal, seed_mode, preview],
              16_384,
              35_000,
              [],
              input
            )

          {:ok, %{"complete" => true}} = JSON.decode(String.trim(output))

          cond do
            mode == "reload-rotated" ->
              {:ok, replacement, 5} = Store.rotate_principal_credential(store, @principal)
              replacement

            mode == "reload-revoked" ->
              {:ok, 5} = Store.revoke_target_grant(store, @principal, thing.id)
              original

            mode == "reload-calendar" ->
              File.rm!(zone_path)
              original

            true ->
              original
          end
        else
          original
        end

      current_input =
        JSON.encode!(%{
          "original" => Base.url_encode64(current, padding: false),
          "other" => Base.url_encode64(other, padding: false)
        }) <> "\n"

      with {:ok, output} <-
             Command.run(
               executable,
               [path, journal, mode, preview],
               16_384,
               35_000,
               [],
               current_input
             ),
           {:ok, %{"complete" => true}} <- JSON.decode(String.trim(output)),
           state <- Agent.get(evidence, & &1),
           false <- state.error,
           true <-
             Enum.all?(
               state.requests,
               &(&1["credential"] in [
                   Base.url_encode64(original, padding: false),
                   Base.url_encode64(current, padding: false)
                 ])
             ),
           {:ok,
            %{
              store_revision: revision,
              dispatch_enabled: false,
              writable: true,
              held_requests: 0,
              queued_requests: 0
            }} <- Store.health(store),
           true <- revision == expected_revision(mode),
           true <- length(state.originals) == mutation_count(mode),
           true <- mode not in ~w(lost-reply reload-lost-read) or state.dropped,
           true <- original_lookup?(state),
           true <- final_journal?(journal, mode),
           do: :ok,
           else: (
             {:ok, %{"line" => line} = failed} ->
               {:error, "assertion #{line}: #{failed["reason"] || "unexpected state"}"}

             {:error, reason} ->
               {:error, reason}

             _ ->
               {:error, "original publication, authority or final state differed"}
           )
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)

      for pid <- [clock, evidence, server, gate, store],
          is_pid(pid) and Process.alive?(pid),
          do: GenServer.stop(pid)
    end
  end

  defp expected_revision("interval-lifecycle"), do: 9
  defp expected_revision("utc-lifecycle"), do: 8
  defp expected_revision("reload-activate"), do: 6
  defp expected_revision("reload-rotated"), do: 7
  defp expected_revision("reload-revoked"), do: 5
  defp expected_revision("reload-missing"), do: 3
  defp expected_revision(mode) when mode in ~w(changed-custody changed-controller edited), do: 3
  defp expected_revision(_), do: 4
  defp mutation_count("interval-lifecycle"), do: 4
  defp mutation_count("utc-lifecycle"), do: 3
  defp mutation_count("once-fold"), do: 2
  defp mutation_count(mode) when mode in ~w(reload-activate reload-rotated), do: 2
  defp mutation_count("reload-missing"), do: 0
  defp mutation_count(mode) when mode in ~w(changed-custody changed-controller edited), do: 0
  defp mutation_count(_), do: 1

  defp final_journal?(journal, mode) do
    path = Path.join(journal, "native-pending-v1.json")

    if mutation_count(mode) == 0 do
      not File.exists?(path)
    else
      case File.read(path) do
        {:ok, bytes} ->
          case JSON.decode(bytes) do
            {:ok, ["wotex-home.native-pending.v4", revision, []]} ->
              revision == 2 * mutation_count(mode)

            _ ->
              false
          end

        _ ->
          false
      end
    end
  end

  defp original_lookup?(state) do
    Enum.all?(
      Enum.filter(state.requests, &(&1["operation"] == "schedule_original_status")),
      fn request ->
        request["original_document"] in state.originals
      end
    )
  end

  defp proxy(listener, socket, journal, store, evidence, mode) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          case exchange(peer, socket, journal, store, evidence, mode) do
            :ok -> :ok
            _ -> Agent.update(evidence, &%{&1 | error: true})
          end
        after
          :gen_tcp.close(peer)
        end

        proxy(listener, socket, journal, store, evidence, mode)

      {:error, _} ->
        :ok
    end
  end

  defp exchange(peer, socket, journal, store, evidence, mode) do
    with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 10_000),
         true <- size in 1..65_536,
         {:ok, bytes} <- :gen_tcp.recv(peer, size, 10_000),
         {:ok, request} <- Frame.decode_request(bytes),
         :ok <- publication(journal, store, request) do
      state = Agent.get(evidence, & &1)
      mutation = request["operation"] in @mutations

      if mutation and mode == "first-refused",
        do: {:ok, _} = Store.revoke_principal(store, @principal)

      response =
        case Client.request(socket, request, 12_000) do
          {:ok, response} -> response
          _ -> nil
        end

      response =
        if request["operation"] == "controller_identity" and is_map(response) and
             ((mode == "changed-controller" and state.identities == 2) or
                (mode == "reload-changed-controller" and state.source_reads > 0)),
           do: put_in(response, ["controller_identity", "owner_id"], String.duplicate("0", 64)),
           else: response

      drop =
        not state.dropped and
          ((mode == "lost-reply" and mutation) or
             (mode == "reload-lost-read" and request["operation"] == "schedule_source"))

      Agent.update(evidence, fn s ->
        %{
          s
          | requests: s.requests ++ [request],
            originals: s.originals ++ if(mutation, do: [request["original_document"]], else: []),
            dropped: s.dropped or drop,
            identities:
              s.identities + if(request["operation"] == "controller_identity", do: 1, else: 0),
            source_reads:
              s.source_reads + if(request["operation"] == "schedule_source", do: 1, else: 0)
        }
      end)

      if not drop and is_map(response) do
        {:ok, frame} = Frame.encode_response(response)
        :gen_tcp.send(peer, frame)
      else
        :ok
      end
    end
  end

  defp publication(journal, store, request) do
    if request["operation"] in @mutations do
      document = request["original_document"]

      with {:ok, kind, input} <- OperationInput.decode(document),
           true <- request["operation"] == "schedule_" <> kind,
           {:ok, raw} <- File.read(Path.join(journal, "native-pending-v1.json")),
           {:ok,
            [
              "wotex-home.native-pending.v4",
              revision,
              [
                [
                  "schedule",
                  [deployment, owner, 1, @principal],
                  ["manual", verifier],
                  ["schedule_operation", ^document],
                  ["pending"]
                ]
              ]
            ]} <- JSON.decode(raw),
           true <- revision > 0,
           {:ok, identity} <- Store.native_setup_identity(store),
           true <- deployment == identity["deployment_id"] and owner == identity["owner_id"],
           {:ok, credential} <- Base.url_decode64(request["credential"], padding: false),
           true <- verifier == Codec.hash(credential),
           :ok <- source(input, kind),
           do: :ok,
           else: (_ -> {:error, :unpublished_original})
    else
      :ok
    end
  end

  defp source(input, kind) when kind in ~w(review admit) do
    with {:ok, source, rule} <- OperationInput.source(kind, input),
         true <-
           source["author_id"] == @principal and source["target_id"] == "light:schedule-fixture" and
             source["resource_revision"] == 0,
         true <-
           rule.effect ==
             {"light:schedule-fixture", "power",
              %WotexHome.Semantics.Value{kind: :boolean, data: true}},
         do: :ok,
         else: (_ -> {:error, :changed_source})
  end

  defp source(_, _), do: :ok

  defp directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

defmodule Mix.Tasks.Woh.Native.Schedule.Panel.Smoke do
  @moduledoc "Real Store native schedule drafts, confirmation, publication and recovery with calendar choices and window renders; no installed custody or effects."
  @shortdoc "Check native schedule panel against Store"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeSchedulePanelSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native schedule panel twenty-one private Store workflows passed")
      {:error, reason} -> Mix.raise("native schedule panel smoke failed: #{inspect(reason)}")
      _ -> Mix.raise("native schedule panel fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.schedule.panel.smoke")
end
