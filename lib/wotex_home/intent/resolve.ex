defmodule WotexHome.Intent.Resolve do
  @moduledoc """
  Pure resolution of an untrusted Light-power candidate to a typed preview.

  The caller supplies current authenticated grants and an exact alias index.
  The returned mutation still needs Store authentication, revision, policy and
  runtime guards. This module never submits a request or holds driver access.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Registry
  alias WotexHome.Intent.Grammar
  alias WotexHome.Mutation
  alias WotexHome.Semantics.{Capability, Thing}

  @max_i64 9_223_372_036_854_775_807

  @spec preview(
          Grammar.t(),
          %{String.t() => [String.t()]},
          %{String.t() => Thing.t()},
          MapSet.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, Mutation.t()} | {:error, atom()}
  def preview(
        %Grammar{source: :exact_grammar, locale: "en"} = candidate,
        aliases,
        things,
        allowed_targets,
        operation_id,
        authority_epoch,
        expected_revision
      )
      when is_map(aliases) and is_map(things) and is_struct(allowed_targets, MapSet) do
    with true <-
           valid_inputs?(
             candidate,
             aliases,
             things,
             allowed_targets,
             operation_id,
             authority_epoch,
             expected_revision
           ),
         {:ok, target_id} <- exact_target(candidate.target_phrase, aliases),
         true <- MapSet.member?(allowed_targets, target_id),
         {:ok, %Thing{id: ^target_id, role: "Light"} = thing} <- Map.fetch(things, target_id),
         {:ok, _document} <- Registry.encode_thing(thing),
         {:ok, %Capability{} = capability} <- Thing.capability(thing, "power"),
         true <- Capability.supports?(capability, "write") do
      Mutation.new(%{
        "api_version" => 1,
        "operation_id" => operation_id,
        "authority_epoch" => authority_epoch,
        "expected_revision" => expected_revision,
        "target_id" => target_id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => candidate.intent == :light_power_on}
      })
    else
      false -> {:error, :target_unavailable}
      :error -> {:error, :target_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  def preview(_candidate, _aliases, _things, _allowed_targets, _operation_id, _epoch, _revision),
    do: {:error, :invalid_intent_preview}

  defp valid_inputs?(candidate, aliases, things, allowed_targets, operation_id, epoch, revision) do
    Grammar.valid?(candidate) and
      Id.valid?(operation_id) and valid_revision?(epoch) and valid_revision?(revision) and
      map_size(aliases) <= 128 and map_size(things) <= 128 and
      MapSet.size(allowed_targets) <= 32 and
      Enum.all?(allowed_targets, &Id.valid?/1) and
      Enum.all?(aliases, fn {name, ids} ->
        is_binary(name) and byte_size(name) in 1..80 and String.valid?(name) and
          is_list(ids) and length(ids) in 1..8 and Enum.all?(ids, &Id.valid?/1)
      end)
  end

  defp exact_target(phrase, aliases) do
    matches =
      aliases
      |> Enum.filter(fn {name, _ids} -> String.downcase(String.trim(name)) == phrase end)
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.uniq()

    case matches do
      [id] -> {:ok, id}
      [] -> {:error, :target_unknown}
      _ -> {:error, :target_ambiguous}
    end
  end

  defp valid_revision?(value), do: is_integer(value) and value >= 0 and value <= @max_i64
end
