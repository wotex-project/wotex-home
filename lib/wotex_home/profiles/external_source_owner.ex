defmodule WotexHome.Profiles.ExternalSourceOwner do
  @moduledoc """
  Holds checked host sources and nonrenewing original-scoped leases.

  `start_link/1` binds bounded memory custody to an explicitly selected live
  publisher. Only that publisher may `publish/2` a
  `WotexHome.Profiles.ExternalSourceSelection`; `catalogue/1` returns safe source
  assertions and the current owner incarnation.

  `hold/5` binds a snapshot to the exact principal and original operation.
  `checkout/4` binds its commit guard to the caller, while `validate/5` and
  `finish/4` check and consume that same checkout. Exact consumed replay succeeds
  without renewing the lease; cancellation and expiry prevent further use.
  Publisher loss retires the temporary owner, and a new owner has a fresh epoch
  with no restored transient leases.

  The owner receives principal IDs, never credentials or a Store connection. It
  publishes no observations, opens no transport and grants no current authority;
  `WotexHome.Durable.Store` derives the authenticated operation scope.
  """

  use GenServer
  alias WotexHome.Id
  alias WotexHome.Profiles.{EnvelopeCodec, ExternalSourceSelection}
  @maximum 9_223_372_036_854_775_807
  @active [:pending, :checked_out]

  @doc "Starts bounded memory custody under one explicitly configured live publisher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    if valid_options?(options) and Process.alive?(options[:publisher]),
      do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name])),
      else: {:error, :invalid_external_source_owner}
  end

  def start_link(_), do: {:error, :invalid_external_source_owner}

  @doc "Publisher loss requires an explicit new installation, rather than dead-PID restart."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :temporary}

  @doc "Publishes a checked current source from the configured publisher only."
  @spec publish(GenServer.server(), term()) :: {:ok, map()} | {:error, atom()}
  def publish(server, selection), do: GenServer.call(server, {:publish, selection}, 5000)
  @doc "Returns safe retained source assertions and this owner incarnation."
  @spec catalogue(GenServer.server()) :: {:ok, map()}
  def catalogue(server), do: GenServer.call(server, :catalogue, 5000)

  @doc "Borrows current native source data after Store derives the selection author; allocates no lease."
  def current(server, principal, source, epoch, sha),
    do: GenServer.call(server, {:current, principal, source, epoch, sha}, 5000)

  @doc "Holds one nonrenewing snapshot under an exact principal/original scope."
  @spec hold(GenServer.server(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, atom()} | :not_found
  def hold(server, principal, original, source, epoch),
    do: GenServer.call(server, {:hold, principal, original, source, epoch}, 5000)

  @doc "Reads only the principal's original lease summary."
  @spec status(GenServer.server(), term(), term(), term()) ::
          {:ok, map()} | {:error, atom()} | :not_found
  def status(server, principal, epoch, operation),
    do: GenServer.call(server, {:status, principal, epoch, operation}, 5000)

  @doc "Borrows a pending native snapshot and binds its local guard to the caller."
  @spec checkout(GenServer.server(), term(), term(), term()) ::
          {:ok, map()} | {:error, atom()} | :not_found
  def checkout(server, principal, token, original),
    do: GenServer.call(server, {:checkout, principal, token, original}, 5000)

  @doc "Checks an internal commit guard for the exact checked-out caller."
  @spec validate(GenServer.server(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, atom()} | :not_found
  def validate(server, principal, token, original, caller),
    do: GenServer.call(server, {:validate, principal, token, original, caller}, 5000)

  @doc "Consumes one caller-owned checkout; exact consumed replay succeeds unchanged."
  @spec finish(GenServer.server(), term(), term(), term()) :: :ok | {:error, atom()} | :not_found
  def finish(server, principal, token, original),
    do: GenServer.call(server, {:finish, principal, token, original}, 5000)

  @doc "Cancels an uncommitted original without renewing it."
  @spec cancel(GenServer.server(), term(), term(), term()) :: :ok | {:error, atom()} | :not_found
  def cancel(server, principal, epoch, operation),
    do: GenServer.call(server, {:cancel, principal, epoch, operation}, 5000)

  @impl true
  def init(options) do
    publisher = options[:publisher]
    source_limit = Keyword.get(options, :source_limit, 32)
    lease_limit = Keyword.get(options, :lease_limit, 8)
    ttl = Keyword.get(options, :ttl_ms, 60000)
    bytes = Keyword.get(options, :max_bytes, 4_194_304)

    if valid_options?(options) do
      Process.send_after(self(), :expire, min(ttl, 1000))

      {:ok,
       %{
         publisher: publisher,
         publisher_monitor: Process.monitor(publisher),
         owner_epoch: nonce(),
         source_limit: source_limit,
         lease_limit: lease_limit,
         ttl: ttl,
         max_bytes: bytes,
         sources: %{},
         entries: %{},
         tokens: %{}
       }}
    else
      {:stop, :invalid_external_source_owner}
    end
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_external_source_owner) |> Map.put(:message, :redacted)

  @impl true
  def handle_call({:publish, _}, {caller, _}, %{publisher: publisher} = state)
      when caller != publisher,
      do: {:reply, {:error, :external_source_publisher_denied}, expire(state)}

  def handle_call({:publish, value}, _, state) do
    state = expire(state)

    with {:ok, _} <- ExternalSourceSelection.to_map(value),
         {:ok, bytes} <- source_bytes(value),
         ref = value.data["source_ref"],
         :ok <- generation(state.sources[ref], value),
         total =
           Enum.sum(Enum.map(state.sources, fn {_, s} -> s.bytes end)) -
             if(state.sources[ref], do: state.sources[ref].bytes, else: 0) + bytes,
         true <-
           map_size(state.sources) + if(Map.has_key?(state.sources, ref), do: 0, else: 1) <=
             state.source_limit and total <= state.max_bytes do
      entry = %{value: value, bytes: bytes}

      next =
        if state.sources[ref] && state.sources[ref].value == value do
          state
        else
          state = retire_source(state, ref)
          put_in(state.sources[ref], entry)
        end

      {:reply, {:ok, source_summary(value)}, next}
    else
      false -> {:reply, {:error, :external_source_capacity}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:catalogue, _, state) do
    state = expire(state)

    sources =
      state.sources
      |> Enum.sort_by(fn {ref, _} -> ref end)
      |> Enum.map(fn {_, s} -> source_summary(s.value) end)

    {:reply, {:ok, %{"owner_epoch" => state.owner_epoch, "sources" => sources}}, state}
  end

  def handle_call({:current, principal, source, epoch, sha}, _, state) do
    state = expire(state)

    with :ok <- current_ref(principal, source, epoch, sha),
         :ok <- same_epoch(state.owner_epoch, epoch),
         entry when is_map(entry) <- state.sources[source],
         true <- entry.value.sha256 == sha,
         do:
           {:reply,
            {:ok,
             %{
               selection: entry.value,
               guard: %{owner_epoch: epoch, source_ref: source, source_selection_sha256: sha}
             }}, state},
         else: (
           nil -> {:reply, :not_found, state}
           false -> {:reply, {:error, :stale_external_source}, state}
           error -> {:reply, error, state}
         )
  end

  def handle_call({:hold, principal, original, source, epoch}, _, state) do
    state = expire(state)

    with :ok <- original(principal, original),
         true <- Id.valid?(source),
         :ok <- same_epoch(epoch, state.owner_epoch) do
      scope = scope(principal, original)

      case state.entries[scope] do
        nil ->
          hold_new(state, scope, original, source)

        %{summary: s} ->
          if s["input_sha256"] == original["input_sha256"] and s["source_ref"] == source,
            do: {:reply, {:ok, s}, state},
            else: {:reply, {:error, :external_source_conflict}, state}
      end
    else
      false -> {:reply, invalid(), state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:status, principal, epoch, operation}, _, state) do
    state = expire(state)

    if scope_fields?(principal, epoch, operation) do
      case state.entries[{principal, epoch, operation}] do
        nil -> {:reply, :not_found, state}
        entry -> {:reply, {:ok, entry.summary}, state}
      end
    else
      {:reply, invalid(), state}
    end
  end

  def handle_call({:checkout, principal, token, original}, {caller, _}, state) do
    state = expire(state)

    with {:ok, key, entry} <- entry(state, principal, token, original),
         :ok <- live_source(state, entry) do
      case entry.state do
        :pending ->
          checked = %{
            entry
            | state: :checked_out,
              summary: Map.put(entry.summary, "state", "checked_out"),
              caller: caller,
              monitor: Process.monitor(caller)
          }

          {:reply, {:ok, borrowed(checked)}, put_in(state.entries[key], checked)}

        :checked_out when entry.caller == caller ->
          {:reply, {:ok, borrowed(entry)}, state}

        :checked_out ->
          {:reply, {:error, :external_source_busy}, state}

        _ ->
          {:reply, retired(), state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:validate, principal, token, original, caller}, _, state) do
    state = expire(state)

    with {:ok, _, entry} <- entry(state, principal, token, original),
         :ok <- live_source(state, entry),
         true <-
           entry.state == :checked_out and is_pid(caller) and entry.caller == caller and
             Process.alive?(caller) do
      {:reply, {:ok, guard(entry)}, state}
    else
      false -> {:reply, {:error, :external_source_busy}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:finish, principal, token, original}, {caller, _}, state) do
    state = expire(state)

    with {:ok, key, entry} <- entry(state, principal, token, original) do
      cond do
        entry.state == :consumed ->
          {:reply, :ok, state}

        entry.state == :checked_out and entry.caller == caller ->
          {:reply, :ok, retire(state, key, :consumed)}

        entry.state == :checked_out ->
          {:reply, {:error, :external_source_busy}, state}

        true ->
          {:reply, retired(), state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cancel, principal, epoch, operation}, _, state) do
    state = expire(state)

    if scope_fields?(principal, epoch, operation) do
      key = {principal, epoch, operation}

      case state.entries[key] do
        nil -> {:reply, :not_found, state}
        %{state: :pending} -> {:reply, :ok, retire(state, key, :cancelled)}
        %{state: :cancelled} -> {:reply, :ok, state}
        %{state: :checked_out} -> {:reply, {:error, :external_source_busy}, state}
        _ -> {:reply, retired(), state}
      end
    else
      {:reply, invalid(), state}
    end
  end

  @impl true
  def handle_info(:expire, state) do
    Process.send_after(self(), :expire, min(state.ttl, 1000))
    {:noreply, expire(state)}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{publisher_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    next =
      Enum.reduce(state.entries, state, fn {key, e}, acc ->
        if e.monitor == monitor, do: retire(acc, key, :cancelled), else: acc
      end)

    {:noreply, next}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp hold_new(state, key, original, source) do
    active = Enum.count(state.entries, fn {_, e} -> e.state in @active end)

    cond do
      state.sources[source] == nil ->
        {:reply, :not_found, state}

      active >= state.lease_limit or map_size(state.entries) >= 1024 ->
        {:reply, {:error, :external_source_capacity}, state}

      true ->
        value = state.sources[source].value
        token = unique_token(state.tokens)
        {principal, epoch, operation} = key

        summary = %{
          "owner_epoch" => state.owner_epoch,
          "principal_id" => principal,
          "authority_epoch" => epoch,
          "operation_id" => operation,
          "input_sha256" => original["input_sha256"],
          "source_ref" => source,
          "source_selection_sha256" => value.sha256,
          "token" => token,
          "state" => "pending"
        }

        e = %{
          summary: summary,
          state: :pending,
          selection: value,
          deadline: now() + state.ttl,
          caller: nil,
          monitor: nil
        }

        next = %{
          state
          | entries: Map.put(state.entries, key, e),
            tokens: Map.put(state.tokens, token, key)
        }

        {:reply, {:ok, summary}, next}
    end
  end

  defp entry(state, principal, token, original) do
    with :ok <- original(principal, original),
         true <- token?(token) do
      key = state.tokens[token]

      case state.entries[key] do
        %{summary: %{"principal_id" => ^principal} = summary} = e ->
          if key == scope(principal, original) and
               summary["input_sha256"] == original["input_sha256"],
             do: {:ok, key, e},
             else: {:error, :external_source_conflict}

        _ ->
          :not_found
      end
    else
      false -> invalid()
      error -> error
    end
  end

  defp live_source(state, e) do
    cond do
      e.state not in @active ->
        retired()

      state.sources[e.summary["source_ref"]] == nil ->
        {:error, :stale_external_source}

      state.sources[e.summary["source_ref"]].value.sha256 != e.summary["source_selection_sha256"] ->
        {:error, :stale_external_source}

      true ->
        :ok
    end
  end

  defp expire(state),
    do:
      Enum.reduce(state.entries, state, fn {key, e}, acc ->
        if e.state in @active and now() >= e.deadline, do: retire(acc, key, :expired), else: acc
      end)

  defp retire_source(state, source),
    do:
      Enum.reduce(state.entries, state, fn {key, e}, acc ->
        if e.state in @active and e.summary["source_ref"] == source,
          do: retire(acc, key, :invalidated),
          else: acc
      end)

  defp retire(state, key, status) do
    e = state.entries[key]
    if e.monitor, do: Process.demonitor(e.monitor, [:flush])

    put_in(state.entries[key], %{
      e
      | state: status,
        summary: Map.put(e.summary, "state", Atom.to_string(status)),
        selection: nil,
        deadline: nil,
        caller: nil,
        monitor: nil
    })
  end

  defp borrowed(e), do: %{selection: e.selection, guard: guard(e)}

  defp guard(e) do
    s = e.summary

    %{
      owner_epoch: s["owner_epoch"],
      token: s["token"],
      principal_id: s["principal_id"],
      authority_epoch: s["authority_epoch"],
      operation_id: s["operation_id"],
      input_sha256: s["input_sha256"],
      source_ref: s["source_ref"],
      source_selection_sha256: s["source_selection_sha256"],
      checkout_pid: e.caller,
      expires_at: e.deadline
    }
  end

  defp source_summary(v),
    do: %{
      "source_ref" => v.data["source_ref"],
      "source_selection_sha256" => v.sha256,
      "data" => v.data
    }

  defp generation(nil, _), do: :ok
  defp generation(%{value: same}, same), do: :ok

  defp generation(%{value: previous}, next),
    do:
      if(next.data["source_generation"] == previous.data["source_generation"] + 1,
        do: :ok,
        else: {:error, :stale_external_source_generation}
      )

  defp original(p, r),
    do:
      if(
        EnvelopeCodec.keys?(r, ~w(authority_epoch input_sha256 operation_id)) and
          scope_fields?(p, r["authority_epoch"], r["operation_id"]) and
          EnvelopeCodec.digest?(r["input_sha256"]),
        do: :ok,
        else: invalid()
      )

  defp scope_fields?(p, e, op), do: Id.valid?(p) and integer?(e, 1, @maximum) and Id.valid?(op)
  defp scope(p, r), do: {p, r["authority_epoch"], r["operation_id"]}
  defp same_epoch(same, same), do: :ok
  defp same_epoch(_, _), do: {:error, :external_source_owner_changed}
  defp integer?(n, min, max), do: is_integer(n) and n in min..max

  defp valid_options?(options) do
    Keyword.keyword?(options) and
      Enum.all?(
        Keyword.keys(options),
        &(&1 in [:name, :publisher, :source_limit, :lease_limit, :ttl_ms, :max_bytes])
      ) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      is_pid(options[:publisher]) and valid_name?(options[:name]) and
      integer?(Keyword.get(options, :source_limit, 32), 1, 32) and
      integer?(Keyword.get(options, :lease_limit, 8), 1, 32) and
      integer?(Keyword.get(options, :ttl_ms, 60000), 100, 60000) and
      integer?(Keyword.get(options, :max_bytes, 4_194_304), 1, 4_194_304)
  end

  defp token?(t),
    do: is_binary(t) and byte_size(t) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, t)

  defp valid_name?(name) when is_nil(name) or is_atom(name), do: true
  defp valid_name?({:global, _}), do: true
  defp valid_name?({:via, module, _}) when is_atom(module), do: true
  defp valid_name?(_), do: false

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp unique_token(tokens) do
    value = nonce()
    if Map.has_key?(tokens, value), do: unique_token(tokens), else: value
  end

  defp current_ref(principal, source, epoch, sha) do
    if Id.valid?(principal) and Id.valid?(source) and token?(epoch) and EnvelopeCodec.digest?(sha),
      do: :ok,
      else: invalid()
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp invalid, do: {:error, :invalid_external_source_lease}
  defp retired, do: {:error, :external_source_retired}

  defp source_bytes(v) do
    i = v.inputs
    limits = i["reader"].inputs["reader_limits"]

    case apply(Wotex.JSON, :encode, [
           %{
             "source" => i["source"],
             "reader" => i["reader"].inputs,
             "channels" => i["channels"]
           },
           [
             max_bytes: limits["max_bytes"],
             max_depth: limits["max_depth"] + 1,
             max_nodes: limits["max_nodes"],
             max_collection_size: 256,
             max_string_bytes: 4096
           ]
         ]) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      _ -> {:error, :external_profile_limit}
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == Wotex.JSON and error.function == :encode and error.arity == 2,
        do: {:error, :profiles_producer_unavailable},
        else: {:error, :invalid_external_source}
  end
end
