defmodule Mix.Tasks.Woh.Native.Paired.Recovery.Smoke do
  @moduledoc "Checks original paired metadata/unsigned production refusal and the closed adapter over actual Authority pairing, TLS, SQLite restart and exact original retries; creates no signed app session."
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

  def run([]) do
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
        NativePendingCodec NativePendingStorage NativePendingPairedCustody NativePendingRecoveryOperations
        NativePairedPendingRecoveryOperations NativePairedRecoveryCorrespondence)

      args =
        [
          "-parse-as-library",
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
        "native original paired correspondence, cancellation, private CAS and unsigned production refusal passed"
      )

      checked(
        executable,
        [associations, pending, Path.join(root, "metadata"), "inspect"],
        10_000,
        "fresh original paired journal check passed"
      )

      actual_owner(executable, root, associations)
      wrong_principal(executable, root)

      Mix.shell().info(
        "native original paired metadata/unsigned refusal, real pairing, original receipts/retries/restart/revocation and wrong-principal refusal passed"
      )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.paired.recovery.smoke")

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

  defp start_owner(root, identity, binding) do
    {:ok, store} = Store.start_link(path: Path.join(root, "owner.sqlite"))
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

    {port, task} = peer().peer(fixture, "valid", :paired, response: JSON.encode!(response))
    invitation = peer().invitation(fixture, port)

    input = %{
      "mode" => "wrong-principal",
      "invitation" => peer().invitation_body(invitation),
      "bootstrap" => peer().request_body(),
      "directory" => private_directory(root, "wrong-principal")
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

  defp transport(executable, input) do
    body = JSON.encode!(input)

    case Command.run_diagnostic(
           executable,
           [],
           16_384,
           20_000,
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
