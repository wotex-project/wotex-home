defmodule WotexHome.Lifx.PowerSession do
  @moduledoc """
  Pure SetLightPower acknowledgement and separate GetLightPower readback.

  This constructs bytes for an already authorized, claimed power operation; it
  has no transport or durable admission authority. An ACK only means the device
  answered the packet. A matching readback is a reported state, not proof of a
  physical effect or permission to finish a durable receipt.

  `new/5` binds a claimed operation to its target and Thing. The caller sends
  bytes from `issue_set/4`, handles the ACK, then performs the independent
  read exchange. Preserve an unknown outcome when either response is missing
  or late; retry policy belongs to the durable authority.
  """

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.{InterviewSession, Ledger, Packet, Report}
  alias WotexHome.Mutation
  alias WotexHome.Semantics.{Capability, Thing, Value}

  @enforce_keys [
    :candidate,
    :target,
    :thing,
    :mutation,
    :desired_on?,
    :duration_ms,
    :set_key,
    :read_key,
    :acknowledged?,
    :readback
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(Candidate.t(), binary(), Thing.t(), Mutation.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, atom()}
  def new(
        %Candidate{} = candidate,
        target,
        %Thing{role: "Light"} = thing,
        %Mutation{} = mutation,
        duration_ms
      ) do
    with {:ok, _interview} <- InterviewSession.new(candidate, target),
         {:ok, _document} <- Registry.encode_thing(thing),
         true <-
           Mutation.valid?(mutation) and mutation.target_id == thing.id and
             mutation.capability_key == "power",
         {:ok, capability} <- Thing.capability(thing, "power"),
         true <- Capability.supports?(capability, "write"),
         {:ok, %Value{kind: :boolean, data: on?} = value} <- Value.new(mutation.value),
         true <- Capability.accepts?(capability, value),
         true <- is_integer(duration_ms) and duration_ms >= 0 and duration_ms <= 60_000 do
      {:ok,
       %__MODULE__{
         candidate: candidate,
         target: target,
         thing: thing,
         mutation: mutation,
         desired_on?: on?,
         duration_ms: duration_ms,
         set_key: nil,
         read_key: nil,
         acknowledged?: false,
         readback: nil
       }}
    else
      _ -> {:error, :invalid_power_session}
    end
  end

  def new(_candidate, _target, _thing, _mutation, _duration_ms),
    do: {:error, :invalid_power_session}

  @doc "Construct the one absolute write. The caller must have durably claimed and rechecked it."
  @spec issue_set(t(), Ledger.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), t(), Ledger.t()} | {:error, atom()}
  def issue_set(%__MODULE__{set_key: nil} = session, %Ledger{} = ledger, now_ms, ttl_ms) do
    with {:ok, {source, target, sequence} = key, updated_ledger} <-
           Ledger.issue(ledger, session.target, :ack, now_ms, ttl_ms),
         {:ok, packet} <-
           Packet.set_light_power(
             source,
             target,
             sequence,
             session.desired_on?,
             session.duration_ms
           ) do
      {:ok, packet, %{session | set_key: key}, updated_ledger}
    end
  end

  def issue_set(%__MODULE__{}, %Ledger{}, _now_ms, _ttl_ms),
    do: {:error, :set_already_issued}

  @doc "Record only a correlated ACK; this is not a readback or completed effect."
  @spec accept_ack(t(), Ledger.t(), String.t(), binary(), non_neg_integer()) ::
          {:ok, t(), Ledger.t()} | {:error, atom(), Ledger.t()}
  def accept_ack(%__MODULE__{} = session, %Ledger{} = ledger, endpoint, bytes, now_ms) do
    with :ok <- endpoint(session, endpoint),
         {:ok, packet} <- Packet.decode(bytes),
         :ok <- matching_packet(packet, session.set_key, 45),
         {:ok, %{kind: :ack}, updated_ledger} <- Ledger.accept(ledger, packet, now_ms) do
      {:ok, %{session | acknowledged?: true}, updated_ledger}
    else
      {:error, reason, updated_ledger} -> {:error, reason, updated_ledger}
      {:error, reason} -> {:error, reason, ledger}
    end
  end

  @doc "Construct one readback after the write was handed to the transport."
  @spec issue_read(t(), Ledger.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), t(), Ledger.t()} | {:error, atom()}
  def issue_read(%__MODULE__{set_key: nil}, %Ledger{}, _now_ms, _ttl_ms),
    do: {:error, :set_not_issued}

  def issue_read(%__MODULE__{read_key: nil} = session, %Ledger{} = ledger, now_ms, ttl_ms) do
    with {:ok, {source, target, sequence} = key, updated_ledger} <-
           Ledger.issue(ledger, session.target, :light_power, now_ms, ttl_ms),
         {:ok, packet} <- Packet.get_light_power(source, target, sequence) do
      {:ok, packet, %{session | read_key: key}, updated_ledger}
    end
  end

  def issue_read(%__MODULE__{}, %Ledger{}, _now_ms, _ttl_ms),
    do: {:error, :read_already_issued}

  @doc "Return a typed report and whether it matches the requested power value."
  @spec accept_read(t(), Ledger.t(), String.t(), binary(), non_neg_integer(), map()) ::
          {:ok, :reported_match | :reported_mismatch, WotexHome.Semantics.Observation.t(), t(),
           Ledger.t()}
          | {:error, atom(), Ledger.t()}
  def accept_read(%__MODULE__{} = session, %Ledger{} = ledger, endpoint, bytes, now_ms, metadata) do
    with :ok <- endpoint(session, endpoint),
         {:ok, packet} <- Packet.decode(bytes),
         :ok <- matching_packet(packet, session.read_key, 118),
         {:ok, %{kind: :light_power} = response, updated_ledger} <-
           Ledger.accept(ledger, packet, now_ms) do
      case Report.from_response(session.thing, response, metadata) do
        {:ok, [report]} ->
          comparison =
            if response.on? == session.desired_on?,
              do: :reported_match,
              else: :reported_mismatch

          {:ok, comparison, report, %{session | readback: comparison}, updated_ledger}

        _ ->
          {:error, :invalid_power_readback, updated_ledger}
      end
    else
      {:error, reason, updated_ledger} -> {:error, reason, updated_ledger}
      {:error, reason} -> {:error, reason, ledger}
      _ -> {:error, :invalid_power_readback, ledger}
    end
  end

  defp endpoint(session, endpoint) do
    if endpoint == session.candidate.source_endpoint,
      do: :ok,
      else: {:error, :endpoint_mismatch}
  end

  defp matching_packet(_packet, nil, _type), do: {:error, :request_not_issued}

  defp matching_packet(%Packet{} = packet, {source, target, sequence}, type) do
    if packet.source == source and packet.target == target and packet.sequence == sequence and
         packet.type == type and not packet.tagged,
       do: :ok,
       else: {:error, :unmatched_response}
  end
end
