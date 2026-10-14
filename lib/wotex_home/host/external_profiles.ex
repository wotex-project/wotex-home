defmodule WotexHome.Host.ExternalProfiles do
  @moduledoc """
  Supervises transient source and report custody for an explicit live publisher.

  Host installs this subtree after Store and private profile custody, using
  `rest_for_one` ordering so source-owner loss also retires report custody.
  The source and report owners are temporary children bound to the configured
  publisher; publisher loss does not cause an automatic republish loop.

  A subtree restart creates fresh owner epochs with empty transient state.
  Retained profile history remains in Store, and startup never manufactures
  a source selection, decoded report or physical qualification.
  """

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
