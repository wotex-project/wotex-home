defmodule Woh.Tool.NativeRulePanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Rules.{Codec, OperationInput, Rule}
  alias WotexHome.Semantics.Thing
  @principal "manager:rule-panel-fixture"
  @mutations ~w(record_rule_review admit_rule activate_rule invoke_rule)
  @modes ["lifecycle"] ++
           for(
             kind <- ~w(review admit activate invoke),
             recovery <- ~w(lookup retry),
             do: kind <> "-" <> recovery
           ) ++
           ~w(admit-unsubmitted admit-missing admit-refused admit-first-refused admit-stale admit-tampered admit-changed admit-controller admit-edited admit-publication admit-lookup-tampered admit-restart-lookup admit-restart-retry)

  def run(project) do
    root =
      directory("/private/tmp", "rp-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")

    executable = Path.join(root, "rule-panel")
    preview = Path.join(project, "_build/native/rule-panel-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    try do
      sources =
        ~w(LocalHealthClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativeRuleOperationWire NativeRuleClient NativeScheduleWire NativeScheduleClient NativePendingCodec NativePendingStorage NativePendingCoordinator NativePendingRecoveryOperations NativePendingPanel NativeRulePanel)

      sources = Enum.uniq(sources ++ Woh.Tool.NativePairedRecoverySources.names())

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
          [Path.join(project, "native/macos/Tests/NativeRulePanelSmoke.swift"), "-o", executable]

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
    journal = directory(root, "journal")
    {:ok, store} = Store.start_link(path: Path.join(root, "home.sqlite"))
    {:ok, thing} = thing()
    {:ok, 1} = Store.enroll_thing(store, thing)
    permissions = ~w(read rule:review rule:manage control:ordinary)
    {:ok, original, 2} = Store.provision_principal(store, @principal, permissions, [thing.id])

    {:ok, other, 3} =
      Store.provision_principal(store, "manager:rule-panel-other", permissions, [thing.id])

    authority = Authority.new(store: store)
    socket = Path.join(root, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(root, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    {:ok, evidence} =
      Agent.start_link(fn ->
        %{
          first: nil,
          originals: [],
          requests: [],
          mutations: [],
          error: false,
          tampered: false,
          identities: 0
        }
      end)

    proxy = Task.async(fn -> proxy(listener, socket, journal, store, evidence, mode) end)

    input =
      JSON.encode!(%{
        "original" => Base.url_encode64(original, padding: false),
        "other" => Base.url_encode64(other, padding: false)
      }) <> "\n"

    try do
      with :ok <- run_fixture(executable, path, journal, mode, preview, input),
           :ok <- restart(executable, path, journal, mode, preview, input),
           state <- Agent.get(evidence, & &1),
           false <- state.error,
           {:ok, %{store_revision: revision, dispatch_enabled: false, writable: true}} <-
             Store.health(store),
           true <- revision == expected_revision(mode),
           true <-
             Enum.all?(
               state.requests,
               &(&1["credential"] == Base.url_encode64(original, padding: false))
             ),
           true <- exact_retry?(state),
           :ok <- final_journal(journal, mode),
           :ok <- final_policy(authority, original, mode),
           do: :ok,
           else: (_ -> {:error, "original input, revision, custody or retained journal differed"})
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)
      for pid <- [evidence, server, store], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp restart(executable, path, journal, mode, preview, input) do
    if String.contains?(mode, "restart") do
      with :ok <-
             run_fixture(
               executable,
               path,
               journal,
               if(String.ends_with?(mode, "retry"), do: "recover-retry", else: "recover-lookup"),
               preview,
               input
             ),
           :ok <- run_fixture(executable, path, journal, "invoke-restarted", preview, input),
           do: :ok
    else
      :ok
    end
  end

  defp run_fixture(executable, path, journal, mode, preview, input) do
    with {:ok, output} <-
           Command.run(executable, [path, mode, journal, preview], 16_384, 30_000, [], input),
         {:ok, %{"complete" => true}} <- JSON.decode(String.trim(output)),
         do: :ok,
         else: (
           {:ok, %{"complete" => false, "line" => line}} -> {:error, "fixture assertion #{line}"}
           {:error, reason} when is_binary(reason) -> {:error, reason}
           _ -> {:error, "foreground rule fixture did not complete"}
         )
  end

  defp expected_revision("lifecycle"), do: 9

  defp expected_revision(mode) do
    cond do
      mode in ["admit-changed", "admit-controller", "admit-edited"] -> 3
      mode == "admit-refused" -> 5
      String.starts_with?(mode, "activate") -> 5
      String.starts_with?(mode, "invoke") or String.contains?(mode, "restart") -> 6
      true -> 4
    end
  end

  defp exact_retry?(state) do
    Enum.all?(state.mutations, fn request ->
      Enum.all?(state.mutations, fn other ->
        request["operation_id"] != other["operation_id"] or request == other
      end)
    end)
  end

  defp final_journal(journal, mode) do
    if mode in ["admit-changed", "admit-controller", "admit-edited"] do
      if File.exists?(Path.join(journal, "native-pending-v1.json")),
        do: {:error, :unexpected_publication},
        else: :ok
    else
      with {:ok, bytes} <- File.read(Path.join(journal, "native-pending-v1.json")),
           {:ok, ["wotex-home.native-pending.v3", revision, entries]} <- JSON.decode(bytes),
           true <- is_integer(revision) and revision > 0,
           true <- if(mode == "admit-refused", do: length(entries) == 1, else: entries == []),
           do: :ok,
           else: (_ -> {:error, :invalid_final_journal})
    end
  end

  defp final_policy(authority, credential, mode) do
    if mode in ["admit-refused", "admit-first-refused"] do
      if Authority.rule_status(authority, credential) == {:error, :unauthorized},
        do: :ok,
        else: {:error, :revocation_unconfirmed}
    else
      with {:ok, current} <- Authority.current_rule_source(authority, credential),
           true <-
             if(
               String.starts_with?(mode, "activate") or String.starts_with?(mode, "invoke") or
                 String.contains?(mode, "restart"),
               do: current.state == :active and current.rule != nil,
               else: current.state == :inactive
             ),
           do: :ok,
           else: (_ -> {:error, :unexpected_policy})
    end
  end

  defp proxy(listener, socket, journal, store, evidence, mode) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          case exchange(peer, socket, journal, store, evidence, mode) do
            :ok -> :ok
            _ -> Agent.update(evidence, &%{&1 | error: true})
          end
        rescue
          _ -> Agent.update(evidence, &%{&1 | error: true})
        catch
          _, _ -> Agent.update(evidence, &%{&1 | error: true})
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
         :ok <- verify_publication(journal, store, request) do
      state = Agent.get(evidence, & &1)
      mutation = request["operation"] in @mutations
      target = mutation and request["operation"] == target_operation(mode)
      first = target and state.first == nil

      if first and mode == "admit-stale",
        do: {:ok, _, _} = Store.provision_principal(store, "reader:fixture", ["read"], [])

      if first and mode == "admit-first-refused",
        do: {:ok, _} = Store.revoke_principal(store, @principal)

      unsent = first and mode in ["admit-unsubmitted", "admit-missing"]

      response =
        if unsent do
          nil
        else
          case Client.request(socket, request, 12_000) do
            {:ok, response} -> response
            _ -> nil
          end
        end

      if first and mode == "admit-refused",
        do: {:ok, _} = Store.revoke_principal(store, @principal)

      {response, tampered} = adjust(response, request, state, mode, first)

      drop =
        first and
          mode not in [
            "lifecycle",
            "admit-stale",
            "admit-first-refused",
            "admit-publication",
            "admit-tampered"
          ]

      Agent.update(evidence, fn state ->
        %{
          state
          | first: if(first, do: request, else: state.first),
            requests: state.requests ++ [request],
            mutations: state.mutations ++ if(mutation, do: [request], else: []),
            originals: state.originals ++ if(mutation, do: [record(request)], else: []),
            tampered: state.tampered or tampered,
            identities:
              state.identities + if(request["operation"] == "controller_identity", do: 1, else: 0)
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

  defp target_operation(mode) do
    cond do
      mode == "lifecycle" -> nil
      String.starts_with?(mode, "review") -> "record_rule_review"
      String.starts_with?(mode, "activate") -> "activate_rule"
      String.starts_with?(mode, "invoke") -> "invoke_rule"
      true -> "admit_rule"
    end
  end

  defp adjust(response, request, state, mode, first) do
    cond do
      mode == "admit-controller" and request["operation"] == "controller_identity" and
        state.identities == 1 and is_map(response) ->
        {put_in(response, ["controller_identity", "deployment_id"], String.duplicate("a", 64)),
         false}

      mode == "admit-tampered" and first and is_map(response) ->
        {put_in(response, ["rule_receipt", "operation_id"], "rule:substituted"), true}

      mode == "admit-lookup-tampered" and request["operation"] == "rule_original_status" and
        not state.tampered and is_map(response) ->
        {put_in(response, ["rule_original", "input_digest"], String.duplicate("0", 64)), true}

      true ->
        {response, false}
    end
  end

  defp verify_publication(journal, store, request) do
    if request["operation"] in @mutations do
      expected = record(request)

      with {:ok, bytes} <- Base.url_decode64(request["credential"], padding: false),
           {:ok, identity} <- Store.native_setup_identity(store),
           {:ok, raw} <- File.read(Path.join(journal, "native-pending-v1.json")),
           {:ok,
            [
              "wotex-home.native-pending.v3",
              revision,
              [
                [
                  "rule",
                  [deployment, owner, 1, @principal],
                  ["manual", verifier],
                  ^expected,
                  ["pending"]
                ]
              ]
            ]} <- JSON.decode(raw),
           true <-
             is_integer(revision) and revision > 0 and deployment == identity["deployment_id"] and
               owner == identity["owner_id"],
           true <- verifier == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
           do: :ok,
           else: (_ -> {:error, :original_publication_differed})
    else
      :ok
    end
  end

  defp record(request) do
    prefix = ["wotex-home.explicit-rule-operation.v1"]

    case request["operation"] do
      operation when operation in ~w(record_rule_review admit_rule) ->
        kind = if operation == "admit_rule", do: "admit", else: "review"
        [source] = request["rules"]

        input = %{
          "authority_epoch" => request["authority_epoch"],
          "operation_id" => request["operation_id"],
          "expected_revision" => request["expected_revision"],
          "rule_id" => source["id"],
          "source_revision" => source["source_revision"],
          "target_id" => source["effect"]["target_id"],
          "on" => source["effect"]["value"]["value"]
        }

        {:ok, canonical} = OperationInput.source(kind, input)
        {:ok, typed} = Rule.new(source)
        {:ok, ^canonical} = Codec.encode([typed])
        {:ok, record} = OperationInput.encode(kind, input)
        JSON.decode!(record)

      "activate_rule" ->
        prefix ++
          [
            "activate",
            request["authority_epoch"],
            request["operation_id"],
            request["expected_revision"],
            request["admission_revision"]
          ]

      "invoke_rule" ->
        prefix ++
          [
            "invoke",
            request["authority_epoch"],
            request["operation_id"],
            request["rule_generation"],
            request["rule_id"]
          ]
    end
  end

  defp thing do
    Thing.new(%{
      "id" => "light:rule-fixture",
      "role" => "Light",
      "profile_ref" => "fixture:rule:1",
      "capabilities" => [
        %{
          "thing_id" => "light:rule-fixture",
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => ["read", "write"],
          "risk_class" => "ordinary",
          "profile_ref" => "fixture:rule:1",
          "evidence_ref" => "fixture:rule-panel",
          "freshness_ms" => 5_000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    })
  end

  defp directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

defmodule Mix.Tasks.Woh.Native.Rule.Panel.Smoke do
  @moduledoc "Actual private-Store native rule decisions, original publication and restart recovery; no signing, Keychain or physical effects."
  @shortdoc "Check native explicit rule panel against Store"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeRulePanelSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native explicit rule panel 22 private Store and restart workflows passed"
        )

      {:error, reason} ->
        Mix.raise("native rule panel smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.rule.panel.smoke")
end
