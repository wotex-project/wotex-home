defmodule WotexHome.Rules.ExternalInputPackage do
  @moduledoc """
  Retains reviewed external-input claims and separately verifies their signatures.

  `encode/1` accepts the closed string-key package map containing its fixed
  `"format"`, `"definition_document"`, `"signed"` decision, `"cohort"` and
  `"attestations"`. It checks historical correspondence, retains the exact
  Definition document and uses the public JSON producer for the other inner
  documents. Success returns `{:ok, document}` with canonical package bytes.

  `decode/1` returns `{:ok, historical}` with exactly the string keys `"data"`,
  `"document"` and `"sha256"`. It checks canonical outer wire, historical
  Definition identity, the sorted eight passed cases and decision/cohort/evidence
  correspondence. It uses compiled immutable v1 programme data, requiring no
  producer, current programme file or trusted key. Signature encodings and
  distinct reviewer IDs are checked; signature trust and distinct public-key
  bytes require live verification. Packages are bounded to 262,144 bytes, and
  their hash binds the format, newline and exact document bytes.

  `verify/4` takes a package document, supplied current context and separate
  trusted case-reviewer and decision-reviewer key maps. It compares the complete
  claimed context, reconstructs the native `WotexHome.Rules.ExternalInput` and
  requires its exact original document, then verifies all signatures through
  `WotexHome.Qualification.ExternalInputDecision.verify/6`. Success returns the
  same `{:ok, historical}` metadata. This path requires available producers and
  the actual current, digest-pinned programme file.

  All three operations return `{:error, reason}` on refusal, using closed,
  payload-free external-input codes. A supplied context mismatch returns
  `{:error, :external_input_basis_changed}`; live review can also refuse with
  `:invalid_external_input_decision` or `:qualification_unavailable`.

  Store owns measuring current context, authentication and any SQLite installation.
  Historical parsing or a valid signature cannot restore current authority. This
  module neither samples source clocks nor inspects raw physical artifacts;
  successful verification grants no target or physical dispatch permission.
  """

  alias WotexHome.Profiles.{AuthoringWire, DocumentChunks, EnvelopeCodec}
  alias WotexHome.Qualification.{Attestation, Evidence, ExternalInputDecision}
  alias WotexHome.Rules.{ExternalInput, ExternalInputFormat}

  @format "wotex-home.external-input-package@1"
  @wire "wotex-home.external-input-package.v1"
  @inner ~w(signed cohort attestations)

  @doc "Creates canonical retained bytes from complete historical package claims; it verifies no keys."
  @spec encode(term()) :: {:ok, String.t()} | {:error, atom()}
  def encode(data) do
    ExternalInputFormat.guard(
      fn ->
        with {:ok, _} <- historical(data),
             {:ok, definition} <- DocumentChunks.encode(data["definition_document"], 262_144),
             {:ok, documents} <- canonical_inner(data),
             {:ok, document} <- ExternalInputFormat.wire([@wire, definition | documents], 262_144) do
          {:ok, document}
        else
          {:error, _} = error -> error
          _ -> invalid()
        end
      end,
      :document
    )
  end

  @doc "Returns plain historical data/document/sha256 metadata without live producers or trusted keys."
  @spec decode(term()) :: {:ok, map()} | {:error, atom()}
  def decode(document) do
    ExternalInputFormat.guard(fn ->
      with {:ok, [@wire, definition, signed, cohort, attestations] = wire} <-
             AuthoringWire.decode(document, 262_144),
           {:ok, ^document} <- ExternalInputFormat.wire(wire, 262_144),
           {:ok, definition} <- DocumentChunks.decode(definition, 262_144),
           {:ok, signed} <- inner(signed),
           {:ok, cohort} <- inner(cohort),
           {:ok, attestations} <- inner(attestations),
           data = %{
             "format" => @format,
             "definition_document" => definition,
             "signed" => signed,
             "cohort" => cohort,
             "attestations" => attestations
           },
           {:ok, _} <- historical(data) do
        {:ok,
         %{
           "data" => data,
           "document" => document,
           "sha256" => ExternalInputFormat.hash(@format, document)
         }}
      else
        {:error, _} = error -> error
        _ -> invalid()
      end
    end)
  end

  @doc "Checks the exact claimed context and native Definition plus all trusted signatures, without installation."
  @spec verify(term(), term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def verify(document, current_context, case_keys, decision_keys) do
    ExternalInputFormat.guard(fn ->
      with {:ok, package} <- decode(document),
           data = package["data"],
           {:ok, historical} <- ExternalInput.decode(data["definition_document"]),
           :ok <- current_context(historical["data"]["context"], current_context),
           d = historical["data"],
           {:ok, definition} <- ExternalInput.new(d["context"], d["mapping"], d["registry"]),
           true <- definition.document == data["definition_document"],
           {:ok, ^document} <- encode(data),
           {:ok, _} <-
             ExternalInputDecision.verify(
               data["signed"],
               definition,
               data["cohort"],
               data["attestations"],
               case_keys,
               decision_keys
             ) do
        {:ok, package}
      else
        {:error, _} = error -> error
        _ -> invalid()
      end
    end)
  end

  defp historical(data) do
    with true <-
           EnvelopeCodec.keys?(data, ~w(attestations cohort definition_document format signed)),
         :ok <- ExternalInputFormat.byte_limit(data["definition_document"], 262_144),
         :ok <- ExternalInputFormat.bounded(Map.delete(data, "definition_document")),
         true <- ExternalInputFormat.shape?(data, "input_package"),
         {:ok, definition} <- ExternalInput.decode(data["definition_document"]),
         {cases, programme} = ExternalInputDecision.historical_programme(),
         {:ok, cohort} <- Evidence.cohort_digest(data["cohort"]),
         {:ok, receipts} <- receipts(data["attestations"], programme),
         true <-
           data["attestations"] == Enum.sort_by(data["attestations"], & &1["receipt"]["case_id"]),
         {:ok, summary} <- Evidence.summarize(cases, receipts, data["cohort"]),
         true <- Enum.all?(summary, &(&1["status"] == "passed")),
         decision = data["signed"]["decision"],
         true <-
           decision["definition_sha256"] == definition["sha256"] and
             decision["programme_sha256"] == programme,
         true <-
           decision["cohort_sha256"] == cohort and
             decision["evidence_set_sha256"] == evidence_hash(data["attestations"]),
         true <- signature?(data["signed"]["signature"]),
         true <- Enum.all?(receipts, &(&1["reviewer_ref"] != decision["reviewer_key_id"])) do
      {:ok, definition}
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  defp receipts(attestations, programme) do
    Enum.reduce_while(attestations, {:ok, []}, fn a, {:ok, all} ->
      with true <- EnvelopeCodec.keys?(a, ~w(programme_digest receipt reviewer_key_id signature)),
           true <- a["programme_digest"] == programme and signature?(a["signature"]),
           {:ok, _} <- Attestation.signing_payload(a["reviewer_key_id"], programme, a["receipt"]),
           do: {:cont, {:ok, all ++ [a["receipt"]]}},
           else: (_ -> {:halt, invalid()})
    end)
  end

  defp canonical_inner(data) do
    Enum.reduce_while(@inner, {:ok, []}, fn field, {:ok, all} ->
      with {:ok, bytes} <- ExternalInputFormat.producer_json(data[field], 65_536),
           {:ok, chunks} <- DocumentChunks.encode(bytes, 65_536),
           do: {:cont, {:ok, all ++ [chunks]}},
           else: (error -> {:halt, error})
    end)
  end

  defp inner(chunks) do
    with {:ok, bytes} <- DocumentChunks.decode(chunks, 65_536),
         do: ExternalInputFormat.decode_json(bytes, 65_536)
  end

  defp signature?(bytes) when is_binary(bytes) and byte_size(bytes) == 86 do
    case Base.url_decode64(bytes, padding: false) do
      {:ok, value} when byte_size(value) == 64 ->
        Base.url_encode64(value, padding: false) == bytes

      _ ->
        false
    end
  end

  defp signature?(_), do: false

  defp evidence_hash(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp current_context(same, same), do: :ok
  defp current_context(_, _), do: {:error, :external_input_basis_changed}
  defp invalid, do: {:error, :invalid_external_input}
end
