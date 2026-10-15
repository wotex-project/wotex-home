defmodule Woh.Tool.PairedWorkspaceProvider do
  @moduledoc false

  use GenServer

  def init({draft, release, invalid_first}),
    do:
      {:ok,
       %{
         draft: draft,
         release: release,
         invalid_first: invalid_first,
         calls: 0,
         pending: nil,
         deadline: nil
       }}

  def handle_call(:calls, _, state), do: {:reply, state.calls, state}

  def handle_call({:generate_profile, _document, _maximum}, from, %{pending: nil} = state) do
    Process.send_after(self(), :release, 10)

    {:noreply,
     %{
       state
       | pending: from,
         calls: state.calls + 1,
         deadline: System.monotonic_time(:millisecond) + 8000
     }}
  end

  def handle_info(:release, state) do
    cond do
      File.regular?(state.release) ->
        draft = if state.invalid_first && state.calls == 1, do: "{}", else: state.draft
        GenServer.reply(state.pending, {:ok, draft})
        {:noreply, %{state | pending: nil}}

      System.monotonic_time(:millisecond) >= state.deadline ->
        GenServer.reply(state.pending, {:error, :fixture_release_missing})
        {:noreply, %{state | pending: nil}}

      true ->
        Process.send_after(self(), :release, 10)
        {:noreply, state}
    end
  end

  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_paired_workspace_provider)
      |> Map.put(:message, :redacted)
end

