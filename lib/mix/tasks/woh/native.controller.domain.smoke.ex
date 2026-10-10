defmodule Mix.Tasks.Woh.Native.Controller.Domain.Smoke do
  @moduledoc "Checks the operation-scoped typed SDK over actual pinned TLS and private UDS."
  @shortdoc "Check paired domain SDK transport and original correspondence"
  @requirements ["loadpaths"]
  use Mix.Task
  @compile {:no_warn_undefined, WotexHome.TestSupport.ControllerTLSFixture}
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.ControllerConnections.{InstallationIdentity, PairingReview, Server}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Server, as: UDS
  alias WotexHome.Profiles.{Custody, ReviewSession}
  alias WotexHome.Semantics.Thing
  @custody __MODULE__.Custody
  @reviews __MODULE__.Reviews

  def run(arguments) when arguments in [[], ["authority"], ["guards"]] do
    Code.require_file("test/support/controller_tls_fixture.exs")
    root = Path.join("/private/tmp", "woh-domain-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "domain-smoke")

    try do
      sources =
        ~w(LocalHealthClient NativeControllerPairingWire NativeControllerTLSClient NativeControllerAPIClient NativeControllerDomainClient NativeRuleOperationWire NativeRuleClient NativeScheduleWire NativeScheduleClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments)

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
          [
            Path.expand("native/macos/Tests/NativeControllerDomainClientSmoke.swift"),
            "-o",
            executable
          ]

      case Command.run_diagnostic("swiftc", args, 1_048_576, 90_000) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("native domain compiler failed: #{reason}")
      end

      Mix.shell().info("native controller domain Swift compilation passed")

      if arguments != ["authority"] do
        fixture = peer().create(Path.join(root, "certificates"))

        if arguments == [] do
          independent(executable, fixture)
          Mix.shell().info("native domain seventeen independent transport and scope cases passed")
        end

        guarded(executable, fixture)
        Mix.shell().info("native domain sixteen independent bounded exchange guard cases passed")
      end

      if arguments != ["guards"], do: authority(executable, root)

      Mix.shell().info(
        if arguments == ["guards"],
          do: "native controller bounded exchange guard checks passed",
          else:
            "native controller domain trust/deadline/cancellation/scope and real typed UDS/TLS parity passed"
      )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.controller.domain.smoke [authority|guards]")
  defp peer, do: WotexHome.TestSupport.ControllerTLSFixture
  defp credential, do: Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)
  defp request, do: %{"api_version" => 1, "operation" => "health", "credential" => credential()}

  defp health do
    %{
      "api_version" => 1,
      "outcome" => "ok",
      "health" => %{
        "store_revision" => 9,
        "authority_epoch" => 1,
        "rule_generation" => 0,
        "held_requests" => 0,
        "queued_requests" => 0,
        "claimed_requests" => 0,
        "unknown_outcomes" => 0,
        "active_things" => 0,
        "active_principals" => 1,
        "writable" => true,
        "dispatch_enabled" => false
      }
    }
  end

  defp independent(executable, fixture) do
    for {variant, mode, response, expected} <- [
          {"valid", "health", health(), "ok"},
          {"valid", "broker", health(), "ok"},
          {"valid", "outliving", health(), "ok"},
          {"wrong_name", "health", health(), "tlsPeerUnverified"},
          {"changed", "health", health(), "tlsPinChanged"},
          {"valid", "health", put_in(health(), ["health", "authority_epoch"], true),
           "outcomeUnknown"},
          {"valid", "health", Map.put(health(), "extra", true), "outcomeUnknown"},
          {"valid", "health",
           %{"api_version" => 1, "outcome" => "error", "reason" => "unauthorized"},
           "server:unauthorized"},
          {"valid", "late-decode", health(), "outcomeUnknown"}
        ] do
      {port, task} = peer().peer(fixture, variant, :paired, response: JSON.encode!(response))
      invited = if variant == "changed", do: "valid", else: variant
      check(executable, peer().invitation(fixture, port, invited), mode, expected)

      observed =
        if variant == "valid",
          do: {:request, JSON.encode!(request())},
          else: :no_application_bytes

      require_peer(task, observed)
    end

    for mode <- ~w(cancel concurrent) do
      marker = Path.join(fixture.directory, mode)

      {port, task} =
        peer().peer(fixture, "valid", :slow_body,
          response: JSON.encode!(health()),
          request_marker: marker
        )

      check(
        executable,
        peer().invitation(fixture, port),
        mode,
        "outcomeUnknown",
        marker: marker
      )

      require_peer(task, {:request, JSON.encode!(request())})
    end

    for mode <- [:lost, :slow_body, :oversize] do
      {port, task} =
        peer().peer(fixture, "valid", mode,
          response: JSON.encode!(health()),
          maximum_response: 1_048_576
        )

      check(executable, peer().invitation(fixture, port), "health", "outcomeUnknown")
      require_peer(task, {:request, JSON.encode!(request())})
    end

    # A real listener independently proves that preflight refusal and a clock
    # producer crossing the original budget never even connect.
    for mode <- ~w(mismatch no-exchange slow-clock) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)

      try do
        check(
          executable,
          peer().invitation(fixture, port),
          mode,
          if(mode == "slow-clock", do: "outcomeUnknown", else: "invalidRecord")
        )

        {:error, :timeout} = :gen_tcp.accept(listener, 50)
      after
        :gen_tcp.close(listener)
      end
    end
  end

  defp guarded(executable, fixture) do
    for action <- ~w(refuse block cancel) do
      mode = "guard-#{action}-opening"
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)

      try do
        check(
          executable,
          peer().invitation(fixture, port),
          mode,
          guard_outcome(action, "opening"),
          marker: Path.join(fixture.directory, mode)
        )

        {:error, :timeout} = :gen_tcp.accept(listener, 100)
      after
        :gen_tcp.close(listener)
      end
    end

    for {mode, variant, response, expected, application?} <-
          [
            {"guard-pass", "valid", health(), "ok", true},
            {"guard-wrong-pin", "changed", health(), "tlsPinChanged", false},
            {"guard-refuse-delivering", "valid",
             %{"api_version" => 1, "outcome" => "error", "reason" => "unauthorized"},
             "outcomeUnknown", true},
            {"guard-invalid-domain", "valid",
             put_in(health(), ["health", "authority_epoch"], true), "outcomeUnknown", true}
          ] ++
            for(
              phase <- ~w(sending delivering decoded),
              action <- ~w(refuse block cancel),
              do:
                {"guard-#{action}-#{phase}", "valid", health(), guard_outcome(action, phase),
                 phase != "sending"}
            ) do
      {port, task} = peer().peer(fixture, variant, :paired, response: JSON.encode!(response))

      check(executable, peer().invitation(fixture, port), mode, expected,
        marker: Path.join(fixture.directory, mode)
      )

      require_peer(
        task,
        if(application?, do: {:request, JSON.encode!(request())}, else: :no_application_bytes)
      )
    end
  end

  defp guard_outcome("cancel", _phase), do: "outcomeUnknown"

  defp guard_outcome("block", phase) when phase in ["opening", "sending"],
    do: "tlsHandshakeTimeout"

  defp guard_outcome("refuse", phase) when phase in ["opening", "sending"], do: "invalidRecord"
  defp guard_outcome(_action, _phase), do: "outcomeUnknown"

  defp authority(executable, root) do
    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "identity"), %{
        not_before: now - 60,
        not_after: now + 86_400
      })

    profiles = Path.join(root, "profiles")
    File.mkdir!(profiles)
    File.chmod!(profiles, 0o700)

    {:ok, store} =
      Store.start_link(
        path: Path.join(root, "home.sqlite"),
        profile_custody: @custody,
        profile_reviews: @reviews
      )

    {:ok, custody} = Custody.start_link(root: profiles, name: @custody, store_owner: store)
    {:ok, reviews} = ReviewSession.start_link(custody: custody, name: @reviews)
    {:ok, pairing} = PairingReview.start_link(store_owner: store)
    {:ok, gate} = WotexHome.Authority.ReviewGate.start_link(limit: 1)
    clock = Woh.Tool.NativeScheduleRecoverySmoke.attach_clock(root, store)

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:native-domain",
        "role" => "Light",
        "profile_ref" => "fixture:native-domain",
        "capabilities" => [
          %{
            "thing_id" => "light:native-domain",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:native-domain",
            "evidence_ref" => "fixture:native-domain",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, _} = Store.enroll_thing(store, thing)
    principal = "manager:native-domain"

    {:ok, key, _} =
      Store.provision_principal(
        store,
        principal,
        ~w(read control:ordinary rule:review rule:manage profile:manage host:maintain),
        [thing.id]
      )

    authority =
      Authority.new(
        store: store,
        profile_custody: custody,
        profile_reviews: reviews,
        pairing_reviews: pairing,
        review_gate: gate
      )

    socket = Path.join(root, "ipc/home.sock")
    {:ok, uds} = UDS.start_link(authority: authority, socket_path: socket)
    {:ok, interfaces} = :inet.getifaddrs()

    {interface, _} =
      Enum.find(interfaces, fn {_, props} ->
        {127, 0, 0, 1} in Keyword.get_values(props, :addr)
      end)

    {:ok, reservation} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(reservation)
    :gen_tcp.close(reservation)

    {:ok, server} =
      Server.start_link(
        enabled: true,
        authority: authority,
        identity: identity,
        binding: %{interface: List.to_string(interface), address: {127, 0, 0, 1}, port: port}
      )

    try do
      {:ok, template} = Server.template(server)
      {:ok, _, invitation} = Authority.pairing_open(authority, template)

      check(executable, invitation, "authority", "ok",
        credential: Base.url_encode64(key, padding: false),
        socket: socket,
        principal: principal,
        artifact: File.read!("test/support/profiles/lifx-power.json")
      )

      {:ok, %{dispatch_enabled: false}} = Store.health(store)
    after
      Enum.each([server, uds, clock, gate, pairing, reviews, custody, store], &GenServer.stop/1)
    end
  end

  defp require_peer(task, expected) do
    observed = Task.await(task, 18_000)

    matches =
      case {observed, expected} do
        {{:request, body}, {:request, original}} -> JSON.decode(body) == JSON.decode(original)
        {actual, expected} -> actual == expected
      end

    unless matches, do: Mix.raise("domain peer observed unexpected fields or retry")
  end

  defp check(executable, invitation, mode, expected, opts \\ []) do
    body =
      JSON.encode!(%{
        "invitation" => peer().invitation_body(invitation),
        "mode" => mode,
        "expected" => expected,
        "credential" => Keyword.get(opts, :credential, credential()),
        "marker" => Keyword.get(opts, :marker),
        "socket" => Keyword.get(opts, :socket),
        "principal" => Keyword.get(opts, :principal),
        "artifact" => Keyword.get(opts, :artifact)
      })

    case Command.run_diagnostic(
           executable,
           [],
           4096,
           25_000,
           <<byte_size(body)::32, body::binary>>
         ) do
      {:ok, output} ->
        unless String.trim(output) == "native controller domain case passed",
          do: Mix.raise("domain fixture did not complete")

      {:error, reason} ->
        Mix.raise("native domain #{mode} check failed: #{reason}")
    end
  end
end
