defmodule Mix.Tasks.Woh.Native.Controller.Tls.Smoke do
  @moduledoc "Checks Apple TLS against independent peers and an isolated real Authority listener; no installed controller is provisioned."
  @shortdoc "Check native controller TLS trust and bounded bootstrap"
  @requirements ["loadpaths"]
  use Mix.Task
  @compile {:no_warn_undefined, WotexHome.TestSupport.ControllerTLSFixture}
  alias Woh.Tool.Command
  alias WotexHome.ControllerConnections.InstallationIdentity
  alias WotexHome.ControllerConnections.{PairingReview, Server}
  alias WotexHome.Authority
  alias WotexHome.Durable.Store

  def run([]) do
    Code.require_file("test/support/controller_tls_fixture.exs")

    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "woh-controller-native-tls-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "controller-tls-smoke")

    try do
      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        Path.join(root, "cache"),
        "-target",
        "arm64-apple-macos15.0",
        Path.expand("native/macos/Sources/NativeControllerPairingWire.swift"),
        Path.expand("native/macos/Sources/NativeControllerTLSClient.swift"),
        Path.expand("native/macos/Tests/NativeControllerTLSClientSmoke.swift"),
        "-o",
        executable
      ]

      case Command.run_diagnostic("swiftc", args, 1_048_576, 60_000) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("native controller TLS compiler failed: #{reason}")
      end

      fixture = peer().create(Path.join(root, "certificates"))

      cases = [
        {"valid", :paired, "paired"},
        {"valid", :fragmented, "paired"},
        {"valid", :refused, "refused"},
        {"wrong_name", :paired, "tlsPeerUnverified"},
        {"common_name_only", :paired, "tlsPeerUnverified"},
        {"uri_name_only", :paired, "tlsPeerUnverified"},
        {"wrong_purpose", :paired, "tlsPeerUnverified"},
        {"expired", :paired, "tlsPeerUnverified"},
        {"future", :paired, "tlsPeerUnverified"},
        {"unknown_critical", :paired, "tlsPeerUnverified"},
        {"unknown_ca", :paired, "tlsPeerUnverified"},
        {"corrupt", :paired, "tlsPeerUnverified"},
        {"changed", :paired, "tlsPinChanged"},
        {"valid", :lost, "outcomeUnknown"},
        {"valid", :oversize, "outcomeUnknown"},
        {"valid", :empty, "outcomeUnknown"},
        {"valid", :truncated, "outcomeUnknown"},
        {"valid", :wrong_digest, "outcomeUnknown"},
        {"valid", :widened, "outcomeUnknown"},
        {"valid", :slow_header, "outcomeUnknown"},
        {"valid", :slow_body, "outcomeUnknown"}
      ]

      for {variant, mode, expected} <- cases do
        {port, task} = peer().peer(fixture, variant, mode)
        invited_variant = if variant == "changed", do: "valid", else: variant
        invitation = peer().invitation(fixture, port, invited_variant)

        check(executable, invitation, expected,
          deadline: mode in [:slow_header, :slow_body],
          name: "#{variant}/#{mode}"
        )

        require_peer(
          task,
          if(expected in ["tlsPeerUnverified", "tlsPinChanged"],
            do: :no_application_bytes,
            else: {:request, peer().request_body()}
          )
        )
      end

      for identity <- [["ipv4", "127.0.0.1"], ["ipv6", "0000:0000:0000:0000:0000:0000:0000:0001"]] do
        {port, task} = peer().peer(fixture)
        check(executable, peer().invitation(fixture, port, "valid", identity), "paired")
        require_peer(task, {:request, peer().request_body()})
      end

      {port, task} = peer().peer(fixture, "valid", :paired, ip: {0, 0, 0, 0, 0, 0, 0, 1})

      invitation =
        peer().invitation(fixture, port)
        |> Map.put("endpoint", ["ipv6", "0000:0000:0000:0000:0000:0000:0000:0001", port])

      check(executable, invitation, "paired")
      require_peer(task, {:request, peer().request_body()})

      {port, task} = peer().peer(fixture, "valid", :paired, ip: {0, 0, 0, 0, 0, 0, 0, 1})

      invitation =
        peer().invitation(fixture, port) |> Map.put("endpoint", ["dns", "localhost", port])

      check(executable, invitation, "paired", name: "DNS IPv6 endpoint")
      require_peer(task, {:request, peer().request_body()})

      {port, task} = peer().peer(fixture, "valid", :paired, versions: [:"tlsv1.2"])
      check(executable, peer().invitation(fixture, port), "tlsPeerUnverified")
      require_peer(task, :no_application_bytes)
      {port, task} = peer().peer(fixture)

      check(executable, peer().invitation(fixture, port), "tlsClockUncertain",
        uncertainty: 86_401_000
      )

      require_peer(task, :no_application_bytes)

      check(
        executable,
        peer().invitation(fixture, 49_999) |> Map.put("trust_anchor", "YWJj"),
        "invalidTrust"
      )

      check(
        executable,
        peer().invitation(fixture, 49_999)
        |> Map.put("endpoint", ["ipv6", "fe80:0000:0000:0000:0000:0000:0000:0001", 49_999]),
        "tlsClientInterfaceRequired"
      )

      for cancel <- [false, true] do
        {port, task} = silent_peer()

        check(
          executable,
          peer().invitation(fixture, port),
          if(cancel, do: "cancelled", else: "tlsHandshakeTimeout"),
          cancel: cancel,
          deadline: not cancel
        )

        require_peer(task, :closed)
      end

      generated_identity(executable, root)
      authority_listener(executable, root)

      Mix.shell().info(
        "native controller TLS 34 independent trust, frame, deadline, cancellation, installation identity and real Authority pairing cases passed"
      )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.controller.tls.smoke")
  defp peer, do: WotexHome.TestSupport.ControllerTLSFixture

  defp check(executable, invitation, expected, opts \\ []) do
    now = System.system_time(:millisecond)

    body =
      JSON.encode!(%{
        "invitation" => peer().invitation_body(invitation),
        "request" => Keyword.get(opts, :request, peer().request_body()),
        "earliest" => now,
        "latest" => now + Keyword.get(opts, :uncertainty, 0),
        "expected" => expected,
        "deadline" => Keyword.get(opts, :deadline, false),
        "cancel" => Keyword.get(opts, :cancel, false),
        "pairing_scope" => Keyword.get(opts, :pairing_scope),
        "expected_refusal" => Keyword.get(opts, :expected_refusal, "confirmation_denied")
      })

    # Private fixture records only; native diagnostics contain closed outcome
    # names and never print the supplied invitation, certificate or frame.
    case Command.run_diagnostic(
           executable,
           [],
           16_384,
           8_000,
           <<byte_size(body)::32, body::binary>>
         ) do
      {:ok, output} ->
        unless String.trim(output) == "native controller TLS case passed",
          do: Mix.raise("native controller TLS case did not complete")

      {:error, reason} ->
        Mix.raise(
          "native controller TLS #{Keyword.get(opts, :name, expected)} case failed: #{reason}"
        )
    end
  end

  defp require_peer(task, expected) do
    unless Task.await(task, 8_000) == expected,
      do: Mix.raise("native controller TLS peer observed unexpected application bytes")
  end

  defp generated_identity(executable, root) do
    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "identity"), %{
        not_before: now - 60,
        not_after: now + 86_400
      })

    {:ok, public} = InstallationIdentity.descriptor(identity)
    {:ok, options} = InstallationIdentity.server_options(identity)
    {:ok, listener} = :ssl.listen(0, [ip: {127, 0, 0, 1}] ++ options)
    {:ok, {_, port}} = :ssl.sockname(listener)

    # Literal synthetic framing is independent of the production pairing codec.
    request =
      peer().request_body()
      |> JSON.decode!()
      |> List.replace_at(2, public["controller_id"])
      |> JSON.encode!()

    response =
      peer().response()
      |> JSON.decode!()
      |> List.replace_at(2, public["controller_id"])
      |> List.replace_at(6, peer().hash(request))
      |> JSON.encode!()

    task =
      Task.async(fn ->
        try do
          {:ok, accepted} = :ssl.transport_accept(listener, 5_000)
          {:ok, socket} = :ssl.handshake(accepted, 5_000)

          try do
            {:ok, <<size::32>>} = :ssl.recv(socket, 4, 5_000)
            true = size in 1..8_192
            {:ok, received} = :ssl.recv(socket, size, 5_000)
            :ok = :ssl.send(socket, <<byte_size(response)::32, response::binary>>)
            {:request, received}
          after
            :ssl.close(socket)
          end
        after
          :ssl.close(listener)
        end
      end)

    invitation =
      Map.merge(public, %{
        "endpoint" => ["ipv4", "127.0.0.1", port],
        "invitation_id" => String.duplicate("2", 64),
        "bootstrap_secret" => Base.url_encode64(:binary.copy(<<3>>, 32), padding: false)
      })

    # Endpoint and finite synthetic secret are fixture input, never arguments.
    try do
      check(executable, invitation, "paired", request: request, name: "installation identity")
      require_peer(task, {:request, request})
    after
      :ssl.close(listener)
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp silent_peer do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 7_000)

          try do
            drain(socket, 0)
          after
            :gen_tcp.close(socket)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    {port, task}
  end

  defp authority_listener(executable, root) do
    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "authority.identity"), %{
        not_before: now - 60,
        not_after: now + 86_400
      })

    {:ok, store} = Store.start_link(path: Path.join(root, "authority.sqlite"))
    {:ok, reviews} = PairingReview.start_link(store_owner: store)
    authority = Authority.new(store: store, pairing_reviews: reviews)
    address = {127, 0, 0, 1}
    {:ok, interfaces} = :inet.getifaddrs()

    {interface, _} =
      Enum.find(interfaces, fn {_, props} -> address in Keyword.get_values(props, :addr) end)

    {:ok, reserved} = :gen_tcp.listen(0, [:binary, active: false, ip: address])
    {:ok, {^address, port}} = :inet.sockname(reserved)
    :gen_tcp.close(reserved)

    {:ok, listener} =
      Server.start_link(
        enabled: true,
        authority: authority,
        identity: identity,
        binding: %{interface: List.to_string(interface), address: address, port: port}
      )

    try do
      {:ok, template} = Server.template(listener)
      {:ok, admin, invitation} = Authority.pairing_open(authority, template, 5_000)

      request =
        peer().request()
        |> Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)))

      {:ok, reference} = Authority.pairing_prepare(authority, admin, request)
      {:ok, scope} = Authority.pairing_setup_context(authority)
      {:ok, _} = Authority.pairing_approve(authority, admin, reference)

      body =
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

      check(executable, invitation, "paired",
        request: body,
        pairing_scope: scope,
        name: "real Authority pairing"
      )

      {:ok, 1} = Store.revision(store)

      check(executable, invitation, "refused",
        request: body,
        expected_refusal: "invitation_consumed",
        name: "real consumed replay"
      )

      {:ok, 1} = Store.revision(store)
      {:ok, %{dispatch_enabled: false, active_things: 0}} = Store.health(store)
    after
      GenServer.stop(listener)
      GenServer.stop(reviews)
      GenServer.stop(store)
    end
  end

  defp drain(socket, count) when count < 65_536 do
    case :gen_tcp.recv(socket, 0, 7_000) do
      {:ok, bytes} -> drain(socket, count + byte_size(bytes))
      {:error, :closed} -> :closed
      _ -> :not_closed
    end
  end
end
