defmodule Woh.Tool.NativeAccessPanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Server
  alias WotexHome.NativeSetup.TargetCodec
  alias WotexHome.Profiles.{Custody, ReviewSession}
  @custody __MODULE__.Custody
  @reviews __MODULE__.Reviews
  @modes ~w(grant-success grant-lost grant-unsubmitted grant-refused grant-stale grant-changed-session grant-changed-reference grant-publication grant-unavailable grant-tampered revoke-success revoke-lost revoke-unavailable restart-lookup restart-retry)

  def run(project) do
    Code.require_file(Path.join(project, "test/support/portable_profile_fixture.exs"))

    root =
      directory("/private/tmp", "wa-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")

    executable = Path.join(root, "access-panel")
    preview = Path.join(project, "_build/native/access-panel-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    try do
      with :ok <- compile(project, executable) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(project, executable, directory(root, mode), mode, preview) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{inspect(reason)}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp compile(project, executable) do
    sources =
      ~w(LocalHealthClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativePendingCodec NativePendingStorage NativePendingCoordinator NativePendingRecoveryOperations NativePendingPanel NativeAccessPanel)

    args =
      [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(Path.dirname(executable), "cache"),
        "-framework",
        "SwiftUI",
        "-framework",
        "AppKit",
        "-framework",
        "Security"
      ] ++
        Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
        [Path.join(project, "native/macos/Tests/NativeAccessPanelSmoke.swift"), "-o", executable]

    case Command.run("swiftc", args, 1_048_576, 60_000) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp check(project, executable, root, mode, preview) do
    profiles = directory(root, "profiles")
    journal = directory(root, "journal")

    {:ok, store} =
      Store.start_link(
        path: Path.join(root, "home.sqlite"),
        profile_custody: @custody,
        profile_reviews: @reviews
      )

    {:ok, custody} = Custody.start_link(root: profiles, name: @custody, store_owner: store)
    {:ok, reviews} = ReviewSession.start_link(custody: custody, name: @reviews)
    {:ok, scope} = WotexHome.Lifx.IPv4Scope.new({192, 0, 2, 2}, 24)

    {:ok, capture} =
      WotexHome.Lifx.CaptureSession.start_link(
        interface_id: "en0",
        scope: scope,
        transport: {Woh.Tool.NativeProfilesPanelSmoke.Peer, :fixture}
      )

    authority =
      Authority.new(
        store: store,
        profile_custody: custody,
        profile_reviews: reviews,
        capture: capture
      )

    fixture = apply(WotexHome.Test.PortableProfileFixture, :context, [])
    [candidate] = fixture.evidence.candidates
    interview = fixture.evidence.interview

    {:ok, package} =
      WotexHome.Lifx.ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:fixture")

    {:ok, operator, _} =
      Store.provision_principal(
        store,
        "operator:access-fixture",
        ["profile:manage", "enroll:review"],
        []
      )

    {:ok, maintainer, _} =
      Store.provision_principal(store, "maintainer:access-fixture", ["host:maintain"], [])

    enrollment = %{
      "operator_id" => "operator:access-fixture",
      "candidate_ref" => candidate.raw_ref,
      "stable_id" => interview.stable_id,
      "profile_ref" => fixture.current.profile_ref,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:access-fixture"
    }

    {:ok, _} =
      Store.commit_enrollment(
        store,
        operator,
        [candidate],
        interview,
        [package.profile],
        fixture.current,
        enrollment
      )

    secret = :crypto.strong_rand_bytes(32)
    {:ok, identity} = Authority.native_setup_identity(authority)

    native =
      identity
      |> Map.drop(["store_revision"])
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
      })

    {:ok, creation} = Authority.ensure_native_principal(authority, native)

    {:ok, digest} =
      Authority.stage_profile(
        authority,
        operator,
        File.read!(Path.join(project, "test/support/profiles/lifx-power.json"))
      )

    {:ok, revision} = Store.revision(store)

    {:ok, _} =
      Authority.begin_maintenance(authority, maintainer, 1, "maintenance:access", revision)

    {:ok, revision} = Store.revision(store)

    {:ok, approval} =
      Authority.profile_change(authority, operator, %{
        "action" => "approve",
        "authority_epoch" => 1,
        "operation_id" => "approve:access",
        "expected_revision" => revision,
        "artifact_digest" => digest,
        "expected_trust_revision" => 0
      })

    {:ok, session, [%{raw_ref: candidate}]} = Authority.lifx_discover(authority, operator)
    {:ok, _, _} = Authority.lifx_interview(authority, operator, session, candidate)
    {:ok, target} = Authority.profile_target(authority, operator, "light:fixture")

    selection = %{
      "action" => "select",
      "authority_epoch" => 1,
      "operation_id" => "select:access",
      "expected_revision" => target.store_revision,
      "artifact_digest" => digest,
      "expected_trust_revision" => approval.final_revision,
      "target_id" => target.target_id,
      "expected_resource_revision" => target.resource_revision,
      "expected_binding_revision" => target.binding_revision,
      "expected_selection_generation" => 0,
      "expected_policy_generation" => target.policy_generation,
      "expected_rule_generation" => target.rule_generation,
      "session_ref" => session,
      "candidate_ref" => candidate,
      "review_ref" => "review:access"
    }

    {:ok, _} = Authority.prepare_profile_selection(authority, operator, selection)
    {:ok, _} = Authority.profile_change(authority, operator, selection)
    {:ok, %{begin_revision: begin_revision}} = Authority.maintenance_status(authority, maintainer)
    {:ok, revision} = Store.revision(store)

    {:ok, _} =
      Authority.end_maintenance(
        authority,
        maintainer,
        1,
        "maintenance:access:end",
        revision,
        begin_revision
      )

    original = native |> Map.delete("role") |> Map.put("creation_revision", creation["revision"])

    if String.starts_with?(mode, "revoke") do
      {:ok, target} = Authority.profile_target(authority, secret, "light:fixture")

      grant =
        Map.merge(original, %{
          "operation_id" => "access:initial",
          "expected_revision" => target.store_revision,
          "target_id" => target.target_id,
          "resource_revision" => target.resource_revision,
          "binding_revision" => target.binding_revision,
          "selection_generation" => target.selection_generation,
          "artifact_digest" => target.artifact_digest
        })

      {:ok, _} = Authority.native_target_change(authority, "grant", grant)
    end

    if mode == "revoke-unavailable", do: File.rm!(Path.join(profiles, digest <> ".json"))
    {:ok, base_revision} = Store.revision(store)
    api = Path.join(root, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: api)
    access_path = Path.join(root, "fixture-access.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ifaddr: {:local, String.to_charlist(access_path)}
      ])

    File.chmod!(access_path, 0o600)
    {:ok, evidence} = Agent.start_link(fn -> %{requests: [], first: nil, mutations: 0} end)
    proxy = Task.async(fn -> proxy(listener, authority, store, journal, mode, evidence) end)

    reference =
      JSON.encode!([
        "wotex-home.native-credential-broker.v1",
        "recover",
        native["deployment_id"],
        native["owner_id"],
        1,
        "operator",
        native["verifier"],
        creation["revision"]
      ])

    input =
      JSON.encode!(%{
        "secret" => Base.url_encode64(secret, padding: false),
        "reference" => reference
      }) <> "\n"

    try do
      result =
        if String.starts_with?(mode, "restart-") do
          with :ok <-
                 run_fixture(executable, api, access_path, journal, "create-lost", preview, input),
               {:ok, committed} <- Store.revision(store),
               bytes <- File.read!(Path.join(journal, "native-pending-v1.json")),
               :ok <- run_fixture(executable, api, access_path, journal, mode, preview, input),
               {:ok, ^committed} <- Store.revision(store),
               true <- bytes != File.read!(Path.join(journal, "native-pending-v1.json")),
               do: :ok
        else
          run_fixture(executable, api, access_path, journal, mode, preview, input)
        end

      with :ok <- result,
           {:ok, %{dispatch_enabled: false, writable: true}} <- Store.health(store),
           {:ok, %{qualification_head: nil}} <-
             Authority.profile_target(authority, operator, "light:fixture"),
           {:ok, final_revision} <- Store.revision(store),
           true <- final_revision == base_revision + delta(mode),
           true <- valid_requests?(Agent.get(evidence, & &1), mode),
           do: :ok,
           else: (_ -> {:error, "access model, original publication or Store result differed"})
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)

      for pid <- [evidence, server, capture, reviews, custody, store],
          Process.alive?(pid),
          do: GenServer.stop(pid)
    end
  end

  defp proxy(listener, authority, store, journal, mode, evidence) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 5_000)
          true = size in 1..4_096
          {:ok, bytes} = :gen_tcp.recv(peer, size, 5_000)
          [_, kind | _] = JSON.decode!(bytes)
          {:ok, input} = TargetCodec.decode(kind, bytes)
          true = published?(journal, kind, input, bytes)
          state = Agent.get(evidence, & &1)
          first = state.first || bytes

          Agent.update(
            evidence,
            &%{
              &1
              | requests: &1.requests ++ [{kind, bytes}],
                first: first,
                mutations: &1.mutations + if(kind == "status", do: 0, else: 1)
            }
          )

          if mode == "grant-stale" && state.requests == [],
            do: Store.provision_principal(store, "readonly:changed", ["read"], [])

          drop =
            state.requests == [] &&
              mode in ~w(grant-lost grant-unsubmitted grant-refused revoke-lost restart-lookup restart-retry)

          if mode != "grant-unsubmitted" || state.requests != [] do
            result =
              if kind == "status",
                do: Authority.native_target_status(authority, input),
                else: Authority.native_target_change(authority, kind, input)

            {:ok, reply} =
              case result do
                {:ok, receipt} ->
                  TargetCodec.encode(
                    "receipt",
                    if(mode == "grant-tampered" && state.requests == [],
                      do: %{receipt | "input_digest" => String.duplicate("0", 64)},
                      else: receipt
                    )
                  )

                :not_found ->
                  TargetCodec.encode("not_found", input)

                {:error, reason} ->
                  TargetCodec.encode("error", %{"reason" => Atom.to_string(reason)})
              end

            if mode == "grant-refused" && state.requests == [],
              do: Store.revoke_principal(store, "native-setup-v1:1:operator")

            unless drop, do: :gen_tcp.send(peer, <<byte_size(reply)::32, reply::binary>>)
          end
        after
          :gen_tcp.close(peer)
        end

        proxy(listener, authority, store, journal, mode, evidence)

      {:error, :closed} ->
        :ok
    end
  end

  defp published?(journal, kind, input, bytes) do
    [
      "wotex-home.native-pending.v2",
      _,
      [
        [
          "access",
          [deployment, owner, epoch, principal],
          ["native", "operator", creation, verifier],
          operation,
          ["pending"]
        ]
      ]
    ] = JSON.decode!(File.read!(Path.join(journal, "native-pending-v1.json")))

    true = principal == "native-setup-v1:#{epoch}:operator"

    original = %{
      "deployment_id" => deployment,
      "owner_id" => owner,
      "authority_epoch" => epoch,
      "creation_revision" => creation,
      "verifier" => verifier
    }

    expected =
      case operation do
        ["native_target_grant", op, revision, target, resource, binding, generation, artifact] ->
          Map.merge(original, %{
            "operation_id" => op,
            "expected_revision" => revision,
            "target_id" => target,
            "resource_revision" => resource,
            "binding_revision" => binding,
            "selection_generation" => generation,
            "artifact_digest" => artifact
          })

        ["native_target_revoke", op, revision, target] ->
          Map.merge(original, %{
            "operation_id" => op,
            "expected_revision" => revision,
            "target_id" => target
          })
      end

    expected =
      if kind == "status",
        do:
          Map.take(
            expected,
            ~w(deployment_id owner_id authority_epoch creation_revision verifier operation_id)
          ),
        else: expected

    {:ok, canonical} = TargetCodec.encode(kind, expected)
    canonical == bytes && input == expected
  end

  defp delta(mode)
       when mode in ~w(grant-changed-session grant-changed-reference grant-unavailable), do: 0

  defp delta("grant-refused"), do: 2
  defp delta(_), do: 1

  defp valid_requests?(%{requests: requests, first: first}, mode) do
    changes = for {kind, bytes} <- requests, kind != "status", do: bytes

    case mode do
      value when value in ~w(grant-changed-session grant-changed-reference grant-unavailable) ->
        requests == []

      "grant-refused" ->
        length(changes) == 3 && Enum.all?(changes, &(&1 == first))

      "grant-unsubmitted" ->
        length(requests) == 3 && length(changes) == 2 && Enum.all?(changes, &(&1 == first))

      "restart-retry" ->
        length(changes) == 2 && Enum.all?(changes, &(&1 == first))

      value when value in ~w(grant-lost revoke-lost restart-lookup grant-tampered) ->
        length(requests) == 2 && length(changes) == 1

      _ ->
        length(requests) == 1
    end
  end

  defp run_fixture(executable, api, access, journal, mode, preview, input) do
    with {:ok, output} <-
           Command.run(
             executable,
             [api, access, journal, mode, preview],
             16_384,
             20_000,
             [],
             input
           ),
         {:ok, %{"complete" => true}} <- JSON.decode(String.trim(output)),
         do: :ok,
         else: (
           {:ok, %{"complete" => false, "line" => line}} ->
             {:error, "native access assertion #{line}"}

           error ->
             error
         )
  end

  defp directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

defmodule Mix.Tasks.Woh.Native.Access.Panel.Smoke do
  @moduledoc "Checks explicit native access model publication/recovery with private actual Stores and inert custody; no signed-host or physical qualification."
  @shortdoc "Check native access review and original recovery"
  @requirements ["loadpaths"]
  use Mix.Task
  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeAccessPanelSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native access passed fifteen actual Store review/publication/recovery workflows; no signed custody or device packets"
        )

      {:error, reason} ->
        Mix.raise("native access panel smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.access.panel.smoke")
end
