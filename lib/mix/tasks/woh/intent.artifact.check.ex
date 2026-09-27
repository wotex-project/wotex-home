defmodule Woh.Tool.IntentArtifact do
  @moduledoc false

  @files ~w(LICENSE.base config.json evaluation.json model.safetensors special_tokens_map.json tokenizer.json tokenizer_config.json vocab.txt)
  @native_files ~w(LICENSE.base config.json evaluation.json params.nx tokenizer.json tokenizer_config.json vocab.txt)
  @labels ~w(other light_power_on light_power_off)
  @base_revision "12040accade4e8a0f71eabdb258fecc2e7e948be"
  @limits %{
    "LICENSE.base" => 65_536,
    "config.json" => 65_536,
    "evaluation.json" => 1_048_576,
    "model.safetensors" => 536_870_912,
    "params.nx" => 536_870_912,
    "special_tokens_map.json" => 65_536,
    "tokenizer.json" => 8_388_608,
    "tokenizer_config.json" => 65_536,
    "vocab.txt" => 2_097_152,
    "manifest.json" => 65_536
  }

  def files, do: @files
  def labels, do: @labels
  def base_revision, do: @base_revision

  def check(slot, corpus) do
    with :ok <- directory(slot),
         {:ok, manifest} <- bounded_json(Path.join(slot, "manifest.json")),
         :ok <- manifest_contract(manifest),
         :ok <- file_set(slot, Map.keys(manifest["files"])),
         :ok <- check_files(slot, manifest["files"]),
         :ok <- corpus_file(corpus),
         {:ok, config} <- bounded_json(Path.join(slot, "config.json")),
         {:ok, tokenizer} <- bounded_json(Path.join(slot, "tokenizer_config.json")),
         :ok <- model_contract(manifest["schema"], config, tokenizer, manifest["files"]),
         {:ok, evaluation} <- bounded_json(Path.join(slot, "evaluation.json")),
         :ok <- evaluation_contract(evaluation, corpus, manifest["schema"]) do
      baseline = if is_map(evaluation["baseline"]), do: evaluation["baseline"], else: %{}

      {:ok,
       %{
         "manifest_sha256" => Woh.Tool.Hash.sha256(Path.join(slot, "manifest.json")),
         "production_admitted" => false,
         "outperforms_baselines_on_authored_set" =>
           evaluation["outperforms_baselines_on_authored_set"],
         "gate_test" => evaluation["gate_test"],
         "grammar_test" => evaluation["grammar_test"],
         "compact_baseline_gate_test" => baseline["gate_test"]
       }}
    end
  end

  defp directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _ -> {:error, "candidate slot is missing or a symlink"}
    end
  end

  defp file_set(slot, files) do
    case File.ls(slot) do
      {:ok, names} ->
        if MapSet.new(names) == MapSet.new(files ++ ["manifest.json"]),
          do: :ok,
          else: {:error, "candidate slot file set changed"}

      _ ->
        {:error, "candidate slot file set changed"}
    end
  end

  defp bounded_json(path) do
    case Woh.Tool.Json.read(path, Map.fetch!(@limits, Path.basename(path))) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp manifest_contract(manifest) do
    files = if is_map(manifest), do: manifest["files"], else: nil

    allowed_files =
      case is_map(manifest) && manifest["schema"] do
        "wotex-home.intent-artifact.v1" -> @files
        "wotex-home.intent-artifact.v2" -> @native_files
        _ -> []
      end

    valid =
      is_map(manifest) and Map.keys(manifest) |> MapSet.new() == MapSet.new(~w(schema files)) and
        allowed_files != [] and is_map(files) and
        MapSet.new(Map.keys(files)) == MapSet.new(allowed_files) and
        Enum.all?(Map.values(files), fn value ->
          is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
        end)

    if valid, do: :ok, else: {:error, "invalid artifact manifest"}
  end

  defp check_files(slot, files) do
    Enum.reduce_while(files, :ok, fn {name, expected}, _ ->
      path = Path.join(slot, name)
      limit = Map.fetch!(@limits, name)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}}
        when size > 0 and size <= limit ->
          if Woh.Tool.Hash.sha256(path) == expected,
            do: {:cont, :ok},
            else: {:halt, {:error, "artifact file missing or changed: #{name}"}}

        _ ->
          {:halt, {:error, "artifact file missing or changed: #{name}"}}
      end
    end)
  end

  defp corpus_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= 1_048_576 -> :ok
      _ -> {:error, "intent corpus is unavailable or overlong"}
    end
  end

  defp model_contract(schema, config, tokenizer, files) do
    id2label =
      @labels |> Enum.with_index() |> Map.new(fn {label, index} -> {to_string(index), label} end)

    label2id = @labels |> Enum.with_index() |> Map.new()

    common =
      is_map(config) and config["model_type"] == "distilbert" and
        config["architectures"] == ["DistilBertForSequenceClassification"] and
        config["id2label"] == id2label and config["label2id"] == label2id and
        is_map(tokenizer)

    valid =
      case schema do
        "wotex-home.intent-artifact.v1" ->
          common and tokenizer["tokenizer_class"] == "DistilBertTokenizer" and
            tokenizer["do_lower_case"] == true and tokenizer["model_max_length"] == 512

        "wotex-home.intent-artifact.v2" ->
          common and config["artifact_format"] == "axon-nx-params-v1" and
            files["LICENSE.base"] ==
              "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1" and
            files["tokenizer.json"] ==
              "ce64fce797c24f68df90b40a3f74f579b336a493db14bd583fd520ea0d8c9a98" and
            files["tokenizer_config.json"] ==
              "a025160ef0431f1a392f6f050c1310f4c5d9fb6f275932dbccba73c4d214bf10" and
            files["vocab.txt"] ==
              "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"

        _ ->
          false
      end

    if valid, do: :ok, else: {:error, "model or tokenizer label contract changed"}
  end

  defp evaluation_contract(evaluation, corpus, schema) do
    evaluation_schema =
      case schema do
        "wotex-home.intent-artifact.v1" -> "wotex-home.intent-evaluation.v1"
        "wotex-home.intent-artifact.v2" -> "wotex-home.intent-evaluation.v2"
      end

    valid =
      is_map(evaluation) and evaluation["schema"] == evaluation_schema and
        evaluation["labels"] == @labels and
        evaluation["corpus_sha256"] == Woh.Tool.Hash.sha256(corpus) and
        evaluation["base_revision"] == @base_revision and
        evaluation["supported_profile"] == "exact-english-light-v1" and
        evaluation["language"] == "en" and evaluation["max_tokens"] == 48 and
        evaluation["production_admitted"] == false

    if valid, do: :ok, else: {:error, "candidate evaluation metadata changed"}
  end
end

defmodule Mix.Tasks.Woh.Intent.Artifact.Check do
  @moduledoc """
  Checks a local intent candidate slot before it is considered for release.

  Run `mix woh.intent.artifact.check SLOT` with the authored corpus at its
  default path, or pass `--corpus FILE`. The task checks bounded files,
  symlinks, duplicate JSON members, hashes and the DistilBERT label contract.
  It accepts the historical Safetensors candidate and the Elixir trainer's
  native Nx parameter slot. Its report keeps the candidate's evaluation
  disposition; a passing check alone does not authenticate the slot, parse
  model weights or admit it to production.
  """

  @shortdoc "Check an intent candidate artifact"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {options, positionals, invalid} = OptionParser.parse(args, strict: [corpus: :string])

    case {positionals, invalid} do
      {[slot], []} ->
        corpus = options[:corpus] || "priv/intent/corpus-v2.json"

        case Woh.Tool.IntentArtifact.check(slot, corpus) do
          {:ok, report} -> Mix.shell().info(JSON.encode!(report))
          {:error, reason} -> Mix.raise("intent artifact error: #{reason}")
        end

      _ ->
        Mix.raise("usage: mix woh.intent.artifact.check SLOT [--corpus FILE]")
    end
  end
end
