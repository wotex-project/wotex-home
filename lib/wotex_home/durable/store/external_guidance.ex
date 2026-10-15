defmodule WotexHome.Durable.Store.ExternalGuidance do
  @moduledoc """
  Projects bounded external-profile preparation metadata for the single Store.

  `context/3`, `sources/3` and `target/3` authenticate on Store's borrowed
  connection before consulting the installed reader or host source owner. They
  return `{:ok, metadata}` or `{:error, reason}` with body ceilings of 4,096,
  32,768 and 8,192 bytes respectively. Source choices contain at most 32 sorted
  entries; absent live reader/source owners are represented as unavailable
  rather than reconstructed from retained target history.

  `inspection/3` resolves only the actor's exact retained inspection and owned
  imports, returning `{:ok, header, original, objects}`, `:not_found` or a typed
  error. Store then rebuilds the approval manifest from current immutable bytes
  and the matching reader; `artifact/3` checks that prepared manifest identity
  and wraps the safe metadata within 65,536 bytes. It does not independently
  establish actor ownership or byte custody.

  This stateless collaborator creates no operation, lease, grant or journal row.
  Comparison metadata is a snapshot, not current authority or a reservation.
  Adapters use the corresponding `WotexHome.Authority` operations; they neither
  open another connection nor supply a source-owner process in a request.
  """

  alias WotexHome.Durable.Store.{
    ExternalInspections,
    ExternalTargets,
    ExternalTrustWriter,
    MaintenanceWriter,
    ProfileWriter
  }

  alias WotexHome.Profiles.{EnvelopeCodec, ExternalArtifact, ExternalSourceOwner, ReaderSelection}
  @maximum 9_223_372_036_854_775_807
  @reference ~w(authority_epoch input_sha256 operation_id result_sha256 revision)
  @source_fields ~w(method policy_sha256 reader_basis_sha256 source_epoch source_generation source_ref trust)

  def context(db, credential, reader) do
    with {:ok, header, _} <- basis(db, credential, false),
         {:ok, maintenance} <- MaintenanceWriter.snapshot(db),
         do:
           sized(
             Map.merge(header, %{
               "format" => "wotex-home.external-profile-context@1",
               "maintenance" => Atom.to_string(maintenance.state),
               "maintenance_revision" => maintenance.begin_revision,
               "reader" => reader_summary(reader)
             }),
             4096
           )
  end

  def sources(db, credential, owner) do
    with {:ok, header, _} <- basis(db, credential, true),
         {:ok, sources} <- source_catalogue(owner),
         do:
           sized(
             Map.merge(
               header,
               Map.put(sources, "format", "wotex-home.external-source-catalogue@1")
             ),
             32768
           )
  end

  def target(db, credential, target) do
    with true <- WotexHome.Id.valid?(target),
         {:ok, header, catalogue} <- basis(db, credential, true),
         :ok <- ExternalTargets.validate(db),
         {:ok, cursor} <- ExternalTargets.cursor(db, target),
         {:ok, artifact, trust} <- target_artifact(cursor, catalogue),
         do:
           sized(
             Map.merge(header, %{
               "format" => "wotex-home.external-target-basis@1",
               "target_id" => target,
               "state" => cursor.state || "absent",
               "selection_revision" => cursor.selection_revision,
               "selection_generation" => cursor.generation,
               "resource_revision" => cursor.resource_revision,
               "binding_revision" => cursor.binding_revision,
               "artifact_digest" => artifact,
               "trust_revision" => trust
             }),
             8192
           ),
         else: (
           false -> {:error, :invalid_external_target}
           error -> error
         )
  end

  def reference?(value) do
    EnvelopeCodec.keys?(value, @reference) and
      Enum.all?(
        ~w(authority_epoch revision),
        &(is_integer(value[&1]) and value[&1] in 1..@maximum)
      ) and
      WotexHome.Id.valid?(value["operation_id"]) and
      Enum.all?(~w(input_sha256 result_sha256), &EnvelopeCodec.digest?(value[&1]))
  end

  def inspection(db, credential, reference) do
    with true <- reference?(reference),
         {:ok, header, _} <- basis(db, credential, false),
         :ok <- ExternalInspections.validate(db),
         {:ok, original} <-
           ExternalInspections.retained_original(db, header["principal_id"], reference),
         {:ok, objects} <-
           ExternalInspections.owned_records(db, header["principal_id"], original.input),
         do: {:ok, header, original, objects},
         else: (
           false -> {:error, :invalid_external_inspection_reference}
           error -> error
         )
  end

  def artifact(header, reference, value) do
    with {:ok, _} <- ExternalArtifact.encode(value["artifact"]),
         {:ok, digest} <- ExternalArtifact.identity(value["artifact"]),
         true <- digest == value["artifact_digest"],
         do:
           sized(
             Map.merge(header, %{
               "format" => "wotex-home.external-inspection-artifact@1",
               "inspection_ref" => reference,
               "artifact_digest" => digest,
               "artifact" => value["artifact"]
             }),
             65536
           ),
         else: (
           false -> {:error, :external_artifact_mismatch}
           error -> error
         )
  end

  defp basis(db, credential, target?) do
    with {:ok, principal} <-
           if(target?,
             do: ExternalTargets.actor(db, credential),
             else: ProfileWriter.review_actor(db, credential)
           ),
         {:ok, catalogue} <- ExternalTrustWriter.catalogue(db, credential),
         do:
           {:ok,
            Map.put(
              Map.take(catalogue, ~w(authority_epoch store_revision policy_generation)),
              "principal_id",
              principal
            ), catalogue}
  end

  defp target_artifact(%{outcome: nil}, _), do: {:ok, nil, 0}

  defp target_artifact(cursor, catalogue) do
    with {:ok, artifact} <- ExternalArtifact.decode(cursor.outcome["artifact_document"]),
         {:ok, digest} <- ExternalArtifact.identity(artifact),
         item when is_map(item) <-
           Enum.find(catalogue["items"], &(&1["artifact_digest"] == digest)),
         do: {:ok, digest, item["trust_revision"]},
         else: (_ -> {:error, :corrupt_external_targets})
  end

  defp reader_summary(nil), do: unavailable_reader("external_reader_unavailable")

  defp reader_summary(reader) do
    case ReaderSelection.to_map(reader) do
      {:ok, summary} ->
        %{"state" => "available", "basis_sha256" => summary["basis_sha256"], "reason" => nil}

      {:error, :profiles_producer_unavailable} ->
        unavailable_reader("profiles_producer_unavailable")

      _ ->
        unavailable_reader("external_reader_unavailable")
    end
  end

  defp unavailable_reader(reason),
    do: %{"state" => "unavailable", "basis_sha256" => nil, "reason" => reason}

  defp unavailable_sources,
    do:
      {:ok,
       %{
         "state" => "unavailable",
         "owner_epoch" => nil,
         "sources" => [],
         "reason" => "external_source_unavailable"
       }}

  defp source_catalogue(nil), do: unavailable_sources()

  defp source_catalogue(owner) do
    case ExternalSourceOwner.catalogue(owner) do
      {:ok, value} -> project_sources(value)
      _ -> {:error, :invalid_external_source_catalogue}
    end
  catch
    :exit, _ -> unavailable_sources()
  end

  defp project_sources(value) do
    with true <-
           EnvelopeCodec.keys?(value, ~w(owner_epoch sources)) and epoch?(value["owner_epoch"]),
         true <- bounded?(value["sources"], 32),
         rows = Enum.map(value["sources"], &source_row/1),
         true <- Enum.all?(rows, &is_map/1),
         refs = Enum.map(rows, & &1["source_ref"]),
         true <- refs == Enum.sort(Enum.uniq(refs)),
         do:
           {:ok,
            %{
              "state" => "available",
              "owner_epoch" => value["owner_epoch"],
              "sources" => rows,
              "reason" => nil
            }},
         else: (_ -> {:error, :invalid_external_source_catalogue})
  end

  defp source_row(row) do
    with true <- EnvelopeCodec.keys?(row, ~w(data source_ref source_selection_sha256)),
         data = row["data"],
         true <-
           EnvelopeCodec.keys?(
             data,
             ~w(format method policy_sha256 reader_basis_sha256 source_epoch source_generation source_ref stable_id_sha256 trust)
           ),
         true <-
           data["format"] == "wotex-home.external-source-selection@1" and
             row["source_ref"] == data["source_ref"],
         true <- WotexHome.Id.valid?(data["source_ref"]) and epoch?(data["source_epoch"]),
         true <-
           is_integer(data["source_generation"]) and data["source_generation"] in 1..@maximum,
         true <-
           data["method"] in ~w(operator_configured legacy_tofu physical_button qr_install_code) and
             data["trust"] in ~w(unauthenticated_local authenticated_device bridge_attested synthetic_lab),
         true <-
           EnvelopeCodec.digest?(row["source_selection_sha256"]) and
             Enum.all?(
               ~w(policy_sha256 reader_basis_sha256 stable_id_sha256),
               &EnvelopeCodec.digest?(data[&1])
             ),
         do:
           Map.put(
             Map.take(data, @source_fields),
             "source_selection_sha256",
             row["source_selection_sha256"]
           ),
         else: (_ -> :invalid)
  end

  defp epoch?(value),
    do: is_binary(value) and byte_size(value) == 32 and value =~ ~r/\A[0-9a-f]{32}\z/

  defp bounded?([], _), do: true
  defp bounded?([_ | tail], left) when left > 0, do: bounded?(tail, left - 1)
  defp bounded?(_, _), do: false

  defp sized(value, maximum) do
    if byte_size(JSON.encode!(value)) <= maximum,
      do: {:ok, value},
      else: {:error, :external_profile_limit}
  end
end
