defmodule Mix.Tasks.Woh.Profile.Authoring.Install do
  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Publish immutable private authoring configuration for a future Host startup"

  def run([directory, source]) do
    case WotexHome.Host.ProfileConfiguration.publish(directory, source) do
      {:ok, summary} -> Mix.shell().info(JSON.encode!(summary))
      {:error, reason} -> Mix.raise("profile authoring installation refused: #{reason}")
    end
  end

  def run(_),
    do: Mix.raise("usage: mix woh.profile.authoring.install DATA_DIRECTORY PRIVATE_CONFIG_FILE")
end
