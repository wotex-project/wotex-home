defmodule WotexHome.Semantics.Scene do
  @moduledoc """
  Closed scene intent bound to exact enrolled Thing/profile declarations.

  Construction is a pure plan. It does not authorize, queue or dispatch any
  member. Each member targets a whole-Thing effect domain in this subset.

  `new/2` rejects undeclared targets, capabilities and stale revisions before
  a scene can be submitted. `target_ids/1` lists the Things that a later
  authority service must claim and recheck together. A valid scene still
  needs per-member receipts and readback; it does not promise atomic device
  effects.
  """

  alias WotexHome.Id
  alias WotexHome.Semantics.{Capability, Thing, Value}

  @keys ~w(version id revision members)
  @member_keys ~w(target_id profile_ref capability_key expected_revision value)
  @max_i64 9_223_372_036_854_775_807

  @enforce_keys [:id, :revision, :members]
  defstruct @enforce_keys

  @type member :: %{
          target_id: String.t(),
          profile_ref: String.t(),
          capability_key: String.t(),
          expected_revision: non_neg_integer(),
          value: Value.t()
        }
  @type t :: %__MODULE__{id: String.t(), revision: non_neg_integer(), members: [member()]}

  @spec new(map(), %{String.t() => Thing.t()}) :: {:ok, t()} | {:error, atom()}
  def new(input, things) when is_map(input) and is_map(things) do
    with :ok <- closed(input, @keys),
         true <-
           input["version"] == 1 and Id.valid?(input["id"]) and
             revision?(input["revision"]),
         {:ok, members} <- members(input["members"], things),
         true <- unique_domains?(members) do
      {:ok, %__MODULE__{id: input["id"], revision: input["revision"], members: members}}
    else
      false -> {:error, :invalid_scene}
      {:error, _} = error -> error
    end
  end

  def new(_input, _things), do: {:error, :invalid_scene}

  @spec target_ids(t()) :: [String.t()]
  def target_ids(%__MODULE__{members: members}), do: Enum.map(members, & &1.target_id)

  defp members(raw, things) when is_list(raw) and length(raw) > 0 and length(raw) <= 32 do
    Enum.reduce_while(raw, {:ok, []}, fn input, {:ok, parsed} ->
      case member(input, things) do
        {:ok, item} -> {:cont, {:ok, [item | parsed]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp members(_raw, _things), do: {:error, :invalid_members}

  defp member(input, things) when is_map(input) do
    with :ok <- closed(input, @member_keys),
         true <-
           Id.valid?(input["target_id"]) and Id.valid?(input["profile_ref"]) and
             Id.valid?(input["capability_key"]) and revision?(input["expected_revision"]),
         {:ok, %Thing{profile_ref: profile_ref} = thing} <-
           Map.fetch(things, input["target_id"]),
         true <- profile_ref == input["profile_ref"] and thing.id == input["target_id"],
         {:ok, %Capability{} = capability} <- Thing.capability(thing, input["capability_key"]),
         true <- Capability.supports?(capability, "write") and capability.risk_class == "ordinary",
         {:ok, value} <- Value.new(input["value"]),
         true <- Capability.accepts?(capability, value) do
      {:ok,
       %{
         target_id: thing.id,
         profile_ref: thing.profile_ref,
         capability_key: capability.key,
         expected_revision: input["expected_revision"],
         value: value
       }}
    else
      :error -> {:error, :target_unavailable}
      false -> {:error, :unsupported_member}
      {:error, _} = error -> error
    end
  end

  defp member(_input, _things), do: {:error, :invalid_member}

  defp unique_domains?(members) do
    target_ids = Enum.map(members, & &1.target_id)
    length(target_ids) == length(Enum.uniq(target_ids))
  end

  defp closed(input, keys) do
    if Enum.sort(Map.keys(input)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp revision?(revision),
    do: is_integer(revision) and revision >= 0 and revision <= @max_i64
end
