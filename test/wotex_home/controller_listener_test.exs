defmodule WotexHome.ControllerListenerTest do
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Authority.ReviewGate

  alias WotexHome.ControllerConnections.{
    Binding,
    BootstrapClient,
    CertificateClock,
    InstallationIdentity,
    PairingReview,
    TLSIdentity
  }

  alias WotexHome.ControllerConnections.Server, as: LAN
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Server}
  alias WotexHome.Semantics.Thing
  @moduletag requires_socket: true

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-controller-listener-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "identity"), %{
        not_before: now - 60,
        not_after: now + 86400
      })

    store = start_supervised!({Store, path: Path.join(root, "home.sqlite")})
    {:ok, _} = Store.enroll_thing(store, thing())

    {:ok, operator, _} =
      Store.provision_principal(store, "operator:tls", ["control:ordinary", "read"], ["light:tls"])

    {:ok, reader, _} = Store.provision_principal(store, "reader:tls", ["read"], [])
    reviews = start_supervised!({PairingReview, store_owner: store})
    gate = start_supervised!({ReviewGate, limit: 2})
    authority = Authority.new(store: store, pairing_reviews: reviews, review_gate: gate)
    socket = Path.join(root, "ipc/home.sock")
    start_supervised!({Server, authority: authority, socket_path: socket})
    binding = selected_binding({127, 0, 0, 1})
    opts = [enabled: true, authority: authority, identity: identity, binding: binding]
    listener = start_supervised!(Supervisor.child_spec({LAN, opts}, restart: :temporary))
    {:ok, template} = LAN.template(listener)

    %{
      root: root,
      identity: identity,
      store: store,
      reviews: reviews,
      authority: authority,
      socket: socket,
      binding: binding,
      listener: listener,
      template: template,
      opts: opts,
      operator: Base.url_encode64(operator, padding: false),
      reader: Base.url_encode64(reader, padding: false)
    }
  end

  test "one TLS 1.3 request has identical scoped reads and validation to private UDS", c do
    for payload <- [
          %{"api_version" => 1, "operation" => "health", "credential" => c.reader},
          %{"api_version" => 1, "operation" => "controller_scope", "credential" => c.reader},
          %{"api_version" => 1, "operation" => "controller_scope", "credential" => c.operator},
          %{
            "api_version" => 1,
            "operation" => "controller_scope",
            "credential" => c.reader,
            "permissions" => ["host:maintain"]
          },
          %{
            "api_version" => 1,
            "operation" => "catalogue",
            "credential" => c.operator,
            "watermark" => nil,
            "after" => nil,
            "page_size" => 10
          },
          %{
            "api_version" => 1,
            "operation" => "snapshot",
            "credential" => c.reader,
            "watermark" => nil,
            "after" => nil,
            "page_size" => 100
          },
          %{
            "api_version" => 1,
            "operation" => "health",
            "credential" => c.reader,
            "extra" => true
          },
          %{"api_version" => 1, "operation" => "provision_principal", "credential" => c.reader},
          %{"api_version" => 1, "operation" => "pairing_open", "credential" => c.reader},
          %{
            "api_version" => 1,
            "operation" => "health",
            "credential" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          }
        ] do
      assert {:ok, local} = Client.request(c.socket, payload)
      assert local == request(c, payload)
    end

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "mutation and original status retain the same receipt across TLS, UDS and retry", c do
    payload = mutation(c.operator, "op:tls")
    tls = request(c, payload)
    assert tls["outcome"] == "ok"
    assert {:ok, ^tls} = Client.request(c.socket, payload)
    assert ^tls = request(c, payload)
    assert {:ok, 4} = Store.revision(c.store)

    status = %{
      "api_version" => 1,
      "operation" => "status",
      "credential" => c.operator,
      "authority_epoch" => 1,
      "operation_id" => "op:tls"
    }

    assert {:ok, local} = Client.request(c.socket, status)
    assert local == request(c, status)

    denied = request(c, mutation(c.reader, "op:denied"))

    assert %{
             "outcome" => "ok",
             "receipt" => %{"disposition" => "rejected", "reason" => "target_unavailable"}
           } = denied

    assert {:ok, ^denied} = Client.request(c.socket, mutation(c.reader, "op:denied"))
    assert {:ok, 5} = Store.revision(c.store)
    assert {:ok, %{dispatch_enabled: false}} = Store.health(c.store)
  end

  test "a lost TLS mutation reply resolves only its original operation and is not retried", c do
    socket = connect(c)
    send_json(socket, mutation(c.operator, "op:lost"))
    await(fn -> Store.revision(c.store) == {:ok, 4} end)
    :ssl.close(socket)

    status = %{
      "api_version" => 1,
      "operation" => "status",
      "credential" => c.operator,
      "authority_epoch" => 1,
      "operation_id" => "op:lost"
    }

    assert %{"outcome" => "ok"} = request(c, status)
    assert {:ok, 4} = Store.revision(c.store)
    assert %{"outcome" => "not_found"} = request(c, %{status | "operation_id" => "op:new"})
  end

  test "current credential revocation and rotation apply to an already established TLS socket",
       c do
    socket = connect(c)
    {:ok, operator} = Base.url_decode64(c.operator, padding: false)
    assert {:ok, rotated, _} = Store.rotate_principal_credential(c.store, "operator:tls")

    send_json(socket, %{
      "api_version" => 1,
      "operation" => "health",
      "credential" => Base.url_encode64(operator, padding: false)
    })

    assert %{"outcome" => "error", "reason" => "unauthorized"} = receive_json(socket)
    :ssl.close(socket)

    assert %{"outcome" => "ok"} =
             request(c, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => Base.url_encode64(rotated, padding: false)
             })

    assert {:ok, _} = Store.revoke_principal(c.store, "operator:tls")

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             request(c, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => Base.url_encode64(rotated, padding: false)
             })
  end

  test "one preconfirmed bootstrap provisions real default access once and replay issues no secret",
       c do
    {admin, invitation, bootstrap} = prepare(c)
    {:ok, ref} = Authority.pairing_prepare(c.authority, admin, bootstrap)
    {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:ok, paired} = BootstrapClient.run(invitation, bootstrap, clock())
    assert paired["permissions"] == ["read"] and paired["target_ids"] == []
    assert paired["controller_id"] == c.identity.controller_id
    assert paired["credential"] != invitation["bootstrap_secret"]
    assert {:ok, 4} = Store.revision(c.store)

    assert {:ok, %{"reason" => "invitation_consumed"} = replay} =
             BootstrapClient.run(invitation, bootstrap, clock())

    refute Map.has_key?(replay, "credential")
    assert {:ok, 4} = Store.revision(c.store)

    scope_request = %{
      "api_version" => 1,
      "operation" => "controller_scope",
      "credential" => paired["credential"]
    }

    assert {:ok, local_scope} = Client.request(c.socket, scope_request)
    assert local_scope == request(c, scope_request)

    assert %{
             "outcome" => "ok",
             "controller_scope" => %{
               "principal_id" => principal,
               "permissions" => ["read"],
               "target_ids" => []
             }
           } = local_scope

    assert principal == paired["principal_id"]
    assert {:ok, 4} = Store.revision(c.store)

    assert %{"outcome" => "ok"} =
             request(c, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => paired["credential"]
             })
  end

  test "live local approval grants only the explicit target while the socket owns the offer", c do
    {admin, invitation, bootstrap} = prepare(c)

    task =
      Task.async(fn ->
        BootstrapClient.run(invitation, bootstrap, clock(), %{
          "permissions" => ["control:ordinary", "read"],
          "target_ids" => ["light:tls"]
        })
      end)

    await(fn -> match?({:ok, [_]}, Authority.pairing_pending(c.authority, admin)) end)
    {:ok, [%{reference: ref}]} = Authority.pairing_pending(c.authority, admin)

    {:ok, _} =
      Authority.pairing_approve(c.authority, admin, ref, %{
        "permissions" => ["control:ordinary", "read"],
        "target_ids" => ["light:tls"]
      })

    assert {:ok, paired} = Task.await(task, 6_000)
    assert %{"outcome" => "ok"} = request(c, mutation(paired["credential"], "op:paired"))
    assert {:ok, 5} = Store.revision(c.store)
  end

  test "denied and unconfirmed network offers do not provision", c do
    {admin, invitation, bootstrap} = prepare(c)
    task = Task.async(fn -> BootstrapClient.run(invitation, bootstrap, clock()) end)
    await(fn -> match?({:ok, [_]}, Authority.pairing_pending(c.authority, admin)) end)
    {:ok, [%{reference: ref}]} = Authority.pairing_pending(c.authority, admin)
    assert :ok = Authority.pairing_deny(c.authority, admin, ref)
    assert {:ok, %{"reason" => "confirmation_denied"}} = Task.await(task, 6_000)
    assert {:ok, 3} = Store.revision(c.store)
    assert :ok = Authority.pairing_close(c.authority, admin)

    assert {:ok, %{"reason" => "pairing_closed"}} =
             BootstrapClient.run(invitation, bootstrap, clock())

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "bootstrap expiry closes pending exchange without consumption", c do
    {_admin, invitation, bootstrap} = prepare(c, 300)

    assert {:ok, %{"reason" => "pairing_expired"}} =
             BootstrapClient.run(invitation, bootstrap, clock())

    assert {:ok, 3} = Store.revision(c.store)
    assert :available = Store.pairing_consumed(c.store, invitation["invitation_id"])
  end

  test "malformed, empty, oversized and duplicate-member frames never dispatch", c do
    for bytes <- [
          <<0::32>>,
          <<65_537::32>>,
          <<8_193::32, "[">>,
          <<2::32, "{}">>,
          frame("{\"api_version\":1,\"api_version\":1}"),
          frame("[null]"),
          frame(<<255>>)
        ] do
      socket = connect(c)
      :ssl.send(socket, bytes)
      assert {:ok, _} = :ssl.recv(socket, 4, 2_000) |> allow_closed()
      :ssl.close(socket)
      assert {:ok, 3} = Store.revision(c.store)
    end
  end

  test "partial headers and bodies retain one five-second frame deadline", c do
    for prefix <- [<<0>>, <<100::32, "{">>] do
      socket = connect(c)
      started = System.monotonic_time(:millisecond)
      :ssl.send(socket, prefix)
      assert {:ok, _} = :ssl.recv(socket, 4, 6_000) |> allow_closed()
      assert (System.monotonic_time(:millisecond) - started) in 4_700..6_000
      :ssl.close(socket)
    end

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "silent TLS handshakes expire and TLS 1.2 never receives an application route", c do
    {:ok, raw} = :gen_tcp.connect({127, 0, 0, 1}, c.binding.port, [:binary, active: false], 1_000)
    started = System.monotonic_time(:millisecond)
    assert {:error, :closed} = :gen_tcp.recv(raw, 0, 6_000)
    assert (System.monotonic_time(:millisecond) - started) in 4_700..6_000
    :gen_tcp.close(raw)

    assert {:error, _} =
             :ssl.connect(
               {127, 0, 0, 1},
               c.binding.port,
               [versions: [:"tlsv1.2"], verify: :verify_none, active: false, log_level: :none],
               2_000
             )

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "32 handshakes share one cap; overload rejects promptly and leaves UDS/Store usable", c do
    sockets =
      for _ <- 1..32 do
        {:ok, socket} =
          :gen_tcp.connect({127, 0, 0, 1}, c.binding.port, [:binary, active: false], 1_000)

        socket
      end

    try do
      await(fn -> LAN.status(c.listener).connections == 32 end)
      assert %{enabled: true, limit: 32, connections: 32} = LAN.status(c.listener)

      {:ok, excess} =
        :gen_tcp.connect({127, 0, 0, 1}, c.binding.port, [:binary, active: false], 1_000)

      closed_with_alerts(excess, System.monotonic_time(:millisecond) + 1_000)
      :gen_tcp.close(excess)

      assert {:ok, %{"outcome" => "ok"}} =
               Client.request(c.socket, %{
                 "api_version" => 1,
                 "operation" => "health",
                 "credential" => c.reader
               })

      :gen_tcp.close(hd(sockets))
      await(fn -> LAN.status(c.listener).connections == 31 end)

      assert %{"outcome" => "ok"} =
               request(c, %{"api_version" => 1, "operation" => "health", "credential" => c.reader})
    after
      Enum.each(sockets, &:gen_tcp.close/1)
    end
  end

  for owner <- [:store, :reviews] do
    test "#{owner} loss closes listener and every accepted socket", c do
      socket = connect(c)
      monitor = Process.monitor(c.listener)
      assert :ok = stop_supervised(unquote(if owner == :store, do: Store, else: PairingReview))
      assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
      assert {:error, :closed} = :ssl.recv(socket, 0, 2_000)
      :ssl.close(socket)

      assert {:error, _} =
               :gen_tcp.connect({127, 0, 0, 1}, c.binding.port, [:binary, active: false], 500)
    end
  end

  test "abrupt listener loss closes established and pre-handshake sockets", c do
    socket = connect(c)

    {:ok, pending} =
      :gen_tcp.connect({127, 0, 0, 1}, c.binding.port, [:binary, active: false], 1_000)

    await(fn -> LAN.status(c.listener).connections == 2 end)
    monitor = Process.monitor(c.listener)
    Process.exit(c.listener, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1_000
    assert {:error, :closed} = :ssl.recv(socket, 0, 2_000)
    closed_with_alerts(pending, System.monotonic_time(:millisecond) + 2_000)
    :ssl.close(socket)
    :gen_tcp.close(pending)

    assert {:error, _} =
             :gen_tcp.connect({127, 0, 0, 1}, c.binding.port, [:binary, active: false], 500)

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "listener diagnostics disclose neither its TLS material nor application credentials", c do
    {_admin, invitation, _bootstrap} = prepare(c)
    status = :sys.get_status(c.listener) |> inspect(limit: :infinity, printable_limit: :infinity)

    secrets = [
      c.operator,
      c.reader,
      invitation["bootstrap_secret"],
      Base.url_encode64(c.identity.key, padding: false),
      c.identity.seal.path
    ]

    absent = Enum.all?(secrets, &(not String.contains?(status, &1)))
    assert absent
    assert String.contains?(status, "private_controller_listener")
  end

  test "private identity replacement fences both pending sockets and new accepts", c do
    socket = connect(c)
    monitor = Process.monitor(c.listener)
    path = c.identity.seal.path
    File.rename!(path, Path.join(c.root, "displaced"))

    :ok =
      WotexHome.Recovery.PrivateFile.write(path, File.read!(Path.join(c.root, "displaced")), 8192)

    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    assert {:error, :closed} = :ssl.recv(socket, 0, 2_000)
    :ssl.close(socket)

    assert {:error, _} =
             :gen_tcp.connect({127, 0, 0, 1}, c.binding.port, [:binary, active: false], 500)

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "explicit enable, exact live address, nonprivileged port and original identity are required",
       c do
    Process.flag(:trap_exit, true)

    for opts <- [
          Keyword.delete(c.opts, :enabled),
          Keyword.put(c.opts, :enabled, false),
          Keyword.put(c.opts, :binding, %{c.binding | address: {0, 0, 0, 0}}),
          Keyword.put(c.opts, :binding, %{c.binding | port: 0}),
          Keyword.put(c.opts, :binding, %{c.binding | port: 443}),
          Keyword.put(c.opts, :binding, %{c.binding | interface: "missing-home-interface"}),
          Keyword.put(c.opts, :binding, %{c.binding | address: {192, 0, 2, 1}}),
          Keyword.put(c.opts, :identity, %{c.identity | key: <<0>>}),
          Keyword.put(c.opts, :timeout, 1),
          c.opts ++ [enabled: true]
        ] do
      assert {:error, :invalid_controller_listener_config} = LAN.start_link(opts)
    end

    assert :ok = Binding.check(c.binding)
    assert LAN.status(c.listener).connections == 0
    assert {:ok, 3} = Store.revision(c.store)
  end

  test "the selected IPv6 loopback binds only that address and preserves DNS identity", c do
    selected = selected_binding({0, 0, 0, 0, 0, 0, 0, 1})

    listener =
      start_supervised!(
        Supervisor.child_spec({LAN, Keyword.put(c.opts, :binding, selected)},
          id: :ipv6,
          restart: :temporary
        )
      )

    {:ok, template} = LAN.template(listener)
    assert template["identity"] == c.template["identity"]

    assert template["endpoint"] == [
             "ipv6",
             "0000:0000:0000:0000:0000:0000:0000:0001",
             selected.port
           ]

    assert %{"outcome" => "ok"} =
             request(%{c | template: template, binding: selected}, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => c.reader
             })
  end

  test "a second frame on one connection cannot stage a second operation", c do
    socket = connect(c)
    first = frame(JSON.encode!(mutation(c.operator, "op:first")))
    second = frame(JSON.encode!(mutation(c.operator, "op:second")))
    :ssl.send(socket, first <> second)
    assert %{"outcome" => "ok"} = receive_json(socket)
    :ssl.close(socket)
    {:ok, credential} = Base.url_decode64(c.operator, padding: false)
    assert :not_found = Store.request_status(c.store, credential, 1, "op:second")
    assert {:ok, 4} = Store.revision(c.store)
  end

  test "a stalled review mailbox cannot extend the network pairing budget or block ordinary reads",
       c do
    {_admin, invitation, bootstrap} = prepare(c, 10_000)
    :ok = :sys.suspend(c.reviews)

    try do
      started = System.monotonic_time(:millisecond)
      assert {:error, :outcome_unknown} = BootstrapClient.run(invitation, bootstrap, clock())
      assert (System.monotonic_time(:millisecond) - started) in 4_700..6_000
      assert {:ok, 3} = Store.revision(c.store)
      assert Process.alive?(c.listener)

      assert %{"outcome" => "ok"} =
               request(c, %{"api_version" => 1, "operation" => "health", "credential" => c.reader})
    after
      :sys.resume(c.reviews)
    end
  end

  test "a stalled Store cannot extend the ordinary TLS request deadline", c do
    socket = connect(c)
    :ok = :sys.suspend(c.store)

    try do
      started = System.monotonic_time(:millisecond)
      send_json(socket, %{"api_version" => 1, "operation" => "health", "credential" => c.reader})
      assert %{"outcome" => "error", "reason" => "request_timeout"} = receive_json(socket)
      assert (System.monotonic_time(:millisecond) - started) in 4_700..6_000
      assert Process.alive?(c.listener)
    after
      :sys.resume(c.store)
      :ssl.close(socket)
    end

    assert {:ok, 3} = Store.revision(c.store)

    assert %{"outcome" => "ok"} =
             request(c, %{"api_version" => 1, "operation" => "health", "credential" => c.reader})
  end

  test "explicit Host composition retains identity and closes pairing across Store restart", c do
    alias WotexHome.Host
    host_binding = selected_binding({127, 0, 0, 1})

    host =
      start_supervised!(
        {Host,
         data_dir: Path.join(c.root, "host"),
         controller_lan: %{identity: c.identity, binding: host_binding}}
      )

    original_store = Host.store()
    original_listener = Process.whereis(WotexHome.Host.ControllerLAN)
    assert {:ok, _admin, invitation} = Host.open_controller_pairing()
    assert invitation["controller_id"] == c.identity.controller_id
    Process.exit(original_store, :kill)

    await(fn ->
      is_pid(Host.store()) and Host.store() != original_store and
        is_pid(Process.whereis(WotexHome.Host.ControllerLAN)) and
        Process.whereis(WotexHome.Host.ControllerLAN) != original_listener
    end)

    assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())

    bootstrap =
      Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret))
      |> Map.merge(%{
        "client_id" => String.duplicate("4", 64),
        "request_id" => String.duplicate("5", 64),
        "client_label" => "Old boot"
      })

    assert {:ok, %{"reason" => "pairing_closed"}} =
             BootstrapClient.run(invitation, bootstrap, clock())

    assert {:ok, _admin, current} = Host.open_controller_pairing()
    assert current["controller_id"] == invitation["controller_id"]
    assert current["leaf_pin"] == invitation["leaf_pin"]
    refute current["invitation_id"] == invitation["invitation_id"]
    assert Process.alive?(host)
    assert :ok = stop_supervised(Host)

    assert {:error, _} =
             :gen_tcp.connect({127, 0, 0, 1}, host_binding.port, [:binary, active: false], 500)
  end

  defp prepare(c, duration \\ 5_000) do
    {:ok, admin, invitation} = Authority.pairing_open(c.authority, c.template, duration)

    request =
      Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret))
      |> Map.merge(%{
        "client_id" => String.duplicate("4", 64),
        "request_id" => String.duplicate("5", 64),
        "client_label" => "Private TLS fixture"
      })

    {admin, invitation, request}
  end

  defp request(c, payload) do
    socket = connect(c)

    try do
      send_json(socket, payload)
      receive_json(socket)
    after
      :ssl.close(socket)
    end
  end

  defp connect(c) do
    invitation =
      Map.merge(c.template, %{
        "invitation_id" => String.duplicate("1", 64),
        "bootstrap_secret" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      })

    {:ok, trust} = TLSIdentity.new(invitation)
    {:ok, options} = TLSIdentity.options(trust, clock())
    {:ok, socket} = :ssl.connect(c.binding.address, c.binding.port, options, 5_000)
    socket
  end

  defp clock do
    now = System.os_time(:millisecond)
    {:ok, value} = CertificateClock.new(now - 100, now + 100)
    value
  end

  defp send_json(socket, payload), do: :ssl.send(socket, frame(JSON.encode!(payload)))
  defp frame(body), do: <<byte_size(body)::32, body::binary>>

  defp receive_json(socket) do
    {:ok, <<size::32>>} = :ssl.recv(socket, 4, 6_000)
    true = size in 1..1_048_576
    {:ok, body} = :ssl.recv(socket, size, 6_000)
    JSON.decode!(body)
  end

  defp closed_with_alerts(socket, deadline, buffered \\ "") do
    case :gen_tcp.recv(socket, 0, max(0, deadline - System.monotonic_time(:millisecond))) do
      {:error, :closed} ->
        assert alert_records?(buffered)

      {:ok, bytes} when byte_size(buffered) + byte_size(bytes) <= 64 ->
        closed_with_alerts(socket, deadline, buffered <> bytes)

      _ ->
        flunk("overloaded connection was not promptly rejected")
    end
  end

  defp alert_records?(""), do: true

  defp alert_records?(<<21, 3, 3, 0, 2, level, reason, tail::binary>>)
       when level in [1, 2] and reason in [0, 90], do: alert_records?(tail)

  defp alert_records?(_), do: false

  defp allow_closed({:error, :closed}), do: {:ok, :closed}
  defp allow_closed(result), do: result

  defp selected_binding(address) do
    {:ok, interfaces} = :inet.getifaddrs()

    {name, _} =
      Enum.find(interfaces, fn {_, props} -> address in Keyword.get_values(props, :addr) end)

    family = if tuple_size(address) == 8, do: :inet6, else: :inet
    {:ok, socket} = :gen_tcp.listen(0, [family, :binary, active: false, ip: address])
    {:ok, {^address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    %{interface: List.to_string(name), address: address, port: port}
  end

  defp await(predicate, tries \\ 150)

  defp await(predicate, tries) when tries > 0 do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(predicate, tries - 1)
        )
  end

  defp await(_, _), do: flunk("bounded listener state did not arrive")

  defp mutation(credential, operation),
    do: %{
      "api_version" => 1,
      "operation" => "submit",
      "credential" => credential,
      "mutation" => %{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => operation,
        "expected_revision" => 0,
        "target_id" => "light:tls",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      }
    }

  defp thing do
    {:ok, thing} =
      Thing.new(%{
        "id" => "light:tls",
        "role" => "Light",
        "profile_ref" => "fixture:tls",
        "capabilities" => [
          %{
            "thing_id" => "light:tls",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:tls",
            "evidence_ref" => "fixture:tls",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    thing
  end
end
