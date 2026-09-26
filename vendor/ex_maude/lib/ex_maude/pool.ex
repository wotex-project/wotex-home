defmodule ExMaude.Pool do
  @moduledoc """
  Poolboy-based pool of Maude server processes.

  This module manages a pool of backend workers (Port, C-Node, or NIF), providing:
  - Automatic worker checkout/checkin
  - Connection pooling for concurrent operations
  - Worker supervision and restart

  ## Configuration

      config :ex_maude,
        backend: :port,         # :port | :cnode | :nif
        pool_size: 4,           # Number of Maude processes
        pool_max_overflow: 2    # Extra workers under load

  ## Usage

  The pool is typically accessed via `ExMaude.Maude` rather than directly:

      # Checkout, execute, and checkin automatically
      ExMaude.Pool.transaction(fn worker ->
        ExMaude.Server.execute(worker, "reduce in NAT : 1 + 2 .")
      end)

  ## Architecture

  ```
  ExMaude.Pool (Poolboy)
      │
      ├── Worker 1 (Backend.impl()) ─── Maude Process 1
      ├── Worker 2 (Backend.impl()) ─── Maude Process 2
      ├── Worker 3 (Backend.impl()) ─── Maude Process 3
      └── Worker 4 (Backend.impl()) ─── Maude Process 4
  ```

  ## Telemetry

  This module emits the following telemetry events:

  - `[:ex_maude, :pool, :checkout, :start]` - Emitted when checkout begins
  - `[:ex_maude, :pool, :checkout, :stop]` - Emitted when checkout completes

  Measurements include `:duration` in native time units.
  Metadata includes `:pool` and `:backend` (`:unknown` until a worker is acquired).
  The stop event reports the selected worker backend and `:result` (`:ok` or `:error`),
  and is emitted before the transaction callback runs.

  See `ExMaude.Telemetry` for full event documentation and integration examples.
  """

  alias ExMaude.{Backend, Error}

  @pool_name :ex_maude_pool
  @default_pool_size 4
  @default_max_overflow 2
  @checkout_timeout_ms 5_000

  @doc """
  Returns the child spec for the pool supervisor.

  ## Options

    * `:name` - Local pool name (default: `:ex_maude_pool`)
    * `:worker_module` - Override the backend module (default: `Backend.impl()`)
    * `:pool_size` - Number of workers (default: from config)
    * `:pool_max_overflow` - Extra workers under load (default: from config)

  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    name = Keyword.get(opts, :name, @pool_name)
    unless is_atom(name), do: raise(ArgumentError, "pool :name must be an atom")

    worker_module = Keyword.get(opts, :worker_module, Backend.impl())

    pool_config = [
      name: {:local, name},
      worker_module: worker_module,
      size: Keyword.get(opts, :pool_size, config_pool_size()),
      max_overflow: Keyword.get(opts, :pool_max_overflow, config_max_overflow())
    ]

    worker_opts =
      opts
      |> Keyword.drop([:name, :pool_size, :pool_max_overflow, :worker_module])
      |> Keyword.put_new(:pool, name)

    {id, start, restart, shutdown, type, modules} =
      :poolboy.child_spec(name, pool_config, worker_opts)

    %{
      id: id,
      start: start,
      restart: restart,
      shutdown: shutdown,
      type: type,
      modules: modules
    }
  end

  @doc """
  Executes a function with a checked-out worker.

  The worker is automatically returned to the pool after the function completes.

  ## Examples

      ExMaude.Pool.transaction(fn worker ->
        ExMaude.Server.execute(worker, "reduce in NAT : 1 + 2 .")
      end)

  ## Options

    * `:checkout_timeout` - How long to wait for a free worker, in ms
      (default: 5000). This bounds only the checkout; the command executed
      inside `fun` carries its own `:timeout`.
    * `:timeout` - Deprecated alias for `:checkout_timeout`, kept for
      backwards compatibility.
    * `:pool` - Registered pool name (default: `:ex_maude_pool`).
  """
  @spec transaction((pid() -> result), keyword()) :: result | {:error, Error.t()}
        when result: any()
  def transaction(fun, opts \\ []) when is_function(fun, 1) do
    pool = Keyword.get(opts, :pool, @pool_name)

    timeout =
      Keyword.get(opts, :checkout_timeout) ||
        Keyword.get(opts, :timeout, @checkout_timeout_ms)

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ex_maude, :pool, :checkout, :start],
      %{system_time: System.system_time()},
      %{backend: :unknown, pool: pool}
    )

    case checkout(pool: pool, timeout: timeout) do
      worker when is_pid(worker) ->
        checkout_stopped(start_time, pool, :ok, worker_backend(worker))

        try do
          fun.(worker)
        catch
          :exit, reason -> {:error, Error.pool_error(reason)}
        after
          checkin(worker, pool: pool)
        end

      error ->
        checkout_stopped(start_time, pool, :error, :unknown)
        error
    end
  end

  @doc """
  Broadcasts a function to every worker currently owned by the pool.

  Useful for operations that need to affect all Maude sessions, such as
  loading a module. Checked-out workers are included; any worker that cannot
  perform the operation reports an error in its result slot.

  ## Examples

      ExMaude.Pool.broadcast(fn worker ->
        ExMaude.Server.load_file(worker, "/path/to/module.maude")
      end)

  ## Options

    * `:timeout` - Per-worker time budget in ms (default: 30000). Should be
      at least as large as the command timeout used inside `fun`, so the
      worker's own command deadline fires first.
    * `:pool` - Registered pool name (default: `:ex_maude_pool`).

  Returns `{:error, %ExMaude.Error{}}` if the pool is unavailable. A worker
  whose call exits or exceeds the budget yields `{:error, _}` in the result
  list; the caller is never taken down.
  """
  @spec broadcast((pid() -> result), keyword()) ::
          {:ok, [result | {:error, Error.t()}]} | {:error, Error.t()}
        when result: any()
  def broadcast(fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    pool = Keyword.get(opts, :pool, @pool_name)

    with {:ok, workers} <- pool_workers(pool),
         :ok <- ensure_workers_present(workers) do
      {:ok, supervisor} = Task.Supervisor.start_link()

      try do
        results =
          supervisor
          |> Task.Supervisor.async_stream_nolink(workers, fun,
            timeout: timeout,
            on_timeout: :kill_task,
            ordered: true
          )
          |> Enum.map(fn
            {:ok, value} -> value
            {:exit, reason} -> {:error, Error.pool_error({:broadcast_failed, reason})}
          end)

        {:ok, results}
      after
        Supervisor.stop(supervisor)
      end
    end
  end

  @doc """
  Returns the current pool status.

  ## Examples

      ExMaude.Pool.status()
      #=> %{size: 4, overflow: 0, available: 3, in_use: 1}
  """
  @spec status(keyword()) :: %{
          size: non_neg_integer(),
          overflow: non_neg_integer(),
          available: non_neg_integer(),
          in_use: non_neg_integer(),
          state: atom()
        }
  def status(opts \\ []) do
    pool = Keyword.get(opts, :pool, @pool_name)

    try do
      {state_name, workers, overflow, monitors} = :poolboy.status(pool)

      # workers is the count of available workers in the pool
      # monitors is the count of checked-out workers being monitored
      # Overflow workers are included in both `monitors` while checked out
      # and `overflow`; subtracting them yields the configured base size.
      pool_size = workers + monitors - overflow

      %{
        size: pool_size,
        overflow: overflow,
        available: workers,
        in_use: monitors,
        state: state_name
      }
    catch
      :exit, _ ->
        %{size: 0, overflow: 0, available: 0, in_use: 0, state: :not_started}
    end
  end

  @doc """
  Checks out a worker from the pool.

  Remember to check the worker back in with `checkin/2` using the same pool.
  Prefer `transaction/2` for automatic resource management.
  """
  @spec checkout(keyword()) :: pid() | :full | {:error, Error.t()}
  def checkout(opts \\ []) do
    pool = Keyword.get(opts, :pool, @pool_name)
    timeout = Keyword.get(opts, :timeout, @checkout_timeout_ms)
    block = Keyword.get(opts, :block, true)

    try do
      :poolboy.checkout(pool, block, timeout)
    catch
      :exit, {:timeout, _} -> {:error, Error.pool_error(:timeout)}
      :exit, {:full, _} -> {:error, Error.pool_error(:full)}
      :exit, reason -> {:error, Error.pool_error(reason)}
    end
  end

  @doc """
  Returns a worker to the pool.
  """
  @spec checkin(pid(), keyword()) :: :ok
  def checkin(worker, opts \\ []) do
    :poolboy.checkin(Keyword.get(opts, :pool, @pool_name), worker)
  end

  defp config_pool_size do
    Application.get_env(:ex_maude, :pool_size, @default_pool_size)
  end

  defp config_max_overflow do
    Application.get_env(:ex_maude, :pool_max_overflow, @default_max_overflow)
  end

  defp checkout_stopped(start_time, pool, result, backend) do
    :telemetry.execute(
      [:ex_maude, :pool, :checkout, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{result: result, backend: backend, pool: pool}
    )
  end

  defp worker_backend(worker) do
    with {:dictionary, dictionary} <- Process.info(worker, :dictionary),
         {module, :init, 1} <- Keyword.get(dictionary, :"$initial_call") do
      Map.get(
        %{
          ExMaude.Backend.Port => :port,
          ExMaude.Backend.CNode => :cnode,
          ExMaude.Backend.NIF => :nif
        },
        module,
        module
      )
    else
      _ -> :unknown
    end
  end

  # Poolboy does not expose worker enumeration as a public function, but its
  # server supports this query specifically for pool-wide operations. Using
  # the supervisor's actual children avoids guessing from application config
  # and includes both checked-out and overflow workers.
  defp pool_workers(pool) do
    workers =
      pool
      |> GenServer.call(:get_all_workers)
      |> Enum.flat_map(fn
        {_, pid, _, _} when is_pid(pid) -> [pid]
        _ -> []
      end)

    {:ok, workers}
  catch
    :exit, _ -> {:error, Error.pool_error(:not_started)}
  end

  defp ensure_workers_present([]), do: {:error, Error.pool_error(:no_workers)}
  defp ensure_workers_present(_), do: :ok
end
