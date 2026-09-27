defmodule WotexHome.Semantics.SceneReport do
  @moduledoc """
  Per-member scene results without an atomic physical-success claim.

  `:reported_match` is Home's qualified reported state, not independent proof
  of light output. Missing members are explicit `:not_started` outcomes.

  Use `new/2` after a scene attempt to describe every member, including work
  that never started. Consumers should inspect individual statuses before
  presenting a summary; one member's success cannot stand in for the scene.
  """

  alias WotexHome.Semantics.Scene

  @statuses [
    :reported_match,
    :protocol_accepted,
    :outcome_unknown,
    :failed,
    :rejected,
    :not_started
  ]
  @enforce_keys [:scene_id, :scene_revision, :members, :summary]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(Scene.t(), %{String.t() => atom()}) :: {:ok, t()} | {:error, atom()}
  def new(%Scene{} = scene, outcomes) when is_map(outcomes) do
    targets = Scene.target_ids(scene)

    if Enum.all?(Map.keys(outcomes), &(&1 in targets)) and
         Enum.all?(Map.values(outcomes), &(&1 in @statuses)) do
      members = Map.new(targets, &{&1, Map.get(outcomes, &1, :not_started)})

      {:ok,
       %__MODULE__{
         scene_id: scene.id,
         scene_revision: scene.revision,
         members: members,
         summary: summarize(Map.values(members))
       }}
    else
      {:error, :invalid_member_outcome}
    end
  end

  def new(_scene, _outcomes), do: {:error, :invalid_scene_report}

  defp summarize(statuses) do
    cond do
      Enum.all?(statuses, &(&1 == :reported_match)) -> :all_reported_match
      Enum.all?(statuses, &(&1 == :not_started)) -> :not_started
      true -> :partial_or_unknown
    end
  end
end
