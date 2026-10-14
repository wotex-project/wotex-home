defmodule Mix.Tasks.Woh.Profile.Generation.Install do
  @moduledoc """
  Publishes immutable private generator policy for a later Host startup.

  Run `mix woh.profile.generation.install DATA_DIRECTORY PRIVATE_CONFIG_FILE`
  with an existing canonical private data root and a mode-0400 source. The task
  loads code paths without starting Home and publishes exact validated bytes
  without replacement. It prints only the delivery digest and aggregate counts.

  The file supplies actor-scoped source/export ceilings, without credentials,
  model endpoints or provider PIDs. A trusted host must separately select a
  checked adapter capability before any attempt can hand off model input.
  """

  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Publish immutable private generator export policy for a future Host startup"

  def run([directory, source]) do
    case WotexHome.Host.GenerationConfiguration.publish(directory, source) do
      {:ok, summary} -> Mix.shell().info(JSON.encode!(summary))
      {:error, reason} -> Mix.raise("generation installation refused: #{reason}")
    end
  end

  def run(_),
    do: Mix.raise("usage: mix woh.profile.generation.install DATA_DIRECTORY PRIVATE_CONFIG_FILE")
end
