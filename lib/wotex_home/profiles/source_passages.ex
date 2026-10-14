defmodule WotexHome.Profiles.SourcePassages do
  @moduledoc """
  Projects explicit UTF-8 byte ranges from verified original source objects.

  `select/2` accepts 1–32 sorted, unique source/offset/length selectors. Offsets
  are byte offsets; each passage is at most 4,096 bytes and the total selected
  text is at most 131,072 bytes. Selected sources are checked against their
  complete object summaries and payload digests before any slice is returned.

  A passage must fit entirely inside its source and contain valid UTF-8 without
  control characters other than newline and tab. Results retain the original
  payload digest, first revision and exact passage digest. They are inert text:
  actor ownership and permission to read or export belong to Authority and Store.
  """

  alias WotexHome.Profiles.{AuthoringObject, AuthoringProducer, EnvelopeCodec}
  @maximum 9_223_372_036_854_775_807

  @doc false
  def references(selectors) do
    with :ok <- bounded(selectors, 32),
         true <- selectors != [],
         :ok <- entries(selectors),
         identities = Enum.map(selectors, &{&1["source_ref"], &1["offset"], &1["length"]}),
         true <- identities == Enum.sort(Enum.uniq(identities)),
         true <- Enum.reduce(selectors, 0, &(&1["length"] + &2)) <= 131_072 do
      {:ok, Enum.uniq(Enum.map(selectors, & &1["source_ref"]))}
    else
      false -> {:error, :invalid_source_passage}
      error -> error
    end
  end

  def select(selectors, sources) do
    with {:ok, refs} <- references(selectors),
         {:ok, table} <- validate_sources(sources, refs) do
      Enum.reduce_while(selectors, {:ok, []}, fn selector, {:ok, result} ->
        case passage(selector, table[selector["source_ref"]]) do
          {:ok, value} -> {:cont, {:ok, [value | result]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, Enum.reverse(result)}
        error -> error
      end
    end
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :authoring_limit}
  defp bounded([_ | rest], remaining), do: bounded(rest, remaining - 1)
  defp bounded(_, _), do: {:error, :invalid_source_passage}

  defp entries(selectors) do
    Enum.reduce_while(selectors, :ok, fn selector, :ok ->
      cond do
        not EnvelopeCodec.keys?(selector, ~w(length offset source_ref)) ->
          {:halt, {:error, :invalid_source_passage}}

        not EnvelopeCodec.digest?(selector["source_ref"]) or
          not is_integer(selector["offset"]) or selector["offset"] not in 0..262_144 or
          not is_integer(selector["length"]) or selector["length"] <= 0 ->
          {:halt, {:error, :invalid_source_passage}}

        selector["length"] > 4096 ->
          {:halt, {:error, :authoring_limit}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @doc false
  def validate_sources(sources, refs) do
    with :ok <- bounded(sources, 32),
         true <- Enum.all?(sources, &source_shape?/1),
         true <- Enum.reduce(sources, 0, &(&1["object"]["payload_bytes"] + 42 + &2)) <= 4_194_304,
         true <- Enum.map(sources, & &1["object"]["object_digest"]) == refs,
         true <- Enum.all?(sources, &source_bytes?/1) do
      {:ok, Map.new(sources, &{&1["object"]["object_digest"], &1})}
    else
      _ -> {:error, :invalid_authoring_source}
    end
  end

  defp source_shape?(source) do
    EnvelopeCodec.keys?(source, ~w(first_revision object payload)) and
      AuthoringObject.valid_summary?(source["object"]) and source["object"]["kind"] == "source" and
      is_integer(source["first_revision"]) and source["first_revision"] in 1..@maximum and
      is_binary(source["payload"]) and
      byte_size(source["payload"]) == source["object"]["payload_bytes"]
  end

  defp source_bytes?(source) do
    with {:ok, object} <- AuthoringObject.new("source", source["payload"]),
         {:ok, summary} <- AuthoringObject.summary(object),
         do: summary == source["object"],
         else: (_ -> false)
  end

  defp passage(selector, source) do
    offset = selector["offset"]
    size = selector["length"]

    if offset + size <= byte_size(source["payload"]) do
      text = binary_part(source["payload"], offset, size)

      if String.valid?(text) and
           not Regex.match?(~r/\p{Cc}/u, String.replace(text, ["\n", "\t"], "")) do
        {:ok,
         Map.merge(selector, %{
           "source_payload_sha256" => source["object"]["payload_sha256"],
           "first_revision" => source["first_revision"],
           "passage_sha256" => AuthoringProducer.sha(text),
           "text" => text
         })}
      else
        {:error, :invalid_source_passage}
      end
    else
      {:error, :invalid_source_passage}
    end
  end
end
