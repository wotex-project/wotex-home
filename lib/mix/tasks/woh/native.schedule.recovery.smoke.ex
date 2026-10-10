defmodule Woh.Tool.NativeScheduleRecoverySmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Rules.OperationInput, as: RuleInput
  alias WotexHome.Schedules.{ClockCodec, ClockOwner, Codec, OperationInput}
  alias WotexHome.Recovery.PrivateFile
  alias WotexHome.Semantics.Thing
  @principal "manager:schedule-fixture"
  @mutations ~w(schedule_review schedule_admit schedule_activate schedule_suspend)
  @modes for(
           kind <- ~w(review admit activate suspend),
           action <- ~w(lookup retry),
           do: kind <> "-" <> action
         ) ++
           ~w(admit-unsubmitted admit-missing admit-refused admit-scope admit-tampered admit-publication)

  def run(project) do
    root =
      directory("/private/tmp", "sr-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")

    executable = Path.join(root, "recovery")

    try do
      sources =
        ~w(LocalHealthClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativeRuleOperationWire NativeRuleClient NativeScheduleWire NativeScheduleClient NativePendingCodec NativePendingStorage NativePendingCoordinator NativePendingRecoveryOperations NativePendingPanel)

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
          [
            Path.join(project, "native/macos/Tests/NativeScheduleRecoverySmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 90_000) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(executable, directory(root, mode), mode) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp check(executable, root, mode) do
    journal = directory(root, "journal")
    {:ok, store} = Store.start_link(path: Path.join(root, "home.sqlite"))
    {:ok, thing} = thing()
    {:ok, 1} = Store.enroll_thing(store, thing)
    permissions = ~w(read rule:review rule:manage control:ordinary)
    {:ok, original, 2} = Store.provision_principal(store, @principal, permissions, [thing.id])

    {:ok, other, 3} =
      Store.provision_principal(store, "manager:schedule-other", permissions, [thing.id])

    {:ok, gate} = WotexHome.Authority.ReviewGate.start_link(limit: 1)
    authority = Authority.new(store: store, review_gate: gate)
    kind = mode |> String.split("-") |> hd()
    clock = if kind == "activate", do: attach_clock(root, store)

    if kind == "activate",
      do:
        {:ok, _} =
          Authority.retain_schedule_content(
            authority,
            original,
            "admit",
            document("admit", "schedule:seed", 3)
          )

    expected = if kind == "activate", do: 4, else: 3
    document = document(kind, "schedule:original", expected)
    socket = Path.join(root, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(root, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    {:ok, evidence} =
      Agent.start_link(fn -> %{first: nil, requests: [], error: false, tampered: false} end)

    proxy = Task.async(fn -> proxy(listener, socket, journal, store, evidence, mode) end)

    input =
      JSON.encode!(%{
        "original" => Base.url_encode64(original, padding: false),
        "other" => Base.url_encode64(other, padding: false),
        "document" => document
      }) <> "\n"

    try do
      with :ok <- run_fixture(executable, path, journal, mode, "create", input),
           {:ok, before} <- Store.health(store),
           true <- before.store_revision == expected + created_revisions(mode, kind),
           :ok <- maybe_recover(executable, path, journal, mode, input),
           {:ok, after_recovery} <- Store.health(store),
           true <-
             after_recovery.store_revision ==
               before.store_revision + if(mode == "admit-unsubmitted", do: 1, else: 0),
           true <-
             after_recovery.dispatch_enabled == false && after_recovery.held_requests == 0 &&
               after_recovery.queued_requests == 0,
           state <- Agent.get(evidence, & &1),
           false <- state.error,
           true <- exact_requests?(state, mode, document),
           request_count = length(state.requests),
           :ok <- run_fixture(executable, path, journal, mode, "verify", input),
           true <- request_count == length(Agent.get(evidence, & &1.requests)),
           do: :ok,
           else: (
             {:error, reason} -> {:error, reason}
             _ -> {:error, "journal, original correspondence or Store revision differed"}
           )
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)

      for pid <- [clock, evidence, server, gate, store],
          is_pid(pid) and Process.alive?(pid),
          do: GenServer.stop(pid)
    end
  end

  defp created_revisions(mode, kind) do
    cond do
      mode in ~w(admit-missing admit-unsubmitted) -> 0
      mode == "admit-refused" -> 2
      kind in ~w(activate suspend) -> 2
      true -> 1
    end
  end

  defp maybe_recover(_, _, _, "admit-publication", _), do: :ok

  defp maybe_recover(executable, socket, journal, mode, input),
    do: run_fixture(executable, socket, journal, mode, "recover", input)

  defp run_fixture(executable, socket, journal, mode, stage, input) do
    preview = Path.expand("_build/native/schedule-pending-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    with {:ok, output} <-
           Command.run(
             executable,
             [socket, journal, mode, stage, preview],
             16_384,
             25_000,
             [],
             input
           ),
         {:ok, %{"complete" => true}} <- JSON.decode(String.trim(output)),
         do: :ok,
         else: (
           {:ok, %{"line" => line}} -> {:error, "#{stage} assertion #{line}"}
           {:error, reason} -> {:error, reason}
           _ -> {:error, "#{stage} did not complete"}
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
      first = mutation and is_nil(state.first)
      unsent = first and mode in ~w(admit-unsubmitted admit-missing)

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

      {response, tampered} =
        cond do
          mode == "admit-scope" and not is_nil(state.first) and
            request["operation"] == "controller_identity" and is_map(response) ->
            {put_in(response, ["controller_identity", "owner_id"], String.duplicate("0", 64)),
             false}

          mode == "admit-tampered" and request["operation"] == "schedule_original_status" and
            not state.tampered and is_map(response) ->
            {put_in(response, ["schedule_receipt", "input_digest"], String.duplicate("0", 64)),
             true}

          true ->
            {response, false}
        end

      Agent.update(evidence, fn s ->
        %{
          s
          | first: if(first, do: request, else: s.first),
            requests: s.requests ++ [request],
            tampered: s.tampered or tampered
        }
      end)

      if is_map(response) and not (first and mode != "admit-publication") do
        {:ok, frame} = Frame.encode_response(response)
        :gen_tcp.send(peer, frame)
      else
        :ok
      end
    end
  end

  defp publication(journal, store, request) do
    if request["operation"] in @mutations do
      original = request["original_document"]

      with {:ok, raw} <- File.read(Path.join(journal, "native-pending-v1.json")),
           {:ok,
            [
              "wotex-home.native-pending.v4",
              1,
              [
                [
                  "schedule",
                  [deployment, owner, 1, @principal],
                  ["manual", verifier],
                  ["schedule_operation", ^original],
                  ["pending"]
                ]
              ]
            ]} <- JSON.decode(raw),
           {:ok, identity} <- Store.native_setup_identity(store),
           true <- deployment == identity["deployment_id"] and owner == identity["owner_id"],
           {:ok, credential} <- Base.url_decode64(request["credential"], padding: false),
           true <- verifier == Codec.hash(credential),
           do: :ok,
           else: (_ -> {:error, :unpublished_original})
    else
      :ok
    end
  end

  defp exact_requests?(state, mode, document) do
    mutations = Enum.filter(state.requests, &(&1["operation"] in @mutations))
    originals = Enum.filter(state.requests, &Map.has_key?(&1, "original_document"))

    length(mutations) ==
      if(String.ends_with?(mode, "retry") or mode == "admit-unsubmitted", do: 2, else: 1) and
      Enum.all?(mutations, &(&1 == state.first)) and
      Enum.all?(originals, &(&1["original_document"] == document)) and
      Enum.all?(state.requests, &(&1["credential"] == state.first["credential"]))
  end

  defp document(kind, operation, expected) do
    common = %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => expected
    }

    input =
      cond do
        kind == "activate" ->
          Map.put(common, "admission_revision", 4)

        kind == "suspend" ->
          common

        true ->
          {:ok, rule} =
            RuleInput.source("admit", %{
              "authority_epoch" => 1,
              "operation_id" => "rule:body",
              "expected_revision" => 3,
              "rule_id" => "rule:one",
              "source_revision" => 1,
              "target_id" => "light:schedule-fixture",
              "on" => true
            })

          {:ok, source} =
            Codec.encode(%{
              "id" => "schedule:one",
              "source_revision" => 1,
              "author_id" => @principal,
              "rule_id" => "rule:one",
              "rule_source_digest" => Codec.hash(rule),
              "target_id" => "light:schedule-fixture",
              "resource_revision" => 0,
              "late_window_ms" => 10_000,
              "uncertainty_tolerance_ms" => 1_000,
              "trigger" => ["interval", 100_000, 60_000, 0, nil]
            })

          Map.merge(common, %{"source_document" => source, "rule_document" => rule})
      end

    {:ok, document} = OperationInput.encode(kind, input)
    document
  end

  def attach_clock(root, store) do
    requests = directory(root, "clock-requests")
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, runtime} = ClockOwner.runtime_digest()

    policy = %{
      source_id: "clock:software-fixture",
      issuer_id: "issuer:software-fixture",
      public_key: public,
      issuer_generation: 1,
      procedure_ref: "procedure:software-only",
      qualification_digest: String.duplicate("a", 64),
      runtime_digest: runtime,
      maximum_response_ms: 30_000,
      maximum_age_ms: 120_000,
      maximum_error_ms: 0,
      drift_ppm: 10,
      maximum_discontinuity_ms: 20,
      monotonic_policy: "invalidate_on_discontinuity"
    }

    {:ok, document} = ClockCodec.policy_document(policy)
    file = Path.join(root, "clock.policy")
    :ok = PrivateFile.write(file, document, 4_096)

    {:ok, owner} =
      ClockOwner.start_link(store: store, operator: self(), root: requests, policy_file: file)

    {:ok, request} = ClockOwner.request(owner)
    {:ok, document} = PrivateFile.read(request.request_file, 4_096)
    {:ok, input} = ClockCodec.decode_request(document)

    record =
      Map.merge(input, %{
        "procedure_ref" => policy.procedure_ref,
        "observed_utc_ms" => System.system_time(:millisecond)
      })

    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(record, :crypto.sign(:eddsa, :none, payload, [private, :ed25519]))

    {:ok, _} = ClockOwner.approve(owner, request.request_digest, package)
    :ok = Store.attach_temporal_clock(store, owner)
    owner
  end

  def thing do
    Thing.new(%{
      "id" => "light:schedule-fixture",
      "role" => "Light",
      "profile_ref" => "fixture:schedule:1",
      "capabilities" => [
        %{
          "thing_id" => "light:schedule-fixture",
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => ["read", "write"],
          "risk_class" => "ordinary",
          "profile_ref" => "fixture:schedule:1",
          "evidence_ref" => "fixture:schedule-recovery",
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

defmodule Mix.Tasks.Woh.Native.Schedule.Recovery.Smoke do
  @moduledoc "Private native schedule journal and exact recovery across real app processes and Store IPC, without Keychain or hardware effects."
  @shortdoc "Check native schedule original recovery"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeScheduleRecoverySmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native schedule recovery 14 private Store and process restart workflows passed"
        )

      {:error, reason} ->
        Mix.raise("native schedule recovery smoke failed: #{inspect(reason)}")

      _ ->
        Mix.raise("native schedule recovery fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.schedule.recovery.smoke")
end
