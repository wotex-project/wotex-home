defmodule WotexHome.Host.ProfileInstallation do
  @moduledoc """
  Prepares explicit profile installation before Host acquires durable resources.

  `prepare/1` reconstructs the checked producer identity and authoring grammar
  from closed trusted configuration. Authoring-only mode creates no reader,
  capture or publisher. Full mode additionally checks matching reader limits,
  the explicit capture and a currently live publisher PID. Nil disables the
  profile installation.

  The prepared value is startup configuration, not durable policy or a live
  device discovery result. Host owns supervision and resource acquisition;
  source publication, profile approval and target selection remain separate.
  """

  alias WotexHome.Profiles.{AuthoringContract, EnvelopeCodec, ProducerIdentity, ReaderSelection}

  def prepare(nil), do: {:ok, nil}

  def prepare(%{mode: :authoring} = config) do
    with true <- keys?(config, [:authoring_limits, :installed, :mode]),
         true <- EnvelopeCodec.keys?(config.installed, ~w(bindings contracts home_contracts)),
         {:ok, producer} <- ProducerIdentity.current(),
         installed = Map.put(config.installed, "producer", producer),
         {:ok, authoring} <- AuthoringContract.export(installed, config.authoring_limits) do
      {:ok, %{reader: nil, authoring: authoring, capture: nil, publisher: nil}}
    else
      false -> invalid()
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  def prepare(config) do
    with true <-
           keys?(config, [:authoring_limits, :capture, :installed, :publisher, :reader_limits]),
         true <- is_pid(config.publisher) and Process.alive?(config.publisher),
         true <- EnvelopeCodec.keys?(config.installed, ~w(bindings contracts home_contracts)),
         true <- is_map(config.authoring_limits) and not is_struct(config.authoring_limits),
         true <- config.authoring_limits["reader"] == config.reader_limits,
         {:ok, producer} <- ProducerIdentity.current(),
         installed = Map.put(config.installed, "producer", producer),
         {:ok, reader} <- ReaderSelection.new(installed, config.capture, config.reader_limits),
         {:ok, authoring} <- AuthoringContract.export(installed, config.authoring_limits) do
      {:ok,
       %{
         reader: reader,
         authoring: authoring,
         capture: config.capture,
         publisher: config.publisher
       }}
    else
      false -> invalid()
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  defp keys?(map, keys),
    do: is_map(map) and not is_struct(map) and Enum.sort(Map.keys(map)) == keys

  defp invalid, do: {:error, :invalid_profile_installation}
end
