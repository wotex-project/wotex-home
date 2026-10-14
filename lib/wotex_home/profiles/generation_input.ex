defmodule WotexHome.Profiles.GenerationInput do
  @moduledoc """
  Exact bounded contract, source-passage and example input for a future generator.

  This pure private value provides no export permission or provider handoff.
  Actor ownership, current policy and durable originals remain Store decisions.
  """

  alias WotexHome.Id
  alias WotexHome.Profiles.{AuthoringContract, AuthoringObject, AuthoringProducer, EnvelopeCodec}

  @ceilings %{
    "max_passages" => 32,
    "max_passage_bytes" => 4096,
    "max_passages_bytes" => 131_072,
    "max_examples" => 32,
    "max_examples_bytes" => 262_144,
    "max_input_bytes" => 1_048_576
  }
  @maximum 9_223_372_036_854_775_807
  @format "wotex-home.profile-generation-input@1"
  @enforce_keys [:document, :sha256, :summary]
  @derive {Inspect, only: [:summary]}
  defstruct @enforce_keys

  @doc "Prepares an inert projection from exactly the explicitly selected native objects."
  def prepare(contract, request, objects) do
    with :ok <- validate_request(request),
         :ok <- bounded(objects, 64),
         {:ok, selected} <- objects(objects, request["passages"], request["examples"]),
         {:ok, current} <- AuthoringContract.to_map(contract),
         :ok <- same_contract(current, request["contract_digest"]),
         {:ok, passages, passage_bytes} <-
           passages(request["passages"], selected, request["limits"]),
         {:ok, examples, example_bytes} <-
           examples(request["examples"], selected, request["limits"]),
         input = %{
           "format" => @format,
           "contract" => %{
             "sha256" => current["contract_sha256"],
             "document" => contract.bytes
           },
           "instruction" => request["instruction"],
           "passages" => passages,
           "examples" => examples
         },
         {:ok, document} <- encode(input, request["limits"]["max_input_bytes"]),
         :ok <- encoded_size(document, request["limits"]["max_input_bytes"]) do
      digest = AuthoringProducer.sha(@format <> "\n" <> document)

      summary = %{
        "format" => "wotex-home.profile-generation-input-summary@1",
        "input_sha256" => digest,
        "input_bytes" => byte_size(document),
        "contract_sha256" => current["contract_sha256"],
        "passages" => length(passages),
        "passage_bytes" => passage_bytes,
        "examples" => length(examples),
        "example_bytes" => example_bytes
      }

      {:ok, %__MODULE__{document: document, sha256: digest, summary: summary}}
    end
  end

  @doc "Checks the bounded structural selection grammar without ownership or byte access."
  def validate_request(request) do
    with :ok <- request_shape(request),
         :ok <- limits(request["limits"]),
         :ok <- bounded(request["passages"], request["limits"]["max_passages"]),
         :ok <- bounded(request["examples"], request["limits"]["max_examples"]),
         do: selectors(request["passages"], request["examples"], request["limits"])
  end

  defp request_shape(r) do
    if EnvelopeCodec.keys?(r, ~w(contract_digest examples instruction limits passages)) and
         EnvelopeCodec.digest?(r["contract_digest"]) and text?(r["instruction"], 4096),
       do: :ok,
       else: invalid()
  end

  defp limits(limits) do
    cond do
      not EnvelopeCodec.keys?(limits, Enum.sort(Map.keys(@ceilings))) ->
        invalid()

      not Enum.all?(@ceilings, fn {k, _} -> is_integer(limits[k]) and limits[k] > 0 end) ->
        invalid()

      not Enum.all?(@ceilings, fn {k, max} -> limits[k] <= max end) ->
        limit()

      true ->
        :ok
    end
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: limit()
  defp bounded([_ | rest], n), do: bounded(rest, n - 1)
  defp bounded(_, _), do: invalid()

  defp handle?(h),
    do:
      EnvelopeCodec.keys?(h, ~w(first_revision object_digest)) and
        EnvelopeCodec.digest?(h["object_digest"]) and is_integer(h["first_revision"]) and
        h["first_revision"] in 1..@maximum

  defp selectors(passages, examples, limits) do
    valid =
      Enum.all?(passages, fn p ->
        EnvelopeCodec.keys?(p, ~w(length offset reference)) and handle?(p["reference"]) and
          is_integer(p["offset"]) and p["offset"] in 0..262_144 and
          is_integer(p["length"]) and p["length"] in 1..4096
      end) and Enum.all?(examples, &handle?/1)

    if valid do
      keys = Enum.map(passages, &{&1["reference"]["object_digest"], &1["offset"], &1["length"]})
      example_keys = Enum.map(examples, & &1["object_digest"])
      refs = Enum.map(passages, & &1["reference"]) ++ examples

      cond do
        keys != Enum.sort(Enum.uniq(keys)) or
            example_keys != Enum.sort(Enum.uniq(example_keys)) ->
          invalid()

        Enum.any?(Enum.group_by(refs, & &1["object_digest"]), fn {_, values} ->
          length(Enum.uniq(values)) != 1
        end) ->
          stale()

        Enum.any?(passages, &(&1["length"] > limits["max_passage_bytes"])) or
            Enum.sum(Enum.map(passages, & &1["length"])) > limits["max_passages_bytes"] ->
          limit()

        true ->
          :ok
      end
    else
      invalid()
    end
  end

  defp objects(objects, passages, examples) do
    if Enum.all?(objects, fn row ->
         EnvelopeCodec.keys?(row, [:object, :reference]) and handle?(row.reference)
       end) do
      refs = Enum.map(objects, & &1.reference)
      keys = Enum.map(refs, & &1["object_digest"])

      expected =
        (Enum.map(passages, & &1["reference"]) ++ examples)
        |> Enum.uniq()
        |> Enum.sort_by(& &1["object_digest"])

      cond do
        keys != Enum.sort(Enum.uniq(keys)) ->
          invalid()

        refs != expected ->
          stale()

        true ->
          check_objects(objects)
      end
    else
      invalid()
    end
  end

  defp check_objects(objects) do
    Enum.reduce_while(objects, {:ok, %{}}, fn row, {:ok, selected} ->
      with {:ok, summary} <- AuthoringObject.summary(row.object),
           true <- summary["object_digest"] == row.reference["object_digest"] do
        {:cont, {:ok, Map.put(selected, summary["object_digest"], row.object)}}
      else
        _ -> {:halt, stale()}
      end
    end)
  end

  defp same_contract(%{"contract_sha256" => digest}, digest), do: :ok
  defp same_contract(_, _), do: {:error, :stale_authoring_basis}

  defp passages(passages, selected, _limits) do
    Enum.reduce_while(passages, {:ok, [], 0}, fn p, {:ok, rows, total} ->
      object = selected[p["reference"]["object_digest"]]

      cond do
        object.kind != "source" ->
          {:halt, stale()}

        p["offset"] + p["length"] > byte_size(object.payload) ->
          {:halt, invalid()}

        true ->
          text = binary_part(object.payload, p["offset"], p["length"])

          if text?(text, 4096) do
            row = p |> Map.put("payload_sha256", object.payload_sha256) |> Map.put("text", text)
            {:cont, {:ok, [row | rows], total + byte_size(text)}}
          else
            {:halt, invalid()}
          end
      end
    end)
    |> ordered()
  end

  defp examples(examples, selected, limits) do
    Enum.reduce_while(examples, {:ok, [], 0}, fn ref, {:ok, rows, total} ->
      object = selected[ref["object_digest"]]

      cond do
        object.kind != "fixture" ->
          {:halt, stale()}

        total + byte_size(object.payload) > limits["max_examples_bytes"] ->
          {:halt, limit()}

        true ->
          case example(object.payload) do
            :ok ->
              row = %{
                "reference" => ref,
                "payload_sha256" => object.payload_sha256,
                "document" => object.payload
              }

              {:cont, {:ok, [row | rows], total + byte_size(object.payload)}}

            error ->
              {:halt, error}
          end
      end
    end)
    |> ordered()
  end

  defp ordered({:ok, rows, bytes}), do: {:ok, Enum.reverse(rows), bytes}
  defp ordered(error), do: error

  defp example(bytes) do
    with {:ok, decoded} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [bytes, json_limits(65_536, 4096)],
             :invalid_generation_input
           ),
         true <- EnvelopeCodec.keys?(decoded, ~w(expected id report selector)),
         true <- Id.valid?(decoded["id"]) do
      :ok
    else
      false -> invalid()
      error -> error
    end
  end

  defp encode(value, max),
    do:
      AuthoringProducer.call(
        Wotex.JSON,
        :encode,
        [value, json_limits(max, 262_144)],
        :invalid_generation_input
      )

  defp json_limits(max, string_bytes),
    do: [
      max_bytes: max,
      max_depth: 8,
      max_nodes: 4096,
      max_collection_size: 256,
      max_string_bytes: string_bytes
    ]

  defp encoded_size(bytes, max) when byte_size(bytes) <= max, do: :ok
  defp encoded_size(_, _), do: limit()

  defp text?(text, maximum),
    do:
      is_binary(text) and byte_size(text) <= maximum and String.valid?(text) and
        not Regex.match?(~r/\p{Cc}/u, String.replace(text, ["\n", "\t"], ""))

  defp invalid, do: {:error, :invalid_generation_input}
  defp stale, do: {:error, :stale_generation_reference}
  defp limit, do: {:error, :authoring_limit}
end
