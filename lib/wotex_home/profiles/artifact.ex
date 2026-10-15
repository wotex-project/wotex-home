defmodule WotexHome.Profiles.Artifact do
  @moduledoc """
  Builds a checked portable-profile v1 artifact with separate raw and semantic identities.

  `parse/1` decodes the exact original bytes, loads the pinned LIFX product
  registry and resolves the host-owned binding. It returns `{:ok, artifact}`
  or a typed `{:error, reason}` from those checks. The artifact retains unchanged
  raw bytes and their digest beside the versioned projection document and its
  distinct digest; `digest/1` computes lowercase SHA-256 for supplied bytes.

  `declaration/2` reparses the retained bytes before deriving the proposed Thing
  for an explicit Home ID. The projection binds exact labels, normalized
  fingerprint, compiler/binding, registry, declaration and selection policy.
  Provenance remains inert attribution.

  A checked artifact or declaration is not catalogue approval, target selection,
  enrollment or physical qualification. Those current decisions remain owned
  by `WotexHome.Authority` and `WotexHome.Durable.Store`.
  """

  alias WotexHome.Profiles.{Bindings, Codec}
  alias WotexHome.Lifx.ProductRegistry

  @enforce_keys [
    :bytes,
    :digest,
    :data,
    :profile,
    :profile_ref,
    :projection_document,
    :projection_digest
  ]
  defstruct @enforce_keys

  def parse(bytes) do
    with {:ok, data} <- Codec.decode(bytes),
         {:ok, registry} <- ProductRegistry.load_pinned(),
         digest = digest(bytes),
         {:ok, resolved} <- Bindings.resolve(data, digest, registry) do
      {:ok,
       struct!(__MODULE__,
         bytes: bytes,
         digest: digest,
         data: data,
         profile: resolved.profile,
         profile_ref: resolved.profile_ref,
         projection_document: resolved.projection_document,
         projection_digest: digest(resolved.projection_document)
       )}
    end
  end

  @doc "Reconstruct a declaration only from revalidated immutable bytes."
  def declaration(%__MODULE__{bytes: bytes}, thing_id) do
    with {:ok, artifact} <- parse(bytes), do: Bindings.declaration(artifact.profile, thing_id)
  end

  def declaration(_, _), do: {:error, :invalid_profile_data}
  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
