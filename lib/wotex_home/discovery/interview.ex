defmodule WotexHome.Discovery.Interview do
  @moduledoc """
  A bounded read-only device interview. Its fields remain reported identity,
  not authenticated ownership or an enrollment decision.

  `new/2` ties the reported manufacturer, model, firmware and stable ID to
  the candidate that was actually selected. A profile matcher may use these
  fields as hints, but an operator and the authority service must still review
  the source, collision state and qualification basis.
  """

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Id

  @keys ~w(candidate_ref transport manufacturer model firmware stable_id)
  @enforce_keys [:candidate_ref, :transport, :manufacturer, :model, :firmware, :stable_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map(), Candidate.t()) :: {:ok, t()} | {:error, atom()}
  def new(input, %Candidate{} = candidate) when is_map(input) do
    with :ok <- closed(input),
         :ok <- identity(input, candidate) do
      {:ok,
       struct!(__MODULE__,
         candidate_ref: input["candidate_ref"],
         transport: input["transport"],
         manufacturer: input["manufacturer"],
         model: input["model"],
         firmware: input["firmware"],
         stable_id: input["stable_id"]
       )}
    end
  end

  def new(_input, _candidate), do: {:error, :invalid_interview}

  defp closed(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp identity(input, candidate) do
    if input["candidate_ref"] == candidate.raw_ref and input["transport"] == candidate.transport and
         Enum.all?(~w(manufacturer model firmware stable_id), &Id.valid?(input[&1])),
       do: :ok,
       else: {:error, :invalid_identity}
  end
end
