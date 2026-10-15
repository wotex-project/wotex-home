defmodule WotexHome.Rules.KernelProposal do
  @moduledoc """
  Calculates and checks one inert generic-kernel proposal for an explicit rule.

  `propose/5` takes a restricted `WotexHome.Rules.Rule`, its exact
  `WotexHome.Semantics.Thing`, a nonnegative resource revision, closed invocation
  metadata and a supplied bare lowercase SHA-256 runtime digest. Invocation
  metadata has exactly the atom keys `:principal_id`, `:authority_epoch`,
  `:operation_id`, `:rule_generation` and `:preparation_digest`. It returns
  `{:ok, projection}` containing the complete compiled program and checked
  initial result, bound to the preparation, runtime and mapping digests.
  The complete JSON projection is limited to 262,144 bytes.

  `validate/6` rebuilds those inputs and returns `{:ok, value}` with a Boolean
  `WotexHome.Semantics.Value` only after checking the complete program, initial
  run, sole proposal and result basis. General retained-run validity is not
  enough: the initial step must be proposed, with no receipts or spent roots.
  `qualify/3` checks both Boolean inputs across distinct original scopes and
  returns `{:ok, digests}` for the requested mapping/source/IR and compiler
  profile. That bundle is input to a later correspondence proof.

  Compilation uses `WotexHome.Rules.KernelMapping`, including its injective
  opaque-ID-to-IRI mapping. The generic original binds the principal, authority
  epoch and operation, without replacing Home's durable original. Every initial
  call uses logical elapsed time zero, fixed epoch/generation and absent UTC
  confidence. Its prospective deadline is not a sampled host clock, a new
  physical timeout or permission to continue an expired run. No run is retained
  or advanced through fabricated admission/handoff receipts.

  Failures return `{:error, reason}` with `:routine_kernel_unavailable`,
  `:unsupported_kernel_profile`, `:routine_kernel_refused` or
  `:invalid_kernel_projection`. The last covers malformed invocation metadata
  or a mismatched program/result. No partial result or fallback evaluator follows.
  These pure helpers do not implement Store adoption or establish a current
  proof. Store must independently authenticate the caller and repeat current
  runtime, authority, declaration and execution guards before admitting work.
  """

  alias WotexHome.Id
  alias WotexHome.Rules.{KernelMapping, Rule}
  alias WotexHome.Semantics.{Thing, Value}

  @max_i64 9_223_372_036_854_775_807
  @invocation ~w(principal_id authority_epoch operation_id rule_generation preparation_digest)a
  @wrapper ~w(format preparation_digest runtime_digest mapping_digest program result)
  @result ~w(run proposals outcome edge basis)
  @proposal ~w(original step_original program_digest path binding installed_basis thing_id resource_roles resource_domains operation input completion evidence_contract)
  @time %{
    "epoch" => "wotex-home.explicit-kernel",
    "clock_generation" => "wotex-home.explicit-kernel.v1",
    "elapsed_ms" => 0,
    "utc_low_ms" => nil,
    "utc_high_ms" => nil
  }
  @prior %{"original" => nil, "busy" => nil, "edge" => nil}

  @spec propose(Rule.t(), Thing.t(), non_neg_integer(), map(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def propose(rule, thing, resource, invocation, runtime) do
    KernelMapping.guarded(fn ->
      with :ok <- invocation(invocation, resource),
           {:ok, compiled} <- compile(rule, thing, runtime),
           {:ok, frame} <- frame(compiled, thing, resource, invocation),
           {:ok, result} <-
             Wotex.Routines.Kernel.advance(
               compiled.program,
               frame.event,
               frame.snapshot,
               @time,
               @prior,
               compiled.profile,
               compiled.limits
             ),
           projection = %{
             "format" => "wotex-home.explicit-kernel-proposal.v1",
             "preparation_digest" => invocation.preparation_digest,
             "runtime_digest" => runtime,
             "mapping_digest" => compiled.mapping_digest,
             "program" => compiled.program,
             "result" => result
           },
           {:ok, _value} <- checked(rule, thing, invocation, runtime, compiled, frame, projection) do
        {:ok, projection}
      end
    end)
  end

  @spec validate(Rule.t(), Thing.t(), non_neg_integer(), map(), String.t(), term()) ::
          {:ok, Value.t()} | {:error, atom()}
  def validate(rule, thing, resource, invocation, runtime, projection) do
    KernelMapping.guarded(fn ->
      with :ok <- invocation(invocation, resource),
           {:ok, compiled} <- compile(rule, thing, runtime),
           {:ok, frame} <- frame(compiled, thing, resource, invocation) do
        checked(rule, thing, invocation, runtime, compiled, frame, projection)
      end
    end)
  end

  @spec qualify(Rule.t(), Thing.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def qualify(rule, thing, runtime) do
    KernelMapping.guarded(fn ->
      with {:ok, requested} <- compile(rule, thing, runtime),
           :ok <- correspondence(rule, thing, runtime) do
        {:ok,
         %{
           kernel_mapping_digest: requested.mapping_digest,
           kernel_source_digest: KernelMapping.bare(requested.program["source_digest"]),
           kernel_ir_digest: KernelMapping.bare(requested.program["ir_digest"]),
           kernel_compiler_profile: requested.program["compiler_profile"]
         }}
      end
    end)
  end

  defp compile(rule, thing, runtime) do
    with {:ok, mapping} <- KernelMapping.build(rule, thing, runtime),
         {:ok, program} <-
           Wotex.Routines.Compiler.compile(
             mapping.source,
             mapping.context,
             mapping.profile,
             mapping.limits
           ),
         {:ok, data} <- Wotex.Routines.Compiler.to_map(program, mapping.profile, mapping.limits) do
      {:ok, Map.put(mapping, :program, data)}
    end
  end

  defp frame(compiled, thing, resource, invocation) do
    original =
      {"wotex-home.rule-original.v1", invocation.principal_id, invocation.authority_epoch,
       invocation.operation_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> then(&("home:rule:" <> &1))

    event = %{
      "kind" => "manual",
      "original" => original,
      "program_digest" => compiled.program["ir_digest"]
    }

    snapshot = %{
      "id" => "sha256:" <> invocation.preparation_digest,
      "membership_generation" =>
        "rule-generation:" <> Integer.to_string(invocation.rule_generation),
      "active_programs" => [compiled.program["ir_digest"]],
      "resource_revisions" => %{KernelMapping.thing_iri(thing.id) => resource},
      "binding_bases" => %{
        "output" => %{
          "profile_digest" => compiled.basis["semantic_digest"],
          "source_id" => "wotex-home.rule-invocation",
          "source_epoch" => "sha256:" <> invocation.preparation_digest,
          "source_time_basis" => nil
        }
      },
      "facts" => %{"output" => nil}
    }

    with {:ok, _} <-
           Wotex.Routines.Snapshot.new(
             snapshot,
             compiled.program,
             compiled.profile,
             compiled.limits
           ),
         do: {:ok, %{event: event, snapshot: snapshot}}
  end

  defp checked(rule, thing, invocation, runtime, compiled, frame, projection) do
    with true <- closed?(projection, @wrapper),
         {:ok, bytes} <- Wotex.JSON.encode(projection, KernelMapping.json_options()),
         true <- byte_size(bytes) <= 262_144,
         true <- projection["format"] == "wotex-home.explicit-kernel-proposal.v1",
         true <- projection["preparation_digest"] == invocation.preparation_digest,
         true <- projection["runtime_digest"] == runtime,
         true <- projection["mapping_digest"] == compiled.mapping_digest,
         true <- projection["program"] == compiled.program,
         :ok <-
           Wotex.Routines.Compiler.current(
             projection["program"],
             compiled.context,
             compiled.profile,
             compiled.limits
           ),
         result = projection["result"],
         true <- closed?(result, @result),
         true <- result["outcome"] == "running" and result["edge"] == nil,
         true <- result["basis"] == result_basis(compiled, frame),
         {:ok, run} <-
           Wotex.Routines.Run.to_map(
             result["run"],
             compiled.program,
             compiled.profile,
             compiled.limits
           ),
         :ok <- initial_run(run, rule, frame.event),
         [step] = run["steps"],
         [proposal] <- result["proposals"],
         true <- closed?(proposal, @proposal),
         true <- proposal == expected_proposal(rule, thing, compiled, frame, step),
         {:ok, value} <- Value.new(%{"type" => "boolean", "value" => proposal["input"]}) do
      {:ok, value}
    else
      _ -> {:error, :invalid_kernel_projection}
    end
  end

  defp initial_run(run, rule, event) do
    case run do
      %{
        "original" => original,
        "epoch" => "wotex-home.explicit-kernel",
        "clock_generation" => "wotex-home.explicit-kernel.v1",
        "start_ms" => 0,
        "last_ms" => 0,
        "deadline_ms" => deadline,
        "status" => "running",
        "steps" => [
          %{
            "path" => [],
            "kind" => "effect",
            "status" => "proposed",
            "started_ms" => 0,
            "deadline_ms" => step_deadline,
            "branch" => nil,
            "receipts" => receipts
          }
        ],
        "spent" => [],
        "window" => nil,
        "reason" => nil
      } ->
        if original == event["original"] and deadline == rule.ownership_ms and
             step_deadline == rule.ownership_ms and
             Enum.all?(Map.values(receipts), &is_nil/1),
           do: :ok,
           else: {:error, :invalid_kernel_projection}

      _ ->
        {:error, :invalid_kernel_projection}
    end
  end

  defp expected_proposal(rule, thing, compiled, frame, step) do
    {_, "power", value} = rule.effect

    %{
      "original" => frame.event["original"],
      "step_original" => step["original"],
      "program_digest" => compiled.program["ir_digest"],
      "path" => [],
      "binding" => "output",
      "installed_basis" => compiled.context["bindings"]["output"]["basis"],
      "thing_id" => KernelMapping.thing_iri(thing.id),
      "resource_roles" => %{"target" => KernelMapping.thing_iri(thing.id)},
      "resource_domains" => [KernelMapping.thing_iri(thing.id)],
      "operation" => "writeproperty",
      "input" => value.data,
      "completion" => "reported_match",
      "evidence_contract" => compiled.basis["evidence"]["report_contract"]
    }
  end

  defp result_basis(compiled, frame) do
    %{
      "program_digest" => compiled.program["ir_digest"],
      "source_digest" => compiled.program["source_digest"],
      "compiler_basis" => compiled.context["compiler_basis"],
      "event" => frame.event,
      "prior" => @prior,
      "snapshot" => frame.snapshot,
      "time" => @time
    }
  end

  defp invocation(invocation, resource) do
    if closed?(invocation, @invocation) and Id.valid?(invocation.principal_id) and
         Id.valid?(invocation.operation_id) and integer?(invocation.authority_epoch, 1, @max_i64) and
         integer?(invocation.rule_generation, 0, @max_i64 - 1) and
         KernelMapping.hash?(invocation.preparation_digest) and integer?(resource, 0, @max_i64),
       do: :ok,
       else: {:error, :invalid_kernel_projection}
  end

  defp correspondence(rule, thing, runtime) do
    for value <- [false, true],
        {principal, epoch, operation} <- [
          {"principal:kernel-proof", 1, "operation:one"},
          {"principal:other-proof", 1, "operation:one"},
          {"principal:kernel-proof", 2, "operation:one"},
          {"principal:kernel-proof", 1, "operation:two"}
        ],
        reduce: :ok do
      :ok ->
        {:ok, requested} = Value.new(%{"type" => "boolean", "value" => value})
        probe = %{rule | effect: {thing.id, "power", requested}}

        invocation = %{
          principal_id: principal,
          authority_epoch: epoch,
          operation_id: operation,
          rule_generation: 1,
          preparation_digest: String.duplicate("f", 64)
        }

        case propose(probe, thing, 0, invocation, runtime) do
          {:ok, _projection} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp closed?(value, keys),
    do:
      is_map(value) and not is_struct(value) and map_size(value) == length(keys) and
        Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp integer?(value, lower, upper),
    do: is_integer(value) and value >= lower and value <= upper
end
