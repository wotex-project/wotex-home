defmodule WotexHome.Firmware.Application do
  @moduledoc """
  Development firmware shell around the shared Home application.

  The path dependency starts Home's Store and private local API. This process
  adds no actuator, network listener, update service or automatic firmware
  validation. Board-specific services require separate qualification.

  The firmware application deliberately has an empty child list. Home's
  configured application starts through the release dependency graph; board
  probes are called explicitly by the lab rather than running on every boot.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: WotexHome.Firmware.Supervisor)
  end
end
