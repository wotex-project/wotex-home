defmodule WotexHome.Application do
  @moduledoc """
  Application lifecycle for the opt-in local host.

  An installed per-user process sets WOTEX_HOME_DATA_DIR to its private
  absolute data directory. No host starts when the setting is absent.
  """

  use Application

  alias WotexHome.Host

  @impl true
  def start(_type, _args) do
    children =
      case System.get_env("WOTEX_HOME_DATA_DIR") do
        nil -> []
        directory -> [{Host, data_dir: directory}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: WotexHome.Supervisor)
  end
end
