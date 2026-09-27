defmodule WotexHome.Durable.SupportExport do
  @moduledoc """
  Explicit, bounded support summary with no household identity or activity.

  The same authenticated caller can inspect the exact field set before asking
  for a new local file. This exports only whitelisted Store health counters;
  it never reads the observation journal, enrolled Thing documents or secrets.
  """

  alias WotexHome.Durable.Store

  @schema "wotex-home.support.v2"
  @max_bytes 4_096
  @health_fields [
    :store_revision,
    :authority_epoch,
    :rule_generation,
    :held_requests,
    :queued_requests,
    :claimed_requests,
    :unknown_outcomes,
    :retained_receipts,
    :receipt_capacity,
    :active_things,
    :active_principals,
    :writable,
    :dispatch_enabled
  ]

  @spec preview(GenServer.server(), binary()) :: {:ok, map()} | {:error, atom()}
  def preview(store, credential) do
    with {:ok, health} <- Store.authorized_health(store, credential),
         true <- valid_health?(health) do
      {:ok,
       %{
         "schema" => @schema,
         "health" =>
           Map.new(@health_fields, fn field ->
             {Atom.to_string(field), Map.fetch!(health, field)}
           end)
       }}
    else
      false -> {:error, :support_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write(GenServer.server(), binary(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def write(store, credential, destination)
      when is_binary(destination) and byte_size(destination) <= 4_096 do
    with {:ok, summary} <- preview(store, credential) do
      write_preview(summary, destination)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def write(_store, _credential, _destination), do: {:error, :invalid_support_destination}

  @doc "Write a server-returned closed preview into a new private local file."
  @spec write_preview(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def write_preview(summary, destination)
      when is_binary(destination) and byte_size(destination) <= 4_096 do
    cond do
      Path.type(destination) != :absolute ->
        {:error, :invalid_support_destination}

      not valid_summary?(summary) ->
        {:error, :support_unavailable}

      true ->
        bytes = JSON.encode!(summary)

        if byte_size(bytes) <= @max_bytes,
          do: write_new(destination, bytes),
          else: {:error, :support_unavailable}
    end
  end

  def write_preview(_summary, _destination), do: {:error, :invalid_support_destination}

  @spec valid_summary?(term()) :: boolean()
  def valid_summary?(%{"schema" => @schema, "health" => health} = summary)
      when map_size(summary) == 2 and is_map(health) do
    keys = Enum.map(@health_fields, &Atom.to_string/1)

    Enum.sort(Map.keys(health)) == Enum.sort(keys) and
      Enum.all?(keys -- ["writable", "dispatch_enabled"], fn key ->
        is_integer(health[key]) and health[key] >= 0
      end) and health["authority_epoch"] >= 1 and health["receipt_capacity"] >= 1 and
      health["retained_receipts"] <= health["receipt_capacity"] and
      is_boolean(health["writable"]) and is_boolean(health["dispatch_enabled"])
  end

  def valid_summary?(_summary), do: false

  defp valid_health?(health) when is_map(health) do
    Enum.all?(@health_fields, &Map.has_key?(health, &1)) and
      Enum.all?(@health_fields -- [:writable, :dispatch_enabled], fn key ->
        is_integer(health[key]) and health[key] >= 0
      end) and health.authority_epoch >= 1 and health.receipt_capacity >= 1 and
      health.retained_receipts <= health.receipt_capacity and
      is_boolean(health.writable) and is_boolean(health.dispatch_enabled)
  end

  defp valid_health?(_health), do: false

  defp write_new(destination, bytes) do
    case File.open(destination, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(destination, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file) do
            {:ok, byte_size(bytes)}
          else
            _ -> {:error, :support_unavailable}
          end

        _ = File.close(file)
        if match?({:error, _}, result), do: File.rm(destination)
        result

      {:error, :eexist} ->
        {:error, :support_exists}

      _ ->
        {:error, :support_unavailable}
    end
  end
end
