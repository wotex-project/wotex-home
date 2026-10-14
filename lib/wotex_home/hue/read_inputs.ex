defmodule WotexHome.Hue.ReadInputs do
  @moduledoc """
  Loads bounded explicit file inputs for a read-only Hue laboratory exchange.

  `load/4` checks one CA certificate and a private application-key file, then
  validates the explicitly selected bridge ID and peer fingerprint through
  `WotexHome.Hue.BridgeTLS`. File/syntax errors return a closed refusal without
  returning partial trust material.

  The helper creates no long-lived custody, enrollment or grant. Callers keep
  the resolved key private and supply the selected LAN/read path separately;
  successful TLS input parsing is not physical bridge qualification.
  """

  import Bitwise

  def load(ca_path, key_path, bridge, pin) do
    with {:ok, pem} <- file(ca_path, 32_768, false),
         [{:Certificate, ca, :not_encrypted}] <- :public_key.pem_decode(pem),
         {:ok, bytes} <- file(key_path, 129, true),
         key = String.trim_trailing(bytes, "\n"),
         true <- key =~ ~r/\A[A-Za-z0-9_-]{16,128}\z/,
         trust = %{bridge_id: bridge, peer_sha256: pin, ca_der: ca},
         {:ok, _} <- WotexHome.Hue.BridgeTLS.options(trust) do
      {:ok, trust, key}
    else
      _ -> {:error, :invalid_hue_input_file}
    end
  rescue
    _ -> {:error, :invalid_hue_input_file}
  end

  defp file(path, limit, private?) when is_binary(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size in 1..limit,
         true <- not private? or (stat.mode &&& 0o777) == 0o600,
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        with true <- same_file?(io, stat, private?),
             bytes when is_binary(bytes) <- IO.binread(io, limit + 1),
             true <- byte_size(bytes) == stat.size,
             true <- same_file?(io, stat, private?) do
          {:ok, bytes}
        else
          _ -> {:error, :invalid_hue_input_file}
        end
      after
        File.close(io)
      end
    else
      _ -> {:error, :invalid_hue_input_file}
    end
  end

  defp file(_, _, _), do: {:error, :invalid_hue_input_file}

  defp same_file?(io, stat, private?) do
    case :file.read_file_info(io) do
      {:ok, {:file_info, size, :regular, _, _, _, _, mode, _, major, minor, inode, uid, _}} ->
        size == stat.size and
          {major, minor, inode, uid} ==
            {stat.major_device, stat.minor_device, stat.inode, stat.uid} and
          (not private? or (mode &&& 0o777) == 0o600)

      _ ->
        false
    end
  end
end
