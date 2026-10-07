defmodule WotexHome.Profiles.Artifact do
  @moduledoc """
  Immutable validated portable data, with separate raw and semantic identities.

  Raw bytes are retained unchanged. The projection's versioned ordered JSON
  array binds exact labels, normalized fingerprint, host compiler/binding,
  registry, declaration and selection policy. Provenance is inert attribution.
  Parsing grants no admission, selection, enrollment or physical authority.
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
