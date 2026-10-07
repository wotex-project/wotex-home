defmodule WotexHome.Recovery do
  @moduledoc "Trusted foreground archive commands with a stdin key; never activate quarantine."
  alias WotexHome.{Authority, Host}
  alias WotexHome.Durable.Backup

  @usage "usage: wotex_home_recovery new-owner OWNER_FILE | bootstrap-transfer | export ARCHIVE | verify ARCHIVE | stage ARCHIVE NEW_DIRECTORY | export-retired SOURCE_DIRECTORY ARCHIVE | retire-export EPOCH OPERATION_ID EXPECTED_REVISION DESTINATION_OWNER_ID ARCHIVE; secrets via stdin"

  def main(["--help"]) do
    IO.puts(@usage)
    0
  end

  def main(["bootstrap-transfer"]) do
    Logger.configure(level: :error)

    result =
      with :ok <- start_foreground_host(), do: WotexHome.Bootstrap.issue_transfer_credential()

    stop_foreground()

    case result do
      {:ok, encoded} ->
        IO.puts(encoded)
        0

      {:error, reason} ->
        failure(reason)
    end
  end

  def main(["new-owner", path]) do
    case run(["new-owner", path], "") do
      {:ok, summary} ->
        IO.puts(JSON.encode!(WotexHome.Profiles.Wire.encode(summary)))
        0

      {:error, reason} ->
        failure(reason)
    end
  end

  def main(arguments) when is_list(arguments) do
    if command_shape?(arguments), do: foreground(arguments), else: usage()
  end

  def main(_), do: usage()

  defp foreground(arguments) do
    Logger.configure(level: :error)
    input_size = if List.first(arguments) == "retire-export", do: 88, else: 44
    input = IO.binread(:stdio, input_size)

    result =
      with :ok <- input_ready(arguments, input),
           :ok <- maybe_start_foreground(arguments),
           do: run(arguments, input)

    stop_foreground()

    case result do
      {:ok, summary} ->
        IO.puts(JSON.encode!(WotexHome.Profiles.Wire.encode(summary)))
        0

      {:error, :usage} ->
        IO.puts(:stderr, @usage)
        2

      {:error, reason} when is_atom(reason) ->
        failure(reason)
    end
  end

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end

  defp command_shape?(["export", path]), do: is_binary(path)
  defp command_shape?(["verify", path]), do: is_binary(path)
  defp command_shape?(["stage", path, directory]), do: is_binary(path) and is_binary(directory)

  defp command_shape?(["export-retired", directory, path]),
    do: is_binary(directory) and is_binary(path)

  defp command_shape?(["retire-export", epoch, operation, revision, owner, path]),
    do: Enum.all?([epoch, operation, revision, owner, path], &is_binary/1)

  defp command_shape?(_), do: false

  defp input_ready(
         ["retire-export" | _],
         <<credential::binary-size(44), backup::binary-size(44)>>
       ) do
    with {:ok, _} <- key(credential), {:ok, _} <- key(backup), do: :ok
  end

  defp input_ready(["retire-export" | _], _), do: {:error, :invalid_retirement_request}

  defp input_ready(_, input) do
    case key(input) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp maybe_start_foreground([command | _]) when command in ["export", "retire-export"],
    do: start_foreground_host()

  defp maybe_start_foreground(_), do: :ok

  defp start_foreground_host do
    case Application.ensure_all_started(:wotex_home) do
      {:ok, _} -> :ok
      _ -> {:error, :host_unavailable}
    end
  end

  defp stop_foreground do
    _ = Application.stop(:wotex_home)
    Logger.flush()
  end

  defp failure(reason) do
    IO.puts(:stderr, "recovery failed: #{reason}")
    1
  end

  def run(["new-owner", path], ""), do: WotexHome.Recovery.Owner.create(path)

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
