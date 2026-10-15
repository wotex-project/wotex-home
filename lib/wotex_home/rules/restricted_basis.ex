defmodule WotexHome.Rules.RestrictedBasis do
  @moduledoc """
  Positive proposal-generation basis for one explicit Boolean Light power rule.

  `qualify/2` takes a single supported `WotexHome.Rules.Rule` and a one-entry
  map containing its exact `WotexHome.Semantics.Thing` declaration. It returns
  `{:ok, basis}` for `explicit-boolean-light-v4`, scope
  `:proposal_generation_only`, or `{:error, reason}`. The basis binds Home's
  closed source/IR, the complete declaration, the actual generic mapping and
  compiled program, and the current ten-application runtime inventory.

  Finite checks compare draft Sandbox proposals, gate precedence and root
  preservation with independent expected results. Separate
  `WotexHome.Rules.KernelProposal` checks exercise the actual initial generic
  proposal for both Boolean values and distinct original scopes. These checks
  retain the distinction between draft desired-state suppression and explicit
  invocation; they do not qualify arbitrary compositions or completed effects.

  The fixed runtime cohort is `:wotex_home`, `:wotex_routines`,
  `:wotex_continuum`, `:wotex`, `:ex_booking`, `:decimal`, `:jason`,
  `:ex_json_schema`, `:nimble_options` and `:tz`. One positive basis may be
  memoized per caller process under exact rule/declaration/runtime bindings.
  Every lookup follows a fresh complete inventory; a cold proof repeats the
  inventory after verification. Grants, clocks, observations and historical
  receipts are not cached by this memo.

  `valid?/1` checks the exact v3 or v4 grammar, obligations and hashes without
  requiring the producer or current authority. Historical v3 validity is not
  current evidence. `current/3` requires exact rebuilt v4 equality: malformed
  records return `:invalid_proposal_basis`, historical or changed bases return
  `:stale_proposal_basis`, and qualification failures retain their atom reason,
  each wrapped as `{:error, reason}`. Success is `:ok`.

  Internal `to_map(basis)` and `from_map(encoded)` codecs return `{:ok, value}`
  or `:error`. They preserve exact profile-specific fields and ordered obligations,
  reject unknown or mixed grammar, and never create atoms from input strings.
  Decoding history neither calls the generic producer nor upgrades an old proof.

  This scope establishes finite proposal correspondence. It does not admit or
  activate a rule, authenticate a live caller, establish clock trust or qualify
  physical effects. Current Store and execution guards remain mandatory.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Id
  alias WotexHome.RuntimeArtifacts

  alias WotexHome.Rules.{
    Analyzer,
    Compiler,
    Event,
    KernelProposal,
    OverrideLease,
    Predicate,
    Rule,
    RuntimeGate,
    Sandbox
  }

  alias WotexHome.Semantics.{Thing, Value}

  @profile "explicit-boolean-light-v4"
  @legacy_profile "explicit-boolean-light-v3"
  @runtime_domain "wotex-home.explicit-kernel-runtime.v1"
  @legacy_keys ~w(result profile target_id obligations rule_digest registry_digest compiler_profile source_digest ir_digest runtime_digest scope basis_digest)a
  @kernel_keys ~w(kernel_mapping_digest kernel_source_digest kernel_ir_digest kernel_compiler_profile)a
  @basis_keys @legacy_keys ++ @kernel_keys
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @legacy_obligations ~w(closed_rule closed_source_bound_ir compiler_correspondence ordinary_light_power single_explicit_trigger literal_predicate one_writer no_feedback one_effect_per_root runtime_correspondence pure_gate_precedence blocked_root_preservation)a
  @obligations @legacy_obligations ++
                 ~w(generic_manual_kernel exact_single_proposal complete_kernel_runtime_cohort)a
  @cache_key {__MODULE__, :positive_correspondence}

  @spec qualify([Rule.t()], %{String.t() => Thing.t()}) :: {:ok, map()} | {:error, atom()}
  def qualify([%Rule{} = rule] = rules, things)
      when is_map(things) and map_size(things) == 1 do
    with [{target_id, %Thing{id: target_id} = thing}] <- Map.to_list(things),
         {:ok, :structurally_restricted} <- Analyzer.restricted(rules, things),
         :ok <- narrow_profile(rule, thing),
         {:ok, document} <- Registry.encode_thing(thing),
         {:ok, runtime_digest} <- runtime_digest(),
         {:ok, program} <- Compiler.compile(rules) do
      bindings = %{
        result: :basis_complete,
        profile: @profile,
        target_id: target_id,
        obligations: @obligations,
        rule_digest: digest({@profile, rule}),
        registry_digest: digest({target_id, document}),
        compiler_profile: program.profile,
        source_digest: program.source_digest,
        ir_digest: program.ir_digest,
        runtime_digest: runtime_digest,
        scope: :proposal_generation_only
      }

      positive_correspondence(bindings, rule, thing)
    else
      {:error, reason} ->
        Process.delete(@cache_key)
        {:error, reason}

      _ ->
        Process.delete(@cache_key)
        {:error, :unsupported_restricted_profile}
    end
  end

  def qualify(_rules, _things) do
    Process.delete(@cache_key)
    {:error, :unsupported_restricted_profile}
  end

  defp positive_correspondence(bindings, rule, thing) do
    case Process.get(@cache_key) do
      {^bindings, basis} ->
        {:ok, basis}

      _ ->
        Process.delete(@cache_key)

        with :ok <- check_correspondence(rule),
             :ok <- check_guard_correspondence(rule),
             {:ok, kernel} <- KernelProposal.qualify(rule, thing, bindings.runtime_digest),
             {:ok, runtime} <- runtime_digest(),
             true <- runtime == bindings.runtime_digest do
          basis = Map.merge(bindings, kernel)
          basis = Map.put(basis, :basis_digest, digest(basis))
          Process.put(@cache_key, {bindings, basis})
          {:ok, basis}
        else
          false -> {:error, :runtime_artifact_unavailable}
          error -> error
        end
    end
  end

  @doc "Closed receipt validation only; neither current qualification nor admission."
  @spec valid?(term()) :: boolean()
  def valid?(basis) when is_map(basis) and not is_struct(basis) do
    {keys, obligations} = grammar(basis[:profile])

    keys != [] and map_size(basis) == length(keys) and
      Enum.sort(Map.keys(basis)) == Enum.sort(keys) and
      basis.result == :basis_complete and
      basis.scope == :proposal_generation_only and Id.valid?(basis.target_id) and
      basis.compiler_profile == "home-rule-ir-v1" and
      basis.obligations == obligations and
      (basis.profile == @legacy_profile or
         (basis.kernel_compiler_profile == "wotex.routines.compiler@1" and
            Enum.all?(
              [basis.kernel_mapping_digest, basis.kernel_source_digest, basis.kernel_ir_digest],
              &hash?/1
            ))) and
      Enum.all?(
        [
          basis.rule_digest,
          basis.registry_digest,
          basis.source_digest,
          basis.ir_digest,
          basis.runtime_digest,
          basis.basis_digest
        ],
        &hash?/1
      ) and
      digest(Map.delete(basis, :basis_digest)) == basis.basis_digest
  end

  def valid?(_basis), do: false

  @doc false
  def to_map(basis) do
    if valid?(basis), do: {:ok, encoded(basis)}, else: :error
  end

  @doc false
  def from_map(encoded) when is_map(encoded) and not is_struct(encoded) do
    {keys, obligations} = grammar(encoded["profile"])

    if keys != [] and map_size(encoded) == length(keys) do
      basis =
        keys
        |> Map.new(&{&1, encoded[Atom.to_string(&1)]})
        |> Map.merge(%{
          result: :basis_complete,
          scope: :proposal_generation_only,
          obligations: obligations
        })

      if valid?(basis) and encoded(basis) == encoded, do: {:ok, basis}, else: :error
    else
      :error
    end
  end

  def from_map(_encoded), do: :error

  defp encoded(basis) do
    Map.new(basis, fn {key, value} ->
      value =
        cond do
          is_atom(value) -> Atom.to_string(value)
          is_list(value) -> Enum.map(value, &Atom.to_string/1)
          true -> value
        end

      {Atom.to_string(key), value}
    end)
  end

  defp grammar(@profile), do: {@basis_keys, @obligations}
  defp grammar(@legacy_profile), do: {@legacy_keys, @legacy_obligations}
  defp grammar(_profile), do: {[], []}

  defp hash?(value), do: is_binary(value) and byte_size(value) == 64 and value =~ @hex64

  @doc "Repeat finite correspondence and compare complete current input/runtime bindings."
  @spec current(map(), [Rule.t()], map()) :: :ok | {:error, atom()}
  def current(basis, rules, things) do
    cond do
      not valid?(basis) ->
        Process.delete(@cache_key)
        {:error, :invalid_proposal_basis}

      basis.profile == @legacy_profile ->
        Process.delete(@cache_key)
        {:error, :stale_proposal_basis}

      true ->
        case qualify(rules, things) do
          {:ok, ^basis} -> :ok
          {:ok, _changed} -> {:error, :stale_proposal_basis}
          error -> error
        end
    end
  end

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
    RuntimeArtifacts.fresh_digest(RuntimeArtifacts.temporal_applications(), @runtime_domain)
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
