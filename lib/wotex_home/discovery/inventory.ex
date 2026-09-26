defmodule WotexHome.Discovery.Inventory do
  @moduledoc """
  Reports collisions in untrusted claimed identifiers without resolving them.
  """

  alias WotexHome.Discovery.Candidate

  @spec conflicts([Candidate.t()]) :: %{{String.t(), String.t()} => [Candidate.t()]}
  def conflicts(candidates) when is_list(candidates) do
    candidates
    |> Enum.flat_map(fn %Candidate{} = candidate ->
      Enum.map(candidate.claimed_identifiers, fn {key, value} -> {{key, value}, candidate} end)
    end)
    |> Enum.group_by(fn {claim, _candidate} -> claim end, fn {_claim, candidate} -> candidate end)
    |> Map.filter(fn {_claim, members} -> length(members) > 1 end)
  end
end
