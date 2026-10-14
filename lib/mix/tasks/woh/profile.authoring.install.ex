defmodule Mix.Tasks.Woh.Profile.Authoring.Install do
  @moduledoc """
  Publishes private authoring policy for a future Host startup.

  Run `mix woh.profile.authoring.install DATA_DIRECTORY PRIVATE_CONFIG_FILE`
  with an existing canonical private data root and a validated immutable source
  file. The task loads code paths without starting the application, publishes
  without replacement and prints only digest/count metadata. Identical bytes
  are a safe retry; a different existing policy refuses.

  The policy takes effect at a new Host startup. It contains installed authoring
  registrations and limits, not operator credentials, captures or a publisher.
  """

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
