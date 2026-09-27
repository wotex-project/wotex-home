defmodule WotexHome.Lifx.CaptureSession do
  @moduledoc """
  Host-owned, in-memory LIFX discovery and identity capture.

  A trusted host supplies one already selected interface transport at startup.
  Callers can select only references produced by that process; they cannot
  supply candidate, interview or packet bodies. The process owns a single
  bounded session, which disappears on restart or after one checkout. It has
  no Store or socket route and does not authorize enrollment or control.

  `discover/4` records candidates from one selected interface and
  `interview/5` reads identity for one captured reference. `checkout/2`
  consumes the resulting capture once for a trusted enrollment review.
  Start a fresh session when the network view changes.
  """

  use GenServer

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Id
  alias WotexHome.Lifx.{CaptureTransport, DiscoveryPath, IPv4Scope, InterviewPath, Ledger, Packet}

  @max_age_ms 60_000
  @max_capture_bytes 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
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

  def start_link(_), do: {:error, :invalid_capture_owner}

  @spec discover(GenServer.server(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, String.t(), [Candidate.t()]} | {:error, atom()}
  def discover(server, source, sequence, duration_ms),
    do: GenServer.call(server, {:discover, source, sequence, duration_ms}, 12_000)

  @spec interview(GenServer.server(), String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, WotexHome.Discovery.Interview.t()} | {:error, atom()}
  def interview(server, session_ref, candidate_ref, source, timeout_ms),
    do:
      GenServer.call(server, {:interview, session_ref, candidate_ref, source, timeout_ms}, 7_000)

  @doc "Returns and consumes completed evidence for a trusted in-process reviewer."
  @spec checkout(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def checkout(server, session_ref), do: GenServer.call(server, {:checkout, session_ref})

  @impl true
  def init({interface_id, scope, transport, ttl}) do
    true = Code.ensure_loaded?(CaptureTransport)
    epoch = "boot:" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    {:ok,
     %{
       interface_id: interface_id,
       scope: scope,
       transport: transport,
       session_ttl_ms: ttl,
       epoch: epoch,
       clock_origin: System.monotonic_time(:millisecond),
       session: nil
     }}
  end

  @impl true
  def handle_call({:discover, source, sequence, duration_ms}, _from, state) do
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

  def handle_call({:interview, ref, candidate_ref, source, timeout_ms}, _from, state) do
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

  def handle_call({:checkout, ref}, _from, state) do
    with {:ok, session} <- current(state.session, ref),
         true <- session.interview != nil do
      evidence =
        Map.take(session, [
          :ref,
          :epoch,
          :interface_id,
          :candidates,
          :selected_candidate_ref,
          :interview,
          :transcript
        ])

      {:reply, {:ok, evidence}, %{state | session: nil}}
    else
      false -> {:reply, {:error, :interview_incomplete}, state}
      {:error, :capture_expired} -> {:reply, {:error, :capture_expired}, %{state | session: nil}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:expire_capture, ref}, %{session: %{ref: ref}} = state),
    do: {:noreply, %{state | session: nil}}

  def handle_info({:expire_capture, _ref}, state), do: {:noreply, state}

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
