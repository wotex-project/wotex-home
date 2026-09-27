defmodule WotexHome.Qualification.Evidence do
  @moduledoc """
  Closed, credential-free qualification receipts and case summaries.

  A receipt records one case in one environment and exact cohort. It never
  grants profile or dispatch authority. Raw captures, device identifiers and
  signing keys stay outside this sanitized value.

  `case_definition/1` and `receipt/1` validate the closed report shapes.
  `summarize/3` compares receipts with the exact current cohort and names
  missing or blocked cases. A syntactically complete summary still needs
  reviewer attestations and artifact checks.
  """

  @cohort_fields ~w(source_identity_ref hardware_sku hardware_revision firmware adapter_profile native_stack host_os runtime network_topology application model)
  @case_fields ~w(case_id requirement_id capability_key environment)
  @receipt_fields ~w(receipt_id case_id requirement_id capability_key environment status cohort source_identity_ref command_sequence assertions artifact_digests exclusions blockers reviewer_ref)
  @assertion_fields ~w(id expected actual)
  @environments ~w(fixture simulator integration hardware field)
  @statuses ~w(passed failed blocked not_run)
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/

  @type document :: map()

  @doc "Produce an opaque source reference with a locally held secret key."
  @spec source_identity_ref(binary(), binary()) :: {:ok, String.t()} | {:error, atom()}
  def source_identity_ref(key, stable_identity)
      when is_binary(key) and byte_size(key) >= 32 and is_binary(stable_identity) and
             byte_size(stable_identity) in 1..256 do
    {:ok, :crypto.mac(:hmac, :sha256, key, stable_identity) |> Base.encode16(case: :lower)}
  end

  def source_identity_ref(_, _), do: {:error, :invalid_identity_input}

  @doc "Validate an exact cohort and return its semantic digest."
  @spec cohort_digest(document()) :: {:ok, String.t()} | {:error, atom()}
  def cohort_digest(cohort) do
    if exact_keys?(cohort, @cohort_fields) and
         Enum.all?(Map.take(cohort, @cohort_fields -- ["source_identity_ref"]), fn {_key, value} ->
           identifier?(value)
         end) and is_binary(cohort["source_identity_ref"]) and
         cohort["source_identity_ref"] =~ @hex64 do
      {:ok, digest(cohort)}
    else
      {:error, :invalid_cohort}
    end
  end

  @doc "Validate a required case without inferring an environment from its name."
  @spec case_definition(document()) :: {:ok, document()} | {:error, atom()}
  def case_definition(case_definition) do
    if exact_keys?(case_definition, @case_fields) and
         Enum.all?(Map.take(case_definition, @case_fields -- ["environment"]), fn {_key, value} ->
           identifier?(value)
         end) and case_definition["environment"] in @environments do
      {:ok, case_definition}
    else
      {:error, :invalid_case_definition}
    end
  end

  @doc "Validate a sanitized immutable receipt."
  @spec receipt(document()) :: {:ok, document()} | {:error, atom()}
  def receipt(receipt) do
    with true <- exact_keys?(receipt, @receipt_fields),
         {:ok, _case} <- case_definition(Map.take(receipt, @case_fields)),
         {:ok, _cohort_digest} <- cohort_digest(receipt["cohort"]),
         true <- identifier?(receipt["receipt_id"]) and identifier?(receipt["reviewer_ref"]),
         true <- receipt["source_identity_ref"] == receipt["cohort"]["source_identity_ref"],
         true <- receipt["status"] in @statuses,
         true <- valid_ids?(receipt["command_sequence"], 64),
         true <- valid_ids?(receipt["exclusions"], 32),
         true <- valid_ids?(receipt["blockers"], 32),
         true <- valid_digests?(receipt["artifact_digests"]),
         true <- valid_assertions?(receipt["assertions"]),
         true <- status_consistent?(receipt) do
      {:ok, receipt}
    else
      _ -> {:error, :invalid_evidence_receipt}
    end
  end

  @doc "Classify every required case for one exact current cohort."
  @spec summarize([document()], [document()], document()) ::
          {:ok, [document()]} | {:error, atom()}
  def summarize(cases, receipts, current_cohort)
      when is_list(cases) and is_list(receipts) and length(cases) <= 512 and
             length(receipts) <= 512 do
    with {:ok, current_digest} <- cohort_digest(current_cohort),
         {:ok, case_index} <- index_cases(cases),
         {:ok, receipt_index} <- index_receipts(receipts, case_index) do
      summary =
        cases
        |> Enum.map(fn case_definition ->
          case_id = case_definition["case_id"]

          case Map.fetch(receipt_index, case_id) do
            :error ->
              result(case_definition, "not_run", "receipt_missing", nil)

            {:ok, receipt} ->
              classify(case_definition, receipt, current_digest)
          end
        end)

      {:ok, summary}
    end
  end

  def summarize(_, _, _), do: {:error, :invalid_evidence_set}

  defp classify(case_definition, receipt, current_digest) do
    {:ok, receipt_digest} = cohort_digest(receipt["cohort"])

    cond do
      receipt_digest != current_digest ->
        result(case_definition, "blocked", "cohort_drift", receipt["receipt_id"])

      receipt["environment"] != case_definition["environment"] ->
        result(case_definition, "blocked", "environment_mismatch", receipt["receipt_id"])

      true ->
        result(case_definition, receipt["status"], nil, receipt["receipt_id"])
    end
  end

  defp result(case_definition, status, reason, receipt_id) do
    %{
      "case_id" => case_definition["case_id"],
      "requirement_id" => case_definition["requirement_id"],
      "capability_key" => case_definition["capability_key"],
      "required_environment" => case_definition["environment"],
      "status" => status,
      "reason" => reason,
      "receipt_id" => receipt_id
    }
  end

  defp index_cases(cases) do
    Enum.reduce_while(cases, {:ok, %{}}, fn case_definition, {:ok, index} ->
      with {:ok, case_definition} <- case_definition(case_definition),
           false <- Map.has_key?(index, case_definition["case_id"]) do
        {:cont, {:ok, Map.put(index, case_definition["case_id"], case_definition)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        true -> {:halt, {:error, :duplicate_case_definition}}
      end
    end)
  end

  defp index_receipts(receipts, case_index) do
    Enum.reduce_while(receipts, {:ok, %{}, MapSet.new()}, fn document, {:ok, index, ids} ->
      with {:ok, receipt} <- receipt(document),
           {:ok, case_definition} <- Map.fetch(case_index, receipt["case_id"]),
           true <-
             receipt["requirement_id"] == case_definition["requirement_id"] and
               receipt["capability_key"] == case_definition["capability_key"],
           false <-
             Map.has_key?(index, receipt["case_id"]) or
               MapSet.member?(ids, receipt["receipt_id"]) do
        {:cont,
         {:ok, Map.put(index, receipt["case_id"], receipt),
          MapSet.put(ids, receipt["receipt_id"])}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        :error -> {:halt, {:error, :unknown_case_receipt}}
        true -> {:halt, {:error, :mismatched_or_duplicate_receipt}}
        false -> {:halt, {:error, :mismatched_or_duplicate_receipt}}
      end
    end)
    |> case do
      {:ok, index, _ids} -> {:ok, index}
      error -> error
    end
  end

  defp status_consistent?(receipt) do
    assertions = receipt["assertions"]
    results = Enum.map(assertions, & &1["actual"])

    case receipt["status"] do
      "passed" ->
        receipt["command_sequence"] != [] and receipt["artifact_digests"] != [] and
          assertions != [] and receipt["exclusions"] == [] and receipt["blockers"] == [] and
          Enum.all?(assertions, &(&1["actual"] == &1["expected"]))

      "failed" ->
        receipt["command_sequence"] != [] and assertions != [] and receipt["blockers"] == [] and
          Enum.any?(assertions, fn assertion ->
            is_boolean(assertion["actual"]) and
              assertion["actual"] != assertion["expected"]
          end)

      "blocked" ->
        receipt["blockers"] != [] and Enum.all?(results, &is_nil/1)

      "not_run" ->
        receipt["command_sequence"] == [] and receipt["artifact_digests"] == [] and
          receipt["exclusions"] == [] and receipt["blockers"] == [] and
          Enum.all?(results, &is_nil/1)
    end
  end

  defp valid_assertions?(assertions) when is_list(assertions) and length(assertions) <= 64 do
    ids =
      Enum.map(assertions, fn assertion ->
        if exact_keys?(assertion, @assertion_fields) and identifier?(assertion["id"]) and
             is_boolean(assertion["expected"]) and
             (is_nil(assertion["actual"]) or is_boolean(assertion["actual"])) do
          assertion["id"]
        end
      end)

    Enum.all?(ids, &is_binary/1) and length(Enum.uniq(ids)) == length(ids)
  end

  defp valid_assertions?(_), do: false

  defp valid_digests?(digests) when is_list(digests) and length(digests) <= 32,
    do: Enum.all?(digests, &(is_binary(&1) and &1 =~ @hex64)) and Enum.uniq(digests) == digests

  defp valid_digests?(_), do: false

  defp valid_ids?(ids, limit) when is_list(ids) and length(ids) <= limit,
    do: Enum.all?(ids, &identifier?/1) and Enum.uniq(ids) == ids

  defp valid_ids?(_, _), do: false

  defp exact_keys?(value, keys) when is_map(value),
    do: Map.keys(value) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys?(_, _), do: false

  defp identifier?(value), do: is_binary(value) and value =~ @identifier

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
