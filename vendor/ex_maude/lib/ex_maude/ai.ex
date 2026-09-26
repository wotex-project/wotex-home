defmodule ExMaude.AI do
  @moduledoc """
  AI rule conflict detection using a Maude equational model.

  Companion to `ExMaude.IoT`. Where `ExMaude.IoT` analyzes physical-
  IoT automation rules over Things, Properties, and Actions, this
  module analyzes AI-generated automation rules over Agents,
  Capabilities, ToolInvocations, and richer predicates (capability,
  budget, jurisdiction, authority, approval).

  Targets the bundled `priv/maude/ai-rules.maude` template.

  ## Conflict types

  Seven conflict types are detected:

    1. `:tool_call_conflict` — same agent, same tool, conflicting
       required arguments
    2. `:capability_shadowing` — two rules grant the same capability
       at equal priority within a tenant
    3. `:pack_tool_composition_mismatch` — same capability name with
       mismatched type-shape signatures
    4. `:sovereignty_violation` — tool invocation routes through a
       jurisdiction outside the tenant's allowed set
    5. `:authority_escalation` — rule grants a capability that
       another rule requires at higher authority
    6. `:approval_gate_bypass` — high-impact invocation reachable
       without traversing an approval gate
    7. `:agent_loop_cascade` — one rule's capability grants another
       rule's required capability (cascade edge)

  ## Usage

      tenant = "acme"

      rules = [
        %{
          id: "approve-then-dose",
          agent_id: {tenant, "ph-controller"},
          trigger: {:prop_lt, "ph", {:int, 6}},
          invocations: [
            {:require_approval, "dosing_high_delta"},
            {:invoke_tool, "dose_chemical",
             %{"chemical" => "ph_up", "ml" => 50}, "high_impact", :eu}
          ],
          capability_grants: [{:cap, "ph_dosing", "v1"}],
          authority_required: 2,
          priority: 1
        },
        %{
          id: "auto-dose",
          agent_id: {tenant, "ph-controller"},
          trigger: {:prop_lt, "ph", {:int, 5}},
          invocations: [
            {:invoke_tool, "dose_chemical",
             %{"chemical" => "ph_up", "ml" => 100}, "high_impact", :eu}
          ],
          capability_grants: [],
          authority_required: 0,
          priority: 1
        }
      ]

      {:ok, conflicts} = ExMaude.AI.detect_conflicts(rules, jurisdictions: [:eu])
      # => [%{type: :approval_gate_bypass, rule1: "auto-dose", rule2: nil, ...}]

  ## Telemetry

  Emits `[:ex_maude, :ai, :detect_conflicts, :start | :stop]` events
  with measurements `:duration`, `:rule_count`, `:conflict_count`
  and metadata including `:result` and `:template` (`:ai_rules`).

  See `ExMaude.Telemetry` for full event documentation.
  """

  alias ExMaude.AI.{ConflictParser, Encoder, Validator}
  alias ExMaude.{Config, Maude}

  @type tenant_id :: String.t()
  @type agent_id :: {tenant_id(), String.t()}

  @type predicate ::
          {:always}
          | {:prop_eq, String.t(), term()}
          | {:prop_gt, String.t(), term()}
          | {:prop_lt, String.t(), term()}
          | {:prop_gte, String.t(), term()}
          | {:prop_lte, String.t(), term()}
          | {:capability_required, String.t()}
          | {:capability_granted, String.t()}
          | {:budget_within, String.t(), {:interval, non_neg_integer(), non_neg_integer()}}
          | {:authority_at_least, non_neg_integer()}
          | {:authority_required, non_neg_integer()}
          | {:jurisdiction_allowed, atom()}
          | {:jurisdiction_forbidden, atom()}
          | {:latency_at_most, non_neg_integer()}
          | {:and, predicate(), predicate()}
          | {:or, predicate(), predicate()}
          | {:not, predicate()}

  @type tool_invocation ::
          {:invoke_tool, name :: String.t(), args :: map(), capability_required :: String.t(),
           jurisdiction :: atom()}
          | {:require_approval, class :: String.t()}

  @type capability ::
          {:cap, name :: String.t(), shape_hash :: String.t()}
          | String.t()

  @type value ::
          {:str, String.t()}
          | {:int, integer()}
          | {:bool, boolean()}
          | {:interval, non_neg_integer(), non_neg_integer()}
          | {:jurisdiction, atom()}
          | nil
          | String.t()
          | integer()
          | boolean()

  @type ai_rule :: %{
          required(:id) => String.t(),
          required(:agent_id) => agent_id(),
          required(:trigger) => predicate(),
          required(:invocations) => [tool_invocation()],
          optional(:capability_grants) => [capability()],
          optional(:authority_required) => non_neg_integer(),
          optional(:priority) => non_neg_integer()
        }

  @type conflict :: ConflictParser.conflict()

  @doc """
  Detects all AI-rule conflicts in a rule set.

  ## Options

    * `:jurisdictions` — list of allowed jurisdiction atoms for the
      tenant (default `[]` which disables sovereignty checking — pass
      explicit allowed set to enable)
    * `:timeout` — Maude command timeout in milliseconds (default
      10_000)
    * `:pool` — registered caller-owned pool (default `:ex_maude_pool`)

  ## Examples

      {:ok, conflicts} = ExMaude.AI.detect_conflicts(rules, jurisdictions: [:eu, :ch])
  """
  @spec detect_conflicts([ai_rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(10_000))
    jurisdictions = Keyword.get(opts, :jurisdictions, [])
    rule_count = ExMaude.Validation.list_count(rules)
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ex_maude, :ai, :detect_conflicts, :start],
      %{system_time: System.system_time(), rule_count: rule_count},
      %{template: :ai_rules}
    )

    result =
      with :ok <- Validator.validate_rules(rules),
           :ok <- Validator.validate_jurisdictions(jurisdictions),
           :ok <- ensure_ai_module_loaded(opts),
           {:ok, maude_rules} <- Encoder.encode_rules(rules),
           jurisdiction_set = Encoder.encode_jurisdiction_set(jurisdictions),
           {:ok, output} <- run_detection(maude_rules, jurisdiction_set, timeout, opts) do
        ConflictParser.parse_result(output)
      end

    duration = System.monotonic_time() - start_time

    {result_atom, conflict_count} =
      case result do
        {:ok, conflicts} -> {:ok, length(conflicts)}
        {:error, _} -> {:error, 0}
      end

    :telemetry.execute(
      [:ex_maude, :ai, :detect_conflicts, :stop],
      %{duration: duration, conflict_count: conflict_count},
      %{result: result_atom, template: :ai_rules}
    )

    result
  end

  @doc """
  Detects only pairwise conflicts (tool-call, capability shadowing,
  pack-tool composition, authority escalation, agent-loop cascade).

  Skips single-rule conflicts (sovereignty, approval-gate bypass).
  """
  @spec detect_pair_conflicts([ai_rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_pair_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(10_000))

    with :ok <- Validator.validate_rules(rules),
         :ok <- ensure_ai_module_loaded(opts),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         command =
           "reduce in AI-CONFLICT-DETECTOR : detectAllPairConflicts(#{maude_rules}) .",
         {:ok, output} <- Maude.execute(command, maude_opts(opts, timeout)) do
      ConflictParser.parse_result(output)
    end
  end

  @doc """
  Detects only sovereignty + approval-gate conflicts (single-rule
  conflicts independent of pair analysis).

  Requires `:jurisdictions` option for sovereignty checking. Approval-
  gate bypass detection runs regardless of jurisdiction set.
  """
  @spec detect_single_rule_conflicts([ai_rule()], keyword()) ::
          {:ok, [conflict()]} | {:error, term()}
  def detect_single_rule_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(10_000))
    jurisdictions = Keyword.get(opts, :jurisdictions, [])

    with :ok <- Validator.validate_rules(rules),
         :ok <- Validator.validate_jurisdictions(jurisdictions),
         :ok <- ensure_ai_module_loaded(opts),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         jurisdiction_set = Encoder.encode_jurisdiction_set(jurisdictions),
         command =
           "reduce in AI-CONFLICT-DETECTOR : detectAllSingleRuleConflicts(#{maude_rules}, #{jurisdiction_set}) .",
         {:ok, output} <- Maude.execute(command, maude_opts(opts, timeout)) do
      ConflictParser.parse_result(output)
    end
  end

  @doc """
  Validates an AI rule structure without sending it to Maude.

  Returns `:ok` if the rule is valid, or `{:error, errors}` with a
  list of validation error messages.
  """
  @spec validate_rule(ai_rule()) :: :ok | {:error, [String.t()]}
  defdelegate validate_rule(rule), to: Validator

  @doc """
  Validates a list of AI rules. Returns `:ok` if all are valid, or
  `{:error, %{rule_id => [errors]}}`.
  """
  @spec validate_rules([ai_rule()]) :: :ok | {:error, %{String.t() => [String.t()]}}
  defdelegate validate_rules(rules), to: Validator

  defp ensure_ai_module_loaded(opts) do
    path = ExMaude.ai_rules_path()

    if File.exists?(path) do
      ExMaude.ensure_file_loaded(path, pool: Keyword.get(opts, :pool, :ex_maude_pool))
    else
      {:error, {:module_not_found, path}}
    end
  end

  defp run_detection(maude_rules, jurisdiction_set, timeout, opts) do
    command =
      "reduce in AI-CONFLICT-DETECTOR : detectAllConflicts(#{maude_rules}, #{jurisdiction_set}) ."

    Maude.execute(command, maude_opts(opts, timeout))
  end

  defp maude_opts(opts, timeout),
    do: [timeout: timeout, pool: Keyword.get(opts, :pool, :ex_maude_pool)]
end
