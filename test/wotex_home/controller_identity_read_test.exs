defmodule WotexHome.ControllerIdentityReadTest do
  @moduledoc false
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.SQL
  alias WotexHome.LocalAPI.{Client, Frame, Server}

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    directory = Path.join(temporary, "woh-identity-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    authority = Authority.new(store: store)
    assert {:ok, reader, 1} = Authority.provision_diagnostic(authority)
    %{directory: directory, path: path, store: store, authority: authority, reader: reader}
  end

  test "zero-target reader gets only current ownership and its own principal without writes", c do
    before = retained_counts(c.path)
    assert {:ok, identity} = Authority.controller_identity(c.authority, c.reader)

    assert Map.keys(identity) |> Enum.sort() ==
             [:authority_epoch, :deployment_id, :owner_id, :principal_id, :store_revision]

    assert identity.principal_id == "diagnostics:local"
    assert identity.authority_epoch == 1 and identity.store_revision == 1
    assert identity.deployment_id =~ ~r/\A[0-9a-f]{64}\z/
    assert identity.owner_id =~ ~r/\A[0-9a-f]{64}\z/
    refute identity.deployment_id == identity.owner_id
    assert framed(c.authority, request(c.reader)) == wire(identity)
    assert retained_counts(c.path) == before
    assert {:ok, 1} = Store.revision(c.store)
  end

  test "separate roles may identify their own context without acquiring read or transfer", c do
    assert {:ok, maintenance, 2} = Authority.provision_maintenance(c.authority)
    assert {:ok, transfer, 3} = Authority.provision_transfer(c.authority)

    assert {:ok, maintenance_identity} = Authority.controller_identity(c.authority, maintenance)
    assert {:ok, transfer_identity} = Authority.controller_identity(c.authority, transfer)
    assert maintenance_identity.principal_id == "maintenance:local"
    assert transfer_identity.principal_id == "transfer:local"

    assert Map.delete(maintenance_identity, :principal_id) ==
             Map.delete(transfer_identity, :principal_id)

    assert maintenance_identity.store_revision == 3
    assert {:error, :permission_denied} = Authority.health(c.authority, maintenance)
    assert {:error, :permission_denied} = Authority.health(c.authority, transfer)
    assert {:error, :permission_denied} = Authority.controller_status(c.authority, c.reader)
    assert retained_counts(c.path) == [3, 3, 0]
  end

  test "unknown, malformed and revoked credentials reveal no identity", c do
    assert {:error, :invalid_credential} = Authority.controller_identity(c.authority, <<1>>)

    assert {:error, :unauthorized} =
             Authority.controller_identity(c.authority, :binary.copy(<<0>>, 32))

    assert {:error, :invalid_credential} = Authority.controller_identity(c.authority, %{})
    assert {:ok, 2} = Store.revoke_principal(c.store, "diagnostics:local")
    before = retained_counts(c.path)
    assert {:error, :unauthorized} = Authority.controller_identity(c.authority, c.reader)

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             framed(c.authority, request(c.reader))

    assert retained_counts(c.path) == before
  end

  test "closed route cannot accept caller identity or expose trusted setup", c do
    for {key, value} <- [
          {"owner_id", String.duplicate("a", 64)},
          {"principal_id", "diagnostic:local"},
          {"role", "operator"},
          {"authority_epoch", 1},
          {"store_revision", 1}
        ] do
      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(c.authority, Map.put(request(c.reader), key, value))
    end

    for operation <- ["native_setup_identity", "ensure_native_principal"] do
      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(c.authority, %{request(c.reader) | "operation" => operation})
    end

    assert %{"outcome" => "error", "reason" => "invalid_credential"} =
             framed(c.authority, %{request(c.reader) | "credential" => "invalid"})

    assert {:ok, 1} = Store.revision(c.store)
  end

  test "restart retains identity while an independent Store cannot impersonate it", c do
    assert {:ok, original} = Authority.controller_identity(c.authority, c.reader)
    :ok = GenServer.stop(c.store)
    store = start_supervised!({Store, path: c.path}, id: :restarted)
    assert {:ok, ^original} = Store.controller_identity(store, c.reader)

    independent =
      start_supervised!({Store, path: Path.join(c.directory, "independent.sqlite")},
        id: :independent
      )

    assert {:error, :unauthorized} = Store.controller_identity(independent, c.reader)

    assert {:ok, other, 1} =
             Store.provision_principal(independent, "diagnostics:local", ["read"], [])

    assert {:ok, other_identity} = Store.controller_identity(independent, other)
    assert other_identity.principal_id == original.principal_id
    refute other_identity.deployment_id == original.deployment_id
    refute other_identity.owner_id == original.owner_id
  end

  test "maintenance identifies active ownership but retirement refuses ordinary context", c do
    assert {:ok, maintenance, 2} = Authority.provision_maintenance(c.authority)
    assert {:ok, transfer, 3} = Authority.provision_transfer(c.authority)
    assert {:ok, barrier} = Store.begin_maintenance(c.store, maintenance, 1, "maint:identity", 3)

    assert {:ok, %{store_revision: revision}} =
             Authority.controller_identity(c.authority, c.reader)

    assert revision == barrier.revision

    assert {:ok, _receipt} =
             Store.retire_controller(c.store, transfer, %{
               "authority_epoch" => 1,
               "operation_id" => "retire:identity",
               "expected_revision" => revision,
               "destination_owner_id" => String.duplicate("a", 64)
             })

    assert {:error, :source_retired} = Authority.controller_identity(c.authority, c.reader)
    assert {:error, :source_retired} = Authority.controller_identity(c.authority, transfer)

    assert %{"outcome" => "error", "reason" => "source_retired"} =
             framed(c.authority, request(c.reader))
  end

  @tag requires_socket: true
  test "actual private socket returns the same authenticated read and current watermark", c do
    socket = Path.join(c.directory, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    assert {:ok, identity} = Authority.controller_identity(c.authority, c.reader)
    assert {:ok, response} = Client.request(socket, request(c.reader))
    assert response == wire(identity)
    assert {:ok, _maintenance, 2} = Authority.provision_maintenance(c.authority)
    assert {:ok, response} = Client.request(socket, request(c.reader))
    assert response == wire(%{identity | store_revision: 2})
    assert {:ok, 2} = Store.revision(c.store)
  end

  defp request(credential),
    do: %{
      "api_version" => 1,
      "operation" => "controller_identity",
      "credential" => Base.url_encode64(credential, padding: false)
    }

  defp wire(identity),
    do: %{
      "api_version" => 1,
      "outcome" => "ok",
      "controller_identity" =>
        Map.new(identity, fn {key, value} -> {Atom.to_string(key), value} end)
    }

  defp framed(authority, request) do
    assert {:ok, frame} = Frame.encode_request(request)
    assert {:ok, <<size::unsigned-big-32, body::binary>>} = Server.route_frame(authority, frame)
    assert size == byte_size(body)
    assert {:ok, response} = Frame.decode_response(body)
    response
  end

  defp retained_counts(path) do
    {:ok, db} = Sqlite3.open(path)

    try do
      assert {:ok, [[revision, journal, targets]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT COUNT(*) FROM authority_journal),(SELECT COUNT(*) FROM principal_targets)"
               )

      [revision, journal, targets]
    after
      Sqlite3.close(db)
    end
  end
end
