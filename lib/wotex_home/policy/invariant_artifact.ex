defmodule WotexHome.Policy.InvariantArtifact do
  @moduledoc """
  Closed reported-fact constraints for the narrow ordinary Light power path.

  A constraint can only restrict the separately qualified direct-power profile.
  It binds canonical predicate source, the shared Home predicate IR and exact
  declaration revisions. It proves neither sensor authentication nor physical
  safety. Installation, current authority and current facts belong to Store.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Id
  alias WotexHome.Lifx.DirectPowerSafety
  alias WotexHome.Rules.Compiler
  alias WotexHome.Semantics.{Capability, Thing}

  @profile "home-reported-power-constraint-v1"
  @max_bytes 4_194_304
  @max_i64 9_223_372_036_854_775_807

  def create(target, source, resources) do
    with true <- Id.valid?(target),
         {:ok, program} <- Compiler.compile_predicate(source),
         true <- length(program.facts) <= 32,
         {:ok, things} <- declarations(resources),
         true <- Map.keys(things) |> Enum.sort() == required_ids(target, program),
         true <- DirectPowerSafety.decision(Map.fetch!(things, target)) == :allow,
         true <- typed?(program.instructions, things) do
      artifact = %{
        "profile" => @profile,
        "scope" => "reported_constraint_only",
        "target_id" => target,
        "source_document" => source,
        "compiler_profile" => program.profile,
        "source_digest" => program.source_digest,
        "ir_digest" => program.ir_digest,
        "resources" => resources
      }

      document = JSON.encode!(artifact)

      if byte_size(document) <= @max_bytes,
        do: {:ok, document},
        else: {:error, :invalid_invariant_artifact}
    else
      _ -> {:error, :invalid_invariant_artifact}
    end
  end

  def decode(document) when is_binary(document) and byte_size(document) <= @max_bytes do
    with {:ok, %{"target_id" => target, "source_document" => source, "resources" => pins} = data} <-
           JSON.decode(document),
         {:ok, ^document} <- create(target, source, pins),
         {:ok, program} <- Compiler.compile_predicate(source) do
      {:ok, data, program}
    else
      _ -> {:error, :invalid_invariant_artifact}
    end
  end

  def decode(_document), do: {:error, :invalid_invariant_artifact}

  def digest(document) when is_binary(document),
    do: :crypto.hash(:sha256, document) |> Base.encode16(case: :lower)

  def required_ids(target, program),
    do: Enum.sort(Enum.uniq([target | Enum.map(program.facts, &elem(&1, 0))]))

  defp declarations(resources) when is_list(resources) and length(resources) in 1..32 do
    Enum.reduce_while(resources, {:ok, %{}, nil}, fn
      %{"thing_id" => id, "resource_revision" => revision, "document" => document} = pin,
      {:ok, things, previous} ->
        with true <- map_size(pin) == 3 and Id.valid?(id),
             true <- is_integer(revision) and revision in 0..@max_i64,
             true <- previous == nil or previous < id,
             {:ok, %Thing{id: ^id} = thing} <- Registry.decode_thing(document) do
          {:cont, {:ok, Map.put(things, id, thing), id}}
        else
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, things, _} -> {:ok, things}
      _ -> :error
    end
  end

  defp declarations(_resources), do: :error

  defp typed?(instructions, things) do
    Enum.all?(instructions, fn
      {op, {id, key}, value} when op in [:eq, :gt] ->
        with {:ok, capability} <- Thing.capability(Map.fetch!(things, id), key) do
          Capability.supports?(capability, "read") and Capability.accepts?(capability, value)
        else
          _ -> false
        end

      _ ->
        true
    end)
  end
end
