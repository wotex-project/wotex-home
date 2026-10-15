defmodule WotexHome.Qualification.ExternalInputDecision do
  @moduledoc """
  Verifies a separately signed review of an external-input correspondence claim.

  `programme/0` returns `{:ok, cases, sha256}` for the shipped, digest-pinned
  eight-case programme. Its callback-based file read closes the file and reads
  at most 16,385 bytes, rejecting content above 16,384 bytes or with a different
  SHA-256 digest. Missing or invalid programme data returns
  `{:error, :qualification_unavailable}`; callers cannot supply replacement policy.
  Historical package parsing uses compiled immutable v1 case definitions and
  their pinned digest instead. Live verification still calls `programme/0` to
  reread the actual current file; compiled data cannot replace that check.

  `signing_payload/1` checks the compiled closed decision shape and size bounds,
  returning `{:ok, payload}` with deterministic, domain-separated signing bytes
  or `{:error, :invalid_external_input_decision}`. It neither signs the payload
  nor verifies the decision's evidence, signatures or current applicability.

  `verify/6` accepts the signed decision, a native
  `WotexHome.Rules.ExternalInput`, a cohort, eight signed case attestations and
  separate trusted case-reviewer and decision-reviewer public-key maps. Each
  key map holds at most 32 IDs mapped to 32-byte Ed25519 public keys. Verification
  rebuilds the native input against its retained context, requires the complete
  passed case set for the exact cohort, and checks every signature and decision
  digest. The decision reviewer must differ from every case reviewer by both
  reviewer ID and public-key bytes. Success returns `{:ok, decision}`.

  Empty trusted-key maps or an unavailable programme can return
  `{:error, :qualification_unavailable}`. Other verification refusals return
  `{:error, :invalid_external_input_decision}`.

  Rebuilding the input does not independently measure Store's current context.
  Store must compare the complete input with independently rebuilt current
  context before installation. Reviewers own inspection of the referenced raw
  artifacts and their physical provenance; this API authenticates sanitized
  claims and receives no private signing keys. Fixture signatures do not prove
  physical qualification. No successful result grants a target, returns a Fact
  or enables dispatch.
  """

  alias WotexHome.Id
  alias WotexHome.Profiles.EnvelopeCodec
  alias WotexHome.Qualification.{Attestation, Evidence}
  alias WotexHome.Rules.{ExternalInput, ExternalInputFormat}

  @programme_digest "8106ed31e44f2e33517c65581a43bc64ae33117d1e3fbcfab780a8bfc3df876f"
  @external_resource Path.expand(
                       "../../../priv/qualification/external-routine-input-v1.json",
                       __DIR__
                     )
  @programme_bytes File.read!(@external_resource)
  if Base.encode16(:crypto.hash(:sha256, @programme_bytes), case: :lower) != @programme_digest,
    do: raise(ArgumentError, "invalid external input programme")

  @historical_cases JSON.decode!(@programme_bytes)["cases"]
  @case_ids ~w(ERI-clock ERI-continuity ERI-conversion ERI-identity ERI-invalid ERI-offline ERI-reconnect ERI-revocation)

  @doc false
  def historical_programme, do: {@historical_cases, @programme_digest}

  @doc "Returns the exact shipped case definitions and digest, without accepting replacement policy."
  @spec programme() :: {:ok, [map()], String.t()} | {:error, :qualification_unavailable}
  def programme do
    path = Application.app_dir(:wotex_home, "priv/qualification/external-routine-input-v1.json")

    with {:ok, bytes} when is_binary(bytes) <-
           File.open(path, [:read, :binary], &IO.binread(&1, 16_385)),
         true <- byte_size(bytes) <= 16_384,
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @programme_digest,
         {:ok,
          %{
            "schema" => "wotex-home.qualification-programme.v1",
            "programme_id" => "external-routine-input-v1",
            "cases" => cases
          } = data} <- JSON.decode(bytes),
         true <- EnvelopeCodec.keys?(data, ~w(cases programme_id schema)),
         true <- is_list(cases) and length(cases) == 8,
         true <- Enum.all?(cases, &match?({:ok, _}, Evidence.case_definition(&1))),
         true <- Enum.sort(Enum.map(cases, & &1["case_id"])) == @case_ids do
      {:ok, cases, @programme_digest}
    else
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  @doc "Returns deterministic domain-separated bytes for one closed reviewer decision."
  @spec signing_payload(term()) :: {:ok, binary()} | {:error, :invalid_external_input_decision}
  def signing_payload(decision) do
    if ExternalInputFormat.bounded(decision) == :ok and
         ExternalInputFormat.shape?(decision, "input_decision") do
      {:ok,
       "WOH11-external-input-decision-v1\0" <> :erlang.term_to_binary(decision, [:deterministic])}
    else
      invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  @doc "Checks complete signed review claims against explicit keys, without installing current authority."
  @spec verify(term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, :invalid_external_input_decision | :qualification_unavailable}
  def verify(
        signed,
        %ExternalInput{data: %{"context" => context}} = definition,
        cohort,
        attestations,
        case_keys,
        decision_keys
      ) do
    with :ok <- keys(case_keys, decision_keys),
         true <- EnvelopeCodec.keys?(signed, ~w(decision signature)),
         true <- is_list(attestations) and length(attestations) == 8,
         :ok <-
           ExternalInputFormat.bounded(%{
             "signed" => signed,
             "cohort" => cohort,
             "attestations" => attestations
           }),
         {:ok, _} <- ExternalInput.to_map(definition, context),
         {:ok, payload} <- signing_payload(signed["decision"]),
         {:ok, cases, programme_digest} <- programme(),
         {:ok, cohort_digest} <- Evidence.cohort_digest(cohort),
         {:ok, receipts} <- verify_cases(attestations, programme_digest, case_keys),
         {:ok, summary} <- Evidence.summarize(cases, receipts, cohort),
         true <- Enum.all?(summary, &(&1["status"] == "passed")),
         true <-
           decision_matches?(
             signed["decision"],
             definition.sha256,
             programme_digest,
             cohort_digest,
             attestations
           ),
         reviewer = signed["decision"]["reviewer_key_id"],
         public_key when is_binary(public_key) <- Map.get(decision_keys, reviewer),
         true <-
           Enum.all?(attestations, fn a ->
             a["reviewer_key_id"] != reviewer and
               Map.fetch!(case_keys, a["reviewer_key_id"]) != public_key
           end),
         {:ok, signature} <- signature(signed["signature"]),
         true <- :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      {:ok, signed["decision"]}
    else
      {:error, :qualification_unavailable} -> unavailable()
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def verify(_, _, _, _, _, _), do: invalid()

  defp decision_matches?(d, definition, programme, cohort, attestations),
    do:
      d["definition_sha256"] == definition and d["programme_sha256"] == programme and
        d["cohort_sha256"] == cohort and d["evidence_set_sha256"] == evidence_digest(attestations)

  defp evidence_digest(attestations),
    do:
      attestations
      |> Enum.sort_by(& &1["receipt"]["case_id"])
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp verify_cases(attestations, programme, keys) do
    Enum.reduce_while(attestations, {:ok, []}, fn a, {:ok, receipts} ->
      case Attestation.verify(a, programme, keys) do
        {:ok, receipt} -> {:cont, {:ok, receipts ++ [receipt]}}
        _ -> {:halt, invalid()}
      end
    end)
  end

  defp keys(case_keys, decision_keys) do
    cond do
      not valid_keys?(case_keys) or not valid_keys?(decision_keys) -> invalid()
      map_size(case_keys) == 0 or map_size(decision_keys) == 0 -> unavailable()
      true -> :ok
    end
  end

  defp valid_keys?(keys) when is_map(keys) and not is_struct(keys) and map_size(keys) <= 32,
    do:
      Enum.all?(keys, fn {id, key} ->
        Id.valid?(id) and is_binary(key) and byte_size(key) == 32
      end)

  defp valid_keys?(_), do: false

  defp signature(encoded) when is_binary(encoded) and byte_size(encoded) == 86 do
    with {:ok, signature} when byte_size(signature) == 64 <-
           Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(signature, padding: false) == encoded,
         do: {:ok, signature},
         else: (_ -> invalid())
  end

  defp signature(_), do: invalid()
  defp invalid, do: {:error, :invalid_external_input_decision}
  defp unavailable, do: {:error, :qualification_unavailable}
end
