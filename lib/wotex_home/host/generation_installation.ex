defmodule WotexHome.Host.GenerationInstallation do
  @moduledoc """
  Checks an explicit generator policy and adapter installation before Host startup.

  `prepare/1` reconstructs at most 32 ordered policies and 32 distinct live
  local adapter capabilities. Every adapter must match an installed policy;
  policies without adapters remain available for inert preparation only.
  Nil selects empty lists. The result contains exactly policies and providers.

  Host selects private policy files separately and passes these checked lists
  to `WotexHome.Durable.Store`. This pure module starts no provider, reads no
  source and grants no export, profile approval or device-control authority.
  Actual model authentication and confinement belong to the adapter's owner.
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
