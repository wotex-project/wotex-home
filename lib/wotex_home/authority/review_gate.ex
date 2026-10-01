defmodule WotexHome.Authority.ReviewGate do
  @moduledoc false

  use GenServer

  @default_limit 2

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec run(GenServer.server(), (-> result)) :: result | {:error, :review_capacity}
        when result: term()
  def run(server, fun) when is_function(fun, 0) do
    case GenServer.call(server, :acquire) do
      :ok ->
        try do
          fun.()
        after
          :ok = GenServer.call(server, :release)
        end

      {:error, :review_capacity} = error ->
        error
    end
  end

  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    if is_integer(limit) and limit in 1..32 do
      {:ok, %{limit: limit, holders: %{}}}
    else
      {:stop, :invalid_review_limit}
    end
  end

  @impl true
  def handle_call(:acquire, {pid, _tag}, state) do
    cond do
      Map.has_key?(state.holders, pid) ->
        {:reply, {:error, :review_capacity}, state}

      map_size(state.holders) >= state.limit ->
        {:reply, {:error, :review_capacity}, state}

      true ->
        ref = Process.monitor(pid)
        {:reply, :ok, put_in(state.holders[pid], ref)}
    end
  end

  def handle_call(:release, {pid, _tag}, state) do
    {ref, holders} = Map.pop(state.holders, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | holders: holders}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    holders =
      case Map.fetch(state.holders, pid) do
        {:ok, ^ref} -> Map.delete(state.holders, pid)
        _ -> state.holders
      end

    {:noreply, %{state | holders: holders}}
  end
end
