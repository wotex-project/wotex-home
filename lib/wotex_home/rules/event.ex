defmodule WotexHome.Rules.Event do
  @moduledoc "Closed trigger event for credential-free draft simulation."

  alias WotexHome.Id
  alias WotexHome.Rules.Fact

  @max_i64 9_223_372_036_854_775_807
  @enforce_keys [:kind, :root_id, :depth, :origin, :rule_id, :fact, :before, :after_value]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(
        %{
          "kind" => "explicit_request",
          "root_id" => root_id,
          "depth" => depth,
          "rule_id" => rule_id
        } = input
      )
      when map_size(input) == 4 do
    if metadata?(root_id, depth) and Id.valid?(rule_id) do
      {:ok,
       %__MODULE__{
         kind: :explicit_request,
         root_id: root_id,
         depth: depth,
         origin: :operator,
         rule_id: rule_id,
         fact: nil,
         before: nil,
         after_value: nil
       }}
    else
      {:error, :invalid_event}
    end
  end

  def new(
        %{
          "kind" => "edge",
          "root_id" => root_id,
          "depth" => depth,
          "origin" => origin,
          "fact" => raw_fact,
          "before" => before,
          "after" => after_value
        } = input
      )
      when map_size(input) == 7 do
    with true <- metadata?(root_id, depth) and origin in ["reported", "synthetic_ack"],
         {:ok, fact} <- Fact.new(raw_fact),
         true <- boolean_fact?(before) and boolean_fact?(after_value) do
      {:ok,
       %__MODULE__{
         kind: :edge,
         root_id: root_id,
         depth: depth,
         origin: if(origin == "reported", do: :reported, else: :synthetic_ack),
         rule_id: nil,
         fact: fact,
         before: before,
         after_value: after_value
       }}
    else
      _ -> {:error, :invalid_event}
    end
  end

  def new(_input), do: {:error, :invalid_event}

  defp metadata?(root_id, depth),
    do: Id.valid?(root_id) and is_integer(depth) and depth >= 0 and depth <= @max_i64

  defp boolean_fact?(value), do: value in [true, false, "unknown"]
end
