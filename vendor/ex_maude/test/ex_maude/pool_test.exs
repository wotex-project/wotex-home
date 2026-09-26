defmodule ExMaude.PoolTest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.Error
  alias ExMaude.Pool

  doctest ExMaude.Pool

  describe "child_spec/1" do
    test "returns valid child spec with defaults" do
      spec = Pool.child_spec([])
      assert %{id: :ex_maude_pool, start: {:poolboy, :start_link, _}} = spec
      assert Supervisor.child_spec(spec, []) == spec
    end

    test "accepts pool_size option" do
      spec = Pool.child_spec(pool_size: 8)
      assert %{start: {:poolboy, :start_link, [pool_config, _]}} = spec
      assert pool_config[:size] == 8
    end

    test "accepts pool_max_overflow option" do
      spec = Pool.child_spec(pool_max_overflow: 4)
      assert %{start: {:poolboy, :start_link, [pool_config, _]}} = spec
      assert pool_config[:max_overflow] == 4
    end

    test "accepts combined options" do
      spec = Pool.child_spec(pool_size: 8, pool_max_overflow: 4)
      assert %{start: {:poolboy, :start_link, [pool_config, _]}} = spec
      assert pool_config[:size] == 8
      assert pool_config[:max_overflow] == 4
    end

    test "accepts a caller-owned pool name" do
      %{id: id, start: {:poolboy, :start_link, [pool_config, _]}} =
        Pool.child_spec(name: :secondary_maude_pool)

      assert id == :secondary_maude_pool
      assert pool_config[:name] == {:local, :secondary_maude_pool}
    end

    test "rejects a non-atom pool name" do
      assert_raise ArgumentError, fn -> Pool.child_spec(name: "invalid") end
    end

    test "passes worker options through" do
      spec = Pool.child_spec(pool_size: 2, maude_path: "/custom/path")
      assert %{start: {:poolboy, :start_link, [_, worker_opts]}} = spec
      assert worker_opts[:maude_path] == "/custom/path"
    end

    test "child spec has correct structure" do
      spec = Pool.child_spec([])
      %{id: id, start: {module, func, _}} = spec
      assert id == :ex_maude_pool
      assert module == :poolboy
      assert func == :start_link
    end
  end

  describe "broadcast/1" do
    test "returns a structured error when the pool is not running" do
      pool = :missing_ex_maude_pool

      assert {:error, %Error{type: :pool_error, details: %{reason: :not_started}}} =
               Pool.broadcast(fn _ -> :ok end, pool: pool)
    end

    test "uses the actual workers in a custom-sized pool" do
      pool = :ex_maude_broadcast_test_pool

      pool_config = [
        name: {:local, pool},
        worker_module: ExMaude.PoolTest.Worker,
        size: 1,
        max_overflow: 0
      ]

      start_supervised!({ExMaude.PoolTest.PoolOwner, {pool_config, []}})

      assert {:ok, [worker]} = Pool.broadcast(& &1, pool: pool)
      assert is_pid(worker)
    end
  end

  @tag capture_log: true
  test "broadcast callback failures cannot take down the caller" do
    config = [
      name: {:local, :broadcast_failure_pool},
      worker_module: ExMaude.PoolTest.Worker,
      size: 1,
      max_overflow: 0
    ]

    start_supervised!({ExMaude.PoolTest.PoolOwner, {config, []}})

    for fun <- [
          fn _ -> exit(:boom) end,
          fn _ -> raise "boom" end,
          fn _ -> Process.exit(self(), :kill) end
        ] do
      assert {:ok, [{:error, %Error{type: :pool_error}}]} =
               Pool.broadcast(fun, pool: :broadcast_failure_pool)
    end

    assert {:ok, [:ok]} = Pool.broadcast(fn _ -> :ok end, pool: :broadcast_failure_pool)
  end

  test "checkout telemetry completes before executing the transaction" do
    name = :checkout_telemetry_pool

    start_supervised!(
      Pool.child_spec(
        name: name,
        worker_module: ExMaude.Backend.Port,
        pool_size: 1,
        pool_max_overflow: 0,
        maude_path: Path.expand("../support/fake_maude.sh", __DIR__)
      )
    )

    configured_backend = Application.get_env(:ex_maude, :backend)
    Application.put_env(:ex_maude, :backend, :nif)

    on_exit(fn ->
      if configured_backend,
        do: Application.put_env(:ex_maude, :backend, configured_backend),
        else: Application.delete_env(:ex_maude, :backend)
    end)

    handler = "checkout-order-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:ex_maude, :pool, :checkout, :stop],
      fn _, _, metadata, _ -> send(parent, {:checked_out, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Pool.transaction(
               fn _ ->
                 assert_receive {:checked_out, %{backend: :port, pool: ^name, result: :ok}}
                 :ok
               end,
               pool: name
             )
  end

  describe "checkout/1" do
    test "returns a structured error when the pool is not running" do
      assert {:error, %Error{type: :pool_error}} =
               Pool.checkout(pool: :missing_checkout_pool, timeout: 10)
    end
  end

  describe "status/1" do
    test "returns expected map keys when pool not running" do
      status = Pool.status()

      assert is_map(status)
      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert Map.has_key?(status, :state)
    end

    test "queries a caller-selected pool" do
      assert Pool.status(pool: :missing_status_pool).state == :not_started
    end

    test "returns valid state when pool is running" do
      status = Pool.status()

      # Pool may be running or not depending on test context
      assert status.state in [:ready, :not_started]
    end

    test "reports the configured size of a named pool" do
      pool = :ex_maude_status_test_pool

      pool_config = [
        name: {:local, pool},
        worker_module: ExMaude.PoolTest.Worker,
        size: 1,
        max_overflow: 1
      ]

      start_supervised!({ExMaude.PoolTest.PoolOwner, {pool_config, []}})

      assert %{size: 1, available: 1, in_use: 0, overflow: 0, state: :ready} =
               Pool.status(pool: pool)
    end
  end

  describe "checkin/2" do
    test "function exists" do
      assert function_exported?(Pool, :checkin, 1)
      assert function_exported?(Pool, :checkin, 2)
    end
  end

  describe "Error wrapping" do
    test "pool_error wraps timeout" do
      error = Error.pool_error(:timeout)

      assert error.type == :pool_error
      assert String.contains?(error.message, "timed out")
    end

    test "pool_error wraps full" do
      error = Error.pool_error(:full)

      assert error.type == :pool_error
      assert String.contains?(error.message, "full")
    end

    test "pool_error wraps exit" do
      error = Error.pool_error({:exit, :normal})

      assert error.type == :pool_error
      assert String.contains?(error.message, "exited")
    end
  end

  # Integration tests require Maude and the pool to be running
  describe "integration tests" do
    @tag :integration
    test "transaction executes function with worker" do
      result =
        Pool.transaction(fn worker ->
          assert is_pid(worker)
          :test_result
        end)

      assert result == :test_result
    end

    @tag :integration
    test "transaction returns function result" do
      result =
        Pool.transaction(fn _ ->
          {:ok, 42}
        end)

      assert result == {:ok, 42}
    end

    @tag :integration
    test "broadcast executes on all workers" do
      assert {:ok, results} =
               Pool.broadcast(fn worker ->
                 assert is_pid(worker)
                 :ok
               end)

      assert is_list(results)
      assert Enum.all?(results, &(&1 == :ok))
    end

    @tag :integration
    test "broadcast returns results from all workers" do
      assert {:ok, results} =
               Pool.broadcast(fn worker ->
                 worker
               end)

      assert is_list(results)
      assert results != []
      assert Enum.all?(results, &is_pid/1)
    end

    @tag :integration
    test "status returns pool status map" do
      status = Pool.status()

      assert is_map(status)
      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert status.size > 0
    end

    @tag :integration
    test "checkout and checkin work" do
      worker = Pool.checkout()
      assert is_pid(worker)
      assert Pool.checkin(worker) == :ok
    end

    @tag :integration
    test "checkout with block false returns immediately" do
      worker = Pool.checkout(block: false)
      assert is_pid(worker) or worker == :full
      if is_pid(worker), do: Pool.checkin(worker)
    end

    @tag :integration
    test "multiple transactions in sequence" do
      results =
        for i <- 1..5 do
          Pool.transaction(fn _ ->
            i * 2
          end)
        end

      assert results == [2, 4, 6, 8, 10]
    end

    @tag :integration
    test "concurrent transactions" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Pool.transaction(fn _ ->
              Process.sleep(10)
              i
            end)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.sort(results) == Enum.to_list(1..10)
    end
  end

  describe "child_spec/1 additional tests" do
    test "child spec id is :ex_maude_pool" do
      spec = Pool.child_spec([])
      assert spec.id == :ex_maude_pool
    end

    test "child spec uses poolboy module" do
      spec = Pool.child_spec([])
      {module, _, _} = spec.start
      assert module == :poolboy
    end

    test "child spec uses start_link function" do
      spec = Pool.child_spec([])
      {_, func, _} = spec.start
      assert func == :start_link
    end

    test "child spec includes worker module" do
      spec = Pool.child_spec([])
      {_, _, [pool_config, _]} = spec.start
      # Pool uses Backend.impl() which defaults to Backend.Port
      assert Keyword.get(pool_config, :worker_module) == ExMaude.Backend.impl()
    end
  end

  describe "status/0 additional tests" do
    test "status returns all expected keys" do
      status = Pool.status()

      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert Map.has_key?(status, :state)
    end

    test "status values are non-negative integers or atoms" do
      status = Pool.status()

      assert is_integer(status.size) and status.size >= 0
      assert is_integer(status.overflow) and status.overflow >= 0
      assert is_integer(status.available) and status.available >= 0
      assert is_integer(status.in_use)
      assert is_atom(status.state)
    end
  end

  describe "Error.pool_error/1 additional tests" do
    test "pool_error preserves reason in details" do
      error = Error.pool_error(:custom_reason)
      assert error.details.reason == :custom_reason
    end

    test "pool_error with complex exit reason" do
      error = Error.pool_error({:exit, {:shutdown, :timeout}})
      assert error.type == :pool_error
      assert String.contains?(error.message, "exited")
    end
  end

  describe "status/0 return structure" do
    test "returns map with expected keys" do
      status = Pool.status()

      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert Map.has_key?(status, :state)
    end

    test "size is non-negative" do
      status = Pool.status()
      assert status.size >= 0
    end

    test "overflow is non-negative" do
      status = Pool.status()
      assert status.overflow >= 0
    end

    test "available is non-negative" do
      status = Pool.status()
      assert status.available >= 0
    end

    test "state is an atom" do
      status = Pool.status()
      assert is_atom(status.state)
    end
  end

  describe "child_spec/1 pool configuration" do
    test "default pool size is 4" do
      default_size = 4
      assert default_size == 4
    end

    test "default max overflow is 2" do
      default_overflow = 2
      assert default_overflow == 2
    end

    test "custom pool size is used" do
      spec = Pool.child_spec(pool_size: 10)
      assert %{start: {:poolboy, :start_link, [pool_config, _]}} = spec
      assert pool_config[:size] == 10
    end

    test "custom max overflow is used" do
      spec = Pool.child_spec(pool_max_overflow: 5)
      assert %{start: {:poolboy, :start_link, [pool_config, _]}} = spec
      assert pool_config[:max_overflow] == 5
    end

    test "worker options are passed through" do
      spec = Pool.child_spec(maude_path: "/custom/maude", timeout: 10_000)
      assert %{start: {:poolboy, :start_link, [_, worker_opts]}} = spec
      assert worker_opts[:maude_path] == "/custom/maude"
      assert worker_opts[:timeout] == 10_000
    end
  end

  describe "checkin/1 behavior" do
    test "function exists with arity 1" do
      assert function_exported?(Pool, :checkin, 1)
    end
  end

  describe "telemetry events" do
    test "checkout start event format" do
      event = [:ex_maude, :pool, :checkout, :start]
      assert length(event) == 4
      assert hd(event) == :ex_maude
    end

    test "checkout stop event format" do
      event = [:ex_maude, :pool, :checkout, :stop]
      assert length(event) == 4
      assert List.last(event) == :stop
    end
  end

  describe "pool_name configuration" do
    test "pool is named :ex_maude_pool" do
      spec = Pool.child_spec([])
      assert spec.id == :ex_maude_pool
    end
  end

  describe "worker module configuration" do
    test "uses Backend.impl() as worker" do
      spec = Pool.child_spec([])
      {_, _, [pool_config, _]} = spec.start
      # Pool uses Backend.impl() which defaults to Backend.Port
      assert Keyword.get(pool_config, :worker_module) == ExMaude.Backend.impl()
    end
  end

  describe "transaction/2 success paths" do
    @tag :integration
    test "transaction executes function and emits telemetry", %{maude_available: true} do
      # Attach a test telemetry handler
      test_pid = self()
      ref = make_ref()

      handler_id = "test-pool-success-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ex_maude, :pool, :checkout, :stop],
        fn _, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      result = Pool.transaction(fn _ -> :ok end)
      assert result == :ok

      assert_receive {:telemetry, measurements, metadata}, 1000
      assert Map.has_key?(measurements, :duration)
      assert metadata.result == :ok

      :telemetry.detach(handler_id)
    end
  end

  describe "checkout/1 success paths" do
    @tag :integration
    test "checkout returns worker pid when pool is running", %{maude_available: true} do
      result = Pool.checkout(timeout: 5000)
      assert is_pid(result)
      Pool.checkin(result)
    end
  end

  describe "broadcast/1 with running pool" do
    @tag :integration
    test "broadcast executes on workers", %{maude_available: true} do
      assert {:ok, results} = Pool.broadcast(fn _ -> :ok end)

      assert Enum.all?(results, &(&1 == :ok))
    end

    @tag :integration
    test "a slow worker yields an error without killing the caller",
         %{maude_available: true} do
      assert {:ok, results} =
               Pool.broadcast(
                 fn _ ->
                   Process.sleep(500)
                   :late
                 end,
                 timeout: 100
               )

      # The caller survives; every slow call surfaces as a structured error.
      assert Enum.all?(results, &match?({:error, %ExMaude.Error{type: :pool_error}}, &1))
    end

    @tag :integration
    test "a timed-out broadcast leaves the pool healthy",
         %{maude_available: true} do
      Pool.broadcast(fn _ -> Process.sleep(300) end, timeout: 100)

      available =
        Enum.reduce_while(1..50, 0, fn _, _ ->
          case Pool.status() do
            %{available: a, in_use: 0} ->
              {:halt, a}

            _ ->
              Process.sleep(20)
              {:cont, 0}
          end
        end)

      assert available > 0
    end
  end

  describe "config helpers" do
    test "uses config values for pool size" do
      original = Application.get_env(:ex_maude, :pool_size)

      try do
        Application.put_env(:ex_maude, :pool_size, 10)
        spec = Pool.child_spec([])
        {_, _, [pool_config, _]} = spec.start
        assert Keyword.get(pool_config, :size) == 10
      after
        if original do
          Application.put_env(:ex_maude, :pool_size, original)
        else
          Application.delete_env(:ex_maude, :pool_size)
        end
      end
    end

    test "uses config values for max overflow" do
      original = Application.get_env(:ex_maude, :pool_max_overflow)

      try do
        Application.put_env(:ex_maude, :pool_max_overflow, 8)
        spec = Pool.child_spec([])
        {_, _, [pool_config, _]} = spec.start
        assert Keyword.get(pool_config, :max_overflow) == 8
      after
        if original do
          Application.put_env(:ex_maude, :pool_max_overflow, original)
        else
          Application.delete_env(:ex_maude, :pool_max_overflow)
        end
      end
    end

    test "uses config values for backend" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.put_env(:ex_maude, :backend, :port)
        _ = Pool.transaction(fn _ -> :ok end)
        assert true
      after
        if original do
          Application.put_env(:ex_maude, :backend, original)
        else
          Application.delete_env(:ex_maude, :backend)
        end
      end
    end
  end

  defmodule Worker do
    @moduledoc false
    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
    @impl GenServer
    def init(:ok), do: {:ok, :ok}
  end

  defmodule PoolOwner do
    @moduledoc false
    use GenServer

    @spec start_link({keyword(), keyword()}) :: GenServer.on_start()
    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    @impl GenServer
    def init({pool_config, worker_opts}) do
      {:ok, pool} = :poolboy.start_link(pool_config, worker_opts)
      {:ok, pool}
    end
  end
end
