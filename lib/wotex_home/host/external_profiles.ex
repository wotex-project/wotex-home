defmodule WotexHome.Host.ExternalProfiles do
  @moduledoc "A replaceable Host subtree retaining temporary publisher-bound profile custody owners."
  use Supervisor
  alias WotexHome.Profiles.{ExternalReportOwner, ExternalSourceOwner}

  def start_link(publisher), do: Supervisor.start_link(__MODULE__, publisher)

  @impl true
  def init(publisher) do
    Supervisor.init(
      [
        {ExternalSourceOwner, publisher: publisher, name: WotexHome.Host.ExternalSources},
        %{
          id: ExternalReportOwner,
          start: {WotexHome.Host, :start_external_reports, [publisher]},
          restart: :temporary
        }
      ],
      strategy: :rest_for_one
    )
  end
end
