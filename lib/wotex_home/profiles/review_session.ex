defmodule WotexHome.Profiles.ReviewSession do
  @moduledoc """
  Bounded transient custody for operator-bound one-use selection proposals.

  This owner receives an authenticated principal ID, not a credential or Store
  connection. It holds exact artifact leases while a proposal is pending and
  through one checked-out commit. Expired pending proposals and dead commit
  callers release leases. Restart discards proposals without restoring authority.
  The Store must authenticate again, repeat CAS/byte/runtime guards and enforce
  the returned local monotonic deadline before any selection transaction.
  """

  use GenServer
  alias WotexHome.Id
  alias WotexHome.Profiles.{Custody, Operation, Review}
  @max_bytes 4_194_304

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def hold(server, principal, review), do: GenServer.call(server, {:hold, principal, review})
  def status(server, principal, token), do: GenServer.call(server, {:status, principal, token})

  def pending(server, principal, document),
    do: GenServer.call(server, {:pending, principal, document})

  def checkout(server, principal, token, document),
    do: GenServer.call(server, {:checkout, principal, token, document})

  def finish(server, token), do: GenServer.call(server, {:finish, token})
  def cancel(server, principal, token), do: GenServer.call(server, {:cancel, principal, token})

  @impl true
  def init(options) do
    custody = options[:custody]
    limit = Keyword.get(options, :limit, 8)
    ttl = Keyword.get(options, :ttl_ms, 60_000)
    bytes = Keyword.get(options, :max_bytes, @max_bytes)

    if (is_pid(custody) or (is_atom(custody) and not is_nil(custody))) and
         is_integer(limit) and limit in 1..32 and is_integer(ttl) and ttl in 100..60_000 and
         is_integer(bytes) and bytes in 1..@max_bytes do
      timer = Process.send_after(self(), :expire, min(ttl, 1_000))

      {:ok,
       %{
         custody: custody,
         limit: limit,
         ttl: ttl,
         max_bytes: bytes,
         entries: %{},
         retired: %{},
         timer: timer
       }}
    else
      {:stop, :invalid_profile_review_owner}
    end
  end

  @impl true
  def handle_call({:hold, principal, review}, _from, state) do
    state = expire(state)

    with true <-
           Id.valid?(principal) and Review.valid?(review) and
             principal == review.basis["principal_id"],
         :ok <- fresh_capture(review.capture_deadline),
         {:ok, input} <- Operation.decode(review.input_document) do
      scope = {principal, input["authority_epoch"], input["operation_id"]}

      case find_scope(state, scope) do
        {token, %{review: ^review, state: :pending} = entry} ->
          {:reply, {:ok, summary(token, entry)}, state}

        {_, _} ->
          {:reply, {:error, :profile_review_conflict}, state}

        :consumed ->
          {:reply, {:error, :profile_review_consumed}, state}

        nil ->
          hold_new(state, principal, scope, review)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :invalid_profile_review}, state}
    end
  end

  def handle_call({:pending, principal, document}, _from, state) do
    state = expire(state)

    result =
      with true <- Id.valid?(principal),
           {:ok, input} <- Operation.decode(document),
           "select" <- input["action"] do
        scope = {principal, input["authority_epoch"], input["operation_id"]}

        case find_scope(state, scope) do
          {token, %{state: :pending, review: %{input_document: ^document}} = entry} ->
            {:ok, summary(token, entry)}

          {_, %{state: :pending}} ->
            {:error, :profile_review_conflict}

          nil ->
            :not_found

          _ ->
            {:error, :profile_review_consumed}
        end
      else
        _ -> {:error, :invalid_profile_review}
      end

    {:reply, result, state}
  end

  def handle_call({:status, principal, token}, _from, state) do
    state = expire(state)

    result =
      case state.entries[token] do
        %{principal: ^principal} = entry -> {:ok, summary(token, entry)}
        _ -> :not_found
      end

    {:reply, result, state}
  end

  def handle_call({:checkout, principal, token, document}, {caller, _}, state) do
    state = expire(state)

    case state.entries[token] do
      %{principal: ^principal, state: :pending, review: review} = entry ->
        if document == review.input_document do
          monitor = Process.monitor(caller)
          checked = %{entry | state: :checked_out, caller: caller, monitor: monitor}

          {:reply, {:ok, %{review: review, deadline: entry.deadline}},
           put_in(state.entries[token], checked)}
        else
          {:reply, {:error, :profile_review_conflict}, state}
        end

      %{principal: ^principal} ->
        {:reply, {:error, :profile_review_consumed}, state}

      _ ->
        {:reply, {:error, :profile_review_missing}, state}
    end
  end

  def handle_call({:finish, token}, {caller, _}, state) do
    case state.entries[token] do
      %{state: :checked_out, caller: ^caller} ->
        {:reply, :ok, drop(state, token)}

      _ ->
        {:reply, {:error, :invalid_profile_review_owner}, state}
    end
  end

  def handle_call({:cancel, principal, token}, _from, state) do
    state = expire(state)

    case state.entries[token] do
      %{principal: ^principal, state: :pending} -> {:reply, :ok, drop(state, token)}
      %{principal: ^principal} -> {:reply, {:error, :profile_review_busy}, state}
      _ -> {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_info(:expire, state) do
    state = expire(state)
    timer = Process.send_after(self(), :expire, min(state.ttl, 1_000))
    {:noreply, %{state | timer: timer}}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    tokens = for {token, %{monitor: ^monitor}} <- state.entries, do: token
    {:noreply, Enum.reduce(tokens, state, &drop(&2, &1))}
  end

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    Enum.each(state.entries, fn {_, entry} -> release(state.custody, entry.lease) end)
  end

  defp hold_new(state, principal, scope, review) do
    size = :erlang.external_size(review)
    used = Enum.reduce(state.entries, 0, fn {_, entry}, acc -> acc + entry.size end)
    {:ok, input} = Operation.decode(review.input_document)
    capture = {principal, input["session_ref"]}

    reused =
      Enum.any?(state.entries, fn {_, entry} -> entry.capture == capture end) or
        Enum.any?(state.retired, fn {_, {old, _}} -> old == capture end)

    cond do
      reused ->
        {:reply, {:error, :profile_review_consumed}, state}

      map_size(state.entries) < state.limit and
        map_size(state.entries) + map_size(state.retired) < 128 and
          used + size <= state.max_bytes ->
        case lease(state.custody, review.artifact.digest) do
          {:ok, %{artifact: artifact, token: lease}} when artifact == review.artifact ->
            token =
              "profile-review:" <>
                Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

            entry = %{
              principal: principal,
              scope: scope,
              capture: capture,
              review: review,
              lease: lease,
              deadline: min(review.capture_deadline, now() + state.ttl),
              size: size,
              state: :pending,
              caller: nil,
              monitor: nil
            }

            {:reply, {:ok, summary(token, entry)}, put_in(state.entries[token], entry)}

          {:ok, leased} ->
            release(state.custody, leased.token)
            {:reply, {:error, :profile_review_mismatch}, state}

          error ->
            {:reply, error, state}
        end

      true ->
        {:reply, {:error, :profile_review_capacity}, state}
    end
  end

  defp expire(state) do
    now = now()

    tokens =
      for {token, %{state: :pending, deadline: deadline}} <- state.entries,
          deadline <= now,
          do: token

    state = Enum.reduce(tokens, state, &drop(&2, &1))
    %{state | retired: Map.reject(state.retired, fn {_, {_, deadline}} -> deadline <= now end)}
  end

  defp drop(state, token) do
    {entry, entries} = Map.pop(state.entries, token)
    if entry.monitor, do: Process.demonitor(entry.monitor, [:flush])
    release(state.custody, entry.lease)

    %{
      state
      | entries: entries,
        retired:
          Map.put(state.retired, entry.scope, {entry.capture, entry.review.capture_deadline})
    }
  end

  defp find_scope(state, scope) do
    if Map.has_key?(state.retired, scope),
      do: :consumed,
      else: Enum.find(state.entries, fn {_, entry} -> entry.scope == scope end)
  end

  defp summary(token, entry) do
    %{
      review_token: token,
      review_digest: entry.review.digest,
      state: entry.state,
      remaining_ms: max(0, entry.deadline - now()),
      summary: entry.review.summary,
      basis:
        Map.drop(
          entry.review.basis,
          ~w(stable_id manufacturer model firmware current_thing_document)
        )
    }
  end

  defp lease(custody, digest) do
    Custody.lease(custody, digest)
  catch
    :exit, _ -> {:error, :profile_custody_unavailable}
  end

  defp release(custody, token) do
    Custody.release(custody, token)
  catch
    :exit, _ -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp fresh_capture(deadline) do
    now = now()

    if deadline > now and deadline <= now + 60_000,
      do: :ok,
      else: {:error, :profile_review_expired}
  end
end
