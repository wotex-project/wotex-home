defmodule WotexHome.NativeSetupTest do
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.NativeSetup.Codec

  setup do
    Process.flag(:trap_exit, true)

    directory =
      Path.join(System.tmp_dir!(), "woh-native-setup-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    {:ok, store: store, authority: Authority.new(store: store), path: path, directory: directory}
  end

  test "closed independent records reject alternate and excessive encodings" do
    deployment = String.duplicate("a", 64)
    owner = String.duplicate("b", 64)
    verifier = String.duplicate("c", 64)

    bytes =
      "[\"wotex-home.native-setup-authority.v1\",\"ensure\",\"#{deployment}\",\"#{owner}\",7,\"operator\",\"#{verifier}\"]"

    assert {:ok, input} = Codec.decode("ensure", bytes)
    assert {:ok, ^bytes} = Codec.encode("ensure", input)
    assert input["authority_epoch"] == 7

    assert {:ok, %{}} =
             Codec.decode(
               "identity_request",
               "[\"wotex-home.native-setup-authority.v1\",\"identity\"]"
             )

    for invalid <- [
          String.replace(bytes, ",7,", ",7.0,"),
          String.replace(bytes, ",7,", ",true,"),
          String.replace(bytes, ",7,", ",0,"),
          String.replace(bytes, ",7,", ",9223372036854775808,"),
          String.replace(bytes, "operator", "qualifier"),
          String.replace(bytes, verifier, String.upcase(verifier)),
          " " <> bytes,
          bytes <> "\n",
          "[" <> bytes <> "]",
          "{\"a\":1,\"a\":2}",
          String.duplicate("[", 2_000) <> "0" <> String.duplicate("]", 2_000),
          "[\"wotex-home.native-setup-authority.v1\",\"identity\",1,2,3,4,5,6,7]",
          String.duplicate(" ", 4_097)
        ] do
      assert {:error, :invalid_native_setup_record} = Codec.decode("ensure", invalid)
    end

    assert {:error, :invalid_native_setup_record} =
             Codec.encode("ensure", Map.put(input, "extra", 1))

    assert {:error, :invalid_native_setup_record} =
             Codec.encode("ensure", %{input | "verifier" => <<0::256>>})
  end

  test "all fixed roles start ungranted and retry the original receipt", context do
    {:ok, identity} = Authority.native_setup_identity(context.authority)
    assert identity["store_revision"] == 0

    for {role, revision} <- Enum.with_index(Codec.roles(), 1) do
      {secret, input} = input(identity, role)
      assert {:ok, receipt} = Authority.ensure_native_principal(context.authority, input)
      assert receipt["revision"] == revision
      assert receipt["principal_id"] == "native-setup-v1:1:#{role}"
      refute Map.has_key?(receipt, "verifier")
      refute Map.has_key?(receipt, "credential")
      assert {:ok, ^receipt} = Authority.ensure_native_principal(context.authority, input)
      assert {:ok, ^revision} = Store.revision(context.store)
      assert {:ok, expected} = Codec.permissions(role)
      assert {:ok, [[^expected]]} = permissions(context.store, receipt["principal_id"])
      assert {:ok, [[0]]} = SQL.query(db(context.store), "SELECT COUNT(*) FROM principal_targets")
      refute "qualify:profile" in expected
      refute "policy:manage" in expected

      if role != "transfer" do
        assert {:ok, %{active_principals: ^revision, dispatch_enabled: false}} =
                 Authority.health(context.authority, secret)
      end
    end

    assert :ok = Integrity.validate_snapshot(db(context.store))
  end

  test "lost committed reply survives restart with its original creation revision", context do
    {:ok, identity} = Authority.native_setup_identity(context.authority)
    {secret, input} = input(identity, "operator")
    assert {:ok, receipt} = Authority.ensure_native_principal(context.authority, input)
    assert {:ok, _, 2} = Authority.provision_diagnostic(context.authority)
    GenServer.stop(context.store)
    assert {:ok, reopened} = Store.start_link(path: context.path)
    Process.unlink(reopened)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    authority = Authority.new(store: reopened)
    assert {:ok, ^receipt} = Authority.ensure_native_principal(authority, input)
    assert receipt["revision"] == 1
    assert {:ok, 2} = Store.revision(reopened)
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Authority.health(authority, secret)
  end

  test "changed identity, verifier and reused secret never write or rotate", context do
    {:ok, identity} = Authority.native_setup_identity(context.authority)
    {secret, input} = input(identity, "operator")
    assert {:ok, receipt} = Authority.ensure_native_principal(context.authority, input)

    for {key, value} <- [
          {"deployment_id", String.duplicate("e", 64)},
          {"owner_id", String.duplicate("d", 64)},
          {"authority_epoch", 2}
        ] do
      assert {:error, :native_owner_changed} =
               Authority.ensure_native_principal(context.authority, Map.put(input, key, value))
    end

    assert {:error, :native_custody_conflict} =
             Authority.ensure_native_principal(context.authority, %{
               input
               | "verifier" => String.duplicate("f", 64)
             })

    assert {:error, :native_custody_conflict} =
             Authority.ensure_native_principal(context.authority, %{
               input
               | "role" => "diagnostic"
             })

    assert {:error, :native_custody_required} =
             Store.rotate_principal_credential(context.store, receipt["principal_id"])

    assert {:error, :native_custody_required} =
             Store.grant_target_and_rotate(
               context.store,
               receipt["principal_id"],
               "light:missing"
             )

    assert {:error, :invalid_provisioning} =
             Store.provision_principal(
               context.store,
               "native-setup-v1:1:maintenance",
               ["read"],
               []
             )

    assert {:ok, 1} = Store.revision(context.store)
    assert {:ok, %{writable: true}} = Authority.health(context.authority, secret)
  end

  test "explicit revocation is never undone by ensure", context do
    {:ok, identity} = Authority.native_setup_identity(context.authority)
    {_secret, input} = input(identity, "operator")
    {:ok, receipt} = Authority.ensure_native_principal(context.authority, input)
    assert {:ok, 2} = Store.revoke_principal(context.store, receipt["principal_id"])

    assert {:error, :native_custody_conflict} =
             Authority.ensure_native_principal(context.authority, input)

    assert {:ok, 2} = Store.revision(context.store)
    assert :ok = Integrity.validate_snapshot(db(context.store))
  end

  test "actual journal failure rolls back principal and revision together", context do
    {:ok, identity} = Authority.native_setup_identity(context.authority)
    {_secret, input} = input(identity, "operator")

    assert {:ok, []} =
             SQL.query(db(context.store), """
             CREATE TRIGGER fail_native_provision BEFORE INSERT ON authority_journal
             WHEN NEW.event_type='native_principal_provisioned'
             BEGIN SELECT RAISE(ABORT,'synthetic failure'); END
             """)

    assert {:error, :store_unavailable} =
             Authority.ensure_native_principal(context.authority, input)

    assert {:ok, [[0]]} = SQL.query(db(context.store), "SELECT COUNT(*) FROM principals")
    assert {:ok, [[0]]} = SQL.query(db(context.store), "SELECT COUNT(*) FROM authority_journal")
    assert {:ok, 0} = Store.revision(context.store)
  end

  test "archive verifier checks native history and damaged links fail startup", context do
    {:ok, identity} = Authority.native_setup_identity(context.authority)
    {_secret, input} = input(identity, "operator")
    assert {:ok, _} = Authority.ensure_native_principal(context.authority, input)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(context.directory, "backup.wohb")
    assert {:ok, _} = Store.export_backup(context.store, archive, key)
    assert {:ok, _} = Backup.verify(archive, key)

    assert {:ok, []} =
             SQL.query(
               db(context.store),
               "UPDATE authority_journal SET event_type='principal_provisioned' WHERE revision=1"
             )

    assert {:error, :corrupt_native_setup} = Integrity.validate_snapshot(db(context.store))
    assert {:error, :corrupt_native_setup} = Authority.native_setup_identity(context.authority)
    GenServer.stop(context.store)

    assert {:error, {:store_open_failed, :corrupt_native_setup}} =
             Store.start_link(path: context.path)
  end

  @tag requires_socket: true
  test "ordinary socket has no native provisioning route", context do
    path = Path.join(context.directory, "ipc/home.sock")

    server =
      start_supervised!(
        {WotexHome.LocalAPI.Server, authority: context.authority, socket_path: path}
      )

    assert Process.alive?(server)

    for operation <- ["native_setup_identity", "ensure_native_principal", "native_setup"] do
      assert {:ok, %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"}} =
               WotexHome.LocalAPI.Client.request(path, %{
                 "api_version" => 1,
                 "operation" => operation
               })
    end

    assert {:ok, 0} = Store.revision(context.store)
    assert {:ok, [[0]]} = SQL.query(db(context.store), "SELECT COUNT(*) FROM principals")
  end

  defp input(identity, role) do
    secret = :crypto.strong_rand_bytes(32)

    input =
      identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => role,
        "verifier" => :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
      })

    {secret, input}
  end

  defp db(store), do: :sys.get_state(store).db

  defp permissions(store, principal) do
    with {:ok, [[document]]} <-
           SQL.query(db(store), "SELECT permissions FROM principals WHERE principal_id=?", [
             principal
           ]),
         {:ok, permissions} <- WotexHome.Durable.Registry.decode_permissions(document),
         do: {:ok, [[permissions]]}
  end
end
