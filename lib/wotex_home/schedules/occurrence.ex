defmodule WotexHome.Schedules.Occurrence do
  @moduledoc "Deterministic inert occurrence and causal identities, independent of poll order or wall-clock corrections."
  alias WotexHome.{Id, Schedules.Codec}
  alias WotexHome.Profiles.Codec, as: ProfileCodec

  @format "wotex-home.schedule-occurrence.v1"
  @fields ~w(authority_epoch schedule_id source_revision source_digest rule_generation coordinate)

  def encode(value) do
    if Codec.exact?(value, @fields) and
         Codec.integer?(value["authority_epoch"], 1, Codec.maximum()) and
         Id.valid?(value["schedule_id"]) and
         Codec.integer?(value["source_revision"], 0, Codec.maximum()) and
         ProfileCodec.digest?(value["source_digest"]) and
         Codec.integer?(value["rule_generation"], 1, Codec.maximum()) and
         coordinate?(value["coordinate"]) do
      {:ok, JSON.encode!([@format | Enum.map(@fields, &value[&1])])}
    else
      invalid()
    end
  end

  def decode(bytes) do
    with {:ok, [@format | values]} <- Codec.record(bytes),
         true <- length(values) == length(@fields),
         occurrence = Map.new(Enum.zip(@fields, values)),
         {:ok, ^bytes} <- encode(occurrence),
         do: {:ok, occurrence},
         else: (_ -> invalid())
  end

  def identity(value) do
    with {:ok, bytes} <- encode(value) do
      digest = Codec.hash(bytes)
      {:ok, %{id: "occ:" <> digest, root_id: "cause:schedule:" <> digest, document: bytes}}
    end
  end

  def build(source, epoch, generation, coordinate) do
    with {:ok, digest} <- Codec.digest(source) do
      occurrence = %{
        "authority_epoch" => epoch,
        "schedule_id" => source["id"],
        "source_revision" => source["source_revision"],
        "source_digest" => digest,
        "rule_generation" => generation,
        "coordinate" => coordinate
      }

      with {:ok, _} <- encode(occurrence), do: {:ok, occurrence}
    end
  end

  def current?(occurrence, source) do
    with {:ok, _} <- encode(occurrence),
         {:ok, digest} <- Codec.digest(source),
         true <-
           occurrence["schedule_id"] == source["id"] and
             occurrence["source_revision"] == source["source_revision"] and
             occurrence["source_digest"] == digest,
         do: true,
         else: (_ -> false)
  end

  defp coordinate?(["utc", due]), do: Codec.utc?(due)

  defp coordinate?(["countdown", boot, generation, due]),
    do:
      Id.valid?(boot) and Codec.integer?(generation, 1, Codec.maximum()) and
        Codec.integer?(due, 0, Codec.maximum() - 60_000)

  defp coordinate?(_), do: false
  defp invalid, do: {:error, :invalid_schedule_occurrence}
end
