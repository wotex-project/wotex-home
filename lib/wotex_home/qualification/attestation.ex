defmodule WotexHome.Qualification.Attestation do
  @moduledoc """
  Verify a sanitized receipt's reviewer signature against a caller-pinned key.

  The signer does not prove that an artifact exists or a device behaved as
  stated. Key custody, reviewer authorization and raw-evidence inspection are
  separate physical-qualification obligations.
  """

  alias WotexHome.Id
  alias WotexHome.Qualification.Evidence

  @keys ~w(receipt reviewer_key_id programme_digest signature)
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc "Canonical domain-separated bytes for an external trusted signer."
  @spec signing_payload(String.t(), String.t(), map()) :: {:ok, binary()} | {:error, atom()}
  def signing_payload(key_id, programme_digest, receipt) do
    with true <- Id.valid?(key_id) and hex64?(programme_digest),
         {:ok, %{}} <- Evidence.receipt(receipt),
         true <- receipt["reviewer_ref"] == key_id do
      {:ok,
       "WOH11-reviewer-receipt-v1\0" <>
         :erlang.term_to_binary({key_id, programme_digest, receipt}, [:deterministic])}
    else
      _ -> {:error, :invalid_attestation_input}
    end
  end

  @doc "Verify one closed attestation against an external key-ID to public-key map."
  @spec verify(map(), String.t(), %{String.t() => binary()}) ::
          {:ok, map()} | {:error, atom()}
  def verify(attestation, expected_programme_digest, trusted_keys)
      when is_map(attestation) and is_map(trusted_keys) and map_size(trusted_keys) <= 32 do
    with true <- Enum.sort(Map.keys(attestation)) == Enum.sort(@keys),
         key_id when is_binary(key_id) <- attestation["reviewer_key_id"],
         ^expected_programme_digest <- attestation["programme_digest"],
         public_key when is_binary(public_key) and byte_size(public_key) == 32 <-
           Map.get(trusted_keys, key_id),
         {:ok, payload} <-
           signing_payload(key_id, expected_programme_digest, attestation["receipt"]),
         {:ok, signature} <- decode_signature(attestation["signature"]),
         true <- verify_signature(payload, signature, public_key) do
      {:ok, attestation["receipt"]}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  def verify(_, _, _), do: {:error, :invalid_attestation}

  defp decode_signature(encoded) when is_binary(encoded) and byte_size(encoded) == 86 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, signature} when byte_size(signature) == 64 ->
        if Base.url_encode64(signature, padding: false) == encoded,
          do: {:ok, signature},
          else: {:error, :invalid_attestation}

      _ ->
        {:error, :invalid_attestation}
    end
  end

  defp decode_signature(_), do: {:error, :invalid_attestation}

  defp verify_signature(payload, signature, public_key) do
    :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  defp hex64?(value), do: is_binary(value) and value =~ @hex64
end
