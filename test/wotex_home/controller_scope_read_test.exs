defmodule WotexHome.ControllerScopeReadTest do
  @moduledoc false
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.ControllerConnections.{InstallationIdentity, PairingReview}
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.SQL
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Semantics.Thing

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-scope-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    authority = Authority.new(store: store)
    {:ok, reader, 1} = Authority.provision_diagnostic(authority)
    %{root: root, path: path, store: store, authority: authority, reader: reader}
  end

  test "all zero-target roles inspect only their own grants without gaining authority", c do
    assert {:ok, maintenance, 2} = Authority.provision_maintenance(c.authority)
    assert {:ok, transfer, 3} = Authority.provision_transfer(c.authority)
    before = snapshot(c.store)

    for {key, principal, permissions} <- [
          {c.reader, "diagnostics:local", ["read"]},
          {maintenance, "maintenance:local", ["host:maintain"]},
          {transfer, "transfer:local", ["host:transfer"]}
        ] do
      assert {:ok, scope} = Authority.controller_scope(c.authority, key)

      assert Enum.sort(Map.keys(scope)) ==
               Enum.sort([
                 :format,
                 :deployment_id,
                 :owner_id,
                 :authority_epoch,
                 :store_revision,
                 :principal_id,
                 :permissions,
                 :target_ids
               ])

      assert scope.format == "wotex-home.controller-scope.v1"
      assert scope.principal_id == principal and scope.permissions == permissions
      assert scope.target_ids == [] and scope.authority_epoch == 1 and scope.store_revision == 3
      assert {:ok, identity} = Authority.controller_identity(c.authority, key)
      assert Map.take(scope, Map.keys(identity)) == identity
      assert framed(c.authority, request(key)) == wire(scope)
    end

    assert {:error, :permission_denied} = Authority.health(c.authority, maintenance)
    assert {:error, :permission_denied} = Authority.health(c.authority, transfer)
    assert {:error, :permission_denied} = Authority.controller_status(c.authority, c.reader)
    assert snapshot(c.store) == before
  end

  test "scope sorts own assignments without rewriting durable permission order", c do
    for id <- ["light:z", "light:a"],
        do: assert({:ok, _} = Store.enroll_thing(c.store, thing(id)))

    permissions = ["rule:review", "read", "control:ordinary"]

    assert {:ok, key, _} =
             Store.provision_principal(c.store, "operator:scope", permissions, [
               "light:z",
               "light:a"
             ])

    before = snapshot(c.store)
    assert {:ok, scope} = Authority.controller_scope(c.authority, key)
    assert scope.permissions == Enum.sort(permissions)
    assert scope.target_ids == ["light:a", "light:z"]
    assert scope.principal_id == "operator:scope"
    assert framed(c.authority, request(key)) == wire(scope)

    assert {:ok, [[document]]} =
             SQL.query(db(c.store), "SELECT permissions FROM principals WHERE principal_id=?", [
               "operator:scope"
             ])

    assert document == JSON.encode!(permissions)
    assert snapshot(c.store) == before
  end

  test "scope bound admits thirty-two assignments and refuses a corrupt thirty-third", c do
    ids = for n <- 0..32, do: "light:scope#{n}"
    for id <- ids, do: assert({:ok, _} = Store.enroll_thing(c.store, thing(id)))

    assert {:ok, key, _} =
             Store.provision_principal(c.store, "operator:bounds", ["read"], Enum.take(ids, 32))

    assert {:ok, %{target_ids: targets}} = Store.controller_scope(c.store, key)
    assert targets == ids |> Enum.take(32) |> Enum.sort()

    assert {:ok, []} =
             SQL.query(db(c.store), "INSERT INTO principal_targets VALUES (?,?)", [
               "operator:bounds",
               List.last(ids)
             ])

    before = snapshot(c.store)
    assert {:error, :corrupt_principal} = Store.controller_scope(c.store, key)
    assert snapshot(c.store) == before
  end

  test "corrupt permission vocabulary fails closed without changing any table", c do
    assert {:ok, []} =
             SQL.query(db(c.store), "UPDATE principals SET permissions=? WHERE principal_id=?", [
               ~s(["read","unknown:permission"]),
               "diagnostics:local"
             ])

    before = snapshot(c.store)
    assert {:error, :corrupt_principal} = Store.controller_scope(c.store, c.reader)
    assert snapshot(c.store) == before
  end

  test "unknown malformed and revoked keys reveal no scope", c do
    assert {:error, :invalid_credential} = Authority.controller_scope(c.authority, <<1>>)
    assert {:error, :invalid_credential} = Authority.controller_scope(c.authority, %{})

    assert {:error, :unauthorized} =
             Authority.controller_scope(c.authority, :binary.copy(<<0>>, 32))

    assert {:ok, _} = Store.revoke_principal(c.store, "diagnostics:local")
    before = snapshot(c.store)
    assert {:error, :unauthorized} = Authority.controller_scope(c.authority, c.reader)

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             framed(c.authority, request(c.reader))

    assert snapshot(c.store) == before
  end

  test "closed route refuses caller roles identities grants and key material", c do
    before = snapshot(c.store)

    for {field, value} <- [
          {"principal_id", "diagnostics:local"},
          {"owner_id", String.duplicate("a", 64)},
          {"permissions", ["host:maintain"]},
          {"target_ids", []},
          {"authority_epoch", 1},
          {"store_revision", 1},
          {"format", "wotex-home.controller-scope.v1"},
          {"credential_verifier", String.duplicate("b", 64)},
          {"role", "operator"}
        ] do
      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(c.authority, Map.put(request(c.reader), field, value))
    end

    assert snapshot(c.store) == before
  end

  test "CLI emits only the fixed authenticated scope request and refuses selectors", c do
    encoded = Base.url_encode64(c.reader, padding: false)
    assert {:ok, scope_request} = WotexHome.CLI.build_request(["controller-scope"], encoded)
    assert scope_request == request(c.reader)

    for arguments <- [
          ["controller-scope", "diagnostics:local"],
          ["controller-scope", "--role", "operator"]
        ] do
      assert {:error, :usage} = WotexHome.CLI.build_request(arguments, encoded)
    end
  end

  @tag requires_socket: true
  test "actual private UDS reflects current scope after separate revision changes", c do
    socket = Path.join(c.root, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    assert {:ok, original} = Authority.controller_scope(c.authority, c.reader)
    assert {:ok, response} = Client.request(socket, request(c.reader))
    assert response == wire(original)
    assert {:ok, _, 2} = Authority.provision_maintenance(c.authority)
    assert {:ok, response} = Client.request(socket, request(c.reader))
    assert response == wire(%{original | store_revision: 2})
    assert {:ok, %{dispatch_enabled: false}} = Store.health(c.store)
  end

  test "restart preserves scope and a foreign owner cannot authenticate the original", c do
    assert {:ok, original} = Store.controller_scope(c.store, c.reader)
    :ok = GenServer.stop(c.store)
    store = start_supervised!({Store, path: c.path}, id: :restart)
    assert {:ok, ^original} = Store.controller_scope(store, c.reader)
    foreign = start_supervised!({Store, path: Path.join(c.root, "foreign.sqlite")}, id: :foreign)
    assert {:error, :unauthorized} = Store.controller_scope(foreign, c.reader)
    assert {:ok, other, _} = Store.provision_principal(foreign, "diagnostics:local", ["read"], [])
    assert {:ok, different} = Store.controller_scope(foreign, other)
    refute different.owner_id == original.owner_id
    refute different.deployment_id == original.deployment_id
    assert different.principal_id == original.principal_id
  end

  test "maintenance preserves active scope but retirement refuses it", c do
    assert {:ok, maintenance, 2} = Authority.provision_maintenance(c.authority)
    assert {:ok, transfer, 3} = Authority.provision_transfer(c.authority)
    assert {:ok, barrier} = Store.begin_maintenance(c.store, maintenance, 1, "maint:scope", 3)
    assert {:ok, %{store_revision: revision}} = Authority.controller_scope(c.authority, c.reader)
    assert revision == barrier.revision

    assert {:ok, _} =
             Store.retire_controller(c.store, transfer, %{
               "authority_epoch" => 1,
               "operation_id" => "retire:scope",
               "expected_revision" => revision,
               "destination_owner_id" => String.duplicate("a", 64)
             })

    before = snapshot(c.store)
    assert {:error, :source_retired} = Authority.controller_scope(c.authority, c.reader)
    assert snapshot(c.store) == before
  end

  test "an actually consumed approved pairing exposes only its retained own grants", c do
    now = System.os_time(:second)

    assert {:ok, identity} =
             InstallationIdentity.create(Path.join(c.root, "identity"), %{
               not_before: now - 60,
               not_after: now + 86_400
             })

    assert {:ok, public} = InstallationIdentity.descriptor(identity)
    template = Map.put(public, "endpoint", ["ipv4", "127.0.0.1", 49_999])

    reviews = start_supervised!({PairingReview, store_owner: c.store})
    authority = Authority.new(store: c.store, pairing_reviews: reviews)
    assert {:ok, admin, invitation} = Authority.pairing_open(authority, template)

    request =
      Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)), %{
        "client_id" => String.duplicate("1", 64),
        "request_id" => String.duplicate("2", 64),
        "client_label" => "scope fixture"
      })

    assert {:ok, reference} = Authority.pairing_prepare(authority, admin, request)
    assert {:ok, _} = Authority.pairing_approve(authority, admin, reference)
    assert {:ok, paired} = Authority.pairing_complete(authority, request)
    key = Base.url_decode64!(paired["credential"], padding: false)
    before = snapshot(c.store)
    assert {:ok, scope} = Authority.controller_scope(authority, key)
    assert scope.principal_id == paired["principal_id"]
    assert scope.permissions == paired["permissions"] and scope.target_ids == paired["target_ids"]

    assert scope.store_revision == paired["revision"] and
             scope.authority_epoch == paired["authority_epoch"]

    assert snapshot(c.store) == before
  end

  defp request(key),
    do: %{
      "api_version" => 1,
      "operation" => "controller_scope",
      "credential" => Base.url_encode64(key, padding: false)
    }

  defp wire(scope),
    do: %{
      "api_version" => 1,
      "outcome" => "ok",
      "controller_scope" => Map.new(scope, fn {k, v} -> {Atom.to_string(k), v} end)
    }

  defp db(store), do: :sys.get_state(store).db

  defp snapshot(store) do
    database = db(store)

    assert {:ok, tables} =
             SQL.query(
               database,
               "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
             )

    counts =
      for [name] <- tables do
        assert name =~ ~r/\A[a-z_]+\z/
        assert {:ok, [[count]]} = SQL.query(database, "SELECT COUNT(*) FROM " <> name)
        {name, count}
      end

    assert {:ok, meta} = SQL.query(database, "SELECT key,value FROM meta ORDER BY key")
    {counts, meta}
  end

  defp framed(authority, request) do
    assert {:ok, frame} = Frame.encode_request(request)
    assert {:ok, <<size::32, body::binary>>} = Server.route_frame(authority, frame)
    assert size == byte_size(body)
    assert {:ok, response} = Frame.decode_response(body)
    response
  end

  defp thing(id) do
    {:ok, thing} =
      Thing.new(%{
        "id" => id,
        "role" => "Light",
        "profile_ref" => "fixture:scope",
        "capabilities" => [
          %{
            "thing_id" => id,
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:scope",
            "evidence_ref" => "fixture:scope",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    thing
  end
end
