defmodule WotexHome.Host.GenerationInstallation do
  @moduledoc """
  Checks generator policy and adapter capabilities before Host startup.

  `prepare/1` accepts exactly a native policies/providers map, reconstructing
  at most 32 ordered `WotexHome.Profiles.GenerationPolicy` values and 32 distinct
  live local `WotexHome.Profiles.GenerationProvider` capabilities. Each provider
  digest must match an installed policy. The result is `{:ok, installation}`
  with those two checked lists; malformed, dead or unmatched input refuses.
  Nil selects empty lists explicitly.

  Policies without live adapters can still support inert preparation; starting
  an attempt requires its exact selected provider and cannot choose a fallback.
  Host selects private policy files separately and passes the checked lists to
  `WotexHome.Durable.Store` before durable resources and consumers start.

  This pure boundary starts no provider, reads no source and grants no export,
  profile approval or device-control authority. It cannot authenticate an
  external model or establish the adapter owner's OS confinement.
  """

  alias WotexHome.Profiles.{GenerationPolicy, GenerationProvider}

  @doc "Reconstructs a closed native installation; nil explicitly disables generation."
  def prepare(nil), do: {:ok, %{policies: [], providers: []}}

  def prepare(%{policies: policies, providers: providers} = input)
      when not is_struct(input) and map_size(input) == 2 do
    with :ok <- GenerationPolicy.installation(policies),
         :ok <- GenerationProvider.installation(providers),
         allowed = MapSet.new(policies, & &1.provider_sha256),
         true <- Enum.all?(providers, &MapSet.member?(allowed, &1.provider_sha256)),
         do: {:ok, %{policies: policies, providers: providers}},
         else: (_ -> invalid())
  end

  def prepare(_), do: invalid()

  defp invalid, do: {:error, :invalid_generation_installation}
end
