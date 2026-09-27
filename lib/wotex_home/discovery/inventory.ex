defmodule WotexHome.Discovery.Inventory do
  @moduledoc """
  Reports collisions in untrusted claimed identifiers without resolving them.

  Pass candidates from the same bounded discovery view to `conflicts/1`.
  The result groups each repeated claim with the candidates that made it, so
  an enrollment review can stop on ambiguity. No winner is selected from
  packet order or signal strength.
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
