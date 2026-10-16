defmodule WotexHome.Rules.ComposedNativeBasis do
  @moduledoc false

  alias Wotex.Routines.Basis
  alias WotexHome.Rules.ComposedMappingFormat, as: F
  alias WotexHome.Semantics.Capability

  @contracts [
    {"wotex-home.composed-security",
     ~w(current_authenticated_actor current_original_author exact_input_target_grants exact_output_target_grants current_installed_basis single_store_commit)},
    {"wotex-home.composed-lifecycle",
     ~w(inert_proposal held_before_queue root_step_reservation_before_queue handoff_before_transport no_uncertain_retry no_refund preserve_partial_unknown)},
    {"wotex-home.composed-scalar-report",
     ~w(current_qualified_device_report exact_typed_equality exclusive_original_receipt_expiry no_protocol_inference no_causation_inference)}
  ]

  def contracts(selection) do
    Enum.reduce_while(@contracts, {:ok, []}, fn {id, obligations}, {:ok, acc} ->
      body = %{
        "format" => "wotex-home.routine-contract.v1",
        "id" => id,
        "version" => "1",
        "obligations" => obligations
      }

      case F.digest(body, selection) do
        {:ok, digest} ->
          {:cont,
           {:ok,
            acc ++
              [%{"id" => id, "version" => "1", "semantic_digest" => digest, "requires" => []}]}}

        error ->
          {:halt, error}
      end
    end)
  end

  def build(selector, thing, runtime, contracts, selection) do
    with %Capability{} = capability <- thing.capabilities[selector["capability_key"]],
         true <- Capability.supports?(capability, "read"),
         true <-
           selector["kind"] != "native_write" or
             (thing.role == "Light" and capability.risk_class == "ordinary" and
                Capability.supports?(capability, "write")),
         {:ok, value} <- value(capability),
         {:ok, identity} <-
           F.canonical(
             [
               "wotex-home.native-routine-basis@1",
               selector["target_id"],
               selector["capability_key"],
               selector["kind"],
               selector["declaration_sha256"],
               runtime
             ],
             selection
           ) do
      write = selector["kind"] == "native_write"
      refs = Enum.map(contracts, &F.reference/1)

      body = %{
        "format" => "wotex.routines.basis@1",
        "id" => "urn:wotex-home:routine-basis:" <> F.bare(identity),
        "version" => "1",
        "affordance" => %{
          "type" => "property",
          "name" => capability.key,
          "operation" => if(write, do: "writeproperty", else: "readproperty")
        },
        "value" => value,
        "output" => nil,
        "security_contract" => Enum.at(refs, 0),
        "lifecycle_contract" => Enum.at(refs, 1),
        "required_contracts" => [],
        "evidence" => %{
          "sources" => ["device_report"],
          "freshness_ms" => capability.freshness_ms,
          "require_source_time" => false,
          "continuity" => "snapshot",
          "completion" => "reported_match",
          "report_contract" => Enum.at(refs, 2)
        },
        "effects" => %{
          "resource_roles" => if(write, do: ["target"], else: []),
          "repeat" => "never",
          "stop" => if(write, do: "separate_effect", else: "unsupported"),
          "supersession" => "block_until_known",
          "partial_possible" => true,
          "unknown_possible" => true
        },
        "timing" => %{
          "deadline_ms" => 86_400_000,
          "duration_ms" => 0,
          "dwell_ms" => 0,
          "cooldown_ms" => 0,
          "uncertainty" => "block"
        },
        "analysis" => %{"classification" => "unsupported", "profile" => nil, "properties" => []},
        "annotations" => %{}
      }

      with {:ok, bytes} <- F.digest(body, selection),
           {:ok, semantics} <- Basis.semantic_digest(body, selection.limits) do
        basis =
          Map.merge(body, %{
            "byte_digest" => bytes,
            "semantic_digest" => semantics,
            "implementation_digest" => "sha256:" <> runtime,
            "compiler_digest" => "sha256:" <> runtime
          })

        {:ok, basis, Map.put(F.reference(basis), "requires", refs)}
      end
    else
      {:error, _} = error -> error
      _ -> F.unsupported()
    end
  end

  defp value(%Capability{role: "Light", key: "power", value_kind: "boolean"}),
    do: {:ok, %{"type" => "boolean", "unit" => nil, "enum" => []}}

  defp value(%Capability{role: "SmokeDetector", key: key, value_kind: "boolean"})
       when key in ~w(fault self_test),
       do: {:ok, %{"type" => "boolean", "unit" => nil, "enum" => []}}

  defp value(%Capability{role: "SmokeDetector", key: "smoke_state", value_kind: "smoke_state"}),
    do: {:ok, %{"type" => "enum", "unit" => nil, "enum" => ~w(clear alarm)}}

  defp value(%Capability{role: role, key: key, value_kind: "fraction"})
       when (role == "Light" and key == "brightness") or
              (role == "SmokeDetector" and key == "battery_fraction"),
       do: integer("fraction", "ppm", 1_000_000, 0, 1_000_000)

  defp value(%Capability{
         role: "Light",
         key: "colour_temperature",
         value_kind: "kelvin",
         constraints: constraints
       }),
       do: integer("temperature", "K", 1, constraints["min"], constraints["max"])

  defp value(_), do: F.unsupported()

  defp integer(dimension, name, denominator, minimum, maximum),
    do:
      {:ok,
       %{
         "type" => "integer",
         "enum" => [],
         "unit" => %{
           "dimension" => dimension,
           "name" => name,
           "scale_n" => 1,
           "scale_d" => denominator,
           "offset_n" => 0,
           "offset_d" => 1,
           "min" => minimum,
           "max" => maximum
         }
       }}
end
