defmodule WotexHome.Lifx.CaptureSession do
  @moduledoc """
  Host-owned, in-memory LIFX discovery and identity capture.

  An installed host names one live interface; this process selects its IPv4
  scope and owns a bound WoTEx UDP socket for its lifetime. A trusted test host
  can instead supply an explicit transport and scope.
  Callers can select only references produced by that process; they cannot
  supply candidate, interview or packet bodies. The process owns a single
  bounded session, which disappears on restart or after one checkout. It
  has no Store reference, cannot expose the transcript on the local socket and
  cannot authorize control.

  `discover/4` records candidates from one selected interface and
  `interview/5` reads identity for one captured reference. `checkout/2`
  consumes an unbound lab capture once for a trusted enrollment review.
  The authenticated socket uses `discover_auto/2` and `interview_auto/4`,
  which generate correlation keys and bind the session to one operator ID.
  `checkout_auto/3` requires that operator ID when consuming such a session.
  `refresh_auto/3` accepts an enrolled stable ID and immutable Thing
  declaration, resolves a fresh candidate before unicast and returns only
  protocol-validated reports. The owner receives no credential or persistence
  capability. Refresh never consumes or replaces enrollment evidence. Start a
  fresh session when the network view changes.

  Trusted `power_route_auto/4` privately returns fresh enrolled routing and
  capture-owned clock/boot coordinates to Authority. Held work includes a
  fresh report; queued work preserves its sealed report. The owner reserves
  a distinct readback source sequence and returns no transport handle. It
  sends no command and grants no effect authority.
  """

  use GenServer

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Id

  alias WotexHome.Lifx.{
    CaptureTransport,
    DiscoveryPath,
    InterfaceSelection,
    IPv4Scope,
    InterviewPath,
    Ledger,
    Packet,
    ReadPath,
    WotexUdp
  }

  @max_age_ms 60_000
  @max_capture_bytes 300_000
  @max_i64 9_223_372_036_854_775_807

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.sort(Keyword.keys(opts)) in [[:interface_name], [:interface_name, :name]] do
      interface_name = Keyword.fetch!(opts, :interface_name)

      if is_binary(interface_name) and byte_size(interface_name) in 1..64 and
           (not Keyword.has_key?(opts, :name) or is_atom(Keyword.fetch!(opts, :name))) do
        GenServer.start_link(__MODULE__, {:selected, interface_name}, Keyword.take(opts, [:name]))
      else
        {:error, :invalid_capture_owner}
      end
    else
      start_supplied(opts)
    end
  end

  def start_link(_), do: {:error, :invalid_capture_owner}

  defp start_supplied(opts) do
    with true <- Keyword.keyword?(opts),
         true <-
           Enum.sort(Keyword.keys(opts)) in [
             [:interface_id, :scope, :transport],
             [:interface_id, :scope, :session_ttl_ms, :transport]
           ],
         interface_id when is_binary(interface_id) <- Keyword.fetch!(opts, :interface_id),
         true <- Id.valid?(interface_id),
         %IPv4Scope{} = scope <- Keyword.fetch!(opts, :scope),
         {:ok, ^scope} <- IPv4Scope.new(scope.local, scope.prefix),
         {module, _handle} = transport when is_atom(module) <- Keyword.fetch!(opts, :transport),
         true <-
           Code.ensure_loaded?(module) and function_exported?(module, :send, 3) and
             function_exported?(module, :recv, 2),
         ttl when is_integer(ttl) and ttl in 100..@max_age_ms <-
           Keyword.get(opts, :session_ttl_ms, @max_age_ms) do
      GenServer.start_link(__MODULE__, {interface_id, scope, transport, ttl})
    else
      _ -> {:error, :invalid_capture_owner}
    end
  end

  @doc "Returns the selected scope while the interface remains unchanged."
  @spec scope(GenServer.server()) :: {:ok, IPv4Scope.t()} | {:error, atom()}
  def scope(server), do: GenServer.call(server, :scope)

  @spec discover(GenServer.server(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, String.t(), [Candidate.t()]} | {:error, atom()}
  def discover(server, source, sequence, duration_ms),
    do: GenServer.call(server, {:discover, source, sequence, duration_ms}, 12_000)

  @doc "Starts one bounded discovery with an owner-generated LIFX correlation key."
  @spec discover_auto(GenServer.server(), String.t()) ::
          {:ok, String.t(), [Candidate.t()]} | {:error, atom()}
  def discover_auto(server, operator_id) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    GenServer.call(server, {:discover_auto, operator_id, deadline}, 4_000)
  end

  @spec interview(GenServer.server(), String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, WotexHome.Discovery.Interview.t()} | {:error, atom()}
  def interview(server, session_ref, candidate_ref, source, timeout_ms),
    do:
      GenServer.call(server, {:interview, session_ref, candidate_ref, source, timeout_ms}, 7_000)

  @doc "Interviews exactly one captured reference with an owner-generated key."
  @spec interview_auto(GenServer.server(), String.t(), String.t(), String.t()) ::
          {:ok, WotexHome.Discovery.Interview.t()} | {:error, atom()}
  def interview_auto(server, operator_id, session_ref, candidate_ref) do
    deadline = System.monotonic_time(:millisecond) + 3_000

    GenServer.call(
      server,
      {:interview_auto, operator_id, session_ref, candidate_ref, deadline},
      4_000
    )
  end

  @doc "Consumes a completed unbound lab capture for a trusted in-process reviewer."
  @spec checkout(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def checkout(server, session_ref), do: GenServer.call(server, {:checkout, session_ref})

  @doc "Consumes a completed socket capture only for its bound operator ID."
  @spec checkout_auto(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def checkout_auto(server, operator_id, session_ref),
    do: GenServer.call(server, {:checkout_auto, operator_id, session_ref})

  @doc "Discover and refresh exactly one enrolled stable ID through the owner-held transport."
  @spec refresh_auto(
          GenServer.server(),
          String.t(),
          WotexHome.Semantics.Thing.t()
        ) ::
          {:ok, [WotexHome.Semantics.Observation.t()]} | {:error, atom()}
  def refresh_auto(server, stable_id, %WotexHome.Semantics.Thing{} = thing) do
    deadline = System.monotonic_time(:millisecond) + 4_500

    GenServer.call(
      server,
      {:refresh_auto, stable_id, thing, deadline},
      6_000
    )
  end

  def refresh_auto(_server, _stable_id, _thing),
    do: {:error, :invalid_lifx_refresh}

  @doc "Trusted private power routing: fresh read for held work, discovery only for a sealed queue. Reserves a distinct readback sequence."
  def power_route_auto(server, stable_id, %WotexHome.Semantics.Thing{} = thing, phase)
      when phase in [:held, :queued] do
    deadline = System.monotonic_time(:millisecond) + 4_500
    GenServer.call(server, {:power_route_auto, stable_id, thing, phase, deadline}, 6_000)
  end

  def power_route_auto(_, _, _, _), do: {:error, :invalid_power_route}

  @impl true
  def init({:selected, interface_name}) do
    with {:ok, scope} <- InterfaceSelection.select(interface_name),
         {:ok, adapter} <- WotexUdp.open(scope) do
      {:ok,
       initial_state(interface_name, scope, {WotexUdp, adapter}, @max_age_ms, interface_name)}
    end
  end

  def init({interface_id, scope, transport, ttl}) do
    {:ok, initial_state(interface_id, scope, transport, ttl, nil)}
  end

  defp initial_state(interface_id, scope, transport, ttl, selected_interface) do
    true = Code.ensure_loaded?(CaptureTransport)
    epoch = "boot:" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    %{
      interface_id: interface_id,
      selected_interface: selected_interface,
      scope: scope,
      transport: transport,
      session_ttl_ms: ttl,
      epoch: epoch,
      clock_origin: System.monotonic_time(:millisecond),
      read_sequence: 0,
      session: nil
    }
  end

  @impl true
  def handle_call(request, from, %{selected_interface: interface, scope: scope} = state)
      when is_binary(interface) do
    case InterfaceSelection.select(interface) do
      {:ok, ^scope} -> handle_current_call(request, from, state)
      _ -> {:reply, {:error, :selected_interface_changed}, %{state | session: nil}}
    end
  end

  def handle_call(request, from, state), do: handle_current_call(request, from, state)

  defp handle_current_call(:scope, _from, state), do: {:reply, {:ok, state.scope}, state}

  defp handle_current_call(
         {:refresh_auto, stable_id, %WotexHome.Semantics.Thing{} = thing, deadline},
         _from,
         state
       ) do
    state = expire_session(state)

    cond do
      not valid_lifx_stable_id?(stable_id) ->
        {:reply, {:error, :invalid_lifx_refresh}, state}

      is_map(state.session) ->
        {:reply, {:error, :capture_busy}, state}

      state.read_sequence >= @max_i64 ->
        {:reply, {:error, :source_sequence_exhausted}, state}

      System.monotonic_time(:millisecond) + 4_000 > deadline ->
        {:reply, {:error, :capture_deadline_expired}, state}

      true ->
        sequence = state.read_sequence
        next = %{state | read_sequence: sequence + 1}
        {:reply, refresh(state, stable_id, thing, sequence), next}
    end
  end

  defp handle_current_call({:refresh_auto, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_lifx_refresh}, state}

  defp handle_current_call(
         {:power_route_auto, stable_id, %WotexHome.Semantics.Thing{} = thing, phase, deadline},
         _from,
         state
       )
       when phase in [:held, :queued] do
    state = expire_session(state)
    count = if phase == :held, do: 2, else: 1
    required_ms = if phase == :held, do: 4_000, else: 2_000

    cond do
      not valid_lifx_stable_id?(stable_id) ->
        {:reply, {:error, :invalid_power_route}, state}

      is_map(state.session) ->
        {:reply, {:error, :capture_busy}, state}

      state.read_sequence > @max_i64 - count ->
        {:reply, {:error, :source_sequence_exhausted}, state}

      System.monotonic_time(:millisecond) + required_ms > deadline ->
        {:reply, {:error, :capture_deadline_expired}, state}

      true ->
        next = %{state | read_sequence: state.read_sequence + count}
        {:reply, power_route(state, stable_id, thing, state.read_sequence, phase), next}
    end
  end

  defp handle_current_call({:power_route_auto, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_power_route}, state}

  defp handle_current_call({:discover_auto, operator_id, deadline}, from, state) do
    cond do
      not Id.valid?(operator_id) ->
        {:reply, {:error, :invalid_capture_operator}, state}

      active_other_operator?(state.session, operator_id) ->
        {:reply, {:error, :capture_busy}, state}

      System.monotonic_time(:millisecond) + 2_000 > deadline ->
        {:reply, {:error, :capture_deadline_expired}, state}

      true ->
        case handle_current_call(
               {:discover, random_source(), random_sequence(), 2_000},
               from,
               state
             ) do
          {:reply, {:ok, ref, candidates}, next} ->
            {:reply, {:ok, ref, candidates},
             %{next | session: Map.put(next.session, :operator_id, operator_id)}}

          other ->
            other
        end
    end
  end

  defp handle_current_call(
         {:interview_auto, operator_id, ref, candidate_ref, deadline},
         from,
         state
       ) do
    cond do
      not Id.valid?(operator_id) or not is_map(state.session) or
          Map.get(state.session, :operator_id) != operator_id ->
        {:reply, {:error, :capture_missing}, state}

      System.monotonic_time(:millisecond) + 2_000 > deadline ->
        {:reply, {:error, :capture_deadline_expired}, state}

      true ->
        handle_current_call({:interview, ref, candidate_ref, random_source(), 2_000}, from, state)
    end
  end

  defp handle_current_call({:discover, source, sequence, duration_ms}, _from, state) do
    token = make_ref()
    {module, handle} = state.transport
    transport = {CaptureTransport, {module, handle, token}}

    result =
      DiscoveryPath.run(state.interface_id, state.epoch, state.scope, source, sequence,
        transport: transport,
        clock: fn -> clock(state.clock_origin) end,
        duration_ms: duration_ms
      )

    transcript = drain(token, [])

    case result do
      {:ok, candidates, _window} when candidates != [] ->
        with :ok <- transcript_budget(transcript) do
          ref = random_ref()
          now = System.monotonic_time(:millisecond)

          session = %{
            ref: ref,
            epoch: state.epoch,
            interface_id: state.interface_id,
            candidates: candidates,
            interview: nil,
            selected_candidate_ref: nil,
            transcript: transcript,
            expires_at: now + state.session_ttl_ms
          }

          Process.send_after(self(), {:expire_capture, ref}, state.session_ttl_ms)
          {:reply, {:ok, ref, candidates}, %{state | session: session}}
        else
          {:error, reason} -> {:reply, {:error, reason}, %{state | session: nil}}
        end

      {:ok, [], _window} ->
        {:reply, {:error, :no_candidates}, %{state | session: nil}}

      {:error, reason, _window} ->
        {:reply, {:error, reason}, %{state | session: nil}}
    end
  end

  defp handle_current_call({:interview, ref, candidate_ref, source, timeout_ms}, _from, state) do
    with {:ok, session} <- current(state.session, ref),
         true <- session.interview == nil,
         {:ok, candidate} <- selected_candidate(session.candidates, candidate_ref),
         {:ok, target} <- target(candidate),
         {:ok, ledger} <- Ledger.new(source),
         true <- is_integer(timeout_ms) and timeout_ms in 1..5_000 do
      token = make_ref()
      {module, handle} = state.transport

      result =
        InterviewPath.run(candidate, target, ledger,
          transport: {CaptureTransport, {module, handle, token}},
          clock: fn -> clock(state.clock_origin) end,
          timeout_ms: timeout_ms
        )

      transcript = session.transcript ++ drain(token, [])

      case {result, transcript_budget(transcript)} do
        {{:ok, interview, _ledger}, :ok} ->
          updated = %{
            session
            | interview: interview,
              selected_candidate_ref: candidate_ref,
              transcript: transcript
          }

          {:reply, {:ok, interview}, %{state | session: updated}}

        {{:error, reason, _ledger}, _} ->
          {:reply, {:error, reason}, %{state | session: nil}}

        {_, {:error, reason}} ->
          {:reply, {:error, reason}, %{state | session: nil}}
      end
    else
      false -> {:reply, {:error, :interview_unavailable}, state}
      {:error, :capture_expired} -> {:reply, {:error, :capture_expired}, %{state | session: nil}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_current_call({:checkout, ref}, _from, state) do
    checkout(state, ref, nil)
  end

  defp handle_current_call({:checkout_auto, operator_id, ref}, _from, state) do
    if Id.valid?(operator_id),
      do: checkout(state, ref, operator_id),
      else: {:reply, {:error, :invalid_capture_operator}, state}
  end

  defp checkout(state, ref, operator_id) do
    with {:ok, session} <- current(state.session, ref),
         :ok <- checkout_operator(session, operator_id),
         true <- session.interview != nil do
      evidence =
        Map.take(session, [
          :ref,
          :epoch,
          :interface_id,
          :candidates,
          :selected_candidate_ref,
          :interview,
          :expires_at,
          :transcript
        ])

      {:reply, {:ok, evidence}, %{state | session: nil}}
    else
      false -> {:reply, {:error, :interview_incomplete}, state}
      {:error, :capture_expired} -> {:reply, {:error, :capture_expired}, %{state | session: nil}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp checkout_operator(session, operator_id) do
    if Map.get(session, :operator_id) == operator_id,
      do: :ok,
      else: {:error, :capture_missing}
  end

  defp refresh(state, stable_id, thing, sequence) do
    case power_route(state, stable_id, thing, sequence, :held) do
      {:ok, route} -> {:ok, route.reports}
      error -> error
    end
  end

  defp power_route(state, stable_id, thing, sequence, phase) do
    discovery_token = make_ref()
    {module, handle} = state.transport

    discovery =
      DiscoveryPath.run(
        state.interface_id,
        state.epoch,
        state.scope,
        random_source(),
        random_sequence(),
        transport: {CaptureTransport, {module, handle, discovery_token}},
        clock: fn -> clock(state.clock_origin) end,
        duration_ms: 2_000
      )

    _transcript = drain(discovery_token, [])

    with {:ok, candidates, _window} <- discovery,
         {:ok, candidate} <- enrolled_candidate(candidates, stable_id),
         {:ok, target} <- target(candidate),
         {:ok, ledger} <- Ledger.new(random_source()) do
      read_token = make_ref()

      result =
        if phase == :held do
          ReadPath.collect(candidate, target, thing, ledger,
            transport: {CaptureTransport, {module, handle, read_token}},
            clock: fn -> clock(state.clock_origin) end,
            source_epoch: state.epoch,
            source_sequence: sequence,
            boot_epoch: state.epoch,
            timeout_ms: 2_000
          )
        else
          {:ok, [], ledger}
        end

      _transcript = drain(read_token, [])

      case result do
        {:ok, reports, ledger} ->
          origin = state.clock_origin

          {:ok,
           %{
             reports: reports,
             candidate: candidate,
             target: target,
             ledger: ledger,
             clock: fn -> clock(origin) end,
             boot_epoch: state.epoch,
             source_epoch: state.epoch,
             source_sequence: if(phase == :held, do: sequence + 1, else: sequence)
           }}

        {:error, reason, _ledger} ->
          {:error, reason}
      end
    else
      {:ok, [], _window} -> {:error, :device_unavailable}
      {:error, reason, _window} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enrolled_candidate(candidates, stable_id) do
    case Enum.filter(candidates, fn
           %Candidate{claimed_identifiers: %{"stable_id" => ^stable_id}} -> true
           _ -> false
         end) do
      [candidate] -> {:ok, candidate}
      [] -> {:error, :device_unavailable}
      _ -> {:error, :ambiguous_device}
    end
  end

  @impl true
  def handle_info({:expire_capture, ref}, %{session: %{ref: ref}} = state),
    do: {:noreply, %{state | session: nil}}

  def handle_info({:expire_capture, _ref}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{transport: {WotexUdp, adapter}}) do
    _ = WotexUdp.close(adapter)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp current(nil, _ref), do: {:error, :capture_missing}

  defp current(%{ref: expected, expires_at: deadline} = session, ref) do
    cond do
      not is_binary(ref) or ref != expected -> {:error, :capture_missing}
      System.monotonic_time(:millisecond) > deadline -> {:error, :capture_expired}
      true -> {:ok, session}
    end
  end

  defp selected_candidate(candidates, ref) do
    case Enum.filter(candidates, &(&1.raw_ref == ref)) do
      [candidate] -> {:ok, candidate}
      _ -> {:error, :ambiguous_or_missing_candidate}
    end
  end

  defp target(%Candidate{claimed_identifiers: %{"stable_id" => "lifx:" <> serial}}),
    do: Packet.target_from_hex(serial)

  defp target(_), do: {:error, :invalid_target}

  defp random_ref,
    do: "capture:" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp random_source do
    <<value::unsigned-big-32>> = :crypto.strong_rand_bytes(4)
    max(2, value)
  end

  defp random_sequence do
    <<value::8>> = :crypto.strong_rand_bytes(1)
    value
  end

  defp active_other_operator?(%{operator_id: owner, expires_at: deadline}, operator_id),
    do: owner != operator_id and System.monotonic_time(:millisecond) <= deadline

  defp active_other_operator?(_session, _operator_id), do: false

  defp expire_session(%{session: %{expires_at: deadline}} = state) do
    if System.monotonic_time(:millisecond) > deadline,
      do: %{state | session: nil},
      else: state
  end

  defp expire_session(state), do: state

  defp valid_lifx_stable_id?("lifx:" <> serial) when byte_size(serial) == 12,
    do: Regex.match?(~r/\A[0-9a-f]{12}\z/, serial)

  defp valid_lifx_stable_id?(_stable_id), do: false

  defp clock(origin),
    do: {System.monotonic_time(:millisecond) - origin, System.system_time(:millisecond)}

  defp drain(token, acc) do
    receive do
      {:lifx_capture_datagram, ^token, direction, endpoint, bytes} ->
        drain(token, [{direction, endpoint, bytes} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp transcript_budget(transcript) do
    bytes =
      Enum.reduce(transcript, 0, fn {_direction, endpoint, packet}, total ->
        total + byte_size(endpoint) + byte_size(packet)
      end)

    if length(transcript) <= 275 and bytes <= @max_capture_bytes,
      do: :ok,
      else: {:error, :capture_budget_exceeded}
  end
end
