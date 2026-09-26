defmodule WotexHome.Durable.SupportExport do
  @moduledoc """
  Explicit, bounded support summary with no household identity or activity.

  The same authenticated caller can inspect the exact field set before asking
  for a new local file. This exports only whitelisted Store health counters;
  it never reads the observation journal, enrolled Thing documents or secrets.
  """

  alias WotexHome.Durable.Store

  @schema "wotex-home.support.v1"
  @max_bytes 4_096
  @health_fields [
    :store_revision,
    :authority_epoch,
    :held_requests,
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
    with true <- Path.type(destination) == :absolute,
         {:ok, summary} <- preview(store, credential),
         bytes <- JSON.encode!(summary),
         true <- byte_size(bytes) <= @max_bytes do
      write_new(destination, bytes)
    else
      false -> {:error, :invalid_support_destination}
      {:error, reason} -> {:error, reason}
    end
  end

  def write(_store, _credential, _destination), do: {:error, :invalid_support_destination}

  defp valid_health?(health) when is_map(health) do
    Enum.all?(@health_fields, &Map.has_key?(health, &1)) and
      Enum.all?(
        [:store_revision, :authority_epoch, :held_requests, :active_things, :active_principals],
        fn key -> is_integer(health[key]) and health[key] >= 0 end
      ) and is_boolean(health.writable) and is_boolean(health.dispatch_enabled)
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
