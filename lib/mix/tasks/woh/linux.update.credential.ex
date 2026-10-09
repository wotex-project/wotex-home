defmodule Woh.Tool.LinuxUpdateCredential do
  @moduledoc false

  # Public launcher input is one canonical encoded bearer, with an optional LF.
  # No credential path, environment value or command argument is accepted.
  def decode(<<credential::binary-size(43), "\n">>), do: decode(credential)

  def decode(credential) when is_binary(credential) and byte_size(credential) == 43 do
    case Base.url_decode64(credential, padding: false) do
      {:ok, bytes} ->
        if byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == credential,
          do: {:ok, credential},
          else: error()

      _ ->
        error()
    end
  end

  def decode(_), do: error()

  def read do
    task = Task.async(fn -> IO.binread(:stdio, 45) end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, bytes} -> decode(bytes)
      _ -> error()
    end
  end

  defp error, do: {:error, :update_credential_refused}
end
