defmodule WotexHome.ControllerConnections.PairingReview do
  @moduledoc """
  One bounded, transient local pairing window, without Store or TLS ownership.

  Trusted setup supplies public installed identity and a current Authority scope.
  Opening generates a new invitation/secret; state retains only its verifier.
  Local approval binds the full original request digest and exact access. One
  checked-out approval is guarded until finish/expiry/owner loss, then discarded.
  Checkout is not durable invitation consumption or credential provisioning.
  """
  use GenServer
  alias WotexHome.ControllerConnections.{Codec, ReviewCodec, TLSIdentity}
  @template ~w(controller_id identity leaf_pin trust_anchor endpoint)
  @request ~w(controller_id invitation_id client_id request_id client_label)
  @binding ~w(store_boot deployment_id owner_id authority_epoch)
  @maximum_ms 300_000
  @maximum_pending 8
  @maximum_attempts 32

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Trusted local opening; returned invitation requires private transfer custody."
  def open(server, public_identity, scope, duration_ms \\ @maximum_ms),
    do: GenServer.call(server, {:open, public_identity, scope, duration_ms})

  @doc "Trusted preconfirmation of a private client request, before network exchange."
  def prepare(server, admin, request), do: GenServer.call(server, {:prepare, admin, request})
  @doc "Authenticated bootstrap handler's bounded offer, after TLS; never grants access."
  def offer(server, request), do: GenServer.call(server, {:offer, request})
  def pending(server, admin), do: GenServer.call(server, {:pending, admin})

  def approve(server, admin, reference, current_scope, access \\ Codec.default_access()),
    do: GenServer.call(server, {:approve, admin, reference, current_scope, access})

  def deny(server, admin, reference), do: GenServer.call(server, {:deny, admin, reference})
  def close(server, admin), do: GenServer.call(server, {:close, admin})
  def checkout(server, request), do: GenServer.call(server, {:checkout, request})

  def guard(server, reference, approval),
    do: GenServer.call(server, {:guard, reference, approval})

  def finish(server, reference), do: GenServer.call(server, {:finish, reference})

  @doc "Private Authority composition check; the owner is an opaque lifecycle PID."
  def bound_owner(server, owner), do: GenServer.call(server, {:bound_owner, owner})

  @doc "The bound Store's final commit basis, tied to the original checkout caller."
  def commit_basis(server, reference, approval, caller),
    do: GenServer.call(server, {:commit_basis, reference, approval, caller})

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :store_owner)

    if is_pid(owner) and Process.alive?(owner) do
      {:ok,
       %{
         store_owner: owner,
         owner_monitor: Process.monitor(owner),
         owner_lost: false,
         window: nil,
         reason: :pairing_closed
       }}
    else
      {:stop, :invalid_pairing_review_owner}
    end
  end

  @impl true
  def handle_call(message, from, state) do
    dispatch(message, from, expire(state))
  end

  defp dispatch({:bound_owner, owner}, _from, state) do
    if owner == state.store_owner and not state.owner_lost,
      do: {:reply, :ok, state},
      else: refusal(state, :pairing_unavailable)
  end

  defp dispatch(
         {:open, template, scope, duration},
         {caller, _},
         %{window: nil, owner_lost: false} = state
       ) do
    with true <-
           is_map(template) and not is_struct(template) and
             Enum.sort(Map.keys(template)) == Enum.sort(@template),
         true <- ReviewCodec.scope?(scope) and is_integer(duration) and duration in 1..@maximum_ms,
         secret = :crypto.strong_rand_bytes(32),
         invitation =
           Map.merge(template, %{
             "invitation_id" => random_id(),
             "bootstrap_secret" => Base.url_encode64(secret, padding: false)
           }),
         {:ok, _} <- Codec.encode("invitation", invitation),
         {:ok, _} <- TLSIdentity.new(invitation) do
      admin = make_ref()
      id = make_ref()
      now = mono()

      window = %{
        id: id,
        admin: admin,
        admin_owner: caller,
        admin_monitor: Process.monitor(caller),
        scope: scope,
        controller: invitation["controller_id"],
        invitation: invitation["invitation_id"],
        verifier: :crypto.hash(:sha256, secret),
        opened: now,
        expires: now + duration,
        wall: System.os_time(:millisecond),
        duration: duration,
        offers: %{},
        rejected: MapSet.new(),
        attempts: 0,
        failures: 0,
        backoff: now,
        selected: nil,
        checkout: nil,
        timer: Process.send_after(self(), {:expire, id}, min(duration, 1_000))
      }

      {:reply, {:ok, admin, invitation}, %{state | window: window}}
    else
      _ -> {:reply, {:error, :pairing_unavailable}, state}
    end
  end

  defp dispatch({:open, _, _, _}, _from, %{owner_lost: true} = state),
    do: {:reply, {:error, :pairing_unavailable}, state}

  defp dispatch({:open, _, _, _}, _from, state),
    do: {:reply, {:error, :pairing_busy}, state}

  defp dispatch({:prepare, admin, request}, _from, state) do
    if admin?(state, admin),
      do: hold(state, request, nil),
      else: refusal(state, :pairing_unavailable)
  end

  defp dispatch({:offer, request}, {caller, _}, state), do: hold(state, request, caller)

  defp dispatch({:pending, admin}, _from, state) do
    if admin?(state, admin) do
      rows =
        Enum.map(state.window.offers, fn {ref, entry} ->
          %{
            reference: ref,
            original: entry.original,
            phase: phase(state.window, ref),
            approval: entry.approval
          }
        end)
        |> Enum.sort_by(& &1.original["request_digest"])

      {:reply, {:ok, rows}, state}
    else
      refusal(state, :pairing_unavailable)
    end
  end

  defp dispatch({:approve, admin, ref, scope, access}, _from, state) do
    with true <- admin?(state, admin),
         %{checkout: nil} = window <- state.window,
         %{approval: nil} = entry <- window.offers[ref],
         true <- window.selected == nil,
         true <- ReviewCodec.scope?(scope) and Codec.access?(access),
         true <- Map.take(scope, @binding) == Map.take(window.scope, @binding),
         true <- scope["expected_revision"] >= window.scope["expected_revision"],
         approval = entry.original |> Map.merge(scope) |> Map.merge(access),
         {:ok, _} <- ReviewCodec.encode("approval", approval) do
      notify(entry, ref, :approved)
      offers = Map.put(window.offers, ref, %{entry | approval: approval})
      {:reply, {:ok, approval}, %{state | window: %{window | selected: ref, offers: offers}}}
    else
      _ -> refusal(state, :confirmation_denied)
    end
  end

  defp dispatch({:deny, admin, ref}, _from, state) do
    with true <- admin?(state, admin),
         %{checkout: nil} = window <- state.window,
         entry when is_map(entry) <- window.offers[ref] do
      notify(entry, ref, :confirmation_denied)
      demonitor(entry)
      selected = if window.selected == ref, do: nil, else: window.selected

      window = %{
        window
        | offers: Map.delete(window.offers, ref),
          selected: selected,
          rejected: MapSet.put(window.rejected, entry.original["request_digest"])
      }

      {:reply, :ok, %{state | window: window}}
    else
      _ -> refusal(state, :confirmation_denied)
    end
  end

  defp dispatch({:close, admin}, _from, state) do
    if admin?(state, admin),
      do: {:reply, :ok, discard(state, :pairing_closed)},
      else: refusal(state, :pairing_unavailable)
  end

  defp dispatch({:checkout, request}, {caller, _}, state) do
    with {:ok, original} <- authenticate(state, request),
         %{checkout: nil, selected: selected} = window <- state.window,
         %{original: ^original, approval: approval} = entry when is_map(approval) <-
           window.offers[selected],
         true <- entry.owner in [nil, caller],
         {:ok, digest} <- ReviewCodec.digest(approval) do
      entry = attach(entry, caller)
      reference = make_ref()

      window = %{
        window
        | offers: Map.put(window.offers, selected, entry),
          checkout: %{reference: reference, digest: digest, caller: caller}
      }

      {:reply, {:ok, reference, approval}, %{state | window: window}}
    else
      {:error, reason} -> failed_auth(state, reason)
      _ -> refusal(state, :confirmation_denied)
    end
  end

  defp dispatch({:guard, reference, approval}, _from, state) do
    with %{checkout: %{reference: ^reference, digest: digest}} <- state.window,
         {:ok, ^digest} <- ReviewCodec.digest(approval),
         do: {:reply, :ok, state},
         else: (_ -> refusal(state, unavailable(state)))
  end

  defp dispatch({:commit_basis, reference, approval, caller}, {store, _}, state) do
    with true <- store == state.store_owner,
         %{
           checkout: %{reference: ^reference, digest: digest, caller: ^caller},
           verifier: verifier
         } <- state.window,
         {:ok, ^digest} <- ReviewCodec.digest(approval),
         do: {:reply, {:ok, verifier}, state},
         else: (_ -> refusal(state, unavailable(state)))
  end

  defp dispatch({:finish, reference}, {caller, _}, state) do
    case state.window do
      %{checkout: %{reference: ^reference, caller: ^caller}} ->
        {:reply, :ok, discard(state, :pairing_closed)}

      _ ->
        refusal(state, unavailable(state))
    end
  end

  @impl true
  def handle_info({:expire, id}, state) do
    state = expire(state)

    case state.window do
      %{id: ^id} = window ->
        timer =
          Process.send_after(self(), {:expire, id}, min(max(1, window.expires - mono()), 1_000))

        {:noreply, %{state | window: %{window | timer: timer}}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state),
    do: {:noreply, %{discard(state, :pairing_unavailable) | owner_lost: true}}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state = expire(state)

    case state.window do
      %{admin_monitor: ^monitor} ->
        {:noreply, discard(state, :pairing_closed)}

      %{offers: offers} = window ->
        case Enum.find(offers, fn {_, entry} -> entry.monitor == monitor end) do
          {ref, _} when window.selected == ref -> {:noreply, discard(state, :outcome_unknown)}
          {ref, _} -> {:noreply, %{state | window: %{window | offers: Map.delete(offers, ref)}}}
          _ -> {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_, state), do: discard(state, :pairing_closed)

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_controller_pairing_review)
      |> Map.put(:message, :redacted)

  defp hold(state, request, caller) do
    with {:ok, original} <- authenticate(state, request),
         %{checkout: nil} = window <- state.window do
      case Enum.find(window.offers, fn {_, entry} -> entry.original == original end) do
        {ref, %{owner: owner} = entry} when owner in [nil, caller] ->
          window = %{window | offers: Map.put(window.offers, ref, attach(entry, caller))}
          {:reply, {:ok, ref}, %{state | window: window}}

        {_, _} ->
          refusal(state, :pairing_busy)

        nil ->
          hold_new(state, original, caller)
      end
    else
      {:error, reason} -> failed_auth(state, reason)
      _ -> refusal(state, :pairing_busy)
    end
  end

  defp hold_new(state, original, caller) do
    window = state.window

    cond do
      MapSet.member?(window.rejected, original["request_digest"]) ->
        refusal(state, :confirmation_denied)

      map_size(window.offers) >= @maximum_pending or window.attempts >= @maximum_attempts ->
        refusal(state, :pairing_busy)

      Enum.any?(window.offers, fn {_, entry} ->
        entry.original["client_id"] == original["client_id"]
      end) ->
        refusal(state, :pairing_busy)

      true ->
        ref = make_ref()
        entry = attach(%{original: original, approval: nil, owner: nil, monitor: nil}, caller)

        {:reply, {:ok, ref},
         %{
           state
           | window: %{
               window
               | attempts: window.attempts + 1,
                 offers: Map.put(window.offers, ref, entry)
             }
         }}
    end
  end

  defp authenticate(%{window: nil} = state, _), do: {:error, unavailable(state)}

  defp authenticate(%{window: window}, request) do
    if mono() < window.backoff do
      {:error, :pairing_busy}
    else
      with {:ok, body} <- Codec.encode("request", request),
           true <-
             request["controller_id"] == window.controller and
               request["invitation_id"] == window.invitation,
           {:ok, secret} <- Base.url_decode64(request["bootstrap_secret"], padding: false),
           true <- :crypto.hash_equals(:crypto.hash(:sha256, secret), window.verifier) do
        {:ok,
         Map.take(request, @request)
         |> Map.put("request_digest", Base.encode16(:crypto.hash(:sha256, body), case: :lower))}
      else
        _ -> {:error, :invitation_unavailable}
      end
    end
  end

  defp failed_auth(%{window: window} = state, :invitation_unavailable) when not is_nil(window) do
    failures = window.failures + 1

    if failures >= @maximum_attempts do
      refusal(discard(state, :pairing_unavailable), :invitation_unavailable)
    else
      delay = min(8_000, 250 * Integer.pow(2, min(failures - 1, 5)))

      refusal(
        %{state | window: %{window | failures: failures, backoff: mono() + delay}},
        :invitation_unavailable
      )
    end
  end

  defp failed_auth(state, reason), do: refusal(state, reason)
  defp refusal(state, reason), do: {:reply, {:error, reason}, state}
  defp unavailable(%{window: nil, reason: :outcome_unknown}), do: :pairing_closed
  defp unavailable(%{window: nil, reason: reason}), do: reason
  defp unavailable(_), do: :pairing_unavailable
  defp admin?(%{window: %{admin: admin}}, value), do: is_reference(value) and value == admin
  defp admin?(_, _), do: false

  defp phase(%{checkout: checkout, selected: ref}, ref) when not is_nil(checkout),
    do: :checked_out

  defp phase(%{selected: ref}, ref), do: :approved
  defp phase(_, _), do: :pending
  defp attach(entry, nil), do: entry

  defp attach(%{owner: nil} = entry, caller),
    do: %{entry | owner: caller, monitor: Process.monitor(caller)}

  defp attach(entry, _), do: entry
  defp demonitor(%{monitor: nil}), do: :ok
  defp demonitor(%{monitor: ref}), do: Process.demonitor(ref, [:flush])
  defp notify(%{owner: nil}, _, _), do: :ok

  defp notify(entry, ref, status),
    do: send(entry.owner, {:controller_pairing_review, ref, status})

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  defp mono, do: System.monotonic_time(:millisecond)

  defp expire(state) do
    if state.owner_lost or not Process.alive?(state.store_owner),
      do: %{discard(state, :pairing_unavailable) | owner_lost: true},
      else: expire_window(state)
  end

  defp expire_window(%{window: nil} = state), do: state

  defp expire_window(%{window: window} = state) do
    now = mono()
    wall = System.os_time(:millisecond)

    cond do
      not Process.alive?(window.admin_owner) ->
        discard(state, :pairing_closed)

      selected_owner_lost?(window) ->
        discard(state, :outcome_unknown)

      now < window.opened or now >= window.expires or wall < window.wall or
        wall - window.wall >= window.duration or
          abs(wall - window.wall - (now - window.opened)) > 250 ->
        discard(state, :pairing_expired)

      true ->
        state
    end
  end

  defp selected_owner_lost?(%{selected: nil}), do: false

  defp selected_owner_lost?(window) do
    case window.offers[window.selected] do
      %{owner: nil} -> false
      %{owner: owner} -> not Process.alive?(owner)
    end
  end

  defp discard(%{window: nil} = state, reason), do: %{state | reason: reason}

  defp discard(%{window: window} = state, reason) do
    Process.cancel_timer(window.timer)
    Process.demonitor(window.admin_monitor, [:flush])

    for {ref, entry} <- window.offers do
      demonitor(entry)
      notify(entry, ref, reason)
    end

    %{state | window: nil, reason: reason}
  end
end
