defmodule WotexHome.Rules.KernelMapping do
  @moduledoc """
  Builds Home's bounded, inert Boolean power mapping for the generic kernel.

  `build/3` takes one restricted `WotexHome.Rules.Rule`, its exact
  `WotexHome.Semantics.Thing` declaration and a supplied complete-runtime digest
  as 64 lowercase hexadecimal characters, without a prefix. It returns
  `{:ok, mapping}` with atom keys `:source`, `:context`, `:basis`,
  `:mapping_digest`, `:profile` and `:limits`. The context contains the checked
  offline registry, basis and exact instance/resource bindings used by
  `WotexHome.Rules.KernelProposal`.

  The supported source is an explicit-request, literal-true Boolean power write
  to an ordinary Light, with causal budget one and zero cooldown. Pure ownership
  values span 1–86,400,000 milliseconds; accepting one here does not widen the
  narrower durable admission profile. The generated source has one effect and
  requires a reported match, with no child routines or runtime discovery.

  Home Thing IDs remain opaque. The generic Thing and whole-resource domain use
  `urn:wotex-home:thing:` followed by unpadded URL-safe Base64 of the exact ID
  bytes. This injective IRI mapping neither changes the Home device identity nor
  establishes enrollment. Security, lifecycle and report semantics are Home-owned
  contract values; no endpoint, credential, Store connection or transport enters
  the generic inputs.

  Failures return `{:error, reason}`: `:routine_kernel_unavailable` for missing
  public producer APIs, `:unsupported_kernel_profile` for unsupported inputs,
  and `:routine_kernel_refused` for producer refusal or caught failure.
  The supplied runtime digest is bound into the mapping, not measured or
  authenticated here. This pure helper establishes no current proof, durable
  admission, clock trust or physical qualification.
  """

  alias WotexHome.Rules.{Analyzer, Predicate, Rule}
  alias WotexHome.Semantics.{Thing, Value}

  @limits %{
    "max_bytes" => 262_144,
    "max_depth" => 32,
    "max_nodes" => 20_000,
    "max_string_bytes" => 8_192,
    "max_collection_size" => 128,
    "max_integer" => 9_223_372_036_854_775_807
  }
  @profile %{
    "source_bytes" => 32_768,
    "source_depth" => 16,
    "expanded_nodes" => 8,
    "predicate_nodes" => 8,
    "invocation_depth" => 1,
    "parallel_width" => 1,
    "effects" => 1,
    "waits" => 1,
    "active_definitions" => 1,
    "active_runs" => 1,
    "pending_work" => 1,
    "run_ms" => 86_400_000
  }
  @contracts [
    {"wotex-home.rule-security",
     ~w(current_authenticated_invoker current_original_author exact_target_grant single_store_commit)},
    {"wotex-home.rule-lifecycle",
     ~w(inert_proposal held_before_queue handoff_before_transport no_uncertain_retry)},
    {"wotex-home.boolean-report",
     ~w(current_qualified_device_report exact_boolean_equality no_protocol_inference)}
  ]
  @api [
    {Wotex.JSON, :encode, 2},
    {Wotex.Routines.Limits, :new, 1},
    {Wotex.Routines.Profile, :new, 1},
    {Wotex.Routines.Registry, :new, 2},
    {Wotex.Routines.Basis, :new, 3},
    {Wotex.Routines.Basis, :semantic_digest, 2},
    {Wotex.Routines.Compiler, :compile, 4},
    {Wotex.Routines.Compiler, :current, 4},
    {Wotex.Routines.Compiler, :to_map, 3},
    {Wotex.Routines.Kernel, :advance, 7},
    {Wotex.Routines.Snapshot, :new, 4},
    {Wotex.Routines.Run, :to_map, 4}
  ]
  @errors ~w(routine_kernel_unavailable unsupported_kernel_profile routine_kernel_refused invalid_kernel_projection)a
  @hash ~r/\A[0-9a-f]{64}\z/

  @spec build(Rule.t(), Thing.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def build(rule, thing, runtime) do
    guarded(fn ->
      with :ok <- supported(rule, thing),
           true <- hash?(runtime),
           {:ok, limits} <- Wotex.Routines.Limits.new(@limits),
           {:ok, profile} <- Wotex.Routines.Profile.new(@profile),
           {:ok, contracts} <- contracts(),
           {:ok, basis, registry} <- basis(rule, thing, runtime, contracts, limits) do
        source = source(rule)

        context = %{
          "registry" => registry.data,
          "bases" => [basis.data],
          "bindings" => %{
            "output" => %{
              "basis" => reference(basis.data),
              "thing_id" => thing_iri(thing.id),
              "resource_roles" => %{"target" => thing_iri(thing.id)}
            }
          },
          "definitions" => [],
          "arguments" => %{},
          "compiler_basis" => "sha256:" <> runtime
        }

        {:ok,
         %{
           source: source,
           context: context,
           basis: basis.data,
           mapping_digest: bare(basis.data["semantic_digest"]),
           profile: profile,
           limits: limits
         }}
      else
        false -> {:error, :unsupported_kernel_profile}
        error -> error
      end
    end)
  end

  @doc false
  def guarded(callback) when is_function(callback, 0) do
    if Enum.all?(@api, fn {module, function, arity} ->
         Code.ensure_loaded?(module) and function_exported?(module, function, arity)
       end) do
      try do
        case callback.() do
          {:ok, _} = result -> result
          {:error, reason} = error when reason in @errors -> error
          _ -> {:error, :routine_kernel_refused}
        end
      rescue
        _ -> {:error, :routine_kernel_refused}
      catch
        _, _ -> {:error, :routine_kernel_refused}
      end
    else
      {:error, :routine_kernel_unavailable}
    end
  end

  @doc false
  def hash?(value), do: is_binary(value) and byte_size(value) == 64 and value =~ @hash

  @doc false
  def bare("sha256:" <> hash), do: hash

  @doc false
  def thing_iri(id), do: "urn:wotex-home:thing:" <> Base.url_encode64(id, padding: false)

  @doc false
  def json_options do
    @limits
    |> Map.drop(["max_integer"])
    |> Enum.map(fn
      {"max_bytes", value} -> {:max_bytes, value}
      {"max_depth", value} -> {:max_depth, value}
      {"max_nodes", value} -> {:max_nodes, value}
      {"max_string_bytes", value} -> {:max_string_bytes, value}
      {"max_collection_size", value} -> {:max_collection_size, value}
    end)
  end

  defp supported(
         %Rule{
           trigger: {:explicit_request, nil},
           predicate: %Predicate{op: :literal_true, args: nil},
           effect: {id, "power", %Value{kind: :boolean}},
           causal_budget: 1,
           cooldown_ms: 0
         } = rule,
         %Thing{id: id, role: "Light"} = thing
       ) do
    case Analyzer.restricted([rule], %{id => thing}) do
      {:ok, :structurally_restricted} -> :ok
      _ -> {:error, :unsupported_kernel_profile}
    end
  end

  defp supported(_, _), do: {:error, :unsupported_kernel_profile}

  defp contracts do
    Enum.reduce_while(@contracts, {:ok, []}, fn {id, obligations}, {:ok, records} ->
      body = %{
        "format" => "wotex-home.routine-contract.v1",
        "id" => id,
        "version" => "1",
        "obligations" => obligations
      }

      case digest(body) do
        {:ok, digest} ->
          record = %{"id" => id, "version" => "1", "semantic_digest" => digest, "requires" => []}
          {:cont, {:ok, records ++ [record]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp basis(rule, thing, runtime, contracts, limits) do
    by_id = Map.new(contracts, &{&1["id"], reference(&1)})
    power = thing.capabilities["power"]

    body = %{
      "format" => "wotex.routines.basis@1",
      "id" => "wotex-home.boolean-power",
      "version" => "1",
      "affordance" => %{"type" => "property", "name" => "power", "operation" => "writeproperty"},
      "value" => %{"type" => "boolean", "unit" => nil, "enum" => []},
      "output" => nil,
      "security_contract" => by_id["wotex-home.rule-security"],
      "lifecycle_contract" => by_id["wotex-home.rule-lifecycle"],
      "required_contracts" => [],
      "evidence" => %{
        "sources" => ["device_report"],
        "freshness_ms" => power.freshness_ms,
        "require_source_time" => false,
        "continuity" => "snapshot",
        "completion" => "reported_match",
        "report_contract" => by_id["wotex-home.boolean-report"]
      },
      "effects" => %{
        "resource_roles" => ["target"],
        "repeat" => "never",
        "stop" => "separate_effect",
        "supersession" => "block_until_known",
        "partial_possible" => true,
        "unknown_possible" => true
      },
      "timing" => %{
        "deadline_ms" => rule.ownership_ms,
        "duration_ms" => 0,
        "dwell_ms" => 0,
        "cooldown_ms" => 0,
        "uncertainty" => "block"
      },
      "analysis" => %{"classification" => "unsupported", "profile" => nil, "properties" => []},
      "annotations" => %{}
    }

    with {:ok, bytes} <- digest(body),
         {:ok, semantics} <- Wotex.Routines.Basis.semantic_digest(body, limits),
         data =
           Map.merge(body, %{
             "byte_digest" => bytes,
             "semantic_digest" => semantics,
             "implementation_digest" => "sha256:" <> runtime,
             "compiler_digest" => "sha256:" <> runtime
           }),
         record = Map.put(reference(data), "requires", Enum.map(contracts, &reference/1)),
         {:ok, registry} <- Wotex.Routines.Registry.new(contracts ++ [record], limits),
         {:ok, basis} <- Wotex.Routines.Basis.new(data, registry, limits) do
      {:ok, basis, registry}
    end
  end

  defp source(rule) do
    {_, "power", value} = rule.effect

    %{
      "format" => "wotex.routines.source@1",
      "profile" => "bounded-composition@1",
      "id" => rule.id,
      "revision" => Integer.to_string(rule.source_revision),
      "parameters" => %{},
      "bindings" => ["output"],
      "trigger" => %{"kind" => "manual"},
      "condition" => %{"op" => "literal", "value" => true},
      "steps" => %{
        "id" => "power",
        "kind" => "effect",
        "binding" => "output",
        "input" => value.data,
        "completion" => "reported_match"
      },
      "overlap" => "reject",
      "run_ms" => rule.ownership_ms
    }
  end

  defp digest(data) do
    with {:ok, bytes} <- Wotex.JSON.encode(data, json_options()),
         true <- byte_size(bytes) <= @limits["max_bytes"] do
      {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    else
      _ -> {:error, :routine_kernel_refused}
    end
  end

  defp reference(data), do: Map.take(data, ~w(id version semantic_digest))
end
