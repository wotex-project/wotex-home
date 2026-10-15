defmodule Mix.Tasks.Woh.Mqtt.Credential.Install do
  @moduledoc """
  Publishes one sealed private MQTT credential without starting Home or a broker.

  Run `mix woh.mqtt.credential.install DATA_DIRECTORY PRIVATE_CREDENTIAL_FILE`
  with an existing canonical private root and mode-0400 source document. The
  bounded closed file supplies username and canonical base64 password bytes.
  Publication is exclusive; identical retries succeed and different existing
  bytes refuse. Success prints only installed=true, never a credential digest.
  """

  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Publish a sealed private MQTT credential"
  def run([root, source]) do
    case WotexHome.MQTT.Credential.publish(root, source) do
      {:ok, summary} -> Mix.shell().info(JSON.encode!(summary))
      {:error, reason} -> Mix.raise("MQTT credential installation refused: #{reason}")
    end
  end

  def run(_),
    do: Mix.raise("usage: mix woh.mqtt.credential.install DATA_DIRECTORY PRIVATE_CREDENTIAL_FILE")
end
