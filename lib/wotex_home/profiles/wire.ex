defmodule WotexHome.Profiles.Wire do
  @moduledoc """
  Encodes private profile API values and canonical legacy import bytes.

  `decode_import/1` accepts unpadded URL-safe Base64 only when re-encoding yields
  the same text and the decoded payload is 1–32,768 bytes. `import_summary/1`
  returns an inert legacy artifact summary. `encode/1` converts nested atom keys
  and values to their public string representation.

  This boundary performs no custody publication or document approval. Tagged
  authoring objects and their upload/original-operation flow use separate codecs.
  """

  alias WotexHome.Profiles.Artifact

  def decode_import(encoded) when is_binary(encoded) and byte_size(encoded) in 1..43_691 do
    with {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(bytes) in 1..32_768,
         true <- Base.url_encode64(bytes, padding: false) == encoded do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_profile_import}
    end
  end

  def decode_import(_), do: {:error, :invalid_profile_import}

  def import_summary(%Artifact{} = artifact) do
    %{
      artifact_digest: artifact.digest,
      projection_digest: artifact.projection_digest,
      registry_digest: hd(artifact.data["dependencies"])["sha256"],
      id: artifact.data["id"],
      version: artifact.data["version"],
      profile_ref: artifact.profile_ref,
      binding: artifact.data["binding"],
      authority_changed: false
    }
  end

  def encode(value) when value in [nil, true, false], do: value
  def encode(value) when is_atom(value), do: Atom.to_string(value)

  def encode(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key_string(key), encode(item)} end)

  def encode(value) when is_list(value), do: Enum.map(value, &encode/1)
  def encode(value), do: value
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key) when is_binary(key), do: key
end
