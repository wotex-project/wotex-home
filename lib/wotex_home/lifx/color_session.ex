defmodule WotexHome.Lifx.ColorSession do
  @moduledoc """
  Pure SetColor ACK and independent GetColor reported-state exchange.

  This session has no socket or admission authority. A caller must recheck the
  plan's baseline, hold the whole-light effect domain, durably claim the
  operation and pass current guards before handing its SetColor bytes to UDP.
  A correlated readback is still only an unauthenticated local report.
  """

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Registry
  alias WotexHome.Id
  alias WotexHome.Lifx.{ColorPlan, InterviewSession, Ledger, Packet, Report}
  alias WotexHome.Semantics.{Capability, Thing}

  @color_keys ~w(brightness colour_hsv colour_temperature)

  @enforce_keys [
    :candidate,
    :target,
    :thing,
    :plan,
    :duration_ms,
    :set_key,
    :read_key,
    :acknowledged?,
    :readback
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(Candidate.t(), binary(), Thing.t(), ColorPlan.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_color_session}
  def new(
        %Candidate{} = candidate,
        target,
        %Thing{role: "Light"} = thing,
        %ColorPlan{} = plan,
        duration_ms
      ) do
    with {:ok, _interview} <- InterviewSession.new(candidate, target),
         {:ok, _document} <- Registry.encode_thing(thing),
         true <- plan.thing_id == thing.id and Id.valid?(plan.operation_id),
         true <- plan.requested in @color_keys and valid_baseline?(plan.baseline),
         {:ok, capability} <- Thing.capability(thing, plan.requested),
         true <- Capability.supports?(capability, "write"),
         {:ok, _packet} <- Packet.set_color(2, target, 0, plan.raw_hsbk, duration_ms) do
      {:ok,
       %__MODULE__{
         candidate: candidate,
         target: target,
         thing: thing,
         plan: plan,
         duration_ms: duration_ms,
         set_key: nil,
         read_key: nil,
         acknowledged?: false,
         readback: nil
       }}
    else
      _ -> {:error, :invalid_color_session}
    end
  end

  def new(_candidate, _target, _thing, _plan, _duration_ms),
    do: {:error, :invalid_color_session}

  @spec issue_set(t(), Ledger.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), t(), Ledger.t()} | {:error, atom()}
  def issue_set(%__MODULE__{set_key: nil} = session, %Ledger{} = ledger, now_ms, ttl_ms) do
    with {:ok, {source, target, sequence} = key, ledger} <-
           Ledger.issue(ledger, session.target, :ack, now_ms, ttl_ms),
         {:ok, bytes} <-
           Packet.set_color(source, target, sequence, session.plan.raw_hsbk, session.duration_ms) do
      {:ok, bytes, %{session | set_key: key}, ledger}
    end
  end

  def issue_set(%__MODULE__{}, %Ledger{}, _now_ms, _ttl_ms),
    do: {:error, :set_already_issued}

  @spec accept_ack(t(), Ledger.t(), String.t(), binary(), non_neg_integer()) ::
          {:ok, t(), Ledger.t()} | {:error, atom(), Ledger.t()}
  def accept_ack(%__MODULE__{} = session, %Ledger{} = ledger, endpoint, bytes, now_ms) do
    with :ok <- endpoint(session, endpoint),
         {:ok, packet} <- Packet.decode(bytes),
         :ok <- matching_packet(packet, session.set_key, 45),
         {:ok, %{kind: :ack}, ledger} <- Ledger.accept(ledger, packet, now_ms) do
      {:ok, %{session | acknowledged?: true}, ledger}
    else
      {:error, reason, ledger} -> {:error, reason, ledger}
      {:error, reason} -> {:error, reason, ledger}
    end
  end

  @spec issue_read(t(), Ledger.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), t(), Ledger.t()} | {:error, atom()}
  def issue_read(%__MODULE__{set_key: nil}, %Ledger{}, _now_ms, _ttl_ms),
    do: {:error, :set_not_issued}

  def issue_read(%__MODULE__{read_key: nil} = session, %Ledger{} = ledger, now_ms, ttl_ms) do
    with {:ok, {source, target, sequence} = key, ledger} <-
           Ledger.issue(ledger, session.target, :light_state, now_ms, ttl_ms),
         {:ok, bytes} <- Packet.get_color(source, target, sequence) do
      {:ok, bytes, %{session | read_key: key}, ledger}
    end
  end

  def issue_read(%__MODULE__{}, %Ledger{}, _now_ms, _ttl_ms),
    do: {:error, :read_already_issued}

  @spec accept_read(t(), Ledger.t(), String.t(), binary(), non_neg_integer(), map()) ::
          {:ok, :reported_match | :reported_mismatch, [WotexHome.Semantics.Observation.t()], t(),
           Ledger.t()}
          | {:error, atom(), Ledger.t()}
  def accept_read(%__MODULE__{} = session, %Ledger{} = ledger, endpoint, bytes, now_ms, metadata) do
    with :ok <- endpoint(session, endpoint),
         {:ok, packet} <- Packet.decode(bytes),
         :ok <- matching_packet(packet, session.read_key, 107),
         {:ok, %{kind: :light_state} = response, updated_ledger} <-
           Ledger.accept(ledger, packet, now_ms) do
      case Report.from_response(session.thing, response, metadata) do
        {:ok, reports} ->
          raw = Map.take(response, [:hue, :saturation, :brightness, :kelvin])
          result = if raw == session.plan.raw_hsbk, do: :reported_match, else: :reported_mismatch
          {:ok, result, reports, %{session | readback: result}, updated_ledger}

        {:error, reason} ->
          {:error, reason, updated_ledger}
      end
    else
      {:error, reason, updated_ledger} -> {:error, reason, updated_ledger}
      {:error, reason} -> {:error, reason, ledger}
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

  defp valid_baseline?({source_epoch, source_sequence, boot_epoch, utc_ms, monotonic_ms}) do
    Id.valid?(source_epoch) and Id.valid?(boot_epoch) and is_integer(source_sequence) and
      source_sequence >= 0 and is_integer(utc_ms) and utc_ms >= 0 and
      is_integer(monotonic_ms) and monotonic_ms >= 0
  end

  defp valid_baseline?(_baseline), do: false
end
