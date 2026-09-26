defmodule WotexHome.Discovery.Profile do
  @moduledoc """
  Exact packaged profile fingerprint for read-only matching.

  A match is a review hint. It neither creates a Thing nor grants command
  authority. Profile code, credential policy and capability mapping are later
  admission gates.
  """

  alias WotexHome.Discovery.Interview
  alias WotexHome.Id

  @keys ~w(id version transport manufacturer model firmware_versions rank qualification_ref)
  @enforce_keys [
    :id,
    :version,
    :transport,
    :manufacturer,
    :model,
    :firmware_versions,
    :rank,
    :qualification_ref
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(input) when is_map(input) do
    with :ok <- closed(input),
         :ok <- fields(input) do
      {:ok,
       struct!(__MODULE__,
         id: input["id"],
         version: input["version"],
         transport: input["transport"],
         manufacturer: input["manufacturer"],
         model: input["model"],
         firmware_versions: input["firmware_versions"],
         rank: input["rank"],
         qualification_ref: input["qualification_ref"]
       )}
    end
  end

  def new(_input), do: {:error, :invalid_profile}

  @spec match(Interview.t(), [t()]) :: {:ok, t()} | {:error, :unsupported | :ambiguous_profile}
  def match(%Interview{} = interview, profiles)
      when is_list(profiles) and length(profiles) <= 64 do
    matching = Enum.filter(profiles, &matches?(&1, interview))

    case matching do
      [] ->
        {:error, :unsupported}

      _ ->
        highest = Enum.max_by(matching, & &1.rank).rank

        case Enum.filter(matching, &(&1.rank == highest)) do
          [profile] -> {:ok, profile}
          _ -> {:error, :ambiguous_profile}
        end
    end
  end

  def match(_interview, _profiles), do: {:error, :unsupported}

  defp matches?(%__MODULE__{} = profile, interview) do
    profile.transport == interview.transport and profile.manufacturer == interview.manufacturer and
      profile.model == interview.model and interview.firmware in profile.firmware_versions
  end

  defp matches?(_profile, _interview), do: false

  defp closed(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp fields(input) do
    firmwares = input["firmware_versions"]

    if Enum.all?(~w(id version manufacturer model qualification_ref), &Id.valid?(input[&1])) and
         input["transport"] in ~w(udp mdns zigbee configured) and
         is_list(firmwares) and firmwares != [] and length(firmwares) <= 32 and
         Enum.uniq(firmwares) == firmwares and Enum.all?(firmwares, &Id.valid?/1) and
         is_integer(input["rank"]) and input["rank"] >= 0 and input["rank"] <= 100,
       do: :ok,
       else: {:error, :invalid_profile}
  end
end
