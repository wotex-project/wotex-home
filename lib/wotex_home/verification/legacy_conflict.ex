defmodule WotexHome.Verification.LegacyConflict do
  @moduledoc """
  Narrow negative screen using ex_maude's bundled IoT conflict model.

  Only unconditional, explicit-request Boolean effects are translated. The
  bundled model cannot represent Home's unknown facts, edge triggers, timing,
  authority or dispatch uncertainty. A no-finding result stays inconclusive.

  `screen/1` translates a restricted draft and asks ex_maude for a negative
  conflict witness. A witness can reject that draft. An inconclusive result
  must proceed through Home's stronger model, fidelity and runtime admission
  gates before any rule can activate.
  """

  alias WotexHome.Rules.{Compiler, Rule}
  alias WotexHome.Semantics.Value

  @type result :: %{
          decision: :rejected | :inconclusive,
          reason: atom(),
          source_digest: String.t(),
          checker_receipt: ExMaude.Verification.Receipt.t() | nil,
          model_binding: map()
        }

  @spec screen([Rule.t()]) :: {:ok, result()} | {:error, atom()}
  def screen(rules) when is_list(rules) and length(rules) > 0 and length(rules) <= 64 do
    with {:ok, model} <- compile_model(rules) do
      translated = model.rules
      source_digest = digest(model)

      case ExMaude.IoT.detect_conflicts_with_receipt(translated,
             conflict_types: [:state_conflict],
             timeout: 5_000,
             max_response_bytes: 1_048_576,
             max_witness_bytes: 16_384
           ) do
        {:ok, receipt} ->
          {decision, reason} = decision(receipt)

          {:ok,
           %{
             decision: decision,
             reason: reason,
             source_digest: source_digest,
             checker_receipt: receipt,
             model_binding: Map.delete(model, :rules)
           }}

        {:error, _reason} ->
          {:ok,
           %{
             decision: :inconclusive,
             reason: :checker_unavailable_or_failed,
             source_digest: source_digest,
             checker_receipt: nil,
             model_binding: Map.delete(model, :rules)
           }}
      end
    end
  end

  def screen(_rules), do: {:error, :invalid_rule_set}

  @spec translate_rules([Rule.t()]) ::
          {:ok, [map()]} | {:error, :unsupported_model_semantics | :invalid_rule_set}
  def translate_rules(rules)
      when is_list(rules) and length(rules) > 0 and length(rules) <= 64 do
    with {:ok, model} <- compile_model(rules), do: {:ok, model.rules}
  end

  def translate_rules(_rules), do: {:error, :invalid_rule_set}

  @doc "Compile the explicitly negative projection, with complete Home IR identity and omissions."
  def compile_model(rules) do
    with {:ok, program} <- Compiler.compile(rules),
         {:ok, translated} <- translate_entries(program.entries) do
      {:ok,
       %{
         compiler_profile: program.profile,
         source_digest: program.source_digest,
         ir_digest: program.ir_digest,
         model_profile: "bundled-iot-v1/state-conflict-projection-v1",
         scope: :negative_state_conflict_only,
         omissions: [
           :source_revision,
           :explicit_event_identity,
           :cooldown,
           :ownership,
           :causal_budget,
           :current_authority,
           :runtime_gate,
           :effect_domain_arbitration,
           :dispatch_uncertainty
         ],
         rules: translated
       }}
    end
  end

  defp translate_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn rule, {:ok, translated} ->
      case translate_rule(rule) do
        {:ok, item} -> {:cont, {:ok, [item | translated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, translated} -> {:ok, Enum.reverse(translated)}
      error -> error
    end
  end

  defp translate_rule(%{
         id: id,
         trigger: {:explicit_request, nil},
         predicate_code: [:literal_true],
         effect: {target_id, key, %Value{kind: :boolean, data: value}},
         authority_class: :automation,
         unknown_policy: :block
       })
       when is_binary(id) and is_binary(target_id) and is_binary(key) and is_boolean(value) do
    {:ok,
     %{
       id: id,
       thing_id: target_id,
       trigger: {:always},
       actions: [{:set_prop, target_id, key, value}],
       priority: 1
     }}
  end

  defp translate_rule(_rule), do: {:error, :unsupported_model_semantics}

  defp decision(%ExMaude.Verification.Receipt{
         semantic: %{profile: "bundled-iot-v1", operation: :conflicts},
         execution: %{completion: :bounded_complete, findings: findings}
       })
       when is_list(findings) do
    if Enum.any?(findings, &match?(%{type: :state_conflict}, &1)),
      do: {:rejected, :state_conflict},
      else: {:inconclusive, :no_matching_conflict}
  end

  defp decision(_receipt), do: {:inconclusive, :checker_incomplete_or_untrusted}

  defp digest(rules) do
    rules
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
