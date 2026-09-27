defmodule WotexHome.Durable.Registry do
  @moduledoc "Bounded encoding for locally provisioned Thing declarations and credentials."

  alias WotexHome.Semantics.{Capability, Thing}

  @max_document_bytes 65_536

  @spec encode_thing(Thing.t()) :: {:ok, String.t()} | {:error, atom()}
  def encode_thing(%Thing{capabilities: capabilities} = thing)
      when is_map(capabilities) and map_size(capabilities) > 0 and
             map_size(capabilities) <= 32 do
    if Enum.all?(capabilities, fn {key, capability} ->
         is_binary(key) and match?(%Capability{}, capability)
       end) do
      encode_valid_thing(thing)
    else
      {:error, :invalid_thing}
    end
  end

  def encode_thing(_thing), do: {:error, :invalid_thing}

  defp encode_valid_thing(thing) do
    input = %{
      "id" => thing.id,
      "role" => thing.role,
      "profile_ref" => thing.profile_ref,
      "capabilities" =>
        Enum.map(thing.capabilities, fn {_key, capability} -> capability_map(capability) end)
    }

    case Thing.new(input) do
      {:ok, ^thing} ->
        document = JSON.encode!(input)

        if byte_size(document) <= @max_document_bytes,
          do: {:ok, document},
          else: {:error, :thing_too_large}

      _ ->
        {:error, :invalid_thing}
    end
  end

  @spec decode_thing(String.t()) :: {:ok, Thing.t()} | {:error, :corrupt_enrollment}
  def decode_thing(document)
      when is_binary(document) and byte_size(document) <= @max_document_bytes do
    with {:ok, input} <- JSON.decode(document),
         {:ok, thing} <- Thing.new(input),
         {:ok, ^document} <- encode_thing(thing) do
      {:ok, thing}
    else
      _ -> {:error, :corrupt_enrollment}
    end
  end

  def decode_thing(_document), do: {:error, :corrupt_enrollment}

  @spec credential_hash(binary()) :: {:ok, binary()} | {:error, :invalid_credential}
  def credential_hash(credential) when is_binary(credential) and byte_size(credential) == 32,
    do: {:ok, :crypto.hash(:sha256, credential)}

  def credential_hash(_credential), do: {:error, :invalid_credential}

  @spec encode_permissions([String.t()]) :: {:ok, String.t()} | {:error, :invalid_permissions}
  def encode_permissions(permissions) do
    if is_list(permissions) and permissions != [] and
         length(Enum.uniq(permissions)) == length(permissions) and
         Enum.all?(
           permissions,
           &(&1 in ["read", "control:ordinary", "rule:review", "enroll:review"])
         ),
       do: {:ok, JSON.encode!(permissions)},
       else: {:error, :invalid_permissions}
  end

  @spec decode_permissions(String.t()) ::
          {:ok, [String.t()]} | {:error, :corrupt_principal}
  def decode_permissions(document) when is_binary(document) do
    with {:ok, permissions} <- JSON.decode(document),
         {:ok, ^document} <- encode_permissions(permissions) do
      {:ok, permissions}
    else
      _ -> {:error, :corrupt_principal}
    end
  end

  def decode_permissions(_document), do: {:error, :corrupt_principal}

  defp capability_map(%Capability{} = capability) do
    Map.from_struct(capability)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
