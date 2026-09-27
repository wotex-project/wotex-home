defmodule Mix.Tasks.Woh.Intent.Train do
  @moduledoc """
  Trains an offline DistilBERT Light-intent candidate with Elixir.

  Run `mix woh.intent.train` after staging the pinned base checkpoint in
  `_build/intent-base`. The task uses Bumblebee, Axon and EXLA from the
  development environment. It expands the authored corpus, trains a
  three-label classifier, compares held-out results with exact grammar and a
  character n-gram baseline, then writes a hashed native Nx candidate slot.

  The output is evaluation material, not a deployed or authorized command
  path. The task refuses to overwrite an existing slot. Use `--epochs N`,
  `--base DIR`, `--corpus FILE`, and `--output DIR` to select inputs.
  """

  @shortdoc "Train an offline DistilBERT intent candidate"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {options, positionals, invalid} =
      OptionParser.parse(args,
        strict: [base: :string, corpus: :string, output: :string, epochs: :integer]
      )

    if positionals != [] or invalid != [],
      do:
        Mix.raise(
          "usage: mix woh.intent.train [--base DIR] [--corpus FILE] [--output DIR] [--epochs 1..8]"
        )

    epochs = options[:epochs] || 5

    if epochs not in 1..8,
      do: Mix.raise("epochs must be between 1 and 8")

    for app <- [:bumblebee, :exla] do
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("cannot start #{app}: #{inspect(reason)}")
      end
    end

    Code.require_file(Path.expand("../../../../dev/intent_train.exs", __DIR__))

    apply(Woh.IntentTrain, :run, [
      [
        base: options[:base] || "_build/intent-base",
        corpus: options[:corpus] || "priv/intent/corpus-v2.json",
        output: options[:output] || "_build/intent-model-candidate",
        epochs: epochs
      ]
    ])
  end
end
