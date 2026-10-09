defmodule Mix.Tasks.Woh.Native.Controller.Api.Smoke do
  @moduledoc "Checks the shared native ordinary API over pinned TLS against independent peers and real Authority/Store sockets."
  @shortdoc "Check native paired TLS API and original receipt parity"
  @requirements ["loadpaths"]
  use Mix.Task
  @compile {:no_warn_undefined, WotexHome.TestSupport.ControllerTLSFixture}
  alias Woh.Tool.Command
  alias WotexHome.Authority

  alias WotexHome.ControllerConnections.{
    CertificateClock,
    InstallationIdentity,
    PairingReview,
    Server,
    TLSIdentity
  }

  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Client
  alias WotexHome.LocalAPI.Server, as: UDS
  alias WotexHome.Semantics.Thing
  @receipt_fields ~w(principal_id authority_epoch operation_id disposition reason revision)

  def run([]) do
    Code.require_file("test/support/controller_tls_fixture.exs")
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-controller-api-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "controller-api-smoke")

    try do
      sources =
        ~w(LocalHealthClient NativeControllerPairingWire NativeControllerTLSClient NativeControllerAPIClient)

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
            Path.expand("native/macos/Tests/NativeControllerAPIClientSmoke.swift"),
            "-o",
            executable
          ]

      case Command.run_diagnostic("swiftc", args, 1_048_576, 60_000) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("native controller API compiler failed: #{reason}")
      end

      fixture = peer().create(Path.join(root, "certificates"))
      independent(executable, fixture)
      actual_authority(executable, root)

      Mix.shell().info(
        "native controller API independent trust/frame/deadline and real UDS/TLS receipt parity passed"
      )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.controller.api.smoke")
  defp peer, do: WotexHome.TestSupport.ControllerTLSFixture
  defp read, do: %{"api_version" => 1, "operation" => "health", "credential" => secret(9)}
  defp secret(byte), do: Base.url_encode64(:binary.copy(<<byte>>, 32), padding: false)
  defp ok, do: JSON.encode!(%{"api_version" => 1, "outcome" => "ok", "fixture" => true})

  defp independent(executable, fixture) do
    for variant <-
          ~w(valid wrong_name common_name_only uri_name_only wrong_purpose expired future unknown_critical unknown_ca corrupt changed) do
      {port, task} =
        peer().peer(fixture, variant, :paired, response: ok(), maximum_request: 65_536)

      invited = if variant == "changed", do: "valid", else: variant

      expected =
        case variant do
          "valid" -> "ok"
          "changed" -> "tlsPinChanged"
          _ -> "tlsPeerUnverified"
        end

      check(executable, peer().invitation(fixture, port, invited), read(), expected,
        response: ok()
      )

      require_peer(
        task,
        if(variant == "valid", do: {:request, JSON.encode!(read())}, else: :no_application_bytes)
      )
    end

    for mode <- [:fragmented, :lost, :oversize, :empty, :truncated, :slow_header, :slow_body] do
      {port, task} =
        peer().peer(fixture, "valid", mode,
          response: ok(),
          maximum_request: 65_536,
          maximum_response: 1_048_576
        )

      expected = if mode == :fragmented, do: "ok", else: "outcomeUnknown"

      check(executable, peer().invitation(fixture, port), read(), expected,
        response: ok(),
        deadline: mode in [:slow_header, :slow_body]
      )

      require_peer(task, {:request, JSON.encode!(read())})
    end

    for body <- [
          "[]",
          "not JSON",
          ~s({"api_version":1,"api_version":1,"outcome":"ok"}),
          ~S({"api_version":1,"api_ver\u0073ion":1,"outcome":"ok"}),
          ~s({"api_version":1,"outcome":"ok","nested":{"x":1,"x":2}}),
          ~s({"api_version":true,"outcome":"ok"}),
          ~s({"api_version":2,"outcome":"ok"}),
          ~s({"api_version":1,"outcome":"error","reason":"unauthorized","extra":true}),
          ~s({"api_version":1,"outcome":"not_found","extra":true}),
          ~s({"api_version":1,"outcome":"not_found"}),
          String.duplicate("[", 17) <> "0" <> String.duplicate("]", 17)
        ] do
      {port, task} = peer().peer(fixture, "valid", :paired, response: body)
      check(executable, peer().invitation(fixture, port), read(), "outcomeUnknown")
      require_peer(task, {:request, JSON.encode!(read())})
    end

    for reason <- ~w(unauthorized outcome_unknown permission_denied) do
      body = JSON.encode!(%{"api_version" => 1, "outcome" => "error", "reason" => reason})
      {port, task} = peer().peer(fixture, "valid", :paired, response: body)
      check(executable, peer().invitation(fixture, port), read(), "server:#{reason}")
      require_peer(task, {:request, JSON.encode!(read())})
    end

    body = JSON.encode!(%{"api_version" => 1, "outcome" => "not_found"})
    {port, task} = peer().peer(fixture, "valid", :paired, response: body)

    check(executable, peer().invitation(fixture, port), read(), "ok",
      response: body,
      allow_not_found: true
    )

    require_peer(task, {:request, JSON.encode!(read())})

    prefix = JSON.encode!(Map.put(read(), "fixture", ""))

    maximum_request =
      Map.put(read(), "fixture", String.duplicate("a", 65_536 - byte_size(prefix)))

    {port, task} = peer().peer(fixture, "valid", :paired, response: ok(), maximum_request: 65_536)
    check(executable, peer().invitation(fixture, port), maximum_request, "ok", response: ok())
    require_peer(task, {:request, JSON.encode!(maximum_request)})

    {port, task} = peer().peer(fixture, "valid", :paired, response: ok(), versions: [:"tlsv1.2"])
    check(executable, peer().invitation(fixture, port), read(), "tlsPeerUnverified")
    require_peer(task, :no_application_bytes)

    {port, task} = peer().peer(fixture, "valid", :paired, response: ok())

    check(executable, peer().invitation(fixture, port), read(), "tlsClockUncertain",
      uncertainty: 86_401_000
    )

    require_peer(task, :no_application_bytes)

    prefix = JSON.encode!(%{"api_version" => 1, "outcome" => "ok", "fixture" => ""})

    maximum =
      JSON.encode!(%{
        "api_version" => 1,
        "outcome" => "ok",
        "fixture" => String.duplicate("a", 1_048_576 - byte_size(prefix))
      })

    {port, task} = peer().peer(fixture, "valid", :paired, response: maximum)

    check(executable, peer().invitation(fixture, port), read(), "ok",
      expected_hash: peer().hash(maximum)
    )

    require_peer(task, {:request, JSON.encode!(read())})

    for operation <- ["health", "schedule_review"] do
      request = %{read() | "operation" => operation}
      {port, task} = peer().peer(fixture, "valid", :paired, response: ok(), response_delay: 6_000)

      check(
        executable,
        peer().invitation(fixture, port),
        request,
        if(operation == "health", do: "outcomeUnknown", else: "ok"),
        response: ok(),
        deadline: operation == "health",
        review: operation != "health"
      )

      require_peer(task, {:request, JSON.encode!(request)})
    end

    {port, task} = peer().peer(fixture, "valid", :paired, response: ok(), response_delay: 4_500)

    check(executable, peer().invitation(fixture, port), read(), "outcomeUnknown",
      delay_validation: true,
      deadline: true
    )

    require_peer(task, {:request, JSON.encode!(read())})

    marker = Path.join(fixture.directory, "api-request-ready")

    {port, task} =
      peer().peer(fixture, "valid", :slow_body, response: ok(), request_marker: marker)

    check(executable, peer().invitation(fixture, port), read(), "outcomeUnknown",
      cancel: true,
      request_marker: marker
    )

    require_peer(task, {:request, JSON.encode!(read())})

    invalid_requests = [
      "",
      "[]",
      "{}",
      JSON.encode!(Map.put(read(), "api_version", true)),
      JSON.encode!(Map.put(read(), "credential", secret(9) <> "=")),
      ~s({"api_version":1,"api_version":1,"operation":"health","credential":"#{secret(9)}"}),
      String.duplicate(" ", 65_537)
    ]

    for request <- invalid_requests do
      check(executable, peer().invitation(fixture, 49_999), request, "invalidRecord")
    end
  end

  defp actual_authority(executable, root) do
    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "authority.identity"), %{
        not_before: now - 60,
        not_after: now + 86_400
      })

    {:ok, store} = Store.start_link(path: Path.join(root, "authority.sqlite"))
    {:ok, _} = Store.enroll_thing(store, thing())

    {:ok, operator, _} =
      Store.provision_principal(store, "operator:native-tls", ["control:ordinary", "read"], [
        "light:native-tls"
      ])

    {:ok, reader, _} = Store.provision_principal(store, "reader:native-tls", ["read"], [])
    {:ok, reviews} = PairingReview.start_link(store_owner: store)
    authority = Authority.new(store: store, pairing_reviews: reviews)

    {:ok, uds} =
      UDS.start_link(authority: authority, socket_path: Path.join(root, "ipc/home.sock"))

    {:ok, interfaces} = :inet.getifaddrs()

    {interface, _} =
      Enum.find(interfaces, fn {_, props} ->
        {127, 0, 0, 1} in Keyword.get_values(props, :addr)
      end)

    {:ok, reserved} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(reserved)
    :gen_tcp.close(reserved)

    {:ok, listener} =
      Server.start_link(
        enabled: true,
        authority: authority,
        identity: identity,
        binding: %{interface: List.to_string(interface), address: {127, 0, 0, 1}, port: port}
      )

    try do
      {:ok, template} = Server.template(listener)
      {:ok, admin, invitation} = Authority.pairing_open(authority, template)
      operator = Base.url_encode64(operator, padding: false)
      reader = Base.url_encode64(reader, padding: false)
      socket = Path.join(root, "ipc/home.sock")

      for request <- [
            %{read() | "credential" => operator},
            %{read() | "credential" => reader},
            %{read() | "credential" => operator, "operation" => "controller_identity"},
            Map.merge(%{read() | "credential" => operator, "operation" => "catalogue"}, %{
              "watermark" => nil,
              "after" => nil,
              "page_size" => 10
            }),
            Map.merge(%{read() | "credential" => reader, "operation" => "snapshot"}, %{
              "watermark" => nil,
              "after" => nil,
              "page_size" => 100
            })
          ] do
        {:ok, response} = Client.request(socket, request)
        check(executable, invitation, request, "ok", response: JSON.encode!(response))
      end

      mutation = mutation(operator, "op:native-tls")
      digest = check(executable, invitation, mutation, "ok", receipt: true)

      status =
        Map.merge(%{read() | "credential" => operator, "operation" => "status"}, %{
          "authority_epoch" => 1,
          "operation_id" => "op:native-tls"
        })

      {:ok, local} = Client.request(socket, status)
      require_receipt(digest, local)
      require_receipt(check(executable, invitation, status, "ok", receipt: true), local)
      require_receipt(check(executable, invitation, mutation, "ok", receipt: true), local)
      {:ok, 4} = Store.revision(store)

      lost = mutation(operator, "op:native-lost")
      {proxy_port, proxy} = lost_reply_peer(identity, invitation)
      proxy_invitation = Map.put(invitation, "endpoint", ["ipv4", "127.0.0.1", proxy_port])
      check(executable, proxy_invitation, lost, "outcomeUnknown")
      require_peer(proxy, {:request, JSON.encode!(lost)})
      {:ok, 5} = Store.revision(store)
      lost_status = %{status | "operation_id" => "op:native-lost"}
      {:ok, retained} = Client.request(socket, lost_status)
      require_receipt(check(executable, invitation, lost_status, "ok", receipt: true), retained)
      {:ok, 5} = Store.revision(store)

      denied = mutation(reader, "op:native-denied")
      digest = check(executable, invitation, denied, "ok", receipt: true)

      {:ok, local} =
        Client.request(socket, %{
          status
          | "credential" => reader,
            "operation_id" => "op:native-denied"
        })

      true = local["receipt"]["disposition"] == "rejected"
      require_receipt(digest, local)
      {:ok, 6} = Store.revision(store)

      bootstrap =
        peer().request()
        |> Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)))

      {:ok, ref} = Authority.pairing_prepare(authority, admin, bootstrap)

      {:ok, _} =
        Authority.pairing_approve(authority, admin, ref, %{
          "permissions" => ["control:ordinary", "read"],
          "target_ids" => ["light:native-tls"]
        })

      bootstrap_body =
        JSON.encode!([
          "wotex-home.controller-bootstrap-request.v1",
          1,
          bootstrap["controller_id"],
          bootstrap["invitation_id"],
          bootstrap["client_id"],
          bootstrap["request_id"],
          Base.url_encode64(bootstrap["client_label"], padding: false),
          bootstrap["bootstrap_secret"]
        ])

      check(executable, invitation, mutation(secret(9), "op:native-paired"), "ok",
        receipt: true,
        bootstrap: bootstrap_body,
        permissions: ["control:ordinary", "read"],
        targets: ["light:native-tls"],
        socket: socket
      )

      {:ok, 8} = Store.revision(store)
      {:ok, _} = Store.revoke_principal(store, "operator:native-tls")
      check(executable, invitation, %{read() | "credential" => operator}, "server:unauthorized")
      {:ok, %{dispatch_enabled: false}} = Store.health(store)
    after
      GenServer.stop(listener)
      GenServer.stop(uds)
      GenServer.stop(reviews)
      GenServer.stop(store)
    end
  end

  # Independent relay uses the same private test identity, forwards exact bytes
  # to the real Authority TLS socket, consumes its committed reply, then drops
  # delivery. It admits no retry and prints no private material.
  defp lost_reply_peer(identity, invitation) do
    {:ok, options} = InstallationIdentity.server_options(identity)
    {:ok, listener} = :ssl.listen(0, [ip: {127, 0, 0, 1}] ++ options)
    {:ok, {_, port}} = :ssl.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, accepted} = :ssl.transport_accept(listener, 5_000)
          {:ok, socket} = :ssl.handshake(accepted, 5_000)

          try do
            {:ok, <<size::32>>} = :ssl.recv(socket, 4, 5_000)
            true = size in 1..65_536
            {:ok, body} = :ssl.recv(socket, size, 5_000)
            now = System.os_time(:millisecond)
            {:ok, clock} = CertificateClock.new(now, now + 10)
            {:ok, trust} = TLSIdentity.new(invitation)
            {:ok, client_options} = TLSIdentity.options(trust, clock)
            ["ipv4", _, target_port] = invitation["endpoint"]
            {:ok, target} = :ssl.connect({127, 0, 0, 1}, target_port, client_options, 5_000)

            try do
              :ok = :ssl.send(target, <<size::32, body::binary>>)
              {:ok, <<response_size::32>>} = :ssl.recv(target, 4, 5_000)
              true = response_size in 1..1_048_576
              {:ok, _} = :ssl.recv(target, response_size, 5_000)
            after
              :ssl.close(target)
            end

            :ssl.close(socket)
            {:error, :timeout} = :ssl.transport_accept(listener, 150)
            {:request, body}
          after
            :ssl.close(socket)
          end
        after
          :ssl.close(listener)
        end
      end)

    {port, task}
  end

  defp require_receipt(digest, response) do
    actual =
      @receipt_fields
      |> Enum.map(&Map.fetch!(response["receipt"], &1))
      |> JSON.encode!()
      |> peer().hash()

    unless digest == actual, do: Mix.raise("native and UDS disagree on the original receipt")
  end

  defp require_peer(task, expected) do
    unless Task.await(task, 18_000) == expected,
      do: Mix.raise("native API peer observed unexpected application bytes or retry")
  end

  defp check(executable, invitation, request, expected, opts \\ []) do
    now = System.system_time(:millisecond)
    request = if is_binary(request), do: request, else: JSON.encode!(request)

    body =
      JSON.encode!(%{
        "invitation" => peer().invitation_body(invitation),
        "request" => request,
        "earliest" => now,
        "latest" => now + Keyword.get(opts, :uncertainty, 0),
        "expected" => expected,
        "response" => Keyword.get(opts, :response),
        "expected_hash" => Keyword.get(opts, :expected_hash),
        "receipt" => Keyword.get(opts, :receipt, false),
        "cancel" => Keyword.get(opts, :cancel, false),
        "deadline" => Keyword.get(opts, :deadline, false),
        "review" => Keyword.get(opts, :review, false),
        "delay_validation" => Keyword.get(opts, :delay_validation, false),
        "allow_not_found" => Keyword.get(opts, :allow_not_found, false),
        "bootstrap" => Keyword.get(opts, :bootstrap),
        "permissions" => Keyword.get(opts, :permissions),
        "targets" => Keyword.get(opts, :targets),
        "socket" => Keyword.get(opts, :socket),
        "request_marker" => Keyword.get(opts, :request_marker)
      })

    case Command.run_diagnostic(
           executable,
           [],
           4096,
           18_000,
           <<byte_size(body)::32, body::binary>>
         ) do
      {:ok, output} ->
        output = String.trim(output)

        if Keyword.get(opts, :receipt, false) do
          case Regex.run(~r/\Anative controller API receipt ([0-9a-f]{64})\z/, output) do
            [_, digest] -> digest
            _ -> Mix.raise("native API receipt case did not complete")
          end
        else
          unless output == "native controller API case passed",
            do: Mix.raise("native API case did not complete")

          :ok
        end

      {:error, reason} ->
        Mix.raise("native controller API #{expected} case failed: #{reason}")
    end
  end

  defp mutation(credential, operation) do
    %{
      "api_version" => 1,
      "operation" => "submit",
      "credential" => credential,
      "mutation" => %{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => operation,
        "expected_revision" => 0,
        "target_id" => "light:native-tls",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      }
    }
  end

  defp thing do
    {:ok, thing} =
      Thing.new(%{
        "id" => "light:native-tls",
        "role" => "Light",
        "profile_ref" => "fixture:native-tls",
        "capabilities" => [
          %{
            "thing_id" => "light:native-tls",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:native-tls",
            "evidence_ref" => "fixture:native-tls",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    thing
  end
end
