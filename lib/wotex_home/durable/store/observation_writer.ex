defmodule WotexHome.Durable.Store.ObservationWriter do
  @moduledoc """
  Stateless observation transactions for the single Store writer.

  This module receives the Store-owned SQLite handle only for one synchronous
  call. It never opens, closes or retains a database connection and performs no
  device I/O. Returned `:commit` and `:rollback` tuples are consumed by the
  Store's transaction boundary.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.Access
  alias WotexHome.Durable.Store.Journal
  alias WotexHome.Durable.Store.ObservationCodec
  alias WotexHome.Semantics.{Capability, Observation, Thing}

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  import Access, only: [enrolled_thing: 2]
  import Journal, only: [authority_event: 4, next_revision: 1]
  import ObservationCodec, only: [encode_value: 1]

  @max_i64 9_223_372_036_854_775_807
  @select_current """
  SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch,
         source_time_utc_ms, received_time_utc_ms, received_monotonic_ms,
         quality, trust, value_kind, value_a, value_b, revision
  FROM observation_current WHERE thing_id = ? AND capability_key = ?
  """

  @spec record(term(), Observation.t(), Capability.t(), {String.t(), non_neg_integer()}) ::
          tuple()
  def record(db, %Observation{} = observation, %Capability{} = capability, store_clock) do
    with {:ok, thing, _resource_revision} <- enrolled_thing(db, observation.thing_id),
         {:ok, declared} <- Thing.capability(thing, observation.capability_key),
         true <- declared == capability,
         {:ok, rows} <-
           query(db, @select_current, [observation.thing_id, observation.capability_key]),
         :ok <- check_previous(db, rows, observation, capability),
         {:commit, result} <- insert_record(db, observation, capability, store_clock),
         :ok <- maybe_consume_source_epoch_grant(db, rows, observation) do
      {:commit, result}
    else
      :error -> {:rollback, {:policy, :unsupported_capability}}
      false -> {:rollback, {:policy, :capability_mismatch}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      {:duplicate, revision} -> {:rollback, {:duplicate, revision}}
      {:reject, reason} -> {:rollback, {:policy, reason}}
      {:rollback, reason} -> {:rollback, reason}
      {:error, reason} -> {:rollback, reason}
    end
  end

  @spec valid_batch(Thing.t(), [Observation.t()]) ::
          {:ok, [{Observation.t(), Capability.t()}]} | {:error, :invalid_observation_batch}
  def valid_batch(%Thing{} = thing, observations)
      when is_list(observations) and length(observations) in 1..32 do
    with {:ok, _document} <- Registry.encode_thing(thing),
         true <-
           Enum.all?(observations, fn
             %Observation{thing_id: id} -> id == thing.id
             _ -> false
           end),
         true <-
           observations
           |> Enum.map(& &1.capability_key)
           |> then(&(length(&1) == length(Enum.uniq(&1)))),
         true <- one_report_event?(observations) do
      Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, pairs} ->
        case Thing.capability(thing, observation.capability_key) do
          {:ok, capability} ->
            if Observation.valid?(observation, capability) do
              {:cont, {:ok, [{observation, capability} | pairs]}}
            else
              {:halt, {:error, :invalid_observation_batch}}
            end

          :error ->
            {:halt, {:error, :invalid_observation_batch}}
        end
      end)
      |> case do
        {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
        error -> error
      end
    else
      _ -> {:error, :invalid_observation_batch}
    end
  end

  def valid_batch(_thing, _observations), do: {:error, :invalid_observation_batch}

  @spec record_batch(term(), [{Observation.t(), Capability.t()}], tuple()) :: tuple()
  def record_batch(db, pairs, store_clock),
    do: record_batch_with(db, pairs, &record(&1, &2, &3, store_clock))

  @spec record_lifx_refresh_batch(term(), [{Observation.t(), Capability.t()}], tuple()) :: tuple()
  def record_lifx_refresh_batch(db, pairs, store_clock),
    do: record_batch_with(db, pairs, &record_lifx_refresh(&1, &2, &3, store_clock))

  @spec authorize_source_epoch(
          term(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: tuple()
  def authorize_source_epoch(
        db,
        thing_id,
        capability_key,
        old_epoch,
        new_epoch,
        current_revision
      ) do
    with {:ok, thing, _resource_revision} <- enrolled_thing(db, thing_id),
         {:ok, _capability} <- Thing.capability(thing, capability_key),
         {:ok, rows} <- query(db, @select_current, [thing_id, capability_key]),
         :ok <- current_epoch_matches(rows, old_epoch, current_revision),
         {:ok, existing} <-
           query(
             db,
             "SELECT old_epoch, new_epoch, current_revision, grant_revision FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ?",
             [thing_id, capability_key]
           ) do
      case existing do
        [[^old_epoch, ^new_epoch, ^current_revision, revision]] ->
          {:rollback, {:unchanged, {:ok, revision}}}

        _ ->
          with {:ok, revision} <- next_revision(db),
               {:ok, []} <-
                 query(
                   db,
                   "INSERT INTO source_epoch_grants VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(thing_id, capability_key) DO UPDATE SET old_epoch=excluded.old_epoch, new_epoch=excluded.new_epoch, current_revision=excluded.current_revision, grant_revision=excluded.grant_revision",
                   [thing_id, capability_key, old_epoch, new_epoch, current_revision, revision]
                 ),
               :ok <-
                 authority_event(
                   db,
                   revision,
                   "source_epoch_granted",
                   "#{thing_id}/#{capability_key}"
                 ) do
            {:commit, {:ok, revision}}
          else
            {:error, reason} -> {:rollback, reason}
          end
      end
    else
      :error -> {:rollback, {:policy, :unsupported_capability}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      {:error, {:policy, _} = policy} -> {:rollback, policy}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp record_lifx_refresh(db, observation, capability, store_clock) do
    with {:ok, thing, _resource_revision} <- enrolled_thing(db, observation.thing_id),
         {:ok, declared} <- Thing.capability(thing, observation.capability_key),
         true <- declared == capability,
         {:ok, rows} <-
           query(db, @select_current, [observation.thing_id, observation.capability_key]),
         :ok <- check_refresh_previous(rows, observation, capability),
         {:commit, result} <- insert_record(db, observation, capability, store_clock),
         :ok <- clear_superseded_epoch_grant(db, rows, observation) do
      {:commit, result}
    else
      :error -> {:rollback, {:policy, :unsupported_capability}}
      false -> {:rollback, {:policy, :capability_mismatch}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      {:duplicate, revision} -> {:rollback, {:duplicate, revision}}
      {:reject, reason} -> {:rollback, {:policy, reason}}
      {:rollback, reason} -> {:rollback, reason}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp record_batch_with(db, pairs, recorder) do
    Enum.reduce_while(pairs, {[], 0, 0}, fn {observation, capability},
                                            {revisions, new_count, duplicate_count} ->
      case recorder.(db, observation, capability) do
        {:commit, {:ok, revision}} ->
          {:cont, {[revision | revisions], new_count + 1, duplicate_count}}

        {:rollback, {:duplicate, revision}} ->
          {:cont, {[revision | revisions], new_count, duplicate_count + 1}}

        {:rollback, reason} ->
          {:halt, {:rollback, reason}}
      end
    end)
    |> case do
      {revisions, new_count, 0} when new_count > 0 ->
        {:commit, {:ok, Enum.reverse(revisions)}}

      {revisions, 0, duplicate_count} when duplicate_count > 0 ->
        {:rollback, {:unchanged, {:duplicate, Enum.reverse(revisions)}}}

      {_revisions, _new_count, _duplicate_count} ->
        {:rollback, {:policy, :partial_batch_replay}}

      {:rollback, reason} ->
        {:rollback, reason}
    end
  end

  defp one_report_event?([first | rest]) do
    identity = report_event_identity(first)
    Enum.all?(rest, &(report_event_identity(&1) == identity))
  end

  defp report_event_identity(observation) do
    {observation.source_epoch, observation.source_sequence, observation.boot_epoch,
     observation.source_time_utc_ms, observation.received_time_utc_ms,
     observation.received_monotonic_ms, observation.quality, observation.trust}
  end

  defp check_previous(_db, [], _observation, _capability), do: :ok

  defp check_previous(db, [row], observation, capability) do
    [profile_ref, evidence_ref, source_epoch, source_sequence | _rest] = row

    cond do
      profile_ref != capability.profile_ref or evidence_ref != capability.evidence_ref ->
        {:reject, :profile_changed}

      source_epoch != observation.source_epoch ->
        source_epoch_granted?(db, row, observation)

      source_sequence > observation.source_sequence ->
        {:reject, :stale_sequence}

      source_sequence == observation.source_sequence ->
        if same_source_event?(row, observation),
          do: {:duplicate, List.last(row)},
          else: {:reject, :sequence_conflict}

      true ->
        :ok
    end
  end

  defp check_previous(_db, _rows, _observation, _capability),
    do: {:error, :corrupt_value}

  defp check_refresh_previous([], _observation, _capability), do: :ok

  defp check_refresh_previous([row], observation, capability) do
    [profile_ref, evidence_ref, source_epoch | _rest] = row

    cond do
      profile_ref != capability.profile_ref or evidence_ref != capability.evidence_ref ->
        {:reject, :profile_changed}

      source_epoch == observation.source_epoch ->
        check_previous_without_epoch(row, observation)

      true ->
        :ok
    end
  end

  defp check_refresh_previous(_rows, _observation, _capability),
    do: {:error, :corrupt_value}

  defp check_previous_without_epoch(row, observation) do
    source_sequence = Enum.at(row, 3)

    cond do
      source_sequence > observation.source_sequence ->
        {:reject, :stale_sequence}

      source_sequence == observation.source_sequence ->
        if same_source_event?(row, observation),
          do: {:duplicate, List.last(row)},
          else: {:reject, :sequence_conflict}

      true ->
        :ok
    end
  end

  defp source_epoch_granted?(db, row, observation) do
    source_epoch = Enum.at(row, 2)
    current_revision = List.last(row)

    case query(
           db,
           "SELECT grant_revision FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ? AND old_epoch = ? AND new_epoch = ? AND current_revision = ?",
           [
             observation.thing_id,
             observation.capability_key,
             source_epoch,
             observation.source_epoch,
             current_revision
           ]
         ) do
      {:ok, [[grant_revision]]} when is_integer(grant_revision) -> :ok
      {:ok, _} -> {:reject, :source_epoch_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_consume_source_epoch_grant(_db, [], _observation), do: :ok

  defp maybe_consume_source_epoch_grant(db, [row], observation) do
    if Enum.at(row, 2) == observation.source_epoch do
      :ok
    else
      with {:ok, []} <-
             query(
               db,
               "DELETE FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ? AND old_epoch = ? AND new_epoch = ? AND current_revision = ?",
               [
                 observation.thing_id,
                 observation.capability_key,
                 Enum.at(row, 2),
                 observation.source_epoch,
                 List.last(row)
               ]
             ),
           {:ok, [[1]]} <- query(db, "SELECT changes()") do
        :ok
      else
        _ -> {:error, :corrupt_source_epoch_grant}
      end
    end
  end

  defp clear_superseded_epoch_grant(_db, [], _observation), do: :ok

  defp clear_superseded_epoch_grant(db, [row], observation) do
    if Enum.at(row, 2) == observation.source_epoch do
      :ok
    else
      case query(
             db,
             "DELETE FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ?",
             [observation.thing_id, observation.capability_key]
           ) do
        {:ok, []} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp same_source_event?(row, observation) do
    [_, _, _, _, _, source_time, _, _, quality, trust, kind, a, b, _] = row
    {new_kind, new_a, new_b} = encode_value(observation.value)

    source_time == observation.source_time_utc_ms and quality == observation.quality and
      trust == observation.trust and {kind, a, b} == {new_kind, new_a, new_b}
  end

  defp insert_record(db, observation, capability, {store_epoch, store_ms}) do
    with true <-
           WotexHome.Id.valid?(store_epoch) and is_integer(store_ms) and store_ms in 0..@max_i64,
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         true <- is_integer(revision) and revision in 0..(@max_i64 - 1),
         new_revision = revision + 1,
         {kind, a, b} = encode_value(observation.value),
         params = fields(observation, capability, kind, a, b),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO journal VALUES (?, 'observation', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
             [new_revision | params] ++ [store_epoch, store_ms]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO observation_current VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(thing_id, capability_key) DO UPDATE SET profile_ref=excluded.profile_ref, evidence_ref=excluded.evidence_ref, source_epoch=excluded.source_epoch, source_sequence=excluded.source_sequence, boot_epoch=excluded.boot_epoch, source_time_utc_ms=excluded.source_time_utc_ms, received_time_utc_ms=excluded.received_time_utc_ms, received_monotonic_ms=excluded.received_monotonic_ms, quality=excluded.quality, trust=excluded.trust, value_kind=excluded.value_kind, value_a=excluded.value_a, value_b=excluded.value_b, revision=excluded.revision, received_store_boot_epoch=excluded.received_store_boot_epoch, received_store_monotonic_ms=excluded.received_store_monotonic_ms",
             params ++ [new_revision, store_epoch, store_ms]
           ),
         {:ok, []} <-
           query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [new_revision]) do
      {:commit, {:ok, new_revision}}
    else
      false -> {:rollback, :revision_exhausted}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :unexpected_store_result}
    end
  end

  defp fields(observation, capability, kind, a, b) do
    [
      observation.thing_id,
      observation.capability_key,
      capability.profile_ref,
      capability.evidence_ref,
      observation.source_epoch,
      observation.source_sequence,
      observation.boot_epoch,
      observation.source_time_utc_ms,
      observation.received_time_utc_ms,
      observation.received_monotonic_ms,
      observation.quality,
      observation.trust,
      kind,
      a,
      b
    ]
  end

  defp current_epoch_matches([], _old_epoch, _revision),
    do: {:error, {:policy, :no_current_observation}}

  defp current_epoch_matches([row], old_epoch, revision) do
    if Enum.at(row, 2) == old_epoch and List.last(row) == revision,
      do: :ok,
      else: {:error, {:policy, :stale_source_epoch}}
  end

  defp current_epoch_matches(_rows, _old_epoch, _revision),
    do: {:error, :corrupt_value}
end
