defmodule ExMaude.IoT do
  @moduledoc """
  IoT rule conflict detection using a Maude equational model.

  This module evaluates IoT automation rules with the bundled Maude model. Its
  four checks are inspired by conflict categories in the AutoIoT paper
  (arxiv.org/abs/2411.10665):

  ## Conflict Types

  1. **State Conflict** - Two rules target the same device property with
     incompatible values. Example: motion sensor turns light on while
     time-based rule turns it off.

  2. **Environment Conflict** - Two rules produce opposing environmental
     effects. Example: one rule opens a window to cool, another closes it
     to reduce noise.

  3. **State Cascade** - A rule's output triggers another rule, creating
     unexpected chains. Example: door open → light on → play sound →
     light off creates oscillation.

  4. **State-Environment Cascade** - Combined state and environment effects
     cascade through multiple rules. Example: AC on → window closes →
     CO2 rises → window opens → conflicts with AC.

  ## Usage

      # Define rules
      rules = [
        %{
          id: "motion-light",
          thing_id: "light-1",
          trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "light-1", "state", "on"}],
          priority: 1
        },
        %{
          id: "night-light",
          thing_id: "light-1",
          trigger: {:prop_gt, "time", 2300},
          actions: [{:set_prop, "light-1", "state", "off"}],
          priority: 1
        }
      ]

      # Detect conflicts (the bundled iot-rules.maude module is loaded
      # automatically on first call)
      {:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)
      # => [%{type: :state_conflict, rule1: "motion-light", rule2: "night-light", ...}]

  ## Telemetry

  This module emits the following telemetry events:

  - `[:ex_maude, :iot, :detect_conflicts, :start]` - Emitted when detection begins
  - `[:ex_maude, :iot, :detect_conflicts, :stop]` - Emitted when detection completes

  Measurements include `:duration` in native time units, `:rule_count`, and
  `:conflict_count`. Metadata includes `:result` (`:ok` or `:error`) and
  `:template` (`:iot_rules`).

  See `ExMaude.Telemetry` for full event documentation and integration examples.
  """

  alias ExMaude.{Command, Config, Maude}
  alias ExMaude.IoT.{ConflictParser, Encoder, ReceiptRun, Validator}

  @type thing_id :: String.t()

  @type trigger ::
          {:prop_eq, String.t(), term()}
          | {:prop_gt, String.t(), number()}
          | {:prop_lt, String.t(), number()}
          | {:prop_gte, String.t(), number()}
          | {:prop_lte, String.t(), number()}
          | {:env_eq, String.t(), term()}
          | {:env_gt, String.t(), number()}
          | {:env_lt, String.t(), number()}
          | {:always}
          | {:and, trigger(), trigger()}
          | {:or, trigger(), trigger()}
          | {:not, trigger()}

  @type action ::
          {:set_prop, thing_id(), String.t(), term()}
          | {:set_env, String.t(), term()}
          | {:invoke, thing_id(), String.t()}

  @type rule :: %{
          required(:id) => String.t(),
          required(:thing_id) => thing_id(),
          required(:trigger) => trigger(),
          required(:actions) => [action()],
          optional(:priority) => non_neg_integer()
        }

  @type conflict_type :: :state_conflict | :env_conflict | :state_cascade | :state_env_cascade
  @conflict_types [:state_conflict, :env_conflict, :state_cascade, :state_env_cascade]

  @type conflict :: %{
          type: conflict_type(),
          rule1: String.t(),
          rule2: String.t(),
          reason: String.t()
        }

  @doc """
  Detects all conflicts in a set of IoT rules.

  Evaluates the given rules against all four checks in the bundled Maude
  model. Returns a list of detected conflicts, or an empty list if none of
  those checks match.

  ## Examples

      rules = [
        %{id: "r1", thing_id: "light-1", trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "light-1", "state", "on"}], priority: 1},
        %{id: "r2", thing_id: "light-1", trigger: {:prop_gt, "time", 2300},
          actions: [{:set_prop, "light-1", "state", "off"}], priority: 1}
      ]

      {:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)
      [%{type: :state_conflict, rule1: "r1", rule2: "r2", reason: _}] = conflicts

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 10000)
    * `:conflict_types` - List of conflict types to check (default: all)
    * `:pool` - Registered caller-owned pool (default: `:ex_maude_pool`)
  """
  @spec detect_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(10_000))
    rule_count = ExMaude.Validation.list_count(rules)
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ex_maude, :iot, :detect_conflicts, :start],
      %{system_time: System.system_time(), rule_count: rule_count},
      %{template: :iot_rules}
    )

    result =
      with :ok <- Validator.validate_rules(rules),
           :ok <- ensure_iot_module_loaded(opts),
           {:ok, maude_rules} <- Encoder.encode_rules(rules),
           {:ok, output} <- run_detection(maude_rules, timeout, opts) do
        with {:ok, conflicts} <- ConflictParser.parse_result(output) do
          filter_conflicts(conflicts, Keyword.get(opts, :conflict_types))
        end
      end

    duration = System.monotonic_time() - start_time

    {result_atom, conflict_count} =
      case result do
        {:ok, conflicts} -> {:ok, length(conflicts)}
        {:error, _} -> {:error, 0}
      end

    :telemetry.execute(
      [:ex_maude, :iot, :detect_conflicts, :stop],
      %{duration: duration, conflict_count: conflict_count},
      %{result: result_atom, template: :iot_rules}
    )

    result
  end

  @doc """
  Detects only state conflicts in a set of rules.

  State conflicts occur when two rules target the same device property
  with incompatible values.

  ## Examples

      {:ok, conflicts} = ExMaude.IoT.detect_state_conflicts(rules)
  """
  @spec detect_state_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_state_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(10_000))

    with :ok <- Validator.validate_rules(rules),
         :ok <- ensure_iot_module_loaded(opts),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         command = "reduce in CONFLICT-DETECTOR : detectConflicts(#{maude_rules}) .",
         {:ok, output} <- Maude.execute(command, maude_opts(opts, timeout)) do
      ConflictParser.parse_result(output)
    end
  end

  @doc """
  Detects only environment conflicts in a set of rules.

  Environment conflicts occur when two rules produce opposing
  environmental effects.
  """
  @spec detect_env_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_env_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(10_000))

    with :ok <- Validator.validate_rules(rules),
         :ok <- ensure_iot_module_loaded(opts),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         command = "reduce in CONFLICT-DETECTOR : detectEnvConflicts(#{maude_rules}) .",
         {:ok, output} <- Maude.execute(command, maude_opts(opts, timeout)) do
      ConflictParser.parse_result(output)
    end
  end

  @doc """
  Detects cascade conflicts (both state and state-environment).

  Cascade conflicts occur when one rule's output triggers another rule.
  """
  @spec detect_cascade_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_cascade_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(10_000))

    with :ok <- Validator.validate_rules(rules),
         :ok <- ensure_iot_module_loaded(opts),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         command = "reduce in CONFLICT-DETECTOR : detectCascades(#{maude_rules}) .",
         {:ok, output} <- Maude.execute(command, maude_opts(opts, timeout)) do
      ConflictParser.parse_result(output)
    end
  end

  @doc """
  Validates a rule structure without sending it to Maude.

  Returns `:ok` if the rule is valid, or `{:error, errors}` with a list
  of validation error messages.

  ## Examples

      :ok = ExMaude.IoT.validate_rule(%{
        id: "my-rule",
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true},
        actions: [{:set_prop, "device-1", "power", "on"}]
      })

      {:error, ["missing required field: id"]} = ExMaude.IoT.validate_rule(%{})
  """
  @spec validate_rule(rule()) :: :ok | {:error, [String.t()]}
  defdelegate validate_rule(rule), to: Validator

  @doc """
  Validates a list of rules.

  Returns `:ok` if all rules are valid, or `{:error, errors}` with a map
  of rule IDs to their validation errors.
  """
  @spec validate_rules([rule()]) :: :ok | {:error, %{String.t() => [String.t()]}}
  defdelegate validate_rules(rules), to: Validator

  @typedoc """
  A predicate over a world state: a device property holding a value, or an
  environment key holding a value.
  """
  @type state_pred ::
          {:thing_state, thing_id(), String.t(), term()}
          | {:env_state, String.t(), term()}

  @typedoc """
  Options for the state-space verification functions.

    * `:initial_state` - bindings present before any rule fires (default `[]`)
    * `:max_depth` - bound on search depth (default `50`); unbounded searches
      that hit the bound return `{:ok, :unverified}` rather than blocking
    * `:timeout` - per-search timeout in ms (default `30_000`)
    * `:pool` - registered caller-owned pool (default `:ex_maude_pool`)
  """
  @type world_opts :: [
          initial_state: [state_pred()],
          max_depth: pos_integer(),
          timeout: timeout(),
          pool: atom()
        ]

  @doc """
  Searches a bounded execution prefix for a world matching `bad_state`.

  Explores the rule-firing transition system (the `IOT-EXEC` Maude module) from
  the initial state with `=>*` reachability search, looking for a reachable
  world whose state contains `bad_state`.

  Returns:

    * `{:error, {:counterexample, solutions}}` - a reachable bad world (the
      `solutions` carry the matching state/substitution)
    * `{:ok, :unverified}` - no counterexample was found within the bound, or
      Maude was unavailable/timed out. A bounded prefix is not a safety proof.
    * `{:error, %ExMaude.Error{}}` - the verification itself failed (e.g.
      a rule that doesn't encode to valid Maude, or a missing module);
      surfaced as an error rather than `:unverified` because it indicates a
      bug in the input, not an inconclusive search

  `bad_state` is a `state_pred` or a list of them (a list means "all present in
  the same reachable world"). An empty list matches every world. Malformed
  targets return a validation error before pool access.

  ## Examples

      # Rule drives a door into an error state when motion is detected.
      rules = [%{id: "r1", thing_id: "door", trigger: {:prop_eq, "motion", true},
                 actions: [{:set_prop, "door", "state", "error"}], priority: 1}]

      ExMaude.IoT.verify_safety(rules, {:thing_state, "door", "state", "error"},
        initial_state: [{:thing_state, "door", "motion", true}])
      #=> {:error, {:counterexample, [_ | _]}}
  """
  @spec verify_safety([rule()], state_pred() | [state_pred()], world_opts()) ::
          {:ok, :unverified}
          | {:error, {:counterexample, [map()]} | ExMaude.Error.t() | term()}
  def verify_safety(rules, bad_state, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 50)
    timeout = Keyword.get(opts, :timeout, Config.timeout(30_000))

    with :ok <- Validator.validate_rules(rules),
         :ok <- validate_world_inputs(bad_state, opts, :safety),
         :ok <- ensure_iot_module_loaded(opts),
         {:ok, init} <- build_world(rules, opts),
         pattern = bad_state_pattern(bad_state),
         {:ok, solutions} <-
           Maude.search("IOT-EXEC", init, pattern,
             arrow: "=>*",
             max_solutions: 1,
             max_depth: max_depth,
             timeout: timeout,
             pool: Keyword.get(opts, :pool, :ex_maude_pool)
           ) do
      case solutions do
        [] -> {:ok, :unverified}
        [_ | _] -> {:error, {:counterexample, solutions}}
      end
    else
      {:error, err} -> verification_failure(err)
    end
  end

  @doc """
  Bounded liveness check: looks for a deadlock that prevents `rules` from
  reaching `goal_state`.

  Searches for a terminal world (`=>!`, no rule can fire) in which `goal_state`
  does not hold. Because the search only inspects terminal states, this detects
  deadlocks (the system stops short of the goal); it does not detect livelocks
  (infinite progress that never reaches the goal), which need full LTL model
  checking.

  `goal_state` must be one state predicate; lists and `nil` return a validation
  error before pool access.

  Returns:

    * `{:error, :deadlock_possible}` - a reachable terminal world misses the goal
    * `{:ok, :unverified}` - no counterexample was found within the bound, or
      Maude was unavailable/timed out. This is not an unbounded liveness proof.
    * `{:error, %ExMaude.Error{}}` - the verification itself failed (invalid
      rule encoding, missing module, ...)

  ## Examples

      ExMaude.IoT.verify_liveness(rules, {:thing_state, "door", "state", "notified"})
      #=> {:ok, :unverified}
  """
  @spec verify_liveness([rule()], state_pred(), world_opts()) ::
          {:ok, :unverified}
          | {:error, :deadlock_possible | ExMaude.Error.t() | term()}
  def verify_liveness(rules, goal_state, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 50)
    timeout = Keyword.get(opts, :timeout, Config.timeout(30_000))

    with :ok <- Validator.validate_rules(rules),
         :ok <- validate_world_inputs(goal_state, opts, :liveness),
         :ok <- ensure_iot_module_loaded(opts),
         {:ok, init} <- build_world(rules, opts),
         condition = goal_violation_condition(goal_state),
         {:ok, solutions} <-
           Maude.search("IOT-EXEC", init, "world(S:WState, RS:RuleSet)",
             arrow: "=>!",
             condition: condition,
             max_solutions: 1,
             max_depth: max_depth,
             timeout: timeout,
             pool: Keyword.get(opts, :pool, :ex_maude_pool)
           ) do
      case solutions do
        [] -> {:ok, :unverified}
        [_ | _] -> {:error, :deadlock_possible}
      end
    else
      {:error, err} -> verification_failure(err)
    end
  end

  @doc """
  Runs the four bundled conflict checks in an isolated Port worker and returns
  a versioned verification receipt. The receipt records a completed equational
  check or a failure disposition; it does not authorize device actuation.

  `:timeout` is the entire run deadline. `:max_response_bytes` and
  `:max_witness_bytes` bound returned evidence. `:assumptions` records caller
  assertions without treating them as measured facts. Receipt runs do not use
  a shared pool and reject `:pool`.
  """
  @spec detect_conflicts_with_receipt([rule()], keyword()) ::
          {:ok, ExMaude.Verification.Receipt.t()} | {:error, ExMaude.Error.t() | term()}
  def detect_conflicts_with_receipt(rules, opts \\ []) do
    clock = ReceiptRun.start_clock()

    with :ok <- Validator.validate_rules(rules),
         :ok <- validate_conflict_types(Keyword.get(opts, :conflict_types)),
         {:ok, encoded} <- Encoder.encode_rules(rules) do
      command = "reduce in CONFLICT-DETECTOR : detectAllConflicts(#{encoded}) ."

      ReceiptRun.run(
        :conflicts,
        command,
        %{rules: rules, selection: Keyword.get(opts, :conflict_types)},
        opts,
        clock
      )
    end
  end

  @doc """
  Searches for a reachable bad state and returns a versioned receipt.

  A completed run with no finding means only that this bounded search found no
  matching state. A finding contains the returned state/substitution, not a
  reconstructed trace.
  """
  @spec verify_safety_with_receipt([rule()], state_pred() | [state_pred()], keyword()) ::
          {:ok, ExMaude.Verification.Receipt.t()} | {:error, ExMaude.Error.t() | term()}
  def verify_safety_with_receipt(rules, bad_state, opts \\ []) do
    clock = ReceiptRun.start_clock()

    with :ok <- Validator.validate_rules(rules),
         :ok <- validate_world_inputs(bad_state, opts, :safety),
         {:ok, initial} <- build_world(rules, opts) do
      command =
        Command.search("IOT-EXEC", initial, bad_state_pattern(bad_state),
          arrow: "=>*",
          max_solutions: 1,
          max_depth: Keyword.get(opts, :max_depth, 50)
        )

      ReceiptRun.run(
        :safety,
        command,
        %{rules: rules, initial_state: Keyword.get(opts, :initial_state, []), target: bad_state},
        opts,
        clock
      )
    end
  end

  @doc """
  Searches for a reachable terminal world that misses the goal and returns a
  versioned receipt. This check does not detect livelock or prove liveness.
  """
  @spec verify_liveness_with_receipt([rule()], state_pred(), keyword()) ::
          {:ok, ExMaude.Verification.Receipt.t()} | {:error, ExMaude.Error.t() | term()}
  def verify_liveness_with_receipt(rules, goal_state, opts \\ []) do
    clock = ReceiptRun.start_clock()

    with :ok <- Validator.validate_rules(rules),
         :ok <- validate_world_inputs(goal_state, opts, :liveness),
         {:ok, initial} <- build_world(rules, opts) do
      command =
        Command.search("IOT-EXEC", initial, "world(S:WState, RS:RuleSet)",
          arrow: "=>!",
          condition: goal_violation_condition(goal_state),
          max_solutions: 1,
          max_depth: Keyword.get(opts, :max_depth, 50)
        )

      ReceiptRun.run(
        :deadlock,
        command,
        %{rules: rules, initial_state: Keyword.get(opts, :initial_state, []), target: goal_state},
        opts,
        clock
      )
    end
  end

  # Absence of an answer — pool down, worker missing, command deadline — is
  # not evidence either way and maps to the documented {:ok, :unverified}.
  # Anything else (a rule that encodes to invalid Maude, a missing module,
  # a syntax error) is a bug in the input or this library and must surface
  # as an error rather than masquerade as an inconclusive verification.
  defp verification_failure(%ExMaude.Error{type: type})
       when type in [:timeout, :pool_error, :not_connected],
       do: {:ok, :unverified}

  defp verification_failure(err), do: {:error, err}

  defp build_world(rules, opts) do
    with {:ok, rule_set} <- Encoder.encode_rules(rules) do
      state = build_state(Keyword.get(opts, :initial_state, []))
      {:ok, "world(#{state}, #{rule_set})"}
    end
  end

  defp build_state([]), do: "emptyS"
  defp build_state(preds), do: Enum.map_join(preds, " ", &encode_binding/1)

  defp encode_binding({:thing_state, thing_id, property, value}) do
    "pb(#{Encoder.encode_thing_id(thing_id)}, #{Encoder.encode_string(property)}, #{Encoder.encode_value(value)})"
  end

  defp encode_binding({:env_state, key, value}) do
    "eb(#{Encoder.encode_string(key)}, #{Encoder.encode_value(value)})"
  end

  defp bad_state_pattern(preds) when is_list(preds) do
    "world(#{Enum.map_join(preds, " ", &encode_binding/1)} S:WState, RS:RuleSet)"
  end

  defp bad_state_pattern(pred), do: bad_state_pattern([pred])

  defp goal_violation_condition({:thing_state, thing_id, property, value}) do
    term = "propEq(#{Encoder.encode_string(property)}, #{Encoder.encode_value(value)})"
    "holdsFor(#{term}, #{Encoder.encode_thing_id(thing_id)}, S:WState) =/= true"
  end

  defp goal_violation_condition({:env_state, key, value}) do
    term = "envEq(#{Encoder.encode_string(key)}, #{Encoder.encode_value(value)})"
    ~s|holdsFor(#{term}, thing(""), S:WState) =/= true|
  end

  defp validate_world_inputs(predicate, opts, operation) do
    initial_state = Keyword.get(opts, :initial_state, [])
    max_depth = Keyword.get(opts, :max_depth, 50)
    timeout = Keyword.get(opts, :timeout, Config.timeout(30_000))

    cond do
      not (is_integer(max_depth) and max_depth > 0) ->
        validation_error("max_depth must be a positive integer")

      not (is_integer(timeout) and timeout > 0) ->
        validation_error("timeout must be a positive integer")

      not ExMaude.Validation.proper_list?(initial_state) ->
        validation_error("initial_state must be a list of state predicates")

      not Enum.all?(initial_state, &valid_state_pred?/1) ->
        validation_error("initial_state contains an invalid state predicate")

      not valid_target?(predicate, operation) ->
        validation_error("verification target contains an invalid state predicate")

      true ->
        :ok
    end
  end

  defp valid_target?(predicates, :safety) when is_list(predicates) do
    ExMaude.Validation.proper_list?(predicates) and Enum.all?(predicates, &valid_state_pred?/1)
  end

  defp valid_target?(predicate, _), do: valid_state_pred?(predicate)

  defp valid_state_pred?({:thing_state, thing_id, property, value}) do
    non_empty_string?(thing_id) and non_empty_string?(property) and encodable_value?(value)
  end

  defp valid_state_pred?({:env_state, key, value}) do
    non_empty_string?(key) and encodable_value?(value)
  end

  defp valid_state_pred?(_), do: false

  defp non_empty_string?(value), do: value != "" and ExMaude.Validation.string?(value)

  defp encodable_value?(value) do
    is_boolean(value) or is_number(value) or
      ExMaude.Validation.string?(value) or
      (is_atom(value) and ExMaude.Validation.string?(Atom.to_string(value)))
  end

  defp validation_error(message) do
    {:error, ExMaude.Error.new(:validation, message)}
  end

  defp ensure_iot_module_loaded(opts) do
    path = ExMaude.iot_rules_path()

    if File.exists?(path) do
      ExMaude.ensure_file_loaded(path, pool: Keyword.get(opts, :pool, :ex_maude_pool))
    else
      {:error, {:module_not_found, path}}
    end
  end

  defp run_detection(maude_rules, timeout, opts) do
    command = "reduce in CONFLICT-DETECTOR : detectAllConflicts(#{maude_rules}) ."
    Maude.execute(command, maude_opts(opts, timeout))
  end

  defp maude_opts(opts, timeout),
    do: [timeout: timeout, pool: Keyword.get(opts, :pool, :ex_maude_pool)]

  defp filter_conflicts(conflicts, nil), do: {:ok, conflicts}

  defp filter_conflicts(conflicts, types) when is_list(types) and is_integer(length(types)) do
    if Enum.all?(types, &(&1 in @conflict_types)) do
      {:ok, Enum.filter(conflicts, &(&1.type in types))}
    else
      validation_error("conflict_types contains an unsupported conflict type")
    end
  end

  defp filter_conflicts(_, _), do: validation_error("conflict_types must be a list")

  defp validate_conflict_types(nil), do: :ok

  defp validate_conflict_types(types) when is_list(types) do
    if ExMaude.Validation.proper_list?(types) and Enum.all?(types, &(&1 in @conflict_types)) do
      :ok
    else
      validation_error("conflict_types contains an unsupported conflict type")
    end
  end

  defp validate_conflict_types(_), do: validation_error("conflict_types must be a list")
end
