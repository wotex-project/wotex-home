defmodule WotexHome.Lifx.InterviewSession do
  @moduledoc """
  Read-only LIFX identity interview over an externally owned UDP transport.

  The session creates only GetVersion and GetHostFirmware packets. Replies
  must match the discovery endpoint and the in-boot ledger. The resulting
  interview is reported device identity, not enrollment or attestation.
  """

  alias WotexHome.Discovery.{Candidate, Interview}
  alias WotexHome.Lifx.{Ledger, Packet}

  @enforce_keys [:candidate, :target, :version, :firmware]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(Candidate.t(), binary()) :: {:ok, t()} | {:error, atom()}
  def new(%Candidate{} = candidate, target) when is_binary(target) and byte_size(target) == 6 do
    stable_id = "lifx:" <> Base.encode16(target, case: :lower)

    if valid_candidate?(candidate) and candidate.transport == "udp" and
         candidate.claimed_identifiers["stable_id"] == stable_id do
      {:ok, %__MODULE__{candidate: candidate, target: target, version: nil, firmware: nil}}
    else
      {:error, :invalid_interview_candidate}
    end
  end

  def new(_candidate, _target), do: {:error, :invalid_interview_candidate}

  @spec issue(t(), Ledger.t(), non_neg_integer(), pos_integer()) ::
          {:ok, map(), Ledger.t()} | {:error, atom()}
  def issue(%__MODULE__{target: target}, %Ledger{} = ledger, now_ms, ttl_ms) do
    with {:ok, {source_v, ^target, sequence_v}, ledger} <-
           Ledger.issue(ledger, target, :version, now_ms, ttl_ms),
         {:ok, {source_f, ^target, sequence_f}, ledger} <-
           Ledger.issue(ledger, target, :host_firmware, now_ms, ttl_ms),
         {:ok, version_query} <- Packet.get_version(source_v, target, sequence_v),
         {:ok, firmware_query} <- Packet.get_host_firmware(source_f, target, sequence_f) do
      {:ok, %{version: version_query, host_firmware: firmware_query}, ledger}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec accept(t(), Ledger.t(), String.t(), binary(), non_neg_integer()) ::
          {:ok, t(), Ledger.t()} | {:error, atom(), t(), Ledger.t()}
  def accept(%__MODULE__{} = session, %Ledger{} = ledger, endpoint, bytes, now_ms) do
    with true <- endpoint == session.candidate.source_endpoint,
         {:ok, packet} <- Packet.decode(bytes),
         true <- packet.target == session.target and packet.type in [15, 33],
         {:ok, response, ledger} <- Ledger.accept(ledger, packet, now_ms) do
      update(session, ledger, response)
    else
      false -> {:error, :endpoint_or_target_mismatch, session, ledger}
      {:error, reason, updated_ledger} -> {:error, reason, session, updated_ledger}
      {:error, reason} -> {:error, reason, session, ledger}
    end
  end

  @spec finish(t()) :: {:ok, Interview.t()} | {:error, :incomplete_interview}
  def finish(%__MODULE__{candidate: candidate, version: version, firmware: firmware})
      when is_map(version) and is_map(firmware) do
    Interview.new(
      %{
        "candidate_ref" => candidate.raw_ref,
        "transport" => "udp",
        "manufacturer" => "lifx.vendor.#{version.vendor}",
        "model" => "lifx.product.#{version.product}",
        "firmware" => "#{firmware.major}.#{firmware.minor}",
        "stable_id" => candidate.claimed_identifiers["stable_id"]
      },
      candidate
    )
  end

  def finish(_session), do: {:error, :incomplete_interview}

  defp update(session, ledger, %{kind: :version} = response) do
    if is_nil(session.version) or session.version == response,
      do: {:ok, %{session | version: response}, ledger},
      else: {:error, :identity_changed, session, ledger}
  end

  defp update(session, ledger, %{kind: :host_firmware} = response) do
    if is_nil(session.firmware) or session.firmware == response,
      do: {:ok, %{session | firmware: response}, ledger},
      else: {:error, :identity_changed, session, ledger}
  end

  defp valid_candidate?(candidate) do
    candidate
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Candidate.new()
    |> then(&(&1 == {:ok, candidate}))
  end
end
