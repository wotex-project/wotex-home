defmodule ExMaude.Preloads do
  @moduledoc false

  @state_key :preload_state_by_pool
  @default_pool :ex_maude_pool

  @doc false
  @spec for_pool(atom(), [Path.t()] | nil) :: [Path.t()]
  def for_pool(pool \\ @default_pool, configured \\ nil) do
    configured = configured || Application.get_env(:ex_maude, :preload_modules, [])
    runtime = runtime_for_pool(pool)
    reloaded = MapSet.new(runtime, &Path.expand/1)

    Enum.uniq(Enum.reject(configured, &MapSet.member?(reloaded, Path.expand(&1))) ++ runtime)
  end

  @doc false
  @spec runtime_for_pool(atom()) :: [Path.t()]
  def runtime_for_pool(pool \\ @default_pool), do: Enum.reverse(current(pool).paths)

  @doc false
  @spec loaded_for_pool(atom()) :: [Path.t()]
  def loaded_for_pool(pool \\ @default_pool) do
    state = current(pool)

    case workers(pool) do
      [] ->
        []

      workers ->
        workers
        |> Enum.map(&MapSet.new(Map.values(Map.get(state.loaded, &1, %{}))))
        |> Enum.reduce(&MapSet.intersection/2)
        |> MapSet.to_list()
    end
  end

  @doc false
  @spec remember(atom(), Path.t()) :: :ok
  def remember(pool, path) do
    update(pool, fn state ->
      %{state | paths: [path | List.delete(state.paths, path)]}
    end)
  end

  @doc false
  @spec mark_loaded(atom(), [Path.t()], pid()) :: :ok
  def mark_loaded(pool, paths, worker \\ self()) do
    identities = Map.new(Enum.flat_map(paths, &identity_entry/1))

    update(pool, fn state ->
      loaded =
        state.loaded
        |> Map.filter(fn {pid, _} -> Process.alive?(pid) end)
        |> Map.update(worker, identities, &Map.merge(&1, identities))

      %{state | loaded: loaded}
    end)
  end

  @doc false
  @spec forget_loaded(atom(), Path.t(), pid()) :: :ok
  def forget_loaded(pool, path, worker) do
    update(pool, fn state ->
      loaded = Map.update(state.loaded, worker, %{}, &Map.delete(&1, Path.expand(path)))
      %{state | loaded: loaded}
    end)
  end

  @doc false
  @spec identity(Path.t()) :: {:ok, Path.t()} | :error
  # sobelow_skip ["Traversal.FileModule"]
  def identity(path) do
    case File.read(path) do
      {:ok, source} ->
        digest = Base.encode16(:crypto.hash(:sha256, source), case: :lower)
        {:ok, Path.expand(path) <> ":" <> digest}

      {:error, _} ->
        :error
    end
  end

  @doc false
  @spec cache_source(atom(), String.t()) :: {:ok, Path.t()} | {:error, ExMaude.Error.t()}
  # Files live in a private random directory and are created exclusively.
  # sobelow_skip ["Traversal.FileModule"]
  def cache_source(pool, source) when is_binary(source) do
    locked(fn -> cache_for_live_pool(Process.whereis(pool), pool, source) end)
  end

  defp cache_for_live_pool(nil, _, _), do: {:error, ExMaude.Error.pool_error(:not_started)}

  defp cache_for_live_pool(owner, pool, source) do
    with {:ok, directory} <- ensure_cache_dir(pool, owner),
         path =
           Path.join(
             directory,
             Base.encode16(:crypto.hash(:sha256, source)) <> ".maude"
           ),
         :ok <- write_source(path, source) do
      {:ok, path}
    else
      {:error, reason} ->
        {:error, ExMaude.Error.new(:load_error, "Could not cache module: #{inspect(reason)}")}
    end
  end

  defp ensure_cache_dir(pool, owner) do
    case current(pool).cache_dir do
      nil -> create_cache_dir(pool, owner)
      directory -> {:ok, directory}
    end
  end

  # The path is generated internally under a private random directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_cache_dir(pool, owner) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    dir = Path.join(System.tmp_dir!(), "ex_maude-" <> suffix)

    with :ok <- File.mkdir(dir), :ok <- File.chmod(dir, 0o700) do
      # Capture the directory independently of the pool-name map: a new pool
      # can replace that entry before the old pool's DOWN is processed.
      spawn(fn -> remove_cache_on_exit(owner, dir) end)
      update_live_pool(owner, pool, &%{&1 | cache_dir: dir})
      {:ok, dir}
    end
  end

  # Only directories created above reach this private cleanup function.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_cache_on_exit(owner, directory) do
    ref = Process.monitor(owner)
    receive do: ({:DOWN, ^ref, :process, ^owner, _} -> File.rm_rf(directory))
  end

  # The filename is a SHA-256 digest within the pool's private cache directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_source(path, source) do
    case File.write(path, source, [:binary, :exclusive]) do
      {:error, :eexist} -> :ok
      result -> result
    end
  end

  defp current(pool) do
    state_for_owner(pool, Process.whereis(pool))
  end

  defp state_for_owner(pool, owner) do
    case Map.get(Application.get_env(:ex_maude, @state_key, %{}), pool) do
      %{owner: ^owner} = state when is_pid(owner) -> state
      _ -> %{owner: owner, paths: [], loaded: %{}, cache_dir: nil}
    end
  end

  defp update(pool, fun) do
    locked(fn -> update_live_pool(Process.whereis(pool), pool, fun) end)
    :ok
  end

  defp update_live_pool(nil, _, _), do: :ok

  defp update_live_pool(owner, pool, fun) do
    all = Application.get_env(:ex_maude, @state_key, %{})

    unless match?(%{owner: ^owner}, Map.get(all, pool)) do
      spawn(fn -> cleanup_on_exit(pool, owner) end)
    end

    Application.put_env(
      :ex_maude,
      @state_key,
      Map.put(all, pool, fun.(state_for_owner(pool, owner)))
    )
  end

  defp cleanup_on_exit(pool, owner) do
    ref = Process.monitor(owner)

    receive do
      {:DOWN, ^ref, :process, ^owner, _} ->
        locked(fn ->
          all = Application.get_env(:ex_maude, @state_key, %{})

          if match?(%{owner: ^owner}, Map.get(all, pool)) do
            Application.put_env(:ex_maude, @state_key, Map.delete(all, pool))
          end
        end)
    end
  end

  defp locked(fun), do: :global.trans({{__MODULE__, node()}, self()}, fun, [node()])

  defp workers(pool) do
    pool
    |> GenServer.call(:get_all_workers)
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  catch
    :exit, _ -> []
  end

  defp identity_entry(path) do
    case identity(path) do
      {:ok, identity} -> [{Path.expand(path), identity}]
      :error -> []
    end
  end
end
