defmodule WotexHome.Application do
  @moduledoc """
  Application lifecycle for the opt-in local host.

  An installed per-user process sets WOTEX_HOME_DATA_DIR to its private
  absolute data directory. An embedded release may set the trusted
  `:wotex_home, :data_dir` application configuration before applications
  start. No host starts when both settings are absent.

  This distinction lets tests and tools load pure domain modules without
  taking ownership of a household database. A packaged host must set one
  private directory before startup and keep its process under supervision.
  """

  use Application

  alias WotexHome.Host

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:wotex_home, :data_dir) ||
             System.get_env("WOTEX_HOME_DATA_DIR") do
        nil -> []
        directory -> [{Host, data_dir: directory}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: WotexHome.Supervisor)
  end
end
