defmodule WotexHome.Recovery.Owner do
  @moduledoc "Separately provisioned private destination identity; grants no authority."
  alias WotexHome.Profiles.{Artifact, Codec}
  alias WotexHome.Recovery.PrivateFile
  @format "wotex-home.controller-owner.v1"

  def create(path) do
    owner = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    bytes = JSON.encode!([@format, owner])

    with :ok <- PrivateFile.write(path, bytes, 128), do: {:ok, commitment(owner, bytes)}
  end

  def read(path) do
    with {:ok, owner, _seal} <- read_sealed(path), do: {:ok, owner}
  end

  def read_sealed(path) do
    with {:ok, bytes, seal} <- PrivateFile.read_sealed(path, 128),
         {:ok, [@format, owner]} <- JSON.decode(bytes),
         true <- Codec.digest?(owner) and JSON.encode!([@format, owner]) == bytes do
      {:ok, commitment(owner, bytes), seal}
    else
      _ -> {:error, :owner_custody_unavailable}
    end
  end

  defp commitment(owner, bytes),
    do: %{owner_id: owner, owner_custody_digest: Artifact.digest(bytes)}
end
