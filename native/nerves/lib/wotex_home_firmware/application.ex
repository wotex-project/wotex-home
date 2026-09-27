defmodule WotexHome.Firmware.Application do
  @moduledoc """
  Development firmware shell around the shared Home application.

  The path dependency starts Home's Store and private local API. This process
  adds no actuator, network listener, update service or automatic firmware
  validation. Board-specific services require separate qualification.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: WotexHome.Firmware.Supervisor)
  end
end
