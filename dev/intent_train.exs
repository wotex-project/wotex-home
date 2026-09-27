defmodule Woh.IntentTrain do
  @moduledoc false

  @revision "12040accade4e8a0f71eabdb258fecc2e7e948be"
  @base_hashes %{
    "LICENSE" => "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1",
    "config.json" => "69c94b0222d5d1f4b0ad027ca7416cdafb98378cbbb8305d0bf47c9365c60c83",
    "model.safetensors" => "5e3f1108e3cb34ee048634875d8482665b65ac713291a7e32396fb18f6ff0063",
    "tokenizer.json" => "ce64fce797c24f68df90b40a3f74f579b336a493db14bd583fd520ea0d8c9a98",
    "tokenizer_config.json" => "a025160ef0431f1a392f6f050c1310f4c5d9fb6f275932dbccba73c4d214bf10",
    "vocab.txt" => "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"
  }
  @labels ~w(other light_power_on light_power_off)
  @max_tokens 48
  @seed 44

  def run(opts) do
    base = Keyword.fetch!(opts, :base)
    corpus_path = Keyword.fetch!(opts, :corpus)
    output = Keyword.fetch!(opts, :output)
    epochs = Keyword.fetch!(opts, :epochs)
    temporary = output <> ".tmp"

    if File.exists?(output) or File.exists?(temporary),
      do: Mix.raise("intent candidate output or temporary slot already exists")

    verify_base!(base)
    examples = load_corpus!(corpus_path)
    :rand.seed(:exsss, {@seed, @seed, @seed})
    Nx.default_backend({EXLA.Backend, client: :host})

    repository = {:local, base}
    {:ok, spec} = Bumblebee.load_spec(repository, architecture: :for_sequence_classification)
    spec = Bumblebee.configure(spec, num_labels: length(@labels))
    {:ok, %{model: model, params: params}} = Bumblebee.load_model(repository, spec: spec)
    params = initialize_head(model, spec, params)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(repository)
    tokenizer = Bumblebee.configure(tokenizer, length: @max_tokens)
    logits_model = Axon.nx(model, & &1.logits)
    batches = Map.new(examples, fn {split, rows} -> {split, batch(rows, tokenizer)} end)
    baseline = fit_baseline(examples.train)
    baseline_val = baseline_predictions(baseline, examples.validation)
    baseline_test = baseline_predictions(baseline, examples.test)

    loss =
      &Axon.Losses.categorical_cross_entropy(&1, &2,
        reduction: :mean,
        from_logits: true,
        sparse: true
      )

    optimizer = Polaris.Optimizers.adam(learning_rate: 3.0e-5)
    loop = Axon.Loop.trainer(logits_model, loss, optimizer, log: 0, seed: @seed)

    {best, _best_score, history} =
      Enum.reduce(1..epochs, {nil, -1, []}, fn epoch, {current, best_score, history} ->
        start_params = if current, do: current, else: params

        trained =
          Axon.Loop.run(loop, Enum.shuffle(batches.train), start_params,
            epochs: 1,
            compiler: EXLA,
            strict?: false
          )

        trained_params = trained
        val_scores = predict(logits_model, trained_params, batches.validation)
        {threshold, margin} = calibrate_gate(val_scores, examples.validation)
        gate = gate_metrics(val_scores, examples.validation, threshold, margin)
        score = gate["correct_allowed_accepted"] - 100 * gate["false_accepted"]
        entry = %{"epoch" => epoch, "gate_validation" => gate}
        Mix.shell().info(JSON.encode!(entry))

        if score > best_score,
          do: {trained_params, score, history ++ [entry]},
          else: {current, best_score, history ++ [entry]}
      end)

    val_scores = predict(logits_model, best, batches.validation)
    test_scores = predict(logits_model, best, batches.test)
    {gate_threshold, gate_margin} = calibrate_gate(val_scores, examples.validation)
    {baseline_threshold, baseline_margin} = calibrate_gate(baseline_val, examples.validation)
    thresholds = calibrate(val_scores, examples.validation)
    baseline_thresholds = calibrate(baseline_val, examples.validation)
    gate_val = gate_metrics(val_scores, examples.validation, gate_threshold, gate_margin)
    gate_test = gate_metrics(test_scores, examples.test, gate_threshold, gate_margin)
    grammar_val = grammar_metrics(examples.validation)
    grammar_test = grammar_metrics(examples.test)

    baseline_gate_test =
      gate_metrics(baseline_test, examples.test, baseline_threshold, baseline_margin)

    evaluation = %{
      "schema" => "wotex-home.intent-evaluation.v2",
      "base_repository" => "distilbert/distilbert-base-uncased",
      "base_revision" => @revision,
      "base_license" => "Apache-2.0",
      "corpus_sha256" => Woh.Tool.Hash.sha256(corpus_path),
      "language" => "en",
      "supported_profile" => "exact-english-light-v1",
      "gate" => "model_top_agrees_with_exact_grammar_and_authorized_alias",
      "labels" => @labels,
      "libraries" =>
        Map.new([:bumblebee, :axon, :nx, :exla], fn app ->
          {to_string(app), app |> Application.spec(:vsn) |> to_string()}
        end),
      "seed" => @seed,
      "epochs_requested" => epochs,
      "max_tokens" => @max_tokens,
      "split_sizes" =>
        Map.new(examples, fn {split, rows} -> {to_string(split), length(rows)} end),
      "thresholds" => thresholds,
      "margin" => 0.15,
      "gate_threshold" => gate_threshold,
      "gate_margin" => gate_margin,
      "gate_validation" => gate_val,
      "gate_test" => gate_test,
      "grammar_validation" => grammar_val,
      "grammar_test" => grammar_test,
      "validation" => metrics(val_scores, examples.validation, thresholds),
      "test" => metrics(test_scores, examples.test, thresholds),
      "baseline" => %{
        "kind" => "smoothed-character-ngram-naive-bayes",
        "thresholds" => baseline_thresholds,
        "validation" => metrics(baseline_val, examples.validation, baseline_thresholds),
        "test" => metrics(baseline_test, examples.test, baseline_thresholds),
        "gate_threshold" => baseline_threshold,
        "gate_margin" => baseline_margin,
        "gate_test" => baseline_gate_test
      },
      "training_history" => history,
      "outperforms_baselines_on_authored_set" =>
        gate_val["false_accepted"] == 0 and gate_test["false_accepted"] == 0 and
          gate_test["correct_allowed_accepted"] >=
            max(
              grammar_test["correct_allowed_accepted"],
              baseline_gate_test["correct_allowed_accepted"]
            ),
      "production_admitted" => false
    }

    File.mkdir_p!(temporary)

    try do
      write_artifact!(temporary, base, best, evaluation)
      File.rename!(temporary, output)
    after
      if File.exists?(temporary), do: File.rm_rf!(temporary)
    end

    Mix.shell().info(
      JSON.encode!(%{
        "output" => output,
        "gate_test" => gate_test,
        "grammar_test" => grammar_test,
        "baseline_gate_test" => baseline_gate_test,
        "outperforms_baselines_on_authored_set" =>
          evaluation["outperforms_baselines_on_authored_set"]
      })
    )

    :ok
  end

  defp verify_base!(base) do
    Enum.each(@base_hashes, fn {name, expected} ->
      path = Path.join(base, name)

      unless File.regular?(path) and Woh.Tool.Hash.sha256(path) == expected,
        do: Mix.raise("pinned base file missing or changed: #{name}")
    end)
  end

  defp initialize_head(model, spec, params) do
    # Bumblebee initializes absent classification weights and dropout keys
    # with a clock-based Axon seed. Reinitialize them with the recorded seed.
    missing =
      params.data
      |> Map.keys()
      |> Enum.filter(fn key ->
        key in ["pooler.output", "sequence_classification_head.output"] or
          String.contains?(key, "dropout")
      end)

    partial = %{params | data: Map.drop(params.data, missing)}
    template = apply(spec.__struct__, :input_template, [spec])
    {initialize, _predict} = Axon.build(model, seed: @seed, compiler: EXLA)
    initialize.(template, partial)
  end

  defp load_corpus!(path) do
    {:ok, corpus} = Woh.Tool.Json.read(path, 1_048_576)

    unless corpus["schema"] == "wotex-home.intent-corpus.v1" and corpus["language"] == "en" and
             corpus["labels"] == @labels and
             MapSet.new(Map.keys(corpus["splits"])) == MapSet.new(~w(train validation test)),
           do: Mix.raise("invalid intent corpus")

    {examples, _, _, _} =
      Enum.reduce(
        ~w(train validation test),
        {%{}, MapSet.new(), MapSet.new(), MapSet.new()},
        fn split, {all, used_targets, used_templates, used_texts} ->
          source = corpus["splits"][split]

          unless is_map(source) and
                   MapSet.new(Map.keys(source)) == MapSet.new(["targets" | @labels]),
                 do: Mix.raise("invalid intent corpus split: #{split}")

          targets = source["targets"]

          unless is_list(targets) and targets != [] and Enum.all?(targets, &is_binary/1) and
                   length(targets) == length(Enum.uniq(targets)) and
                   MapSet.disjoint?(MapSet.new(targets), used_targets),
                 do: Mix.raise("target aliases leak across splits")

          {rows, used_templates, used_texts} =
            Enum.reduce(@labels, {[], used_templates, used_texts}, fn label,
                                                                      {rows, templates_seen,
                                                                       texts_seen} ->
              templates = source[label]

              unless is_list(templates) and templates != [] and
                       length(templates) == length(Enum.uniq(templates)),
                     do: Mix.raise("empty or duplicate template family")

              Enum.reduce(templates, {rows, templates_seen, texts_seen}, fn template,
                                                                            {rows, templates_seen,
                                                                             texts_seen} ->
                unless is_binary(template) and byte_size(template) <= 256 and
                         not MapSet.member?(templates_seen, template),
                       do: Mix.raise("template family leaks across splits")

                count = length(String.split(template, "{target}")) - 1

                unless count == 1 or (label == "other" and count == 0),
                  do: Mix.raise("invalid target placeholder")

                rendered =
                  if count == 1,
                    do: Enum.map(targets, &String.replace(template, "{target}", &1)),
                    else: [template]

                Enum.reduce(
                  rendered,
                  {rows, MapSet.put(templates_seen, template), texts_seen},
                  fn text, {rows, seen_templates, seen_texts} ->
                    unless text != "" and byte_size(text) <= 256 and
                             not MapSet.member?(seen_texts, text),
                           do: Mix.raise("duplicate or overlong intent example")

                    {[
                       {text, Enum.find_index(@labels, &(&1 == label)), MapSet.new(targets)}
                       | rows
                     ], seen_templates, MapSet.put(seen_texts, text)}
                  end
                )
              end)
            end)

          rows = Enum.reverse(rows)

          unless Enum.all?(rows, fn {text, label, aliases} ->
                   grammar_intent(text, aliases) == label
                 end),
                 do: Mix.raise("corpus label disagrees with grammar: #{split}")

          {Map.put(all, String.to_atom(split), rows),
           MapSet.union(used_targets, MapSet.new(targets)), used_templates, used_texts}
        end
      )

    examples
  end

  defp batch(rows, tokenizer) do
    rows
    |> Enum.chunk_every(16)
    |> Enum.map(fn chunk ->
      texts = Enum.map(chunk, &elem(&1, 0))
      labels = Enum.map(chunk, &elem(&1, 1))
      {Bumblebee.apply_tokenizer(tokenizer, texts), Nx.tensor(labels, type: {:s, 64})}
    end)
  end

  defp predict(model, params, batches) do
    Enum.flat_map(batches, fn {inputs, _labels} ->
      model
      |> Axon.predict(params, inputs, compiler: EXLA)
      |> Axon.Activations.softmax(axis: -1)
      |> Nx.to_list()
    end)
  end

  defp grammar_intent(text, targets) do
    case WotexHome.Intent.Grammar.classify(text) do
      {:ok, %{intent: intent, target_phrase: target}} ->
        if MapSet.member?(targets, target),
          do: Enum.find_index(@labels, &(&1 == Atom.to_string(intent))),
          else: 0

      _ ->
        0
    end
  end

  defp grammar_metrics(rows) do
    scores = Enum.map(rows, fn {text, _, aliases} -> one_hot(grammar_intent(text, aliases)) end)
    gate_metrics(scores, rows, 0.3, 0.0)
  end

  defp one_hot(index), do: for(i <- 0..2, do: if(i == index, do: 1.0, else: 0.0))

  defp fit_baseline(rows) do
    vocabulary = rows |> Enum.flat_map(fn {text, _, _} -> features(text) end) |> MapSet.new()

    counts =
      Enum.map(0..2, fn label ->
        rows
        |> Enum.filter(fn {_, truth, _} -> truth == label end)
        |> Enum.flat_map(fn {text, _, _} -> features(text) end)
        |> Enum.frequencies()
      end)

    {counts, Enum.map(counts, &Enum.sum(Map.values(&1))), MapSet.size(vocabulary),
     Enum.frequencies_by(rows, fn {_, label, _} -> label end)}
  end

  defp features(text) do
    chars = String.graphemes(" " <> String.downcase(text) <> " ")

    for length <- 3..5,
        index <- 0..max(Kernel.length(chars) - length, -1),
        Kernel.length(chars) >= length,
        do: chars |> Enum.slice(index, length) |> Enum.join()
  end

  defp baseline_predictions({counts, totals, vocabulary_size, priors}, rows) do
    Enum.map(rows, fn {text, _, _} ->
      frequencies = Enum.frequencies(features(text))

      logits =
        for label <- 0..2 do
          prior = :math.log((Map.get(priors, label, 0) + 1) / (Enum.sum(Map.values(priors)) + 3))
          denominator = Enum.at(totals, label) + vocabulary_size

          Enum.reduce(frequencies, prior, fn {feature, count}, score ->
            score +
              count * :math.log((Map.get(Enum.at(counts, label), feature, 0) + 1) / denominator)
          end)
        end

      peak = Enum.max(logits)
      weights = Enum.map(logits, &:math.exp(&1 - peak))
      total = Enum.sum(weights)
      Enum.map(weights, &(&1 / total))
    end)
  end

  defp calibrate(scores, rows) do
    Enum.reduce(1..2, %{}, fn label, result ->
      incorrect =
        scores
        |> Enum.zip(rows)
        |> Enum.filter(fn {probabilities, {_, truth, _}} ->
          top(probabilities) == label and truth != label
        end)
        |> Enum.map(fn {probabilities, _} -> Enum.at(probabilities, label) end)

      Map.put(
        result,
        Enum.at(@labels, label),
        min(1.0, max(0.5, Enum.max(incorrect, fn -> 0.0 end) + 0.001))
      )
    end)
  end

  defp calibrate_gate(scores, rows) do
    candidates =
      for threshold <- [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9],
          margin <- [0.0, 0.05, 0.1, 0.15, 0.2],
          result = gate_metrics(scores, rows, threshold, margin),
          result["false_accepted"] == 0,
          do: {result["correct_allowed_accepted"], threshold, margin}

    candidates
    |> Enum.max(fn -> Mix.raise("no zero-false calibration on validation set") end)
    |> then(fn {_, threshold, margin} -> {threshold, margin} end)
  end

  defp gate_metrics(scores, rows, threshold, margin) do
    decisions =
      scores
      |> Enum.zip(rows)
      |> Enum.map(fn {probabilities, {text, _, targets}} ->
        top = top(probabilities)
        grammar = grammar_intent(text, targets)
        [runner_up, highest] = probabilities |> Enum.sort() |> Enum.take(-2)

        if top != 0 and top == grammar and highest >= threshold and highest - runner_up >= margin,
          do: top,
          else: 0
      end)

    basic_metrics(decisions, rows)
  end

  defp metrics(scores, rows, thresholds) do
    raw = Enum.map(scores, &top/1)

    decisions =
      scores
      |> Enum.zip(raw)
      |> Enum.map(fn {probabilities, label} ->
        [runner_up, highest] = probabilities |> Enum.sort() |> Enum.take(-2)

        if label == 0 or highest - runner_up < 0.15 or
             highest < Map.fetch!(thresholds, Enum.at(@labels, label)),
           do: 0,
           else: label
      end)

    basic_metrics(decisions, rows)
    |> Map.put(
      "raw_confusion",
      for(
        truth <- 0..2,
        do:
          for(
            pred <- 0..2,
            do: Enum.count(Enum.zip(raw, rows), fn {p, {_, t, _}} -> p == pred and t == truth end)
          )
      )
    )
  end

  defp basic_metrics(decisions, rows) do
    truth = Enum.map(rows, fn {_, label, _} -> label end)
    positives = Enum.count(truth, &(&1 != 0))

    %{
      "examples" => length(rows),
      "allowed_examples" => positives,
      "other_examples" => length(rows) - positives,
      "correct_allowed_accepted" =>
        Enum.count(Enum.zip(decisions, truth), fn {p, t} -> p == t and t != 0 end),
      "false_accepted" =>
        Enum.count(Enum.zip(decisions, truth), fn {p, t} -> p != 0 and p != t end),
      "abstained" => Enum.count(decisions, &(&1 == 0)),
      "allowed_recall" =>
        if(positives == 0,
          do: 0.0,
          else:
            Float.round(
              Enum.count(Enum.zip(decisions, truth), fn {p, t} -> p == t and t != 0 end) /
                positives,
              4
            )
        )
    }
  end

  defp top(probabilities),
    do: probabilities |> Enum.with_index() |> Enum.max_by(&elem(&1, 0)) |> elem(1)

  defp write_artifact!(directory, base, params, evaluation) do
    config =
      base
      |> Path.join("config.json")
      |> File.read!()
      |> JSON.decode!()
      |> Map.merge(%{
        "architectures" => ["DistilBertForSequenceClassification"],
        "id2label" =>
          Map.new(Enum.with_index(@labels), fn {label, index} -> {to_string(index), label} end),
        "label2id" => Map.new(Enum.with_index(@labels)),
        "artifact_format" => "axon-nx-params-v1"
      })

    File.write!(Path.join(directory, "config.json"), JSON.encode!(config) <> "\n")
    File.write!(Path.join(directory, "evaluation.json"), JSON.encode!(evaluation) <> "\n")
    File.write!(Path.join(directory, "params.nx"), Nx.serialize(params.data))

    for {source, destination} <- [
          {"LICENSE", "LICENSE.base"},
          {"tokenizer.json", "tokenizer.json"},
          {"tokenizer_config.json", "tokenizer_config.json"},
          {"vocab.txt", "vocab.txt"}
        ] do
      File.cp!(Path.join(base, source), Path.join(directory, destination))
    end

    files =
      directory
      |> File.ls!()
      |> Map.new(fn name -> {name, Woh.Tool.Hash.sha256(Path.join(directory, name))} end)

    File.write!(
      Path.join(directory, "manifest.json"),
      JSON.encode!(%{"schema" => "wotex-home.intent-artifact.v2", "files" => files}) <> "\n"
    )
  end
end