defmodule Mix.Tasks.Woh.Native.Paired.Recovery.Smoke do
  @moduledoc """
  Checks original paired recovery custody, transport and power receipts.

  Run `mix woh.native.paired.recovery.smoke` on Apple Silicon macOS 15 or later
  with the Swift 6 toolchain. The task compiles and runs bounded Swift fixtures
  with warnings rejected. Compilation, exchange and assertion failures fail
  the Mix task.

  Checks original paired metadata/unsigned production refusal and the closed
  adapter over actual Authority pairing, TLS, SQLite restart and exact
  original retries. Paired manual import, candidate assessment and source review
  lose their committed replies, then resolve by existing-only reads without
  replay. Their durable history survives native/Store restart and revocation
  retains the original. Both quantity families also exercise generation
  preparation/start reply loss, workspace-required retry, running-to-unknown
  restart, separately confirmed acknowledgements and unsafe workspace isolation.
  A gated synthetic provider is called once per ordinary cohort. Pass
  `--generation-ui` for the focused two-family invalid-draft/explicit-repair cohort:
  no-consent refusal, checked feedback bytes, two bounded provider calls and the
  same original recovery, restart and revocation checks. This creates no signed
  app session. `--workspace-selectors` runs two nonempty-source/fixture cohorts,
  including multiple passages from one source and wrong object reply refusals.

  For focused power checks, run
  `mix woh.native.paired.recovery.smoke --power-receipts`. This retains the shared
  metadata/unsigned-refusal checks, then exercises actual Authority pairing and
  TLS/Store power originals, identical retries and recorded-controller receipt
  reads. It checks found/not-found results, other-principal visibility, immutable
  pending bytes, Store restart, principal revocation and wrong-principal replies.
  It skips the generation/provider cohorts. Each optional flag selects one
  cohort; flags cannot be combined.

  Native Activity model and shared-panel layout checks are provided separately
  by `Mix.Tasks.Woh.Native.Paired.Power.Receipt.Smoke`. The TLS fixtures use raw
  fixture credentials and do not create a successful production signed session.

  The result is executable software evidence for the tested boundary.
  Installed signing, private account custody and physical device qualification
  require their separate acceptance evidence.
  """

  @shortdoc "Check original paired recovery custody and transport"
  @requirements ["loadpaths"]
  use Mix.Task
  @compile {:no_warn_undefined, WotexHome.TestSupport.ControllerTLSFixture}
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.ControllerConnections.{InstallationIdentity, PairingReview, Server}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Server, as: UDS
  alias WotexHome.Semantics.Thing

  def run(scope)
      when scope in [[], ["--generation-ui"], ["--workspace-selectors"], ["--power-receipts"]] do
    Code.require_file("test/support/controller_tls_fixture.exs")
    root = Path.join("/private/tmp", "woh-paired-recovery-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "paired-recovery")
    associations = Path.expand("test/fixtures/controller_connections/native_associations_v1.json")
    pending = Path.expand("test/fixtures/controller_connections/native_pending_v5.json")

    try do
      sources =
        ~w(NativeControllerPairingWire NativeControllerTLSClient NativeControllerAPIClient NativeControllerDomainClient
        NativeControllerAssociations NativeControllerAssociationStorage NativeControllerPairingCustody
        NativePairedKeychainCustodian NativePairedControllerSession SignedSetupPeer NativeSetupWire NativeTargetWire
        NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments LocalHealthClient NativeBrokerClient
        NativeSetupSocket NativeRuleOperationWire NativeRuleClient NativeScheduleClient NativeScheduleWire
        NativeAuthoringReadClient NativeAuthoringOriginalWire NativePendingAuthoring NativeGenerationOriginalWire NativeGenerationClient NativeExternalProfileClient NativeExternalProfileOriginalWire NativeExternalProfileMutationClient NativePendingCodec NativePendingStorage NativePendingPairedCustody NativeAuthoringMutationClient NativePendingRecoveryOperations
        NativePairedPendingRecoveryOperations NativePairedRecoveryCorrespondence NativePendingCoordinator)

      sources =
        Enum.uniq(
          sources ++
            Woh.Tool.NativePairedRecoverySources.names() ++
            ~w(NativeAuthoringFiles NativeAuthoringSelections NativePairedAuthoringClient NativePairedGenerationClient)
        )

      args =
        [
          "-parse-as-library",
          "-whole-module-optimization",
          "-Onone",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-module-cache-path",
          Path.join(root, "cache"),
          "-target",
          "arm64-apple-macos15.0"
        ] ++
          Enum.map(sources, &Path.expand("native/macos/Sources/#{&1}.swift")) ++
          [Path.expand("native/macos/Tests/NativePairedRecoverySmoke.swift"), "-o", executable]

      checked("swiftc", args, 90_000, nil)

      checked(
        executable,
        [associations, pending, root],
        20_000,
        "native original paired correspondence, publication ownership, unsigned coordinator and production refusal passed"
      )

      checked(
        executable,
        [associations, pending, Path.join(root, "metadata"), "inspect"],
        10_000,
        "fresh original paired journal check passed"
      )

      if scope in [["--generation-ui"], ["--workspace-selectors"]] do
        scenario = if scope == ["--generation-ui"], do: "repair", else: "selectors"

        for family <- ~w(temperature research),
            do: authoring_owner(executable, root, family, scenario)
      else
        actual_owner(executable, root, associations)
        if scope != ["--power-receipts"], do: authoring_owner(executable, root)
        wrong_principal(executable, root)
      end

      message =
        case scope do
          ["--generation-ui"] ->
            "paired two-family explicit repair, checked feedback, original recovery, restart and revocation passed"

          ["--workspace-selectors"] ->
            "paired two-family nonempty selectors, owned-object refusals, original recovery, restart and revocation passed"

          ["--power-receipts"] ->
            "paired power receipt TLS/Store reads, immutable originals, restart, revocation and wrong-principal refusal passed"

          [] ->
            "native paired publication/unsigned refusal, real pairing, manual authoring lost replies without replay, original recovery/restart/revocation and wrong-principal refusal passed"
        end

      Mix.shell().info(message)
    after
      File.rm_rf!(root)
    end
  end

  def run(_),
    do:
      Mix.raise(
        "usage: mix woh.native.paired.recovery.smoke [--generation-ui | --workspace-selectors | --power-receipts]"
      )

  defp actual_owner(executable, root, associations) do
    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "owner.identity"), %{
        not_before: now - 60,
        not_after: now + 86_400
      })

    {:ok, interfaces} = :inet.getifaddrs()

    {interface, _} =
      Enum.find(interfaces, fn {_, props} ->
        {127, 0, 0, 1} in Keyword.get_values(props, :addr)
      end)

    {:ok, reserved} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(reserved)
    :gen_tcp.close(reserved)
    binding = %{interface: List.to_string(interface), address: {127, 0, 0, 1}, port: port}
    first = start_owner(root, identity, binding)
    {store, _, _, listener, authority} = first

    payload =
      try do
        {:ok, _} = Store.enroll_thing(store, thing())
        {:ok, before} = Store.revision(store)
        {:ok, template} = Server.template(listener)
        {:ok, admin, invitation} = Authority.pairing_open(authority, template)

        request =
          peer().request()
          |> Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)))

        {:ok, reference} = Authority.pairing_prepare(authority, admin, request)

        {:ok, _} =
          Authority.pairing_approve(authority, admin, reference, %{
            "permissions" => ["control:ordinary", "read"],
            "target_ids" => ["light:paired-original"]
          })

        directory = private_directory(root, "actual-original")
        {:ok, vectors} = associations |> File.read!() |> JSON.decode()
        other = Enum.at(vectors["valid_records"], 4)["body"]

        input = %{
          "mode" => "stage",
          "invitation" => peer().invitation_body(invitation),
          "bootstrap" => bootstrap_body(request),
          "directory" => directory,
          "other" => other
        }

        transport(executable, input)
        {:ok, staged} = Store.revision(store)
        true = staged == before + 2

        for mode <- ["lookup", "retry"] do
          transport(executable, %{input | "mode" => mode})
          {:ok, current} = Store.revision(store)
          true = current == staged
        end

        {:ok, other_key, _} =
          Store.provision_principal(store, "operator:receipt-other", ["read"], [])

        {:ok, read_revision} = Store.revision(store)

        transport(
          executable,
          Map.merge(input, %{
            "mode" => "other-principal-receipt",
            "other_credential" => Base.url_encode64(other_key, padding: false)
          })
        )

        {:ok, ^read_revision} = Store.revision(store)
        input
      after
        stop_owner(first)
      end

    restarted = start_owner(root, identity, binding)
    {store, _, _, _, _} = restarted

    try do
      {:ok, before} = Store.revision(store)

      for mode <- ["lookup", "retry"] do
        transport(executable, %{payload | "mode" => mode})
        {:ok, current} = Store.revision(store)
        true = current == before
      end

      key = File.read!(Path.join(payload["directory"], "raw-fixture.key"))
      {:ok, scope} = Store.controller_scope(store, key)
      {:ok, _} = Store.revoke_principal(store, scope.principal_id)
      transport(executable, %{payload | "mode" => "revoked"})
      {:ok, %{dispatch_enabled: false}} = Store.health(store)
    after
      stop_owner(restarted)
    end
  end

  defp authoring_owner(executable, parent) do
    for family <- ~w(temperature research),
        scenario <- ~w(complete restart),
        do: authoring_owner(executable, parent, family, scenario)
  end

  defp authoring_owner(executable, parent, family_name, scenario) do
    alias WotexHome.Profiles.{
      AuthoringContract,
      Custody,
      GenerationPolicy,
      GenerationProvider,
      ProducerIdentity
    }

    root = private_directory(parent, "authoring-owner-" <> family_name <> "-" <> scenario)
    _ = private_directory(root, "profiles")
    family = fixture(family_name)
    mechanics = fixture("authoring-mechanics")[family_name]
    {:ok, producer} = ProducerIdentity.current()

    installed =
      family |> Map.take(~w(bindings contracts home_contracts)) |> Map.put("producer", producer)

    {:ok, contract} = AuthoringContract.export(installed, mechanics["limits"])

    {:ok, provider_pid} =
      GenServer.start_link(
        Woh.Tool.PairedWorkspaceProvider,
        {mechanics["draft_bytes"], Path.join(root, "native/model-release"), scenario == "repair"}
      )

    policy_input =
      fixture("generation-preparations")[family_name]["policy"]
      |> Map.put("principal_id", "paired-controller-v1:1:" <> peer().request()["client_id"])
      |> Map.put("passages", [])
      |> Map.put("examples", [])
      |> Map.put("remote_export", false)
      |> update_in(["provider", "locality"], fn _ -> "local" end)

    objects = fixture("generation-inputs")[family_name]["objects"]
    source = Enum.find(objects, &(&1["kind"] == "source"))
    example = Enum.find(objects, &(&1["kind"] == "fixture"))

    policy_input =
      if scenario == "selectors" do
        reference = Map.put(source["reference"], "first_revision", 5)

        policy_input
        |> Map.put("passages", [
          %{"reference" => reference, "offset" => 0, "length" => 26},
          %{"reference" => reference, "offset" => 26, "length" => 58}
        ])
        |> Map.put("examples", [Map.put(example["reference"], "first_revision", 6)])
      else
        policy_input
      end

    {:ok, policy} = GenerationPolicy.new(policy_input)
    {:ok, provider} = GenerationProvider.new(policy_input["provider"], provider_pid)

    options = [
      profile_custody: __MODULE__.Custody,
      authoring_contract: contract,
      generation_policies: [policy],
      generation_providers: [provider]
    ]

    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "owner.identity"), %{
        not_before: now - 60,
        not_after: now + 86_400
      })

    {:ok, interfaces} = :inet.getifaddrs()

    {interface, _} =
      Enum.find(interfaces, fn {_, props} ->
        {127, 0, 0, 1} in Keyword.get_values(props, :addr)
      end)

    {:ok, reserved} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(reserved)
    :gen_tcp.close(reserved)
    binding = %{interface: List.to_string(interface), address: {127, 0, 0, 1}, port: port}
    first = start_owner(root, identity, binding, options)
    {store, _, _, listener, authority} = first

    {:ok, custody} =
      Custody.start_link(
        root: Path.join(root, "profiles"),
        store_owner: store,
        name: __MODULE__.Custody
      )

    payload =
      try do
        {:ok, template} = Server.template(listener)
        {:ok, admin, invitation} = Authority.pairing_open(authority, template)

        request =
          peer().request()
          |> Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)))

        {:ok, reference} = Authority.pairing_prepare(authority, admin, request)

        {:ok, _} =
          Authority.pairing_approve(authority, admin, reference, %{
            "permissions" => ["profile:manage"],
            "target_ids" => []
          })

        input = %{
          "mode" => "authoring-stage",
          "invitation" => peer().invitation_body(invitation),
          "bootstrap" => bootstrap_body(request),
          "directory" => private_directory(root, "native"),
          "draft" => mechanics["draft_bytes"]
        }

        input =
          if scenario == "selectors" do
            Map.merge(input, %{
              "source" => source["payload_base64"],
              "fixture" => example["payload_base64"]
            })
          else
            input
          end

        transport(executable, input)
        {:ok, staged} = Store.revision(store)
        true = staged == 4
        transport(executable, %{input | "mode" => "authoring-existing"})
        transport(executable, %{input | "mode" => "authoring-absence"})
        {:ok, ^staged} = Store.revision(store)
        transport(executable, %{input | "mode" => "authoring-data"})
        {:ok, imported} = Store.revision(store)
        true = imported == staged + if(scenario == "selectors", do: 2, else: 1)

        mode =
          case scenario do
            "complete" -> "authoring-workspace"
            "repair" -> "authoring-workspace-repair"
            "selectors" -> "authoring-workspace-selectors"
            "restart" -> "authoring-generation-restart-seed"
          end

        transport(executable, %{input | "mode" => mode})
        true = GenServer.call(provider_pid, :calls) == if(scenario == "repair", do: 2, else: 1)
        input
      after
        GenServer.stop(custody)
        stop_owner(first)
      end

    restarted = start_owner(root, identity, binding, options)
    {store, _, _, _, _} = restarted

    {:ok, custody} =
      Custody.start_link(
        root: Path.join(root, "profiles"),
        store_owner: store,
        name: __MODULE__.Custody
      )

    try do
      {:ok, before} = Store.revision(store)

      if scenario != "restart" do
        transport(executable, %{payload | "mode" => "authoring-existing"})
        transport(executable, %{payload | "mode" => "authoring-workspace-restart"})
      else
        transport(executable, %{payload | "mode" => "authoring-generation-restart-check"})
      end

      {:ok, ^before} = Store.revision(store)
      true = GenServer.call(provider_pid, :calls) == if(scenario == "repair", do: 2, else: 1)
      key = File.read!(Path.join(payload["directory"], "raw-fixture.key"))
      {:ok, scope} = Store.controller_scope(store, key)
      {:ok, _} = Store.revoke_principal(store, scope.principal_id)

      if scenario != "restart" do
        transport(executable, %{payload | "mode" => "authoring-revoked"})
        transport(executable, %{payload | "mode" => "authoring-workspace-revoked"})
      else
        transport(executable, %{payload | "mode" => "authoring-generation-revoked"})
      end

      {:ok, %{dispatch_enabled: false}} = Store.health(store)
    after
      GenServer.stop(custody)
      stop_owner(restarted)
      if Process.alive?(provider_pid), do: GenServer.stop(provider_pid)
    end
  end

  defp fixture(name),
    do: name |> then(&File.read!("test/fixtures/profiles/#{&1}.json")) |> JSON.decode!()

  defp start_owner(root, identity, binding, options \\ []) do
    {:ok, store} =
      Store.start_link(Keyword.merge([path: Path.join(root, "owner.sqlite")], options))

    {:ok, reviews} = PairingReview.start_link(store_owner: store)
    authority = Authority.new(store: store, pairing_reviews: reviews)

    {:ok, uds} =
      UDS.start_link(authority: authority, socket_path: Path.join(root, "ipc/home.sock"))

    {:ok, listener} =
      Server.start_link(enabled: true, authority: authority, identity: identity, binding: binding)

    {store, reviews, uds, listener, authority}
  end

  defp stop_owner({store, reviews, uds, listener, _}) do
    Enum.each([listener, uds, reviews, store], fn pid ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)
  end

  defp wrong_principal(executable, root) do
    fixture = peer().create(Path.join(root, "independent-certs"))

    response = %{
      "api_version" => 1,
      "outcome" => "ok",
      "receipt" => %{
        "principal_id" => "operator:substituted",
        "authority_epoch" => 1,
        "operation_id" => "op:original-paired",
        "disposition" => "held",
        "reason" => nil,
        "revision" => 2
      }
    }

    for mode <- ["wrong-principal", "wrong-principal-receipt"] do
      {port, task} = peer().peer(fixture, "valid", :paired, response: JSON.encode!(response))
      invitation = peer().invitation(fixture, port)

      input = %{
        "mode" => mode,
        "invitation" => peer().invitation_body(invitation),
        "bootstrap" => peer().request_body(),
        "directory" => private_directory(root, mode)
      }

      transport(executable, input)
      {:request, bytes} = Task.await(task, 10_000)
      {:ok, decoded} = JSON.decode(bytes)

      true =
        decoded == %{
          "api_version" => 1,
          "operation" => "status",
          "credential" => Base.url_encode64(:binary.copy(<<8>>, 32), padding: false),
          "authority_epoch" => 1,
          "operation_id" => "op:original-paired"
        }
    end
  end

  defp transport(executable, input) do
    body = JSON.encode!(input)

    timeout =
      if input["mode"] in ~w(authoring-stage authoring-workspace authoring-workspace-repair authoring-workspace-selectors),
        do: 45_000,
        else: 20_000

    case Command.run_diagnostic(
           executable,
           [],
           16_384,
           timeout,
           <<byte_size(body)::32, body::binary>>
         ) do
      {:ok, output} ->
        unless String.trim(output) == "native original paired transport case passed",
          do: Mix.raise("native original paired transport fixture did not complete")

      {:error, reason} ->
        Mix.raise("native original paired #{input["mode"]} fixture failed: #{reason}")
    end
  end

  defp checked(executable, args, timeout, expected) do
    case Command.run_diagnostic(executable, args, 1_048_576, timeout) do
      {:ok, output} ->
        if expected && String.trim(output) != expected,
          do: Mix.raise("native original paired fixture did not complete")

      {:error, reason} ->
        Mix.raise("native original paired fixture failed: #{reason}")
    end
  end

  defp bootstrap_body(request) do
    JSON.encode!([
      "wotex-home.controller-bootstrap-request.v1",
      1,
      request["controller_id"],
      request["invitation_id"],
      request["client_id"],
      request["request_id"],
      Base.url_encode64(request["client_label"], padding: false),
      request["bootstrap_secret"]
    ])
  end

  defp private_directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp thing do
    {:ok, thing} =
      Thing.new(%{
        "id" => "light:paired-original",
        "role" => "Light",
        "profile_ref" => "fixture:paired-original",
        "capabilities" => [
          %{
            "thing_id" => "light:paired-original",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:paired-original",
            "evidence_ref" => "fixture:paired-original",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    thing
  end

  defp peer, do: WotexHome.TestSupport.ControllerTLSFixture
end
