defmodule WotexHome.Lifx.ReadSession do
  @moduledoc """
  Pure, read-only GetColor exchange for one selected LIFX candidate.

  Endpoint and target checks precede ledger correlation. A valid reply becomes
  only the qualified Thing's declared Home observations. The caller owns UDP,
  monotonically numbered report metadata and durable recording.
  """

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.{InterviewSession, Ledger, Packet, Report}
  alias WotexHome.Semantics.Thing

  @enforce_keys [:candidate, :target, :thing, :request_key]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(Candidate.t(), binary(), Thing.t()) :: {:ok, t()} | {:error, atom()}
  def new(%Candidate{} = candidate, target, %Thing{role: "Light"} = thing) do
    with {:ok, _interview} <- InterviewSession.new(candidate, target),
         {:ok, _document} <- Registry.encode_thing(thing) do
      {:ok, %__MODULE__{candidate: candidate, target: target, thing: thing, request_key: nil}}
    else
      _ -> {:error, :invalid_read_session}
    end
  end

  def new(_candidate, _target, _thing), do: {:error, :invalid_read_session}

  @spec issue(t(), Ledger.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), t(), Ledger.t()} | {:error, atom()}
  def issue(
        %__MODULE__{target: target, request_key: nil} = session,
        %Ledger{} = ledger,
        now_ms,
        ttl_ms
      ) do
    with {:ok, {source, ^target, sequence} = key, updated_ledger} <-
           Ledger.issue(ledger, target, :light_state, now_ms, ttl_ms),
         {:ok, query} <- Packet.get_color(source, target, sequence) do
      {:ok, query, %{session | request_key: key}, updated_ledger}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def issue(%__MODULE__{}, %Ledger{}, _now_ms, _ttl_ms),
    do: {:error, :read_already_issued}

  @spec accept(t(), Ledger.t(), String.t(), binary(), non_neg_integer(), map()) ::
          {:ok, [WotexHome.Semantics.Observation.t()], Ledger.t()}
          | {:error, atom(), Ledger.t()}
  def accept(%__MODULE__{} = session, %Ledger{} = ledger, endpoint, bytes, now_ms, metadata) do
    with true <- endpoint == session.candidate.source_endpoint,
         {:ok, packet} <- Packet.decode(bytes),
         true <-
           {packet.source, packet.target, packet.sequence} == session.request_key and
             packet.type == 107 and not packet.tagged,
         {:ok, response, updated_ledger} <- Ledger.accept(ledger, packet, now_ms) do
      case Report.from_response(session.thing, response, metadata) do
        {:ok, reports} -> {:ok, reports, updated_ledger}
        {:error, reason} -> {:error, reason, updated_ledger}
      end
    else
      false -> {:error, :endpoint_or_target_mismatch, ledger}
      {:error, reason, updated_ledger} -> {:error, reason, updated_ledger}
      {:error, reason} -> {:error, reason, ledger}
    end
  end
end
