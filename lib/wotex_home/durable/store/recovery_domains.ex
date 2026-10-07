defmodule WotexHome.Durable.Store.RecoveryDomains do
  @moduledoc "Complete retained Thing domains and conservative transport dependencies; no isolation."
  alias WotexHome.{Id, Durable.Registry}
  alias WotexHome.Durable.Store.RecoverySnapshot
  alias WotexHome.Lifx.{Packet, ProfileCatalogue}
  alias WotexHome.Profiles.{Artifact, Bindings, Codec}
  alias WotexHome.Semantics.Thing
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @format "wotex-home.controller-domains.v2"
  @count_fields ~w(principal_rows active_principal_rows qualified_profile_heads current_observation_rows target_grant_rows source_grant_rows override_lease_rows)a
  @history ~w(revision thing_id stable_id identity_digest digest_version candidate_ref review_ref method qualification_ref operator_id profile_ref manufacturer model firmware)
  @binding ~w(thing_id stable_id identity_digest candidate_ref review_ref method qualification_ref operator_id profile_ref revision digest_version)
  @selection ~w(revision generation state artifact_digest projection_digest resource_revision binding_revision runtime_digest thing_document)
  @unknown ["unknown"]
  @traces ~w(journal observation_current request_receipts request_execution profile_qualifications profile_qualification_history)
          |> Enum.map(fn table ->
            target =
              if table in ~w(request_receipts request_execution),
                do: "target_id",
                else: "thing_id"

            "SELECT #{target} AS target_id,profile_ref FROM #{table}"
          end)
          |> Enum.join(" UNION ALL ")

  def derive(db, mode) do
    with {:ok, logical} <- RecoverySnapshot.commitment(db, mode),
         {:ok, things} when length(things) <= 64 <-
           query(
             db,
             "SELECT thing_id,status,profile_ref,resource_revision,document FROM enrolled_things ORDER BY thing_id COLLATE BINARY LIMIT 65"
           ),
         {:ok, [[selections]]} when selections <= 2_048 <-
           query(db, "SELECT COUNT(*) FROM profile_selection_history"),
         {:ok, artifacts} <- artifacts(db),
         {:ok, records} <- records(db, things, artifacts),
         {:ok, records} <- unresolved(db, records),
         {:ok, counts} <- source_counts(db),
         document =
           JSON.encode!([@format, logical, Enum.map(@count_fields, &counts[&1]), records]),
         true <- byte_size(document) <= 4_194_304 do
      counter =
        if records != [] and Enum.all?(records, &complete?/1),
          do: "no_radio_state",
          else: "unknown"

      {:ok,
       %{
         document: document,
         domain_digest: Artifact.digest(document),
         domain_count: length(records),
         counter_state: counter,
         counter_state_digest: nil,
         source_counts: counts,
         logical_snapshot_digest: logical
       }}
    else
      _ -> invalid()
    end
  end

  defp source_counts(db) do
    with {:ok, [counts]} <-
           query(db, """
           SELECT
             (SELECT COUNT(*) FROM principals),
             (SELECT COUNT(*) FROM principals WHERE status='active'),
             (SELECT COUNT(*) FROM profile_qualifications WHERE status='qualified'),
             (SELECT COUNT(*) FROM observation_current),
             (SELECT COUNT(*) FROM principal_targets),
             (SELECT COUNT(*) FROM source_epoch_grants),
             (SELECT COUNT(*) FROM operator_override_leases)
           """),
         true <- length(counts) == length(@count_fields),
         true <- Enum.all?(counts, &(is_integer(&1) and &1 in 0..131_072)),
         true <- Enum.at(counts, 1) <= hd(counts) do
      {:ok, Map.new(Enum.zip(@count_fields, counts))}
    else
      _ -> invalid()
    end
  end

  defp artifacts(db) do
    with {:ok, rows} when length(rows) <= 64 <-
           query(
             db,
             "SELECT id,version,artifact_digest,projection_digest,metadata_document FROM portable_profiles ORDER BY artifact_digest LIMIT 65"
           ) do
      Enum.reduce_while(rows, {:ok, %{}}, fn [id, version, raw, projection_digest, bytes],
                                             {:ok, artifacts} ->
        with {:ok, data} <- Codec.decode(bytes),
             {:ok, projection} <- Bindings.historical_projection(data),
             true <- Artifact.digest(projection) == projection_digest do
          reference = id <> ":" <> version

          {:cont,
           {:ok,
            Map.put(artifacts, reference, %{data: data, raw: raw, projection: projection_digest})}}
        else
          _ -> {:halt, invalid()}
        end
      end)
    else
      _ -> invalid()
    end
  end

  defp records(db, things, artifacts) do
    Enum.reduce_while(things, {:ok, []}, fn [target, status, reference, resource, document],
                                            {:ok, records} ->
      with {:ok, %Thing{id: ^target, profile_ref: ^reference} = thing} <-
             Registry.decode_thing(document),
           {:ok, binding_rows} <-
             query(
               db,
               "SELECT #{Enum.join(@binding, ",")} FROM enrollment_bindings WHERE thing_id=?",
               [target]
             ),
           true <- length(binding_rows) <= 1,
           {:ok, history} when length(history) <= 32 <-
             query(
               db,
               "SELECT #{Enum.join(@history, ",")} FROM enrollment_review_history WHERE thing_id=? ORDER BY revision LIMIT 33",
               [target]
             ),
           {:ok, selection_rows} when length(selection_rows) <= 2_048 <-
             query(
               db,
               "SELECT #{Enum.join(@selection, ",")} FROM profile_selection_history WHERE target_id=? ORDER BY revision LIMIT 2049",
               [target]
             ),
           {:ok, selections} <- selection_records(selection_rows, target, history, artifacts),
           {:ok, trace_profiles} <-
             query(
               db,
               "SELECT DISTINCT profile_ref FROM (#{@traces}) WHERE target_id=? LIMIT 34",
               [target]
             ) do
        binding = List.first(binding_rows)
        head = if binding, do: Enum.find(history, &(hd(&1) == Enum.at(binding, 9))), else: nil
        identities = Enum.map(history, &[&1, resolve(&1, nil, artifacts)])
        current = resolve(head, thing, artifacts)
        references = [reference | Enum.map(history, &Enum.at(&1, 10))]

        current =
          if Enum.all?(trace_profiles, fn [profile] -> profile in references end),
            do: current,
            else: @unknown

        record = [
          target,
          status,
          reference,
          resource,
          Artifact.digest(document),
          capabilities(thing),
          binding,
          identities,
          selections,
          current
        ]

        {:cont, {:ok, records ++ [record]}}
      else
        _ -> {:halt, invalid()}
      end
    end)
  end

  defp unresolved(db, records) do
    with {:ok, targets} when length(targets) <= 64 <-
           query(
             db,
             "SELECT DISTINCT target_id FROM (SELECT thing_id AS target_id FROM enrolled_things UNION ALL SELECT target_id FROM (#{@traces})) ORDER BY target_id COLLATE BINARY LIMIT 65"
           ),
         true <- Enum.all?(targets, fn [target] -> Id.valid?(target) end) do
      known = Enum.map(records, &hd/1)

      extra =
        for [target] <- targets,
            target not in known,
            do: [target, "unresolved", nil, nil, nil, [], nil, [], [], @unknown]

      {:ok, Enum.sort_by(records ++ extra, &hd/1)}
    else
      _ -> invalid()
    end
  end

  defp selection_records(rows, target, history, artifacts) do
    Enum.reduce_while(rows, {:ok, []}, fn [
                                            revision,
                                            generation,
                                            state,
                                            raw,
                                            projection,
                                            resource,
                                            binding,
                                            runtime,
                                            document
                                          ],
                                          {:ok, records} ->
      with {:ok, %Thing{id: ^target} = thing} <- Registry.decode_thing(document) do
        identity = Enum.find(history, &(hd(&1) == binding))
        transport = resolve(identity, thing, artifacts)

        record = [
          revision,
          generation,
          state,
          raw,
          projection,
          resource,
          binding,
          runtime,
          Artifact.digest(document),
          capabilities(thing),
          transport
        ]

        {:cont, {:ok, records ++ [record]}}
      else
        _ -> {:halt, invalid()}
      end
    end)
  end

  defp resolve(values, thing, artifacts) when is_list(values) and length(values) == 14 do
    identity = Map.new(Enum.zip(@history, values))

    with 2 <- identity["digest_version"],
         "legacy_tofu" <- identity["method"],
         "lifx:" <> serial <- identity["stable_id"],
         {:ok, _} <- Packet.target_from_hex(serial),
         {:ok, profile, expected, kind, dependency} <- profile(identity, artifacts),
         true <-
           profile.transport == "udp" and profile.manufacturer == identity["manufacturer"] and
             profile.model == identity["model"] and
             identity["firmware"] in profile.firmware_versions,
         true <- profile.qualification_ref == identity["qualification_ref"],
         true <- is_nil(thing) or power?(thing, expected) do
      [
        "lifx-direct-power-v1",
        "udp",
        "no_authenticated_radio_state",
        identity["profile_ref"],
        identity["stable_id"],
        identity["manufacturer"],
        identity["model"],
        identity["firmware"],
        kind,
        dependency
      ]
    else
      _ -> @unknown
    end
  end

  defp resolve(_, _, _), do: @unknown

  defp profile(identity, artifacts) do
    case artifacts[identity["profile_ref"]] do
      nil ->
        with {:ok, package} <-
               ProfileCatalogue.fetch(identity["profile_ref"], identity["thing_id"]),
             do: {:ok, package.profile, package.thing, "compiled", ProfileCatalogue.digest()}

      artifact ->
        with {:ok, thing} <-
               Bindings.historical_declaration(artifact.data, artifact.raw, identity["thing_id"]),
             {:ok, profile} <-
               WotexHome.Discovery.Profile.new(
                 Map.merge(artifact.data["fingerprint"], %{
                   "id" => artifact.data["id"],
                   "version" => artifact.data["version"],
                   "rank" => 0,
                   "qualification_ref" => "qualification:pending:profile:" <> artifact.raw
                 })
               ),
             do: {:ok, profile, thing, "portable", artifact.projection}
    end
  end

  defp power?(
         %Thing{role: "Light", capabilities: %{"power" => power} = capabilities} = thing,
         expected
       ) do
    wanted = expected.capabilities["power"]

    map_size(capabilities) == 1 and thing.id == expected.id and
      thing.profile_ref == expected.profile_ref and
      power.value_kind == wanted.value_kind and power.unit == wanted.unit and
      power.risk_class == wanted.risk_class and power.evidence_ref == wanted.evidence_ref and
      Enum.all?(power.operations, &(&1 in wanted.operations)) and power.constraints == %{} and
      power.extensions == %{}
  end

  defp power?(_, _), do: false

  defp capabilities(thing) do
    thing.capabilities
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, capability} ->
      [
        key,
        Enum.sort(capability.operations),
        capability.risk_class,
        capability.value_kind,
        capability.unit
      ]
    end)
  end

  defp complete?([_, _, _, _, _, _, binding, identities, selections, current]) do
    not is_nil(binding) and identities != [] and current != @unknown and
      Enum.all?(identities, &(List.last(&1) != @unknown)) and
      Enum.all?(selections, &(List.last(&1) != @unknown))
  end

  defp invalid, do: {:error, :invalid_transfer_domains}
end
