defmodule WotexHome.Durable.Store.ProfilePins do
  @moduledoc "Owning-domain profile commitments retained with original Store receipts."
  alias WotexHome.{Id, Profiles.LedgerCodec}
  alias WotexHome.Durable.Store.ProfileGuard
  import WotexHome.Durable.Store.SQL, only: [query: 3]

  @fields ~w(target_id owner_revision artifact_digest projection_digest selection_revision selection_generation trust_revision resource_revision)
  @columns Enum.join(@fields, ",")
  @tables %{
    observation: "profile_observation_pins",
    request: "profile_request_pins",
    rule: "profile_rule_pins",
    qualification: "profile_qualification_pins"
  }

  # Capture before retaining an owning row. Its pin is appended in the same
  # transaction, without validating an incomplete intermediate owner/pin pair.
  def capture(db, thing, resource), do: ProfileGuard.current(db, thing, resource)

  def retain(_db, kind, nil, _revision, _scope) when is_map_key(@tables, kind), do: :ok

  def retain(db, kind, pin, revision, scope) when is_map_key(@tables, kind) and is_map(pin) do
    row = Map.put(pin, "owner_revision", revision)

    with {:ok, _} <- LedgerCodec.encode("pin", row),
         true <- revision > pin["selection_revision"],
         {:ok, extra_fields, extra_values} <- scope(kind, scope),
         fields = extra_fields ++ @fields,
         {:ok, []} <-
           query(
             db,
             "INSERT INTO #{@tables[kind]} (#{Enum.join(fields, ",")}) VALUES (#{Enum.map_join(fields, ",", fn _ -> "?" end)})",
             extra_values ++ Enum.map(@fields, &row[&1])
           ) do
      :ok
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  def retain(_, _, _, _, _), do: {:error, :corrupt_profile_ledger}

  def require_current(db, kind, thing, resource, scope) when is_map_key(@tables, kind) do
    with {:ok, pin} <- capture(db, thing, resource),
         {:ok, where, params} <- owner_scope(kind, thing.id, scope),
         {:ok, rows} <-
           query(db, "SELECT #{@columns} FROM #{@tables[kind]} WHERE " <> where, params) do
      compare(rows, pin)
    end
  end

  def require_current(_, _, _, _, _), do: {:error, :corrupt_profile_ledger}

  defp compare([], nil), do: :ok
  defp compare([], _pin), do: {:error, :corrupt_profile_ledger}

  defp compare([values], pin) do
    row = Map.new(Enum.zip(@fields, values))

    with {:ok, _} <- LedgerCodec.encode("pin", row) do
      if Map.delete(row, "owner_revision") == pin, do: :ok, else: {:error, :profile_basis_changed}
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp compare(_, _), do: {:error, :corrupt_profile_ledger}

  defp scope(:request, {principal, epoch, operation}) do
    if Id.valid?(principal) and is_integer(epoch) and epoch in 1..9_223_372_036_854_775_807 and
         Id.valid?(operation),
       do: {:ok, ~w(principal_id authority_epoch operation_id), [principal, epoch, operation]},
       else: {:error, :corrupt_profile_ledger}
  end

  defp scope(kind, nil) when kind in [:observation, :rule, :qualification], do: {:ok, [], []}
  defp scope(_, _), do: {:error, :corrupt_profile_ledger}

  defp owner_scope(:request, target, scope) do
    with {:ok, _, values} <- scope(:request, scope),
         do:
           {:ok, "target_id=? AND principal_id=? AND authority_epoch=? AND operation_id=?",
            [target | values]}
  end

  defp owner_scope(kind, target, revision)
       when kind in [:observation, :rule, :qualification] and is_integer(revision) and
              revision > 0,
       do: {:ok, "target_id=? AND owner_revision=?", [target, revision]}

  defp owner_scope(_, _, _), do: {:error, :corrupt_profile_ledger}
end
