defmodule ExMaude.AI.Encoder do
  @moduledoc """
  Encodes Elixir AI rule structures into Maude syntax compatible with
  the bundled `ai-rules.maude` module.

  Companion to `ExMaude.IoT.Encoder`. Where the IoT encoder handles
  Things, Properties, and Actions, this encoder handles Agents,
  Capabilities, ToolInvocations, and richer predicates (capability,
  budget, jurisdiction, authority).

  ## Type mapping

  | Elixir term | Maude syntax |
  |-------------|--------------|
  | `{"acme", "ag-1"}` (agent id) | `agent(tenant("acme"), "ag-1")` |
  | `{:str, "x"}` | `strVal("x")` |
  | `{:int, 42}` | `intVal("42")` |
  | `{:bool, true}` | `boolVal(true)` |
  | `{:interval, lo, hi}` | `intervalVal(lo, hi)` |
  | `{:jurisdiction, :eu}` | `jurisdictionVal(eu)` |
  | `{:cap, "web_search", "shape_v1"}` | `cap("web_search", "shape_v1")` |
  | `{:invoke_tool, name, args, cap_required, jurisdiction}` | `invokeTool(tool("name"), argMap, "cap", eu)` |
  | `{:require_approval, class}` | `requireApproval("class")` |

  ## Predicate mapping

  | Elixir | Maude |
  |--------|-------|
  | `{:prop_eq, key, val}` | `propEq("key", val)` |
  | `{:capability_required, name}` | `capabilityRequired("name")` |
  | `{:capability_granted, name}` | `capabilityGranted("name")` |
  | `{:budget_within, scope, interval}` | `budgetWithin("scope", intervalVal(...))` |
  | `{:authority_at_least, n}` | `authorityAtLeast(n)` |
  | `{:jurisdiction_allowed, j}` | `jurisdictionAllowed(eu)` |
  | `{:latency_at_most, ms}` | `latencyAtMost(ms)` |
  | `{:always}` | `alwaysP` |
  | `{:and, p1, p2}` | `andP(p1, p2)` |
  | `{:or, p1, p2}` | `orP(p1, p2)` |
  | `{:not, p}` | `notP(p)` |
  """

  @doc """
  Encodes a list of AI rules into Maude rule-set syntax.

  Returns `{:ok, maude_string}` on success.

  ## Examples

      iex> rules = [%{id: "r1", agent_id: {"acme", "ag-1"}, trigger: {:always}, invocations: []}]
      ...> ExMaude.AI.Encoder.encode_rules(rules)
      {:ok, ~s|aiRule("r1", agent(tenant("acme"), "ag-1"), alwaysP, nilInvocation, noCap, 0, 1)|}

      iex> ExMaude.AI.Encoder.encode_rules([])
      {:ok, "emptyRules"}
  """
  @spec encode_rules([ExMaude.AI.ai_rule()]) :: {:ok, String.t()}
  def encode_rules([]), do: {:ok, "emptyRules"}

  def encode_rules(rules) when is_list(rules) do
    {:ok, Enum.map_join(rules, " ; ", &encode_rule/1)}
  end

  @doc """
  Encodes a single AI rule into Maude syntax.
  """
  @spec encode_rule(ExMaude.AI.ai_rule()) :: String.t()
  def encode_rule(rule) do
    id = encode_string(rule.id)
    agent = encode_agent_id(rule.agent_id)
    trigger = encode_predicate(rule.trigger)
    invocations = encode_invocations(rule.invocations)
    cap_grants = encode_capability_set(Map.get(rule, :capability_grants, []))
    authority_required = Map.get(rule, :authority_required, 0)
    priority = Map.get(rule, :priority, 1)

    "aiRule(#{id}, #{agent}, #{trigger}, #{invocations}, #{cap_grants}, #{authority_required}, #{priority})"
  end

  @doc """
  Encodes a jurisdiction set into Maude syntax.

  Used as the second argument to `detectAllConflicts/2` and similar
  facade operations.

  ## Examples

      iex> ExMaude.AI.Encoder.encode_jurisdiction_set([:eu, :us])
      "eu ;; us"

      iex> ExMaude.AI.Encoder.encode_jurisdiction_set([])
      "noJurisdiction"
  """
  @spec encode_jurisdiction_set([atom()]) :: String.t()
  def encode_jurisdiction_set([]), do: "noJurisdiction"

  def encode_jurisdiction_set(jurisdictions) when is_list(jurisdictions) do
    Enum.map_join(jurisdictions, " ;; ", &Atom.to_string/1)
  end

  @doc false
  @spec encode_agent_id({String.t(), String.t()}) :: String.t()
  def encode_agent_id({tenant_id, agent_name})
      when is_binary(tenant_id) and is_binary(agent_name) do
    "agent(tenant(#{encode_string(tenant_id)}), #{encode_string(agent_name)})"
  end

  @doc false
  @spec encode_predicate(ExMaude.AI.predicate()) :: String.t()
  def encode_predicate({:prop_eq, key, value}) do
    "propEq(#{encode_string(key)}, #{encode_value(value)})"
  end

  def encode_predicate({:prop_gt, key, value}) do
    "propGt(#{encode_string(key)}, #{encode_value(value)})"
  end

  def encode_predicate({:prop_lt, key, value}) do
    "propLt(#{encode_string(key)}, #{encode_value(value)})"
  end

  def encode_predicate({:prop_gte, key, value}) do
    "propGte(#{encode_string(key)}, #{encode_value(value)})"
  end

  def encode_predicate({:prop_lte, key, value}) do
    "propLte(#{encode_string(key)}, #{encode_value(value)})"
  end

  def encode_predicate({:capability_required, name}) when is_binary(name) do
    "capabilityRequired(#{encode_string(name)})"
  end

  def encode_predicate({:capability_granted, name}) when is_binary(name) do
    "capabilityGranted(#{encode_string(name)})"
  end

  def encode_predicate({:budget_within, scope, interval}) when is_binary(scope) do
    "budgetWithin(#{encode_string(scope)}, #{encode_value(interval)})"
  end

  def encode_predicate({:authority_at_least, level}) when is_integer(level) and level >= 0 do
    "authorityAtLeast(#{level})"
  end

  def encode_predicate({:authority_required, level}) when is_integer(level) and level >= 0 do
    "authorityRequired(#{level})"
  end

  def encode_predicate({:jurisdiction_allowed, j}) when is_atom(j) do
    "jurisdictionAllowed(#{Atom.to_string(j)})"
  end

  def encode_predicate({:jurisdiction_forbidden, j}) when is_atom(j) do
    "jurisdictionForbidden(#{Atom.to_string(j)})"
  end

  def encode_predicate({:latency_at_most, ms}) when is_integer(ms) and ms >= 0 do
    "latencyAtMost(#{ms})"
  end

  def encode_predicate({:always}), do: "alwaysP"

  def encode_predicate({:and, p1, p2}) do
    "andP(#{encode_predicate(p1)}, #{encode_predicate(p2)})"
  end

  def encode_predicate({:or, p1, p2}) do
    "orP(#{encode_predicate(p1)}, #{encode_predicate(p2)})"
  end

  def encode_predicate({:not, p}) do
    "notP(#{encode_predicate(p)})"
  end

  @doc false
  @spec encode_invocations([ExMaude.AI.tool_invocation()]) :: String.t()
  def encode_invocations([]), do: "nilInvocation"

  def encode_invocations(invocations) when is_list(invocations) do
    Enum.map_join(invocations, " >> ", &encode_invocation/1)
  end

  @doc false
  @spec encode_invocation(ExMaude.AI.tool_invocation()) :: String.t()
  def encode_invocation({:invoke_tool, name, args, cap_required, jurisdiction})
      when is_binary(name) and is_map(args) and is_binary(cap_required) and is_atom(jurisdiction) do
    encoded_args = encode_arg_map(args)
    args_term = if map_size(args) == 0, do: encoded_args, else: "(#{encoded_args})"

    "invokeTool(tool(#{encode_string(name)}), #{args_term}, #{encode_string(cap_required)}, #{Atom.to_string(jurisdiction)})"
  end

  def encode_invocation({:require_approval, class}) when is_binary(class) do
    "requireApproval(#{encode_string(class)})"
  end

  @doc false
  @spec encode_capability_set([ExMaude.AI.capability()]) :: String.t()
  def encode_capability_set([]), do: "noCap"

  def encode_capability_set(caps) when is_list(caps) do
    Enum.map_join(caps, " || ", &encode_capability/1)
  end

  @doc false
  @spec encode_capability(ExMaude.AI.capability()) :: String.t()
  def encode_capability({:cap, name, shape}) when is_binary(name) and is_binary(shape) do
    "cap(#{encode_string(name)}, #{encode_string(shape)})"
  end

  def encode_capability(name) when is_binary(name) do
    # Default shape signature for capabilities passed as bare strings
    "cap(#{encode_string(name)}, #{encode_string("default")})"
  end

  @doc false
  @spec encode_arg_map(map()) :: String.t()
  def encode_arg_map(args) when args == %{}, do: "argMap"

  def encode_arg_map(args) when is_map(args) do
    args
    |> Enum.sort()
    |> Enum.map_join(" andArg ", fn {k, v} ->
      "(#{encode_string(to_string(k))} : #{encode_value(v)})"
    end)
  end

  @doc false
  @spec encode_value(ExMaude.AI.value()) :: String.t()
  def encode_value({:str, s}) when is_binary(s), do: "strVal(#{encode_string(s)})"

  def encode_value({:int, n}) when is_integer(n),
    do: "intVal(#{encode_string(Integer.to_string(n))})"

  def encode_value({:bool, b}) when is_boolean(b), do: "boolVal(#{b})"

  def encode_value({:interval, lo, hi})
      when is_integer(lo) and is_integer(hi) and lo >= 0 and hi >= 0 and lo <= hi do
    "intervalVal(#{lo}, #{hi})"
  end

  def encode_value({:jurisdiction, j}) when is_atom(j),
    do: "jurisdictionVal(#{Atom.to_string(j)})"

  def encode_value(nil), do: "null"

  def encode_value(s) when is_binary(s), do: "strVal(#{encode_string(s)})"
  def encode_value(n) when is_integer(n), do: "intVal(#{encode_string(Integer.to_string(n))})"
  def encode_value(b) when is_boolean(b), do: "boolVal(#{b})"

  @doc false
  @spec encode_string(String.t()) :: String.t()
  def encode_string(s) when is_binary(s), do: ExMaude.Syntax.encode_string(s)
end
