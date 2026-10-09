Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))

defmodule WotexHome.HostTest do
  @moduledoc false

  use ExUnit.Case
  import Bitwise

  alias WotexHome.Authority
  alias WotexHome.Host
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.{Custody, Review, ReviewSession}

  defmodule SocketFreeRestartTree do
    @moduledoc false
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

    def init(opts) do
      {:ok, {flags, children}} = Host.init(opts)
      # Keep the actual Store/gate/power restart order. OS adapters retain their
      # separate tests; no process stands in for a socket or physical device.
      children =
        Enum.reject(
          children,
          &(&1.id in [
              WotexHome.LocalAPI.Server,
              WotexHome.Lifx.CaptureSession
            ])
        )

      {:ok, {flags, children}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "wotex-home-host-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  @tag requires_socket: true
  test "opt-in host owns a private store and local socket lifecycle", %{root: root} do
    data_dir = Path.join(root, "home")
    assert {:ok, host} = Host.start_link(data_dir: data_dir)
    assert is_pid(Host.store())
    assert Authority.owner(Host.authority()) == Host.store()
    assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
    assert Process.whereis(WotexHome.Host.LifxPowerDelivery) == nil
    assert Process.whereis(WotexHome.Host.ScheduleDelivery) == nil
    assert Process.whereis(WotexHome.Host.PairingReviews) == nil
    assert Process.whereis(WotexHome.Host.ControllerLAN) == nil
    assert {:error, :pairing_unavailable} = Host.open_controller_pairing()

    assert {:ok, data_stat} = File.stat(data_dir)
    assert (data_stat.mode &&& 0o777) == 0o700
    assert {:ok, db_stat} = File.stat(Path.join(data_dir, "home.sqlite"))
    assert (db_stat.mode &&& 0o777) == 0o600
    assert File.exists?(Path.join(data_dir, "ipc/home.sock"))

    :ok = Supervisor.stop(host)
    assert Host.store() == nil
    refute File.exists?(Path.join(data_dir, "ipc/home.sock"))
  end

  test "trusted profile bootstraps preserve separate management and review scopes", %{root: root} do
    data_dir = Path.join(root, "bootstrap")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    assert {:ok, host} = SocketFreeRestartTree.start_link(data_dir: data_dir)
    assert {:ok, manager_encoded} = WotexHome.Bootstrap.issue_profile_manager_credential()
    assert {:ok, operator_encoded} = WotexHome.Bootstrap.issue_profile_operator_credential()
    {:ok, manager} = Base.url_decode64(manager_encoded, padding: false)
    {:ok, operator} = Base.url_decode64(operator_encoded, padding: false)
    assert {:error, :principal_exists} = WotexHome.Bootstrap.issue_profile_manager_credential()
    assert {:error, :principal_exists} = WotexHome.Bootstrap.issue_profile_operator_credential()
    assert {:ok, %{items: []}} = Authority.profile_catalogue(Host.authority(), manager)
    assert {:ok, %{items: []}} = Authority.profile_catalogue(Host.authority(), operator)
    fixture = WotexHome.Test.PortableProfileFixture.context()

    assert {:error, :permission_denied} =
             Store.profile_selection_basis(Host.store(), manager, fixture.input)

    assert {:error, :permission_denied} = Authority.lifx_discover(Host.authority(), manager)

    assert {:error, :permission_denied} =
             Authority.begin_maintenance(Host.authority(), operator, 1, "maint:forbidden", 2)

    assert {:error, :permission_denied} =
             Authority.snapshot(Host.authority(), operator, nil, nil, 100)

    :ok = Supervisor.stop(host)
  end

  test "Store ownership precedes profile namespace creation", %{root: root} do
    data_dir = Path.join(root, "owned")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    store = start_supervised!({Store, path: Path.join(data_dir, "home.sqlite")})
    Process.flag(:trap_exit, true)

    assert {:error,
            {:shutdown, {:failed_to_start_child, Store, {:store_open_failed, :already_running}}}} =
             Host.start_link(data_dir: data_dir)

    refute File.exists?(Path.join(data_dir, "profiles"))
    assert {:ok, %{writable: true}} = Store.health(store)
  end

  test "the production profile root is private and malformed existing roots stay untouched", %{
    root: root
  } do
    data_dir = Path.join(root, "invalid-profile-root")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    profiles = Path.join(data_dir, "profiles")
    File.mkdir!(profiles)
    File.chmod!(profiles, 0o755)
    Process.flag(:trap_exit, true)

    assert {:error, {:shutdown, {:failed_to_start_child, Custody, :invalid_profile_custody}}} =
             Host.start_link(data_dir: data_dir)

    assert Host.store() == nil
    assert {:ok, stat} = File.stat(profiles)
    assert (stat.mode &&& 0o777) == 0o755
    File.rmdir!(profiles)
    File.ln_s!(root, profiles)

    assert {:error, {:shutdown, {:failed_to_start_child, Custody, :invalid_profile_custody}}} =
             Host.start_link(data_dir: data_dir)

    assert {:ok, %{type: :symlink}} = File.lstat(profiles)
    assert Host.store() == nil
  end

  test "profile custody restart discards transient reviews and stops consumers while preserving Store",
       %{root: root} do
    data_dir = Path.join(root, "profile-restart")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    assert {:ok, host} = SocketFreeRestartTree.start_link(data_dir: data_dir)
    store = Host.store()
    custody = Process.whereis(WotexHome.Host.ProfileCustody)
    reviews = Process.whereis(WotexHome.Host.ProfileReviews)
    power = Process.whereis(WotexHome.Host.LifxPowerSupervisor)
    assert Host.authority().profile_custody == WotexHome.Host.ProfileCustody
    assert Host.authority().profile_reviews == WotexHome.Host.ProfileReviews
    assert {:ok, stat} = File.stat(Path.join(data_dir, "profiles"))
    assert (stat.mode &&& 0o777) == 0o700
    fixture = WotexHome.Test.PortableProfileFixture.context()
    assert {:ok, digest} = Custody.stage(custody, fixture.artifact.bytes)

    {:ok, review} =
      Review.new(
        fixture.basis,
        fixture.artifact,
        fixture.evidence,
        fixture.input,
        fixture.runtime
      )

    assert {:ok, held} = ReviewSession.hold(reviews, fixture.basis["principal_id"], review)
    assert {:ok, %{lease_count: 1}} = Custody.inventory(custody)
    parent = self()

    {:ok, worker} =
      Task.Supervisor.start_child(power, fn ->
        send(parent, {:profile_worker, self()})

        receive do
          :finish -> :ok
        end
      end)

    monitor = Process.monitor(worker)
    assert_receive {:profile_worker, ^worker}
    Process.exit(custody, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 1_000

    assert_eventually(fn ->
      fresh_custody = Process.whereis(WotexHome.Host.ProfileCustody)
      fresh_reviews = Process.whereis(WotexHome.Host.ProfileReviews)

      is_pid(fresh_custody) and fresh_custody != custody and is_pid(fresh_reviews) and
        fresh_reviews != reviews
    end)

    assert Host.store() == store
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)

    assert :not_found =
             ReviewSession.status(
               WotexHome.Host.ProfileReviews,
               fixture.basis["principal_id"],
               held.review_token
             )

    assert {:ok, artifact} = Custody.read(WotexHome.Host.ProfileCustody, digest)
    assert artifact == fixture.artifact
    assert {:ok, %{lease_count: 0}} = Custody.inventory(WotexHome.Host.ProfileCustody)
    :ok = Supervisor.stop(host)
  end

  test "review-owner restart releases leases without replacing Store or custody", %{root: root} do
    data_dir = Path.join(root, "review-restart")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    {:ok, host} = SocketFreeRestartTree.start_link(data_dir: data_dir)
    store = Host.store()
    custody = Process.whereis(WotexHome.Host.ProfileCustody)
    reviews = Process.whereis(WotexHome.Host.ProfileReviews)
    fixture = WotexHome.Test.PortableProfileFixture.context()
    assert {:ok, _} = Custody.stage(custody, fixture.artifact.bytes)

    {:ok, review} =
      Review.new(
        fixture.basis,
        fixture.artifact,
        fixture.evidence,
        fixture.input,
        fixture.runtime
      )

    assert {:ok, held} = ReviewSession.hold(reviews, fixture.basis["principal_id"], review)
    Process.exit(reviews, :kill)

    assert_eventually(fn ->
      owner = Process.whereis(WotexHome.Host.ProfileReviews)

      is_pid(owner) and owner != reviews and
        match?({:ok, %{lease_count: 0}}, Custody.inventory(custody))
    end)

    assert Host.store() == store
    assert Process.whereis(WotexHome.Host.ProfileCustody) == custody

    assert :not_found =
             ReviewSession.status(
               WotexHome.Host.ProfileReviews,
               fixture.basis["principal_id"],
               held.review_token
             )

    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
    :ok = Supervisor.stop(host)
  end

  test "host rejects an existing nonprivate data directory", %{root: root} do
    data_dir = Path.join(root, "public")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o755)
    Process.flag(:trap_exit, true)
    assert {:error, :invalid_host_directory} = Host.start_link(data_dir: data_dir)
  end

  test "the actual host restart tree stops power workers before replacing Store", %{root: root} do
    data_dir = Path.join(root, "restart-tree")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    assert {:ok, host} = SocketFreeRestartTree.start_link(data_dir: data_dir)
    first_store = Host.store()
    first_pool = Process.whereis(WotexHome.Host.LifxPowerSupervisor)
    parent = self()

    assert {:ok, worker} =
             Task.Supervisor.start_child(first_pool, fn ->
               send(parent, {:worker_started, self()})

               receive do
                 :finish -> :ok
               end
             end)

    monitor = Process.monitor(worker)
    assert_receive {:worker_started, ^worker}, 1_000
    Process.exit(first_store, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 1_000

    assert_eventually(fn ->
      restarted = Host.store()
      pool = Process.whereis(WotexHome.Host.LifxPowerSupervisor)

      is_pid(restarted) and restarted != first_store and is_pid(pool) and pool != first_pool and
        match?({:ok, %{writable: true}}, Store.health(restarted)) and
        Task.Supervisor.children(pool) == []
    end)

    :ok = Supervisor.stop(host)
  end

  test "capture precedes explicit delivery and its power workers in the actual host tree", %{
    root: root
  } do
    previous = Application.get_env(:wotex_home, :lifx_power_dispatch_enabled)
    interface = Application.get_env(:wotex_home, :lifx_capture_interface)
    Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, true)
    Application.put_env(:wotex_home, :lifx_capture_interface, "fixture:interface")

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:wotex_home, :lifx_power_dispatch_enabled),
        else: Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, previous)

      if is_nil(interface),
        do: Application.delete_env(:wotex_home, :lifx_capture_interface),
        else: Application.put_env(:wotex_home, :lifx_capture_interface, interface)
    end)

    assert {:ok, {%{strategy: :rest_for_one}, children}} = Host.init(data_dir: root)
    ids = Enum.map(children, & &1.id)
    capture = Enum.find_index(ids, &(&1 == WotexHome.Lifx.CaptureSession))
    delivery = Enum.find_index(ids, &(&1 == WotexHome.Lifx.PowerDelivery))
    power = Enum.find_index(ids, &(&1 == WotexHome.Host.LifxPowerSupervisor))
    server = Enum.find_index(ids, &(&1 == WotexHome.LocalAPI.Server))
    assert capture < delivery and delivery < power and power < server
  end

  test "delivery owner failure stops power workers before restarting the consumer", %{root: root} do
    previous = Application.get_env(:wotex_home, :lifx_power_dispatch_enabled)
    Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:wotex_home, :lifx_power_dispatch_enabled),
        else: Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, previous)
    end)

    data_dir = Path.join(root, "delivery-restart")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    assert {:ok, host} = SocketFreeRestartTree.start_link(data_dir: data_dir)
    store = Host.store()
    delivery = Process.whereis(WotexHome.Host.LifxPowerDelivery)
    power = Process.whereis(WotexHome.Host.LifxPowerSupervisor)
    observer = self()

    {:ok, worker} =
      Task.Supervisor.start_child(power, fn ->
        send(observer, {:delivery_worker_started, self()})

        receive do
          :finish -> :ok
        end
      end)

    monitor = Process.monitor(worker)
    assert_receive {:delivery_worker_started, ^worker}
    Process.exit(delivery, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 1_000

    assert_eventually(fn ->
      replacement = Process.whereis(WotexHome.Host.LifxPowerDelivery)
      new_power = Process.whereis(WotexHome.Host.LifxPowerSupervisor)

      is_pid(replacement) and replacement != delivery and is_pid(new_power) and new_power != power and
        Task.Supervisor.children(new_power) == []
    end)

    assert Host.store() == store
    :ok = Supervisor.stop(host)
  end

  test "temporal delivery requires both trusted flags and precedes every effect worker", %{
    root: root
  } do
    prior =
      Map.new(
        [:lifx_power_dispatch_enabled, :schedule_delivery_enabled],
        &{&1, Application.get_env(:wotex_home, &1)}
      )

    on_exit(fn ->
      Enum.each(prior, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:wotex_home, key),
          else: Application.put_env(:wotex_home, key, value)
      end)
    end)

    for physical <- [false, true], temporal <- [false, true] do
      Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, physical)
      Application.put_env(:wotex_home, :schedule_delivery_enabled, temporal)
      assert {:ok, {%{strategy: :rest_for_one}, children}} = Host.init(data_dir: root)
      ids = Enum.map(children, & &1.id)
      assert WotexHome.Schedules.Delivery in ids == (physical and temporal)

      if physical and temporal do
        scheduled = Enum.find_index(ids, &(&1 == WotexHome.Schedules.Delivery))
        explicit = Enum.find_index(ids, &(&1 == WotexHome.Lifx.PowerDelivery))
        power = Enum.find_index(ids, &(&1 == WotexHome.Host.LifxPowerSupervisor))
        assert scheduled < explicit and explicit < power
      end
    end
  end

  test "temporal owner failure stops downstream consumers and workers while retaining Store", %{
    root: root
  } do
    prior =
      Map.new(
        [:lifx_power_dispatch_enabled, :schedule_delivery_enabled],
        &{&1, Application.get_env(:wotex_home, &1)}
      )

    Enum.each(Map.keys(prior), &Application.put_env(:wotex_home, &1, true))

    on_exit(fn ->
      Enum.each(prior, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:wotex_home, key),
          else: Application.put_env(:wotex_home, key, value)
      end)
    end)

    data_dir = Path.join(root, "temporal-restart")
    File.mkdir!(data_dir)
    File.chmod!(data_dir, 0o700)
    assert {:ok, host} = SocketFreeRestartTree.start_link(data_dir: data_dir)
    store = Host.store()
    scheduled = Process.whereis(WotexHome.Host.ScheduleDelivery)
    explicit = Process.whereis(WotexHome.Host.LifxPowerDelivery)
    power = Process.whereis(WotexHome.Host.LifxPowerSupervisor)
    observer = self()

    {:ok, worker} =
      Task.Supervisor.start_child(power, fn ->
        send(observer, {:temporal_worker_started, self()})

        receive do
          :finish -> :ok
        end
      end)

    monitor = Process.monitor(worker)
    assert_receive {:temporal_worker_started, ^worker}
    Process.exit(scheduled, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 1_000

    assert_eventually(fn ->
      new_scheduled = Process.whereis(WotexHome.Host.ScheduleDelivery)
      new_explicit = Process.whereis(WotexHome.Host.LifxPowerDelivery)
      new_power = Process.whereis(WotexHome.Host.LifxPowerSupervisor)

      is_pid(new_scheduled) and new_scheduled != scheduled and
        is_pid(new_explicit) and new_explicit != explicit and
        is_pid(new_power) and new_power != power and Task.Supervisor.children(new_power) == []
    end)

    assert Host.store() == store
    assert {:ok, %{writable: true}} = Store.health(store)

    assert_eventually(fn ->
      :sys.get_state(Process.whereis(WotexHome.Host.ScheduleDelivery)).last_poll == :inactive
    end)

    :ok = Supervisor.stop(host)
  end

  @tag requires_socket: true
  test "store crash restarts the owned store and socket together", %{root: root} do
    data_dir = Path.join(root, "home")
    assert {:ok, host} = Host.start_link(data_dir: data_dir)
    first_store = Host.store()
    assert is_pid(first_store)
    Process.exit(first_store, :kill)

    assert_eventually(fn ->
      restarted = Host.store()

      is_pid(restarted) and restarted != first_store and
        match?({:ok, _}, Store.health(restarted)) and
        File.exists?(Path.join(data_dir, "ipc/home.sock"))
    end)

    :ok = Supervisor.stop(host)
  end

  test "an optional component runner restarts without restarting Store or power", %{root: root} do
    File.chmod!(root, 0o700)
    previous = Application.get_env(:wotex_home, :component_preview)

    Application.put_env(:wotex_home, :component_preview,
      root: root,
      executable: System.find_executable("true")
    )

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:wotex_home, :component_preview),
        else: Application.put_env(:wotex_home, :component_preview, previous)
    end)

    assert {:ok, host} = SocketFreeRestartTree.start_link(data_dir: root)
    store = Host.store()
    power = Process.whereis(WotexHome.Host.LifxPowerSupervisor)
    runner = Process.whereis(WotexHome.Host.ComponentRunner)
    assert is_pid(runner)
    assert Host.authority().component_runner == WotexHome.Host.ComponentRunner
    Process.exit(runner, :kill)

    assert_eventually(fn ->
      replacement = Process.whereis(WotexHome.Host.ComponentRunner)
      is_pid(replacement) and replacement != runner
    end)

    assert Host.store() == store
    assert Process.whereis(WotexHome.Host.LifxPowerSupervisor) == power
    assert {:ok, %{dispatch_enabled: false, writable: true}} = Store.health(store)
    :ok = Supervisor.stop(host)
  end

  defp assert_eventually(predicate, attempts \\ 40)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
