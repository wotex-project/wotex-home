defmodule WotexHome.Durable.Store.GenerationPreparations do
  @moduledoc """
  Retains inert generator preparations and their original cancellation history.

  Store supplies its borrowed SQLite connection, current authenticated operation,
  boot identity and monotonic coordinates. Preparation lookup resolves an exact
  original before current-basis work; new records require epoch/revision,
  maintenance, owned-reference and quota guards. Transaction helpers append
  matching journal events and preserve the immutable preparation receipt.

  `status/6` separates that receipt from current prepared, cancelled, expired or
  retired availability. Metadata cancellation never renews the deadline. Historical
  integrity checks need no producer, private bytes or currently installed policy.
  This module opens no connection, invokes no provider and authorizes no handoff.
  """

  alias WotexHome.Durable.Store.{AuthoringObjects, Journal, MaintenanceWriter, ProfileWriter}
  alias WotexHome.Profiles.{AuthoringProducer, GenerationPreparation}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "principal_id,authority_epoch,operation_id,input_document,projection_sha256,basis_sha256,receipt_document,boot_epoch,created_ms,expires_ms,revision,cancellation_revision"
  @maximum 9_223_372_036_854_775_807
  @policy ~w(unauthorized invalid_credential permission_denied authoring_operation_conflict stale_authority_epoch resnapshot_required maintenance_active stale_authoring_reference generation_preparation_capacity invalid_generation_preparation generation_deadline_expired revision_exhausted)a
  def columns, do: @columns

  def prepare(db, credential, document) do
    with {:ok, input} <- GenerationPreparation.decode(document),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_authoring_generations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [[^document, receipt]] ->
          with {:ok, r} <- GenerationPreparation.decode_receipt(receipt), do: {:ok, :existing, r}

        [_] ->
          {:error, :authoring_operation_conflict}

        _ ->
          corrupt()
      end
    end
  end

  def current_basis(db, principal, input, boot, now) do
    with {:ok, [[revision, epoch]]} <- meta(db),
         :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- equal(revision, input["expected_revision"], :resnapshot_required),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, objects} <- ownership(db),
         {:ok, selected} <- references(objects, principal, input),
         {:ok, document} <- GenerationPreparation.encode(input),
         :ok <- capacity(db, byte_size(document), boot, now, true),
         do: {:ok, selected}
  end

  def retain_tx(db, credential, document, projection, basis, boot, created, now) do
    with {:ok, :new, principal, input} <- prepare(db, credential, document),
         {:ok, _} <- current_basis(db, principal, input, boot, now),
         true <-
           WotexHome.Profiles.EnvelopeCodec.digest?(projection) and
             WotexHome.Profiles.EnvelopeCodec.digest?(basis) and boot?(boot) and int?(created) and
             int?(now) and now >= created and
             created <= @maximum - input["budget"]["total_ms"],
         :ok <- deadline(created + input["budget"]["total_ms"], now),
         {:ok, next} <- Journal.next_revision(db),
         r = %{
           "authority_epoch" => input["authority_epoch"],
           "operation_id" => input["operation_id"],
           "revision" => next,
           "input_sha256" => AuthoringProducer.sha(document),
           "projection_sha256" => projection,
           "basis_sha256" => basis,
           "provider_sha256" => input["provider_sha256"],
           "policy_sha256" => input["policy_sha256"],
           "disposition" => "prepared"
         },
         {:ok, receipt} <- GenerationPreparation.encode_receipt(r),
         :ok <-
           Journal.authority_event(
             db,
             next,
             "authoring_generation_prepared",
             input["operation_id"]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_authoring_generations (#{@columns}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
             [
               principal,
               input["authority_epoch"],
               input["operation_id"],
               document,
               projection,
               basis,
               receipt,
               boot,
               created,
               created + input["budget"]["total_ms"],
               next,
               nil
             ]
           ),
         :ok <- validate(db),
         do: {:commit, {:ok, r}},
         else: (
           {:ok, :existing, r} -> {:rollback, {:unchanged, {:ok, r}}}
           :not_found -> {:rollback, {:policy, :stale_authoring_reference}}
           false -> {:rollback, {:policy, :invalid_generation_preparation}}
           {:error, reason} when reason in @policy -> {:rollback, {:policy, reason}}
           {:error, reason} -> {:rollback, reason}
           _ -> {:rollback, :corrupt_generation_preparations}
         )
  end

  def status(db, credential, epoch, operation, boot, now) do
    with true <- is_integer(epoch) and epoch in 1..@maximum and WotexHome.Id.valid?(operation),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document,boot_epoch,expires_ms,cancellation_revision FROM profile_authoring_generations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] ->
          :not_found

        [[receipt, original_boot, expiry, cancelled]] ->
          with {:ok, r} <- GenerationPreparation.decode_receipt(receipt) do
            state =
              cond do
                cancelled != nil -> "cancelled"
                original_boot != boot -> "retired"
                now >= expiry -> "expired"
                true -> "prepared"
              end

            {:ok, %{"original" => r, "state" => state, "cancellation_revision" => cancelled}}
          end

        _ ->
          corrupt()
      end
    else
      false -> {:error, :invalid_generation_preparation}
      error -> error
    end
  end

  def cancel_tx(db, credential, epoch, operation, boot, now) do
    with {:ok, current} <- status(db, credential, epoch, operation, boot, now),
         nil <- current["cancellation_revision"],
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         {:ok, next} <- Journal.next_revision(db),
         :ok <- Journal.authority_event(db, next, "authoring_generation_cancelled", operation),
         {:ok, []} <-
           query(
             db,
             "UPDATE profile_authoring_generations SET cancellation_revision=? WHERE principal_id=? AND authority_epoch=? AND operation_id=? AND cancellation_revision IS NULL",
             [next, principal, epoch, operation]
           ),
         :ok <- validate(db),
         {:ok, result} <- status(db, credential, epoch, operation, boot, now),
         do: {:commit, {:ok, result}},
         else: (
           revision when is_integer(revision) ->
             {:rollback, {:unchanged, status(db, credential, epoch, operation, boot, now)}}

           :not_found ->
             {:rollback, {:unchanged, :not_found}}

           {:error, reason} when reason in @policy ->
             {:rollback, {:policy, reason}}

           {:error, reason} ->
             {:rollback, reason}

           _ ->
             {:rollback, :corrupt_generation_preparations}
         )
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[36]]} -> validate(db)
      {:ok, [[v]]} when v in 4..35 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- AuthoringObjects.validate(db),
         {:ok, objects} <- ownership(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_authoring_generations ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1024,
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_authoring_generations g LEFT JOIN principals p ON p.principal_id=g.principal_id WHERE p.principal_id IS NULL"
           ),
         {:ok, [[maximum, epoch]]} <- meta(db),
         {:ok, events} <-
           query(
             db,
             "SELECT revision,event_type,entity_id FROM authority_journal WHERE event_type IN ('authoring_generation_prepared','authoring_generation_cancelled') ORDER BY revision LIMIT 2049"
           ),
         events = Map.new(events, fn [rev, kind, id] -> {rev, {kind, id}} end),
         true <- map_size(events) == length(rows) + Enum.count(rows, &(List.last(&1) != nil)),
         true <- Enum.all?(rows, &valid_row?(&1, objects, events, maximum, epoch)),
         :ok <- capacity(db, 0, nil, 0, false),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp valid_row?(
         [
           principal,
           epoch,
           op,
           bytes,
           projection,
           basis,
           receipt,
           boot,
           created,
           expires,
           revision,
           cancelled
         ],
         objects,
         events,
         maximum,
         current_epoch
       ) do
    with true <-
           WotexHome.Id.valid?(principal) and is_integer(epoch) and epoch in 1..current_epoch and
             is_integer(revision) and revision in 1..maximum,
         {:ok, input} <- GenerationPreparation.decode(bytes),
         {:ok, r} <- GenerationPreparation.decode_receipt(receipt),
         {:ok, _} <- references(objects, principal, input),
         true <-
           input["authority_epoch"] == epoch and input["operation_id"] == op and
             input["expected_revision"] == revision - 1,
         true <-
           r == %{
             "authority_epoch" => epoch,
             "operation_id" => op,
             "revision" => revision,
             "input_sha256" => AuthoringProducer.sha(bytes),
             "projection_sha256" => projection,
             "basis_sha256" => basis,
             "provider_sha256" => input["provider_sha256"],
             "policy_sha256" => input["policy_sha256"],
             "disposition" => "prepared"
           },
         true <-
           boot?(boot) and int?(created) and int?(expires) and
             expires - created == input["budget"]["total_ms"],
         true <- events[revision] == {"authoring_generation_prepared", op},
         true <-
           cancelled == nil or
             (is_integer(cancelled) and cancelled > revision and cancelled <= maximum and
                events[cancelled] == {"authoring_generation_cancelled", op}),
         do: true,
         else: (_ -> false)
  end

  defp valid_row?(_, _, _, _, _), do: false

  defp references(objects, principal, input) do
    p = input["projection"]

    refs =
      (Enum.map(p["passages"], &{&1["reference"], "source"}) ++
         Enum.map(p["examples"], &{&1, "fixture"}))
      |> Enum.uniq()
      |> Enum.sort_by(fn {r, _} -> r["object_digest"] end)

    Enum.reduce_while(refs, {:ok, []}, fn {ref, kind}, {:ok, selected} ->
      case objects[{principal, ref["object_digest"]}] do
        {summary, first} ->
          if summary["kind"] == kind and first == ref["first_revision"] and
               first <= input["expected_revision"],
             do: {:cont, {:ok, [%{"object" => summary, "first_revision" => first} | selected]}},
             else: {:halt, {:error, :stale_authoring_reference}}

        nil ->
          {:halt, :not_found}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp ownership(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{AuthoringObjects.object_columns()} FROM profile_authoring_objects LIMIT 1025"
           ),
         do:
           {:ok,
            Map.new(rows, fn [p, d, k, h, size, first] ->
              {{p, d},
               {%{
                  "object_digest" => d,
                  "kind" => k,
                  "payload_sha256" => h,
                  "payload_bytes" => size
                }, first}}
            end)}
  end

  defp capacity(db, bytes, boot, now, new?) do
    with {:ok, [[count, total]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0) FROM profile_authoring_generations"
           ),
         true <- count + if(new?, do: 1, else: 0) <= 1024 and total + bytes <= 4_194_304,
         {:ok, [[active]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_authoring_generations WHERE boot_epoch=? AND expires_ms>? AND cancellation_revision IS NULL",
             [boot, now]
           ),
         true <- not new? or active < 16,
         do: :ok,
         else: (_ -> {:error, :generation_preparation_capacity})
  end

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp deadline(expires, now) when now < expires, do: :ok
  defp deadline(_, _), do: {:error, :generation_deadline_expired}

  defp int?(v), do: is_integer(v) and v >= 0 and v <= @maximum

  defp boot?(b),
    do: is_binary(b) and byte_size(b) == 37 and Regex.match?(~r/\Aboot:[0-9a-f]{32}\z/, b)

  defp equal(v, v, _), do: :ok
  defp equal(_, _, r), do: {:error, r}
  defp corrupt, do: {:error, :corrupt_generation_preparations}
end
