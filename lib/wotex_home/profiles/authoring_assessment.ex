defmodule WotexHome.Profiles.AuthoringAssessment do
  @moduledoc "Pure bounded manual finalization and producer mechanics diagnostics, without consumer admission."
  alias WotexHome.Profiles.{AuthoringContract, AuthoringProducer}
  @enforce_keys [:draft_bytes, :bundle_bytes, :contract, :capture, :data]
  defstruct @enforce_keys

  def assess(bytes, contract, capture) do
    with {:ok, summary} <- AuthoringContract.to_map(contract),
         :ok <- draft(bytes, summary["limits"]["max_bundle_bytes"]),
         :ok <- capture(capture, summary["limits"]["reader"]),
         {:ok, final} <- producer(Wotex.Profiles.Draft, :finalize, [bytes, contract.contract]),
         {:ok, bundle, phase, report} <- finalized(final, bytes, contract, capture),
         {:ok, report} <-
           producer(Wotex.Profiles.ValidationReport, :to_map, [report, contract.contract]),
         true <-
           report["contract_sha256"] == contract.contract_sha256 and
             report["candidate_sha256"] == AuthoringProducer.sha(bundle || bytes) do
      data = %{
        "format" => "wotex-home.authoring-mechanics@1",
        "basis_sha256" => summary["basis_sha256"],
        "draft_sha256" => AuthoringProducer.sha(bytes),
        "bundle_sha256" => if(bundle, do: AuthoringProducer.sha(bundle)),
        "phase" => phase,
        "disposition" => report["disposition"],
        "capture_status" => report["capture_status"],
        "report" => report,
        "home_consumption" => "not_assessed",
        "source_review" => "not_assessed",
        "fixture_status" => "not_supplied"
      }

      {:ok,
       %__MODULE__{
         draft_bytes: bytes,
         bundle_bytes: bundle,
         contract: contract,
         capture: capture,
         data: data
       }}
    else
      false -> {:error, :invalid_authoring_assessment}
      error -> error
    end
  end

  def to_map(%__MODULE__{} = value, current_contract) when map_size(value) == 6 do
    with {:ok, current} <- AuthoringContract.to_map(current_contract),
         {:ok, original} <- AuthoringContract.to_map(value.contract),
         :ok <- same_basis(original, current),
         {:ok, rebuilt} <- assess(value.draft_bytes, current_contract, value.capture),
         true <- rebuilt == value,
         do: {:ok, rebuilt.data},
         else: (
           false -> {:error, :invalid_authoring_assessment}
           error -> error
         )
  end

  def to_map(_, _), do: {:error, :invalid_authoring_assessment}

  defp draft(bytes, limit) when is_binary(bytes) and byte_size(bytes) > 0 do
    if byte_size(bytes) <= limit, do: :ok, else: {:error, :authoring_limit}
  end

  defp draft(_, _), do: {:error, :invalid_authoring_assessment}

  defp capture(nil, _), do: :ok

  defp capture(data, limits) when is_map(data) and not is_struct(data) do
    options = [
      max_bytes: limits["max_bytes"],
      max_depth: limits["max_depth"],
      max_nodes: limits["max_nodes"],
      max_collection_size: 32,
      max_string_bytes: 256
    ]

    with {:ok, bytes} <- producer(Wotex.JSON, :encode, [data, options]) do
      if byte_size(bytes) <= limits["max_bytes"], do: :ok, else: {:error, :authoring_limit}
    end
  end

  defp capture(_, _), do: {:error, :invalid_authoring_assessment}

  defp finalized(%{__struct__: Wotex.Profiles.Finalized} = value, bytes, contract, capture)
       when map_size(value) == 5 do
    if value.draft_sha256 == AuthoringProducer.sha(bytes) and
         value.contract_sha256 == contract.contract_sha256 and
         is_binary(value.bundle_bytes) and byte_size(value.bundle_bytes) > 0 and
         byte_size(value.bundle_bytes) <= contract.inputs["limits"]["max_bundle_bytes"] and
         value.bundle_sha256 == AuthoringProducer.sha(value.bundle_bytes) do
      with {:ok, report} <-
             producer(Wotex.Profiles.Validation, :check, [
               value.bundle_bytes,
               contract.contract,
               capture
             ]),
           do: {:ok, value.bundle_bytes, "validate", report}
    else
      {:error, :invalid_authoring_assessment}
    end
  end

  defp finalized(%{__struct__: Wotex.Profiles.ValidationReport} = report, _, _, _)
       when map_size(report) == 2 do
    if report.data["disposition"] == "invalid",
      do: {:ok, nil, "finalize", report},
      else: {:error, :invalid_authoring_assessment}
  end

  defp finalized(_, _, _, _), do: {:error, :invalid_authoring_assessment}

  defp same_basis(%{"basis_sha256" => basis}, %{"basis_sha256" => basis}), do: :ok
  defp same_basis(_, _), do: {:error, :stale_authoring_basis}

  defp producer(module, function, args),
    do: AuthoringProducer.call(module, function, args, :invalid_authoring_assessment)
end
