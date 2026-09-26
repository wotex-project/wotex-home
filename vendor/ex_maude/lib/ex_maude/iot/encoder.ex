defmodule ExMaude.IoT.Encoder do
  @moduledoc """
  Encodes Elixir IoT rule structures into Maude syntax.

  This module handles the conversion of Elixir maps and tuples representing
  IoT rules, triggers, and actions into the corresponding Maude term syntax
  expected by the CONFLICT-DETECTOR module.

  ## Overview

  The encoder transforms Elixir data structures into Maude's term syntax:

  | Elixir Type | Maude Syntax |
  |-------------|--------------|
  | Rule map | `rule(id, thing, trigger, actions, priority)` |
  | Thing ID | `thing("device-id")` |
  | Boolean | `boolVal(true)` or `boolVal(false)` |
  | Integer | `intVal("123")` |
  | String | `strVal("value")` |

  ## Trigger Encoding

  Triggers are encoded into Maude comparison operators:

  | Elixir Trigger | Maude Syntax |
  |----------------|--------------|
  | `{:prop_eq, "temp", 72}` | `propEq("temp", intVal("72"))` |
  | `{:prop_gt, "temp", 80}` | `propGt("temp", intVal("80"))` |
  | `{:env_eq, "time", "night"}` | `envEq("time", strVal("night"))` |
  | `{:always}` | `always` |
  | `{:and, t1, t2}` | `and(t1, t2)` |
  | `{:or, t1, t2}` | `or(t1, t2)` |
  | `{:not, t}` | `not(t)` |

  ## Action Encoding

  Actions are encoded and joined with `;`:

  | Elixir Action | Maude Syntax |
  |---------------|--------------|
  | `{:set_prop, "light", "state", "on"}` | `setProp(thing("light"), "state", strVal("on"))` |
  | `{:set_env, "mode", "away"}` | `setEnv("mode", strVal("away"))` |
  | `{:invoke, "alarm", "trigger"}` | `invoke(thing("alarm"), "trigger")` |

  ## Value Wrapping

  All values are wrapped in type constructors per the Maude IoT module:

  - Booleans → `boolVal(true)` or `boolVal(false)`
  - Integers → `intVal("123")` (string representation)
  - Floats → `intVal("3.14")` (string representation)
  - Strings → `strVal("value")`
  - Atoms → `strVal("atom_name")`

  ## Usage

  This module is typically used internally by `ExMaude.IoT.detect_conflicts/2`:

      # Internal usage
      {:ok, maude_syntax} = ExMaude.IoT.Encoder.encode_rules(rules)
      # => {:ok, "rule(\\"r1\\", thing(\\"light\\"), always, nil, 1)"}

  ## See Also

  - `ExMaude.IoT` - High-level conflict detection API
  - `ExMaude.IoT.Validator` - Rule validation before encoding
  - `ExMaude.IoT.ConflictParser` - Parsing Maude output
  """

  @doc """
  Encodes a list of rules into Maude syntax.

  Returns `{:ok, maude_string}` on success.

  ## Examples

      iex> rules = [%{id: "r1", thing_id: "t1", trigger: {:always}, actions: [], priority: 1}]
      ...> ExMaude.IoT.Encoder.encode_rules(rules)
      {:ok, ~s|rule("r1", thing("t1"), always, nil, 1)|}
  """
  @spec encode_rules([ExMaude.IoT.rule()]) :: {:ok, String.t()}
  def encode_rules([]), do: {:ok, "empty"}

  def encode_rules(rules) do
    {:ok, Enum.map_join(rules, ", ", &encode_rule/1)}
  end

  @doc """
  Encodes a single rule into Maude syntax.
  """
  @spec encode_rule(ExMaude.IoT.rule()) :: String.t()
  def encode_rule(rule) do
    id = encode_string(rule.id)
    thing_id = encode_thing_id(rule.thing_id)
    trigger = encode_trigger(rule.trigger)
    actions = encode_actions(rule.actions)
    priority = Map.get(rule, :priority, 1)

    "rule(#{id}, #{thing_id}, #{trigger}, #{actions}, #{priority})"
  end

  @doc """
  Encodes a thing ID into Maude syntax.
  """
  @spec encode_thing_id(String.t()) :: String.t()
  def encode_thing_id(id), do: "thing(#{encode_string(id)})"

  @doc """
  Encodes a trigger into Maude syntax.

  Supports property comparisons, environment checks, logical operators,
  and the `always` trigger.
  """
  @spec encode_trigger(ExMaude.IoT.trigger()) :: String.t()
  def encode_trigger({:prop_eq, prop, value}),
    do: "propEq(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:prop_gt, prop, value}),
    do: "propGt(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:prop_lt, prop, value}),
    do: "propLt(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:prop_gte, prop, value}),
    do: "propGte(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:prop_lte, prop, value}),
    do: "propLte(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:env_eq, prop, value}),
    do: "envEq(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:env_gt, prop, value}),
    do: "envGt(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:env_lt, prop, value}),
    do: "envLt(#{encode_string(prop)}, #{encode_value(value)})"

  def encode_trigger({:always}), do: "always"

  def encode_trigger({:and, t1, t2}),
    do: "and(#{encode_trigger(t1)}, #{encode_trigger(t2)})"

  def encode_trigger({:or, t1, t2}),
    do: "or(#{encode_trigger(t1)}, #{encode_trigger(t2)})"

  def encode_trigger({:not, t}), do: "not(#{encode_trigger(t)})"

  @doc """
  Encodes a list of actions into Maude syntax.
  """
  @spec encode_actions([ExMaude.IoT.action()]) :: String.t()
  def encode_actions([]), do: "nil"

  def encode_actions(actions) do
    Enum.map_join(actions, " ; ", &encode_action/1)
  end

  @doc """
  Encodes a single action into Maude syntax.
  """
  @spec encode_action(ExMaude.IoT.action()) :: String.t()
  def encode_action({:set_prop, thing_id, prop, value}) do
    "setProp(#{encode_thing_id(thing_id)}, #{encode_string(prop)}, #{encode_value(value)})"
  end

  def encode_action({:set_env, prop, value}) do
    "setEnv(#{encode_string(prop)}, #{encode_value(value)})"
  end

  def encode_action({:invoke, thing_id, action_name}) do
    "invoke(#{encode_thing_id(thing_id)}, #{encode_string(action_name)})"
  end

  @doc """
  Encodes a string value for Maude (quoted).

  Backslashes and double quotes are escaped so the content cannot break
  out of the Maude string literal.

  ## Examples

      iex> ExMaude.IoT.Encoder.encode_string("hello")
      ~s("hello")

      iex> ExMaude.IoT.Encoder.encode_string(~s(say "hi"))
      ~s("say \\\\"hi\\\\"")
  """
  @spec encode_string(String.t() | atom()) :: String.t()
  def encode_string(s) when is_binary(s), do: ExMaude.Syntax.encode_string(s)

  def encode_string(s) when is_atom(s), do: encode_string(Atom.to_string(s))

  @doc """
  Encodes a value into Maude's wrapped value syntax.

  Values are wrapped as `boolVal()`, `intVal()`, or `strVal()` to match
  the Maude type system.
  """
  @spec encode_value(boolean() | number() | String.t() | atom()) :: String.t()
  def encode_value(v) when is_boolean(v), do: "boolVal(#{if v, do: "true", else: "false"})"
  def encode_value(v) when is_integer(v), do: "intVal(#{encode_string(Integer.to_string(v))})"
  def encode_value(v) when is_float(v), do: "intVal(#{encode_string(Float.to_string(v))})"
  def encode_value(v) when is_binary(v), do: "strVal(#{encode_string(v)})"
  def encode_value(v) when is_atom(v), do: "strVal(#{encode_string(Atom.to_string(v))})"
end
