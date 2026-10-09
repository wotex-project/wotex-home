defmodule WotexHome.UpdateFenceTest do
  @moduledoc false
  use ExUnit.Case
  alias WotexHome.Host.UpdateFence

  @artifact String.duplicate("a", 64)

  defp guard(state \\ "pending", revision \\ 3) do
    %{
      "schema_version" => 1,
      "scope" => "linux_release_update_guard",
      "owner_sha256" => String.duplicate("b", 64),
      "artifact_id" => @artifact,
      "authority_epoch" => 1,
      "begin_revision" => revision,
      "state" => state
    }
  end

  test "deny fence is closed, bounded and cannot carry authority or another operation" do
    assert {:ok, _} = UpdateFence.decode(JSON.encode!(guard()))

    for change <- [
          %{"credential" => "private fixture canary"},
          %{"schema_version" => 2},
          %{"schema_version" => 1.0},
          %{"scope" => "install"},
          %{"state" => "authorized"},
          %{"begin_revision" => 0},
          %{"authority_epoch" => 9_223_372_036_854_775_808},
          %{"artifact_id" => "invalid"}
        ] do
      assert {:error, :update_guard_unavailable} =
               UpdateFence.decode(JSON.encode!(Map.merge(guard(), change)))
    end

    assert {:error, :update_guard_unavailable} =
             UpdateFence.decode("{\"schema_version\":1,\"schema_version\":1}")

    assert UpdateFence.valid_configuration?(:disabled)
    refute UpdateFence.valid_configuration?(%{artifact_id: @artifact, path: "/opt/../guard.json"})
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    alias WotexHome.{Authority, CLI, Host}
    alias WotexHome.Durable.Store
    alias WotexHome.LocalAPI.Server
    alias Exqlite.Sqlite3

    setup do
      root = "/opt/woh-fence-test-#{System.unique_integer([:positive])}"
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      path = Path.join(root, "guard.json")
      fence = %{artifact_id: @artifact, path: path}
      database = Path.join(root, "home.sqlite")

      store =
        start_supervised!(
          Supervisor.child_spec({Store, path: database, update_fence: fence}, restart: :temporary)
        )

      authority = Authority.new(store: store)
      {:ok, credential, 1} = Authority.provision_maintenance(authority)
      on_exit(fn -> File.rm_rf!(root) end)

      %{
        root: root,
        path: path,
        fence: fence,
        database: database,
        store: store,
        authority: authority,
        credential: credential
      }
    end

    test "live schema/status is authenticated and its framed shape rejects extra fields", c do
      assert {:ok, status} = Authority.maintenance_update_status(c.authority, c.credential)
      assert status.store_schema_version == 28
      assert status.principal_id == "maintenance:local"
      assert status.update_fence_enabled and status.writable
      assert map_size(status) == 9
      {:ok, ordinary, 2} = Store.provision_principal(c.store, "ordinary:fixture", ["read"], [])

      assert {:error, :permission_denied} =
               Authority.maintenance_update_status(c.authority, ordinary)

      assert {:error, :unauthorized} =
               Authority.maintenance_update_status(c.authority, :binary.copy(<<7>>, 32))

      encoded = Base.url_encode64(c.credential, padding: false)
      {:ok, request} = CLI.build_request(["maintenance-update-status"], encoded)
      {:ok, frame} = WotexHome.LocalAPI.Frame.encode_request(request)
      {:ok, <<size::unsigned-big-32, body::binary>>} = Server.route_frame(c.authority, frame)
      assert size == byte_size(body)

      assert {:ok,
              %{
                "maintenance_update_status" => %{"store_schema_version" => 28, "writable" => true}
              }} =
               WotexHome.LocalAPI.Frame.decode_response(body)

      assert %{"reason" => "unsupported_operation_or_fields"} =
               Server.route(c.authority, Map.put(request, "path", c.database))

      # An external fixture change shows this is the actual DB value rather
      # than a release declaration. No second application writer is installed.
      {:ok, db} = Sqlite3.open(c.database)
      assert :ok = Sqlite3.execute(db, "PRAGMA user_version=26")

      assert {:ok, %{store_schema_version: 26}} =
               Authority.maintenance_update_status(c.authority, c.credential)

      assert :ok = Sqlite3.execute(db, "PRAGMA user_version=28")
      :ok = Sqlite3.close(db)
    end

    test "pending fence denies new end without rewriting history; exact old end retries remain historical",
         c do
      assert {:ok, first} =
               Authority.begin_maintenance(c.authority, c.credential, 1, "begin:first", 1)

      assert {:ok, ended} =
               Authority.end_maintenance(
                 c.authority,
                 c.credential,
                 1,
                 "end:first",
                 first.revision,
                 first.revision
               )

      assert {:ok, second} =
               Authority.begin_maintenance(
                 c.authority,
                 c.credential,
                 1,
                 "begin:second",
                 ended.revision
               )

      publish!(c.path, guard("pending", second.revision))

      assert {:ok, ^ended} =
               Authority.end_maintenance(
                 c.authority,
                 c.credential,
                 1,
                 "end:first",
                 first.revision,
                 first.revision
               )

      assert {:error, :release_update_active} =
               Authority.end_maintenance(
                 c.authority,
                 c.credential,
                 1,
                 "end:second",
                 second.revision,
                 second.revision
               )

      assert {:ok, %{begin_revision: revision, store_revision: revision}} =
               Authority.maintenance_status(c.authority, c.credential)

      assert revision == second.revision

      assert :not_found =
               Authority.maintenance_operation_status(c.authority, c.credential, 1, "end:second")

      assert {:ok, %{writable: true}} = Store.health(c.store)

      publish!(c.path, %{
        guard("complete", second.revision)
        | "artifact_id" => String.duplicate("c", 64)
      })

      assert {:error, :update_artifact_changed} =
               Authority.end_maintenance(
                 c.authority,
                 c.credential,
                 1,
                 "end:second",
                 second.revision,
                 second.revision
               )

      publish!(c.path, guard("complete", second.revision))

      assert {:ok, %{state: :normal}} =
               Authority.end_maintenance(
                 c.authority,
                 c.credential,
                 1,
                 "end:second",
                 second.revision,
                 second.revision
               )
    end

    test "startup checks exact artifact, epoch and retained begin and repeats after restart", c do
      assert :ok = UpdateFence.check_boot(c.store, c.fence)

      assert {:ok, receipt} =
               Authority.begin_maintenance(c.authority, c.credential, 1, "begin:boot", 1)

      publish!(c.path, guard("pending", receipt.revision))
      assert :ok = UpdateFence.check_boot(c.store, c.fence)

      assert {:error, :update_artifact_changed} =
               UpdateFence.check_boot(c.store, %{c.fence | artifact_id: String.duplicate("c", 64)})

      publish!(c.path, %{guard("pending", receipt.revision) | "authority_epoch" => 2})
      assert {:error, :stale_authority_epoch} = UpdateFence.check_boot(c.store, c.fence)
      publish!(c.path, guard("pending", receipt.revision + 1))
      assert {:error, :maintenance_changed} = UpdateFence.check_boot(c.store, c.fence)
      publish!(c.path, guard("pending", receipt.revision))
      GenServer.stop(c.store)
      store = start_supervised!({Store, path: c.database, update_fence: c.fence}, id: :restarted)
      assert :ok = UpdateFence.check_boot(store, c.fence)

      assert {:error, :release_update_active} =
               Store.end_maintenance(
                 store,
                 c.credential,
                 1,
                 "end:boot",
                 receipt.revision,
                 receipt.revision
               )

      publish!(c.path, guard("complete", receipt.revision))

      assert {:ok, _} =
               Store.end_maintenance(
                 store,
                 c.credential,
                 1,
                 "end:boot",
                 receipt.revision,
                 receipt.revision
               )

      publish!(c.path, guard("pending", receipt.revision))
      assert {:error, :maintenance_changed} = UpdateFence.check_boot(store, c.fence)
    end

    test "unsafe guard custody fails closed and leaves its bytes and Store barrier intact", c do
      assert {:ok, receipt} =
               Authority.begin_maintenance(c.authority, c.credential, 1, "begin:custody", 1)

      publish!(c.path, guard("pending", receipt.revision))
      original = File.read!(c.path)

      for mode <- [0o600, 0o666] do
        File.chmod!(c.path, mode)
        assert {:error, :update_guard_unavailable} = UpdateFence.check_boot(c.store, c.fence)

        assert {:error, :update_guard_unavailable} =
                 Authority.end_maintenance(
                   c.authority,
                   c.credential,
                   1,
                   "end:custody",
                   receipt.revision,
                   receipt.revision
                 )

        assert File.read!(c.path) == original
      end

      File.chmod!(c.path, 0o644)
      floating = JSON.encode!(%{guard("complete", receipt.revision) | "schema_version" => 1.0})
      File.write!(c.path, floating)
      assert {:error, :update_guard_unavailable} = UpdateFence.check_boot(c.store, c.fence)

      assert {:error, :update_guard_unavailable} =
               Authority.end_maintenance(
                 c.authority,
                 c.credential,
                 1,
                 "end:custody",
                 receipt.revision,
                 receipt.revision
               )

      assert File.read!(c.path) == floating
      File.write!(c.path, original)
      linked = Path.join(c.root, "linked.json")
      File.ln_s!(c.path, linked)
      assert {:error, :update_guard_unavailable} = UpdateFence.read(%{c.fence | path: linked})
      File.ln!(c.path, Path.join(c.root, "hardlink.json"))
      assert {:error, :update_guard_unavailable} = UpdateFence.read(c.fence)
      File.rm!(Path.join(c.root, "hardlink.json"))
      File.chown!(c.path, 211)
      assert {:error, :update_guard_unavailable} = UpdateFence.read(c.fence)
      File.chown!(c.path, 0)
      File.write!(c.path, String.duplicate("x", 4097))
      assert {:error, :update_guard_unavailable} = UpdateFence.read(c.fence)

      assert {:ok, %{begin_revision: revision, store_revision: revision}} =
               Authority.maintenance_status(c.authority, c.credential)

      assert revision == receipt.revision

      assert :not_found =
               Authority.maintenance_operation_status(c.authority, c.credential, 1, "end:custody")
    end

    @tag :requires_socket
    test "actual host restart tree starts no consumers behind a failed fence", c do
      data = Path.join(c.root, "host")
      File.mkdir!(data)
      File.chmod!(data, 0o700)
      publish!(c.path, guard())
      Process.flag(:trap_exit, true)

      assert {:error, {:shutdown, {:failed_to_start_child, UpdateFence, :maintenance_changed}}} =
               Host.start_link(data_dir: data, update_fence: c.fence)

      refute File.exists?(Path.join(data, "profiles"))
      refute File.exists?(Path.join(data, "ipc"))
      assert Host.store() == nil
      assert Process.whereis(WotexHome.Host.LifxPowerDelivery) == nil
      assert Process.whereis(WotexHome.Host.ScheduleDelivery) == nil
      # Complete cannot make an absent barrier active; it only releases the
      # startup refusal after the coordinator's independently verified finish.
      publish!(c.path, guard("complete"))
      assert {:ok, host} = Host.start_link(data_dir: data, update_fence: c.fence)
      assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
      assert File.exists?(Path.join(data, "ipc/home.sock"))
      Supervisor.stop(host)
    end

    @tag :requires_socket
    test "successful pending boot retains the barrier and a Store restart repeats the fence", c do
      data = Path.join(c.root, "pending-host")
      File.mkdir!(data)
      File.chmod!(data, 0o700)

      bootstrap =
        start_supervised!(
          Supervisor.child_spec({Store, path: Path.join(data, "home.sqlite")},
            restart: :temporary
          ),
          id: :bootstrap
        )

      authority = Authority.new(store: bootstrap)
      {:ok, credential, 1} = Authority.provision_maintenance(authority)

      {:ok, receipt} =
        Authority.begin_maintenance(authority, credential, 1, "begin:pending-host", 1)

      GenServer.stop(bootstrap)
      publish!(c.path, guard("pending", receipt.revision))
      Process.flag(:trap_exit, true)
      assert {:ok, host} = Host.start_link(data_dir: data, update_fence: c.fence)
      on_exit(fn -> if Process.alive?(host), do: Supervisor.stop(host) end)
      assert File.exists?(Path.join(data, "ipc/home.sock"))

      assert {:ok, %{begin_revision: revision, update_fence_enabled: true}} =
               Authority.maintenance_update_status(Host.authority(), credential)

      assert revision == receipt.revision

      assert {:error, :release_update_active} =
               Authority.end_maintenance(
                 Host.authority(),
                 credential,
                 1,
                 "end:pending-host",
                 receipt.revision,
                 receipt.revision
               )

      publish!(c.path, guard("pending", receipt.revision + 1))
      monitor = Process.monitor(host)
      Process.exit(Host.store(), :kill)
      assert_receive {:DOWN, ^monitor, :process, ^host, _}, 5000
      assert Host.store() == nil
      assert Process.whereis(WotexHome.Host.ProfileCustody) == nil
      assert Process.whereis(WotexHome.Host.ProfileReviews) == nil
      assert Process.whereis(WotexHome.Host.LifxPowerDelivery) == nil
      assert Process.whereis(WotexHome.Host.ScheduleDelivery) == nil
      refute File.exists?(Path.join(data, "ipc/home.sock"))
    end

    defp publish!(path, document) do
      File.write!(path, JSON.encode!(document) <> "\n")
      File.chmod!(path, 0o644)
    end
  end
end
