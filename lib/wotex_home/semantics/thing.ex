defmodule WotexHome.Semantics.Thing do
  @moduledoc """
  A stable Home identity with only explicitly declared capabilities.

  Use `new/1` when a profile proposes an enrolled Thing. The constructor
  checks the closed role and capability schema and returns an indexed
  declaration. `capability/2` looks up one declared key; a missing key stays
  missing rather than acquiring a default.

  This value describes what Home may represent. Enrollment, evidence review,
  current grants and command admission happen elsewhere.
  """

  alias WotexHome.Id
  alias WotexHome.Semantics.Capability

  @keys ~w(id role profile_ref capabilities)
  @enforce_keys [:id, :role, :profile_ref, :capabilities]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(input) when is_map(input) do
    with :ok <- closed(input),
         :ok <- identity(input),
         {:ok, capabilities} <- capabilities(input) do
      {:ok,
       %__MODULE__{
         id: input["id"],
         role: input["role"],
         profile_ref: input["profile_ref"],
         capabilities: Map.new(capabilities, &{&1.key, &1})
       }}
    end
  end

  def new(_input), do: {:error, :invalid_thing}

  @spec capability(t(), String.t()) :: {:ok, Capability.t()} | :error
  def capability(%__MODULE__{capabilities: capabilities}, key),
    do: Map.fetch(capabilities, key)

  defp closed(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp identity(input) do
    if Id.valid?(input["id"]) and Id.valid?(input["profile_ref"]) and
         input["role"] in ["Light", "SmokeDetector"],
       do: :ok,
       else: {:error, :invalid_identity}
  end

  defp capabilities(%{"capabilities" => inputs} = input)
       when is_list(inputs) and length(inputs) > 0 and length(inputs) <= 32 do
    with {:ok, capabilities} <- parse_capabilities(inputs),
         true <- Enum.all?(capabilities, &same_identity?(&1, input)),
         true <- unique_keys?(capabilities),
         true <- baseline?(capabilities, input["role"]) do
      {:ok, capabilities}
    else
      false -> {:error, :invalid_capabilities}
      {:error, _} = error -> error
    end
  end

  defp capabilities(_input), do: {:error, :invalid_capabilities}

  defp parse_capabilities(inputs) do
    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, acc} ->
      case Capability.new(input) do
        {:ok, capability} -> {:cont, {:ok, [capability | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp same_identity?(capability, input) do
    capability.thing_id == input["id"] and capability.role == input["role"] and
      capability.profile_ref == input["profile_ref"]
  end

  defp unique_keys?(capabilities) do
    keys = Enum.map(capabilities, & &1.key)
    length(keys) == length(Enum.uniq(keys))
  end

  defp baseline?(capabilities, "Light"), do: Enum.any?(capabilities, &(&1.key == "power"))

  defp baseline?(capabilities, "SmokeDetector"),
    do: Enum.any?(capabilities, &(&1.key == "smoke_state"))
end
