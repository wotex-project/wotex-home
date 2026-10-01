defmodule WotexHome.Durable.Store.StateReadModel do
  @moduledoc """
  Bounded principal-scoped state, catalogue, history and event projections.

  Store invokes these synchronously against its owned connection and handles
  any integrity failure. This module cannot retain the database, create a
  transaction, allocate a revision or send a device command.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.RequestLedger
  alias WotexHome.Semantics.{Thing, Value}

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  import WotexHome.Durable.Store.Access,
    only: [authenticate: 2, allowed_targets: 2, enrolled_thing: 2]

  import WotexHome.Durable.Store.ObservationCodec, only: [decode_current: 3]

  @max_i64 9_223_372_036_854_775_807
  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64

  def snapshot_page_result(db, credential, watermark, after_key, page_size) do
    with :ok <- valid_snapshot_request(watermark, after_key, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- snapshot_rows(db, principal_id, after_key, page_size + 1),
         {:ok, items} <- snapshot_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size

      next_after =
        if more? do
          last = List.last(items)
          %{"thing_id" => last["thing_id"], "capability_key" => last["capability_key"]}
        end

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason} when reason in [:invalid_snapshot_request, :resnapshot_required] ->
        {:error, reason}

      {:error, reason} when reason in [:invalid_credential, :unauthorized, :permission_denied] ->
        {:error, reason}

      {:error, reason} when reason in [:corrupt_principal, :corrupt_value] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  def catalogue_page_result(db, credential, watermark, after_id, page_size) do
    with :ok <- valid_catalogue_request(watermark, after_id, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- catalogue_rows(db, principal_id, after_id || "", page_size + 1),
         {:ok, items} <- catalogue_items(Enum.take(rows, page_size)) do
      next_after = if length(rows) > page_size, do: List.last(items)["id"]

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason}
      when reason in [
             :invalid_catalogue_request,
             :resnapshot_required,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_enrollment
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  def history_page_result(
        db,
        credential,
        thing_id,
        capability_key,
        watermark,
        after_revision,
        page_size
      ) do
    with :ok <-
           valid_history_request(thing_id, capability_key, watermark, after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, thing_id),
         {:ok, thing, _resource_revision} <- enrolled_thing(db, thing_id),
         {:ok, _capability} <- Thing.capability(thing, capability_key),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <-
           history_rows(db, thing_id, capability_key, after_revision, revision, page_size + 1),
         {:ok, items} <- history_items(Enum.take(rows, page_size), thing_id, capability_key) do
      next_after = if length(rows) > page_size, do: List.last(items)["revision"]

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      :error ->
        {:error, :unknown_capability}

      {:error, reason}
      when reason in [
             :invalid_history_request,
             :resnapshot_required,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :corrupt_enrollment,
             :corrupt_principal,
             :corrupt_value
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  def events_page_result(db, credential, after_revision, page_size) do
    with :ok <- valid_events_request(after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[watermark]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- event_cursor_not_ahead(after_revision, watermark),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- event_rows(db, principal_id, after_revision, watermark, page_size + 1),
         {:ok, items} <- event_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size
      next_after = if more?, do: List.last(items)["revision"], else: watermark

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: watermark,
         items: items,
         next_after: next_after,
         has_more: more?
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason}
      when reason in [
             :invalid_events_request,
             :invalid_event_cursor,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_value
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  def request_events_page_result(db, credential, after_revision, page_size) do
    with :ok <- valid_events_request(after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, [[watermark]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- event_cursor_not_ahead(after_revision, watermark),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <-
           query(
             db,
             "SELECT authority_epoch, operation_id, disposition, reason, revision FROM request_journal WHERE principal_id = ? AND revision > ? AND revision <= ? ORDER BY revision LIMIT ?",
             [principal_id, after_revision, watermark, page_size + 1]
           ),
         {:ok, items} <- request_event_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size
      next_after = if more?, do: List.last(items)["revision"], else: watermark

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: watermark,
         items: items,
         next_after: next_after,
         has_more: more?
       }}
    else
      {:error, reason}
      when reason in [
             :invalid_events_request,
             :invalid_event_cursor,
             :invalid_credential,
             :unauthorized,
             :corrupt_principal,
             :corrupt_receipt
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp request_event_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [epoch, operation_id, disposition, reason, revision], {:ok, items}
      when is_integer(epoch) and epoch >= 0 and is_binary(operation_id) and
             is_integer(revision) and revision >= 0 ->
        valid_reason? =
          (disposition == "held" and is_nil(reason)) or
            (disposition == "rejected" and is_binary(reason) and byte_size(reason) <= 128) or
            (RequestLedger.execution_disposition?(disposition) and
               (is_nil(reason) or (is_binary(reason) and byte_size(reason) <= 128)))

        if valid_stored_integer?(epoch) and Id.valid?(operation_id) and
             valid_stored_integer?(revision) and valid_reason? do
          item = %{
            "authority_epoch" => epoch,
            "operation_id" => operation_id,
            "disposition" => disposition,
            "reason" => reason,
            "revision" => revision
          }

          {:cont, {:ok, [item | items]}}
        else
          {:halt, {:error, :corrupt_receipt}}
        end

      _, _ ->
        {:halt, {:error, :corrupt_receipt}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_events_request(after_revision, page_size) do
    if is_integer(after_revision) and after_revision >= 0 and after_revision <= @max_i64 and
         is_integer(page_size) and page_size >= 1 and page_size <= 100,
       do: :ok,
       else: {:error, :invalid_events_request}
  end

  defp event_cursor_not_ahead(after_revision, watermark) when after_revision <= watermark,
    do: :ok

  defp event_cursor_not_ahead(_after_revision, _watermark),
    do: {:error, :invalid_event_cursor}

  defp event_rows(db, principal_id, after_revision, watermark, limit) do
    query(
      db,
      "SELECT j.thing_id, j.capability_key, j.profile_ref, j.evidence_ref, j.source_epoch, j.source_sequence, j.boot_epoch, j.source_time_utc_ms, j.received_time_utc_ms, j.received_monotonic_ms, j.quality, j.trust, j.value_kind, j.value_a, j.value_b, j.revision FROM journal j JOIN principal_targets g ON g.thing_id = j.thing_id JOIN enrolled_things t ON t.thing_id = j.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND j.event_type = 'observation' AND j.revision > ? AND j.revision <= ? ORDER BY j.revision LIMIT ?",
      [principal_id, after_revision, watermark, limit]
    )
  end

  defp event_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, capability_key | rest], {:ok, items} ->
        case decode_current(thing_id, capability_key, rest) do
          {:ok, observation, revision} ->
            [profile_ref, evidence_ref | _] = rest
            item = observation_item(observation, revision, profile_ref, evidence_ref)
            {:cont, {:ok, [item | items]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_history_request(thing_id, capability_key, watermark, after_revision, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    if Id.valid?(thing_id) and Id.valid?(capability_key) and valid_watermark and
         is_integer(after_revision) and after_revision >= 0 and after_revision <= @max_i64 and
         is_integer(page_size) and page_size >= 1 and page_size <= 100,
       do: :ok,
       else: {:error, :invalid_history_request}
  end

  defp history_rows(db, thing_id, capability_key, after_revision, watermark, limit) do
    query(
      db,
      "SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch, source_time_utc_ms, received_time_utc_ms, received_monotonic_ms, quality, trust, value_kind, value_a, value_b, revision FROM journal WHERE thing_id = ? AND capability_key = ? AND revision > ? AND revision <= ? ORDER BY revision LIMIT ?",
      [thing_id, capability_key, after_revision, watermark, limit]
    )
  end

  defp history_items(rows, thing_id, capability_key) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, items} ->
      case decode_current(thing_id, capability_key, row) do
        {:ok, observation, revision} ->
          [profile_ref, evidence_ref | _] = row

          item =
            observation_item(observation, revision, profile_ref, evidence_ref)

          {:cont, {:ok, [item | items]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_catalogue_request(watermark, after_id, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    if valid_watermark and (is_nil(after_id) or Id.valid?(after_id)) and
         (is_nil(after_id) or not is_nil(watermark)) and is_integer(page_size) and
         page_size >= 1 and page_size <= 10,
       do: :ok,
       else: {:error, :invalid_catalogue_request}
  end

  defp catalogue_rows(db, principal_id, after_id, limit) do
    query(
      db,
      "SELECT t.thing_id, t.profile_ref, t.document, t.resource_revision FROM enrolled_things t JOIN principal_targets g ON g.thing_id = t.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND t.thing_id > ? ORDER BY t.thing_id LIMIT ?",
      [principal_id, after_id, limit]
    )
  end

  defp catalogue_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, profile_ref, document, resource_revision], {:ok, items} ->
        with {:ok, %Thing{id: ^thing_id, profile_ref: ^profile_ref}} <-
               Registry.decode_thing(document),
             true <- is_integer(resource_revision) and resource_revision >= 0,
             {:ok, declaration} <- JSON.decode(document) do
          item = Map.put(declaration, "resource_revision", resource_revision)
          {:cont, {:ok, [item | items]}}
        else
          _ -> {:halt, {:error, :corrupt_enrollment}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_snapshot_request(watermark, after_key, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    valid_after =
      is_nil(after_key) or
        (is_map(after_key) and map_size(after_key) == 2 and
           Id.valid?(after_key["thing_id"]) and Id.valid?(after_key["capability_key"]))

    if valid_watermark and valid_after and is_integer(page_size) and page_size >= 1 and
         page_size <= 100 and (is_nil(after_key) or not is_nil(watermark)),
       do: :ok,
       else: {:error, :invalid_snapshot_request}
  end

  defp snapshot_watermark(nil, _revision), do: :ok
  defp snapshot_watermark(revision, revision), do: :ok
  defp snapshot_watermark(_watermark, _revision), do: {:error, :resnapshot_required}

  defp snapshot_rows(db, principal_id, after_key, limit) do
    {thing_id, capability_key} =
      case after_key do
        nil ->
          {"", ""}

        %{"thing_id" => thing_id, "capability_key" => capability_key} ->
          {thing_id, capability_key}
      end

    query(
      db,
      "SELECT c.thing_id, c.capability_key, c.profile_ref, c.evidence_ref, c.source_epoch, c.source_sequence, c.boot_epoch, c.source_time_utc_ms, c.received_time_utc_ms, c.received_monotonic_ms, c.quality, c.trust, c.value_kind, c.value_a, c.value_b, c.revision FROM observation_current c JOIN principal_targets g ON g.thing_id = c.thing_id JOIN enrolled_things t ON t.thing_id = c.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND (c.thing_id > ? OR (c.thing_id = ? AND c.capability_key > ?)) ORDER BY c.thing_id, c.capability_key LIMIT ?",
      [principal_id, thing_id, thing_id, capability_key, limit]
    )
  end

  defp snapshot_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, capability_key | rest], {:ok, items} ->
        case decode_current(thing_id, capability_key, rest) do
          {:ok, observation, revision} ->
            [profile_ref, evidence_ref | _] = rest
            item = observation_item(observation, revision, profile_ref, evidence_ref)

            {:cont, {:ok, [item | items]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp observation_item(observation, revision, profile_ref, evidence_ref) do
    %{
      "thing_id" => observation.thing_id,
      "capability_key" => observation.capability_key,
      "profile_ref" => profile_ref,
      "evidence_ref" => evidence_ref,
      "value" => snapshot_value(observation.value),
      "quality" => observation.quality,
      "trust" => observation.trust,
      "source_epoch" => observation.source_epoch,
      "source_sequence" => observation.source_sequence,
      "boot_epoch" => observation.boot_epoch,
      "source_time_utc_ms" => observation.source_time_utc_ms,
      "received_time_utc_ms" => observation.received_time_utc_ms,
      "received_monotonic_ms" => observation.received_monotonic_ms,
      "revision" => revision
    }
  end

  defp snapshot_value(nil), do: nil

  defp snapshot_value(%Value{kind: :boolean, data: value}),
    do: %{"type" => "boolean", "value" => value}

  defp snapshot_value(%Value{kind: :fraction, data: ppm}),
    do: %{"type" => "fraction", "ppm" => ppm}

  defp snapshot_value(%Value{kind: :kelvin, data: kelvin}),
    do: %{"type" => "kelvin", "kelvin" => kelvin}

  defp snapshot_value(%Value{kind: :hsv, data: {hue, saturation}}),
    do: %{"type" => "hsv", "hue_mdeg" => hue, "saturation_ppm" => saturation}

  defp snapshot_value(%Value{kind: :xy, data: {x, y}}),
    do: %{"type" => "xy", "x_ppm" => x, "y_ppm" => y}

  defp snapshot_value(%Value{kind: :smoke_state, data: state}),
    do: %{"type" => "smoke_state", "state" => state}
end
