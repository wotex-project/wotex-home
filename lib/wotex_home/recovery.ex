defmodule WotexHome.Recovery do
  @moduledoc "Trusted foreground archive commands with a stdin key; never activate quarantine."
  alias WotexHome.{Authority, Host}
  alias WotexHome.Durable.Backup

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

  defp command(["stage", path, destination], key),
    do: Backup.stage_profile_restore(path, key, destination)

  defp command(_, _), do: {:error, :usage}
end
