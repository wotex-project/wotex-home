defmodule WotexHome.Recovery do
  @moduledoc "Trusted foreground archive commands with a stdin key; never activate quarantine."
  alias WotexHome.{Authority, Host}
  alias WotexHome.Durable.Backup

  def run(["retire-export", epoch, operation, revision, owner, path], input)
      when is_binary(epoch) and is_binary(revision) do
    with true <- is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path,
         <<credential_line::binary-size(44), key_line::binary-size(44)>> <- input,
         {:ok, credential} <- key(credential_line),
         {:ok, key} <- key(key_line),
         {epoch, ""} <- Integer.parse(epoch),
         {revision, ""} <- Integer.parse(revision),
         authority = Host.authority(),
         pid when is_pid(pid) <- Authority.owner(authority),
         {:ok, receipt} <-
           Authority.retire_controller(authority, credential, %{
             "authority_epoch" => epoch,
             "operation_id" => operation,
             "expected_revision" => revision,
             "destination_owner_id" => owner
           }),
         {:ok, summary} <- Authority.export_retired_profile_backup(authority, path, key),
         :ok <- Host.stop_retired_source(authority, credential, receipt) do
      {:ok, Map.put(summary, :source_stopped, true)}
    else
      nil -> {:error, :host_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :invalid_retirement_request}
    end
  catch
    :exit, _ -> {:error, :recovery_unavailable}
  end

  def run(arguments, encoded) do
    with {:ok, key} <- key(encoded), do: command(arguments, key)
  catch
    :exit, _ -> {:error, :recovery_unavailable}
  end

  defp key(<<encoded::binary-size(43), "\n">>) do
    with {:ok, key} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(key) == 32 and Base.url_encode64(key, padding: false) == encoded do
      {:ok, key}
    else
      _ -> {:error, :invalid_backup_key}
    end
  end

  defp key(_), do: {:error, :invalid_backup_key}

  defp command(["export", path], key) do
    authority = Host.authority()

    case Authority.owner(authority) do
      pid when is_pid(pid) -> Authority.export_profile_backup(authority, path, key)
      _ -> {:error, :host_unavailable}
    end
  end

  defp command(["verify", path], key), do: Backup.verify(path, key)

  defp command(["export-retired", directory, path], key),
    do: Authority.export_retired_directory(directory, path, key)

  defp command(["stage", path, destination], key),
    do: Backup.stage_profile_restore(path, key, destination)

  defp command(_, _), do: {:error, :usage}
end
