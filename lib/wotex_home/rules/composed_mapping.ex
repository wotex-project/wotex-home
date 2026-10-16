defmodule WotexHome.Rules.ComposedMapping do
  @moduledoc """
  Derives inert routine Programs from exact retained capability selections.

  `WotexHome.Rules.ComposedMapping.build/2` takes a complete source bundle and
  supplied environment, each as a plain string-keyed map or bounded JSON bytes.
  The bundle has exactly `"format"`, `"source"`, `"definitions"`, `"arguments"`
  and `"bindings"`; format is `"wotex-home.routine-source@1"`. Supply all child
  sources and parameter values. Binding selectors are unique and sorted by name,
  with exactly `"name"`, `"kind"`, `"target_id"`, `"capability_key"`,
  `"declaration_sha256"` and `"input"`. The declaration hash covers the entire
  exact retained Thing document. Kind is `"native_read"`, `"native_write"` or
  `"external_read"`; input is `nil` except for the external installation's exact
  `"install_revision"`, `"generation"` and `"definition_sha256"`.

  The environment has exactly `"runtime_sha256"`, `"targets"` and
  `"external_inputs"`, covering the selected targets/external pairs without
  extras. Target rows contain exactly `"target_id"`, `"resource_revision"` and
  `"thing_document"`. External rows contain exactly `"target_id"`,
  `"capability_key"`, `"install_revision"`, `"generation"` and
  `"definition_document"`. Those two arrays are unique and sorted by identity.
  Runtime and retained document identities are supplied claims, not measured
  current custody.

  Usage sketch with independently supplied bundle and environment claims:

      {:ok, projection} = WotexHome.Rules.ComposedMapping.build(bundle, environment)
      :ok = WotexHome.Rules.ComposedMapping.validate(bundle, current_environment, projection)

  Success is `{:ok, projection}` with exactly `"format"`, `"scope"`,
  `"source_sha256"`, `"runtime_sha256"`, `"mapping_sha256"`, `"bindings"` and
  `"program"`. Format is `"wotex-home.composed-mapping@1"`, scope is
  `"composed_mapping_claims_only"`, bindings are ordered origin records and
  program is the complete plain `Wotex.Routines.Program`. Native Boolean, ppm,
  Kelvin and detector read values preserve exact scalar meaning. External reads
  reconstruct their supplied Definition and reuse its full Mapping/Basis/Registry.
  Source effects require `"native_write"` with `"reported_match"` completion;
  reported edges require an external-read Mapping declaring continuous evidence.

  `WotexHome.Rules.ComposedMapping.validate/3` rebuilds from the independently
  supplied current environment and compares the entire projection. It returns
  `:ok` only on equality. Reusing the projection's own claims proves internal
  correspondence alone; recalculating a digest cannot repair an altered result.

  The bundle is at most 4 MiB, with at most 63 children and 32 selectors. Each
  source independently fits 32 KiB/depth sixteen; retained Thing and Definition
  documents fit 64 KiB and 256 KiB respectively. Environment, projection and
  combined argument envelopes obey the fixed 64 MiB aggregate and other bounds
  in `WotexHome.Rules.ComposedProfile`. Every embedded copy counts. Unknown
  members, structs, unsorted/duplicate identities and partial environments refuse.

  Refusals are payload-free `{:error, code}` tuples:

  | Code | Meaning |
  | --- | --- |
  | `:invalid_composed_mapping` | Malformed shape or retained document correspondence |
  | `:composed_mapping_limit` | Byte, shape, count or integer bound exceeded |
  | `:unsupported_composed_mapping` | Unsupported capability, value or source use |
  | `:composed_mapping_basis_changed` | Selector differs from supplied declaration/input |
  | `:composed_registry_conflict` | One registry identity has unequal records |
  | `:composed_mapping_unavailable` | Required public producer/native API is absent |
  | `:invalid_composed_projection` | Claimed projection fails full regeneration comparison |

  Construction reads no Store, clock, device or runtime inventory and creates no
  installation or execution authority. `WotexHome.Authority` and
  `WotexHome.Durable.Store` separately own current authors/grants, source and
  clock custody, signed qualification, complete membership and durable admission.
  Inert mapping success never qualifies physical execution.
  """

  alias Wotex.Routines.{Basis, Input, InputMapping, Registry, Unit}
  alias WotexHome.Durable.Registry, as: HomeRegistry
  alias WotexHome.Profiles.ReadDeclarationCodec
  alias WotexHome.Rules.{ComposedNativeBasis, ComposedProfile, ExternalInput}
  alias WotexHome.Rules.ComposedMappingFormat, as: F
  alias WotexHome.Semantics.ReadCapability

  @api [
    {Wotex.JSON, :encode, 2},
    {Wotex.JSON, :decode, 2},
    {Registry, :new, 2},
    {Basis, :new, 3},
    {Basis, :semantic_digest, 2},
    {Unit, :new, 2},
    {InputMapping, :to_map, 3},
    {Input, :binding_basis, 3},
    {HomeRegistry, :decode_thing, 1},
    {HomeRegistry, :encode_thing, 1},
    {ExternalInput, :decode, 1},
    {ExternalInput, :new, 3},
    {ReadDeclarationCodec, :decode, 1}
  ]

  @doc "Builds the complete mapping claim under the fixed composed profile."
  @spec build(term(), term()) :: {:ok, map()} | {:error, atom()}
  def build(bundle, environment) do
    F.guard(fn ->
      with :ok <- available(),
           {:ok, selection} <- ComposedProfile.new(),
           {:ok, bundle} <- F.admit(bundle, selection, 4_194_304),
           {:ok, environment} <- F.admit(environment, selection, 67_108_864),
           {:ok, _} <- F.canonical(%{"bundle" => bundle, "environment" => environment}, selection),
           :ok <- F.bundle(bundle, selection),
           :ok <- F.environment(environment, bundle),
           {:ok, targets} <-
             reconstruct(environment["targets"], &target(&1, selection), & &1["target_id"]),
           {:ok, inputs} <-
             reconstruct(
               environment["external_inputs"],
               &external/1,
               &{&1["target_id"], &1["capability_key"]}
             ),
           {:ok, contracts} <- ComposedNativeBasis.contracts(selection),
           {:ok, parts} <-
             selectors(bundle["bindings"], environment, targets, inputs, contracts, selection),
           {:ok, registry} <- merge(contracts ++ Enum.flat_map(parts, & &1.records)),
           {:ok, bases} <- merge(Enum.flat_map(parts, & &1.bases)),
           {:ok, registry_value} <- Registry.new(registry, selection.limits),
           :ok <-
             F.each(bases, fn basis ->
               case Basis.new(basis, registry_value, selection.limits) do
                 {:ok, _} -> :ok
                 error -> error
               end
             end),
           :ok <- uses(bundle, parts),
           {:ok, source_hash} <- F.hash("wotex-home.routine-source@1", bundle, selection) do
        projection(bundle, environment, parts, registry, bases, source_hash, selection)
      end
    end)
  end

  @doc "Rebuilds from independently supplied claims and requires exact full projection equality."
  @spec validate(term(), term(), term()) :: :ok | {:error, atom()}
  def validate(bundle, environment, projection) do
    with {:ok, rebuilt} <- build(bundle, environment) do
      F.guard(fn ->
        with {:ok, selection} <- ComposedProfile.new(),
             {:ok, bundle} <- F.admit(bundle, selection, 4_194_304),
             {:ok, environment} <- F.admit(environment, selection, 67_108_864),
             {:ok, claimed} <- F.admit(projection, selection, 67_108_864),
             {:ok, _} <-
               F.canonical(
                 %{"bundle" => bundle, "environment" => environment, "projection" => claimed},
                 selection
               ),
             true <- claimed === rebuilt do
          :ok
        else
          {:error, :composed_mapping_limit} = error -> error
          _ -> {:error, :invalid_composed_projection}
        end
      end)
    end
  end

  defp projection(bundle, environment, parts, registry, bases, source_hash, selection) do
    origins = Enum.map(parts, & &1.origin)
    bindings = Map.new(parts, &{&1.origin["name"], &1.binding})
    runtime = environment["runtime_sha256"]

    with {:ok, mapping_hash} <-
           F.hash(
             "wotex-home.composed-mapping-basis@1",
             [source_hash, runtime, origins, registry, bases, bindings],
             selection
           ),
         context = %{
           "registry" => registry,
           "bases" => bases,
           "bindings" => bindings,
           "definitions" => bundle["definitions"],
           "arguments" => bundle["arguments"],
           "compiler_basis" => "sha256:" <> mapping_hash
         },
         {:ok, program} <- ComposedProfile.compile(bundle["source"], context),
         {:ok, plain} <- ComposedProfile.to_map(program) do
      result = %{
        "format" => "wotex-home.composed-mapping@1",
        "scope" => "composed_mapping_claims_only",
        "source_sha256" => source_hash,
        "runtime_sha256" => runtime,
        "mapping_sha256" => mapping_hash,
        "bindings" => origins,
        "program" => plain
      }

      with {:ok, _} <- F.canonical(result, selection), do: {:ok, result}
    end
  end

  defp reconstruct(rows, constructor, identity) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case constructor.(row) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, identity.(row), value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp target(row, selection) do
    with {:ok, _} <- F.admit(row["thing_document"], selection, 65_536),
         {:ok, thing} <- HomeRegistry.decode_thing(row["thing_document"]),
         {:ok, document} <- HomeRegistry.encode_thing(thing),
         true <- document === row["thing_document"] do
      {:ok, %{thing: thing, row: row, sha256: F.bare(document)}}
    else
      {:error, :composed_mapping_limit} = error -> error
      _ -> F.invalid()
    end
  end

  defp external(row) do
    with {:ok, historical} <- ExternalInput.decode(row["definition_document"]),
         data = historical["data"],
         {:ok, value} <- ExternalInput.new(data["context"], data["mapping"], data["registry"]),
         true <- value.document === row["definition_document"] do
      {:ok, %{definition: value, row: row}}
    else
      false -> F.invalid()
      error -> error
    end
  end

  defp selectors(selectors, environment, targets, inputs, contracts, selection) do
    Enum.reduce_while(selectors, {:ok, []}, fn selector, {:ok, acc} ->
      target = Map.fetch!(targets, selector["target_id"])

      result =
        if target.thing.id === selector["target_id"] and
             target.sha256 === selector["declaration_sha256"] do
          selected(selector, target, inputs, environment["runtime_sha256"], contracts, selection)
        else
          {:error, :composed_mapping_basis_changed}
        end

      case result do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp selected(%{"kind" => "external_read"} = selector, target, inputs, _, _, _) do
    input = Map.fetch!(inputs, {selector["target_id"], selector["capability_key"]})
    definition = input.definition
    context = definition.data["context"]
    cap = target.thing.capabilities[selector["capability_key"]]
    installed = selector["input"]

    cond do
      input.row["install_revision"] !== installed["install_revision"] or
        input.row["generation"] !== installed["generation"] or
        definition.sha256 !== installed["definition_sha256"] or
        context["target_id"] !== selector["target_id"] or
        context["capability_key"] !== selector["capability_key"] or
          context["resource_revision"] !== target.row["resource_revision"] ->
        {:error, :composed_mapping_basis_changed}

      target.thing.role != "EnvironmentalSensor" or not is_struct(cap, ReadCapability) ->
        F.unsupported()

      true ->
        with {:ok, declared} <- ReadDeclarationCodec.decode(cap.record),
             true <- declared["data"] === context["declaration"] do
          basis = definition.data["mapping"]["basis"]
          {:ok, part(selector, target, basis, definition.data["registry"])}
        else
          false -> {:error, :composed_mapping_basis_changed}
          error -> error
        end
    end
  end

  defp selected(selector, target, _, runtime, contracts, selection) do
    with {:ok, basis, record} <-
           ComposedNativeBasis.build(selector, target.thing, runtime, contracts, selection) do
      {:ok, part(selector, target, basis, [record])}
    end
  end

  defp part(selector, target, basis, records) do
    input = selector["input"]
    origin = Map.take(selector, ~w(name kind target_id capability_key declaration_sha256))

    origin =
      Map.merge(origin, %{
        "resource_revision" => target.row["resource_revision"],
        "input_install_revision" => if(input, do: input["install_revision"]),
        "input_generation" => if(input, do: input["generation"]),
        "definition_sha256" => if(input, do: input["definition_sha256"])
      })

    iri = F.iri(selector["target_id"])

    binding = %{
      "basis" => F.reference(basis),
      "thing_id" => iri,
      "resource_roles" =>
        if(selector["kind"] == "native_write", do: %{"target" => iri}, else: %{})
    }

    %{origin: origin, binding: binding, records: records, bases: [basis]}
  end

  defp merge(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn record, {:ok, acc} ->
      case Map.fetch(acc, record["id"]) do
        :error -> {:cont, {:ok, Map.put(acc, record["id"], record)}}
        {:ok, existing} when existing === record -> {:cont, {:ok, acc}}
        _ -> {:halt, {:error, :composed_registry_conflict}}
      end
    end)
    |> case do
      {:ok, table} -> {:ok, Enum.sort_by(Map.values(table), & &1["id"])}
      error -> error
    end
  end

  defp uses(bundle, parts) do
    by_name = Map.new(parts, &{&1.origin["name"], &1})

    F.each([bundle["source"] | bundle["definitions"]], fn source ->
      with :ok <- edge(source["trigger"], by_name), do: effects(source["steps"], by_name)
    end)
  end

  defp edge(%{"kind" => "edge", "binding" => name}, parts) do
    part = Map.fetch!(parts, name)
    basis = hd(part.bases)

    if part.origin["kind"] == "external_read" and basis["evidence"]["continuity"] == "continuous",
      do: :ok,
      else: F.unsupported()
  end

  defp edge(_, _), do: :ok

  defp effects(%{"kind" => "effect"} = node, parts) do
    if parts[node["binding"]].origin["kind"] == "native_write" and
         node["completion"] == "reported_match", do: :ok, else: F.unsupported()
  end

  defp effects(node, parts), do: F.each(F.children(node), &effects(&1, parts))

  defp available do
    if Enum.all?(@api, fn {module, function, arity} ->
         Code.ensure_loaded?(module) and function_exported?(module, function, arity)
       end), do: :ok, else: {:error, :composed_mapping_unavailable}
  end
end
