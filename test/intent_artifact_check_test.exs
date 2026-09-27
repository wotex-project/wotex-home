defmodule WotexHome.IntentArtifactCheckTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.IntentArtifact

  setup do
    directory = Path.join(System.tmp_dir!(), "wotex-intent-#{System.unique_integer([:positive])}")
    slot = Path.join(directory, "slot")
    File.mkdir_p!(slot)
    corpus = Path.join(directory, "corpus.json")
    File.write!(corpus, "corpus")

    for name <- IntentArtifact.files() -- ~w(config.json tokenizer_config.json evaluation.json) do
      File.write!(Path.join(slot, name), "fixture")
    end

    config = %{
      "model_type" => "distilbert",
      "architectures" => ["DistilBertForSequenceClassification"],
      "id2label" =>
        IntentArtifact.labels()
        |> Enum.with_index()
        |> Map.new(fn {label, index} -> {to_string(index), label} end),
      "label2id" => IntentArtifact.labels() |> Enum.with_index() |> Map.new()
    }

    write_json(slot, "config.json", config)

    write_json(slot, "tokenizer_config.json", %{
      "tokenizer_class" => "DistilBertTokenizer",
      "do_lower_case" => true,
      "model_max_length" => 512
    })

    write_json(slot, "evaluation.json", %{
      "schema" => "wotex-home.intent-evaluation.v1",
      "labels" => IntentArtifact.labels(),
      "corpus_sha256" => digest(corpus),
      "base_revision" => IntentArtifact.base_revision(),
      "supported_profile" => "exact-english-light-v1",
      "language" => "en",
      "max_tokens" => 48,
      "production_admitted" => false
    })

    write_manifest(slot)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{slot: slot, corpus: corpus, config: config}
  end

  test "a candidate remains unadmitted, and duplicate members fail", %{slot: slot, corpus: corpus} do
    assert {:ok, %{"production_admitted" => false}} = IntentArtifact.check(slot, corpus)
    manifest = Path.join(slot, "manifest.json")
    source = File.read!(manifest)
    File.write!(manifest, binary_part(source, 0, byte_size(source) - 1) <> ",\"files\":{}}")

    assert {:error, reason} = IntentArtifact.check(slot, corpus)
    assert String.contains?(reason, "duplicate JSON member: files")
  end

  test "a swapped label fails even after its hash is refreshed", %{
    slot: slot,
    corpus: corpus,
    config: config
  } do
    changed = put_in(config, ["id2label", "1"], "light_power_off")
    write_json(slot, "config.json", changed)
    write_manifest(slot)

    assert {:error, "model or tokenizer label contract changed"} =
             IntentArtifact.check(slot, corpus)
  end

  test "linked model weights fail", %{slot: slot, corpus: corpus} do
    path = Path.join(slot, "model.safetensors")
    File.rm!(path)
    File.ln_s!(Path.join(slot, "LICENSE.base"), path)
    write_manifest(slot)

    assert {:error, "artifact file missing or changed: model.safetensors"} =
             IntentArtifact.check(slot, corpus)
  end

  test "a native slot cannot substitute its tokenizer or base license", %{
    slot: slot,
    corpus: corpus,
    config: config
  } do
    File.rename!(Path.join(slot, "model.safetensors"), Path.join(slot, "params.nx"))
    File.rm!(Path.join(slot, "special_tokens_map.json"))
    write_json(slot, "config.json", Map.put(config, "artifact_format", "axon-nx-params-v1"))

    evaluation = slot |> Path.join("evaluation.json") |> File.read!() |> JSON.decode!()

    write_json(
      slot,
      "evaluation.json",
      Map.put(evaluation, "schema", "wotex-home.intent-evaluation.v2")
    )

    files =
      slot
      |> File.ls!()
      |> Enum.reject(&(&1 == "manifest.json"))
      |> Map.new(fn name -> {name, digest(Path.join(slot, name))} end)

    write_json(slot, "manifest.json", %{
      "schema" => "wotex-home.intent-artifact.v2",
      "files" => files
    })

    assert {:error, "model or tokenizer label contract changed"} =
             IntentArtifact.check(slot, corpus)
  end

  defp write_json(slot, name, value), do: File.write!(Path.join(slot, name), JSON.encode!(value))

  defp write_manifest(slot) do
    files = Map.new(IntentArtifact.files(), fn name -> {name, digest(Path.join(slot, name))} end)

    write_json(slot, "manifest.json", %{
      "schema" => "wotex-home.intent-artifact.v1",
      "files" => files
    })
  end

  defp digest(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
