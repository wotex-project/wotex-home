defmodule WotexHome.Rules.RestrictedBasis do
  @moduledoc """
  Positive proposal-generation basis for one explicit Boolean Light power rule.

  This proves only the narrow credential-free proposal semantics enumerated here.
  It does not admit a rule, activate it, check device state, or authorize a send.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Rules.{Analyzer, Event, OverrideLease, Predicate, Rule, RuntimeGate, Sandbox}
  alias WotexHome.Semantics.{Thing, Value}

  @profile "explicit-boolean-light-v1"
  @obligations ~w(closed_rule ordinary_light_power single_explicit_trigger literal_predicate one_writer no_feedback one_effect_per_root runtime_correspondence pure_gate_precedence blocked_root_preservation)a

  @spec qualify([Rule.t()], %{String.t() => Thing.t()}) :: {:ok, map()} | {:error, atom()}
  def qualify([%Rule{} = rule] = rules, things)
      when is_map(things) and map_size(things) == 1 do
    with [{target_id, %Thing{id: target_id} = thing}] <- Map.to_list(things),
         {:ok, :structurally_restricted} <- Analyzer.restricted(rules, things),
         :ok <- narrow_profile(rule, thing),
         :ok <- check_correspondence(rule),
         :ok <- check_guard_correspondence(rule),
         {:ok, document} <- Registry.encode_thing(thing),
         {:ok, runtime_digest} <- runtime_digest() do
      {:ok,
       %{
         result: :basis_complete,
         profile: @profile,
         target_id: target_id,
         obligations: @obligations,
         rule_digest: digest({@profile, rule}),
         registry_digest: digest({target_id, document}),
         runtime_digest: runtime_digest,
         scope: :proposal_generation_only
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unsupported_restricted_profile}
    end
  end

  def qualify(_rules, _things), do: {:error, :unsupported_restricted_profile}

  defp narrow_profile(
         %Rule{
           trigger: {:explicit_request, nil},
           predicate: %Predicate{op: :literal_true, args: nil},
           effect: {target_id, "power", %Value{kind: :boolean}},
           causal_budget: 1,
           cooldown_ms: 0
         },
         %Thing{id: target_id, role: "Light"}
       ),
       do: :ok

  defp narrow_profile(_rule, _thing), do: {:error, :unsupported_restricted_profile}

  defp check_correspondence(rule) do
    {target_id, key, value} = rule.effect
    {:ok, opposite} = Value.new(%{"type" => "boolean", "value" => not value.data})
    states = [:unknown, {:known, value}, {:known, opposite}]
    other_id = if rule.id == "rule:other", do: "rule:other-alt", else: "rule:other"

    events = [
      explicit(rule.id, 0),
      explicit(rule.id, 1),
      explicit(other_id, 0),
      edge("reported"),
      edge("synthetic_ack")
    ]

    cases = for event <- events, desired <- states, do: {event, desired}

    with :ok <-
           Enum.reduce_while(cases, :ok, fn {event, desired}, :ok ->
             case check_one(rule, event, desired, {target_id, key, value}) do
               :ok -> {:cont, :ok}
               error -> {:halt, error}
             end
           end),
         :ok <- check_root_budget(rule) do
      :ok
    end
  end

  defp check_one(rule, event, desired, {target_id, key, value}) do
    with {:ok, sandbox} <- Sandbox.new([rule]),
         {:ok, result, _next} <-
           Sandbox.step(sandbox, event, %{}, %{{target_id, key} => desired}, 0) do
      expected =
        if event.kind == :explicit_request and event.rule_id == rule.id and event.depth == 0 and
             desired != {:known, value} do
          [
            %{
              rule_id: rule.id,
              target_id: target_id,
              capability_key: key,
              value: value,
              root_id: event.root_id,
              depth: 1,
              ownership_ms: rule.ownership_ms
            }
          ]
        else
          []
        end

      if result.proposals == expected and result.conflicts == [],
        do: :ok,
        else: {:error, :runtime_correspondence_failed}
    else
      _ -> {:error, :runtime_correspondence_failed}
    end
  end

  defp check_root_budget(rule) do
    with {:ok, sandbox} <- Sandbox.new([rule]),
         {:ok, first, next} <- Sandbox.step(sandbox, explicit(rule.id, 0), %{}, %{}, 0),
         {:ok, second, _last} <- Sandbox.step(next, explicit(rule.id, 0), %{}, %{}, 0),
         true <- length(first.proposals) == 1 and second.proposals == [] do
      :ok
    else
      _ -> {:error, :runtime_correspondence_failed}
    end
  end

  defp check_guard_correspondence(rule) do
    {target_id, key, value} = rule.effect

    {:ok, live_lease} =
      OverrideLease.new(%{
        "target_id" => target_id,
        "operator_id" => "operator:qualification",
        "authority_epoch" => 1,
        "start_ms" => 100,
        "expires_ms" => 200,
        "basis_revision" => 0
      })

    lease_cases = [
      {:none, []},
      {:live, [live_lease]},
      {:expired, [%{live_lease | expires_ms: 150}]},
      {:old_epoch, [%{live_lease | authority_epoch: 2}]}
    ]

    cases =
      for safety <- [:allow, :deny, :unknown],
          {lease_kind, leases} <- lease_cases,
          event <- [explicit(rule.id, 0), explicit("rule:unmatched", 0)],
          desired <- [:unknown, {:known, value}],
          do: {safety, lease_kind, leases, event, desired}

    Enum.reduce_while(cases, :ok, fn {safety, lease_kind, leases, event, desired}, :ok ->
      expected_gate =
        cond do
          safety == :deny -> :safety_denied
          safety == :unknown -> :safety_unknown
          lease_kind == :live -> :operator_override
          true -> :allow
        end

      expected_proposal? =
        expected_gate == :allow and event.rule_id == rule.id and desired == :unknown

      expected_suppression =
        if event.rule_id == rule.id, do: expected_gate, else: :trigger_not_matched

      result =
        with {:ok, %{^target_id => ^expected_gate} = gate} <-
               RuntimeGate.decisions([target_id], %{target_id => safety}, leases, 1, 150),
             {:ok, sandbox} <- Sandbox.new([rule]),
             {:ok, step, updated} <-
               Sandbox.step(sandbox, event, %{}, %{{target_id, key} => desired}, 150, gate),
             true <-
               expected_proposal? == (length(step.proposals) == 1) and step.conflicts == [],
             true <-
               expected_gate == :allow or
                 (step.suppressed[rule.id] == expected_suppression and
                    updated.root_counts == %{} and updated.last_fired_ms == %{}) do
          :ok
        else
          _ -> {:error, :runtime_correspondence_failed}
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> check_blocked_root_release(rule, target_id, live_lease)
      error -> error
    end
  end

  defp check_blocked_root_release(rule, target_id, lease) do
    event = explicit(rule.id, 0)

    with {:ok, sandbox} <- Sandbox.new([rule]),
         {:ok, blocked_gate} <-
           RuntimeGate.decisions([target_id], %{target_id => :allow}, [lease], 1, 199),
         {:ok, blocked, held} <- Sandbox.step(sandbox, event, %{}, %{}, 199, blocked_gate),
         true <- blocked.proposals == [] and held.root_counts == %{},
         {:ok, released_gate} <-
           RuntimeGate.decisions([target_id], %{target_id => :allow}, [lease], 1, 200),
         {:ok, released, updated} <- Sandbox.step(held, event, %{}, %{}, 200, released_gate),
         true <- length(released.proposals) == 1 and updated.root_counts == %{event.root_id => 1} do
      :ok
    else
      _ -> {:error, :runtime_correspondence_failed}
    end
  end

  defp explicit(rule_id, depth) do
    {:ok, event} =
      Event.new(%{
        "kind" => "explicit_request",
        "root_id" => "root:qualification",
        "depth" => depth,
        "rule_id" => rule_id
      })

    event
  end

  defp edge(origin) do
    {:ok, event} =
      Event.new(%{
        "kind" => "edge",
        "root_id" => "root:qualification",
        "depth" => 0,
        "origin" => origin,
        "fact" => %{"thing_id" => "light:probe", "capability_key" => "power"},
        "before" => false,
        "after" => true
      })

    event
  end

  defp runtime_digest do
    [Rule, Event, Predicate, Sandbox, RuntimeGate, OverrideLease, __MODULE__]
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, binaries} ->
      case :code.get_object_code(module) do
        {^module, binary, _path} -> {:cont, {:ok, [{module, digest(binary)} | binaries]}}
        _ -> {:halt, {:error, :runtime_artifact_unavailable}}
      end
    end)
    |> case do
      {:ok, binaries} -> {:ok, digest(Enum.reverse(binaries))}
      error -> error
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
