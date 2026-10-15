defmodule Mix.Tasks.Woh.Mqtt.Source.Install do
  @moduledoc """
  Publishes immutable private MQTT source configuration for the next Host startup.

  Run `mix woh.mqtt.source.install DATA_DIRECTORY PRIVATE_CONFIG_FILE` after
  provisioning authoring policy and, for password mode, the separate credential.
  Sources must be canonical mode-0400 private files. Publication never overwrites
  different bytes, starts Home or connects a broker. Output contains only the
  configuration digest and channel count, never source identity or endpoints.
  """

  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Publish sealed private MQTT source configuration"
  def run([root, source]) do
    case WotexHome.Host.MQTTConfiguration.publish(root, source) do
      {:ok, summary} -> Mix.shell().info(JSON.encode!(summary))
      {:error, reason} -> Mix.raise("MQTT source installation refused: #{reason}")
    end
  end

  def run(_),
    do: Mix.raise("usage: mix woh.mqtt.source.install DATA_DIRECTORY PRIVATE_CONFIG_FILE")
end
