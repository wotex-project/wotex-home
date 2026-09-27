defmodule WotexHome.CLI do
  @moduledoc """
  Headless read-only client for the private Home socket.

  The credential is read from a 0600 file, not a command-line argument. This
  client has no provisioning, enrollment-commit or device transport authority.
  """

  import Bitwise

  alias WotexHome.Id
  alias WotexHome.LocalAPI.Client

  @usage "usage: wotex_home_cli --socket ABSOLUTE_PATH --credential-file ABSOLUTE_PATH health | receipt EPOCH OPERATION_ID | enrollment REVIEW_REF | overrides THING_ID"

  @spec main([String.t()]) :: 0 | 1 | 2 | 4
  def main(["--help"]), do: usage(0)

  def main(argv) when is_list(argv) do
    with {:ok, socket, credential_file, command} <- options(argv),
         {:ok, credential} <- credential(credential_file),
         {:ok, request} <- request(command, credential),
         {:ok, response} <- Client.request(socket, request) do
      IO.puts(JSON.encode!(response))

      case response["outcome"] do
        "ok" -> 0
        "not_found" -> 4
        _ -> 1
      end
    else
      {:error, :usage} ->
        usage(2)

      {:error, reason} ->
        IO.puts(:stderr, "home CLI error: #{reason}")
        1
    end
  end

  def main(_argv), do: usage(2)

  defp usage(code) do
    IO.puts(if(code == 0, do: :stdio, else: :stderr), @usage)
    code
  end

  defp options(argv) do
    {opts, command, invalid} =
      OptionParser.parse(argv, strict: [socket: :string, credential_file: :string])

    socket = Keyword.get_values(opts, :socket)
    credential_file = Keyword.get_values(opts, :credential_file)

    if invalid == [] and length(socket) == 1 and length(credential_file) == 1 and
         path?(hd(socket), 100) and path?(hd(credential_file), 1_024) and command != [] do
      {:ok, hd(socket), hd(credential_file), command}
    else
      {:error, :usage}
    end
  end

  defp path?(path, max_bytes),
    do: is_binary(path) and byte_size(path) in 1..max_bytes and Path.type(path) == :absolute

  defp credential(path) do
    with {:ok, stat} <- File.lstat(path),
         true <-
           stat.type == :regular and stat.size in 43..45 and
             (stat.mode &&& 0o777) == 0o600,
         {:ok, stream} <- File.open(path, [:read, :binary]) do
      encoded =
        try do
          IO.binread(stream, 129)
        after
          File.close(stream)
        end

      normalized = if is_binary(encoded), do: String.trim_trailing(encoded, "\n"), else: ""

      with true <- byte_size(normalized) == 43 and String.valid?(normalized),
           {:ok, raw} <- Base.url_decode64(normalized, padding: false),
           true <-
             byte_size(raw) == 32 and
               Base.url_encode64(raw, padding: false) == normalized do
        {:ok, normalized}
      else
        _ -> {:error, :invalid_credential_file}
      end
    else
      _ -> {:error, :invalid_credential_file}
    end
  end

  defp request(["health"], credential),
    do: {:ok, base("health", credential)}

  defp request(["receipt", epoch, operation_id], credential) do
    with {:ok, epoch} <- epoch(epoch),
         true <- Id.valid?(operation_id) do
      {:ok,
       base("status", credential)
       |> Map.put("authority_epoch", epoch)
       |> Map.put("operation_id", operation_id)}
    else
      _ -> {:error, :usage}
    end
  end

  defp request(["enrollment", review_ref], credential) do
    if Id.valid?(review_ref),
      do: {:ok, Map.put(base("enrollment_status", credential), "review_ref", review_ref)},
      else: {:error, :usage}
  end

  defp request(["overrides", thing_id], credential) do
    if Id.valid?(thing_id),
      do: {:ok, Map.put(base("overrides", credential), "target_ids", [thing_id])},
      else: {:error, :usage}
  end

  defp request(_command, _credential), do: {:error, :usage}

  defp base(operation, credential),
    do: %{"api_version" => 1, "operation" => operation, "credential" => credential}

  defp epoch(text) when is_binary(text) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 and value <= 9_223_372_036_854_775_807 -> {:ok, value}
      _ -> {:error, :invalid_epoch}
    end
  end
end
