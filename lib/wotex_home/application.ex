defmodule WotexHome.Application do
  @moduledoc """
  Starts Home's supervisor and its explicitly configured local host.

  At application startup, the trusted `:wotex_home, :data_dir` setting takes
  precedence over `WOTEX_HOME_DATA_DIR`. If both are absent, `start/2` supervises
  no Host children, so code and pure domain tools can load without claiming a
  household database. A selected value is passed to
  `WotexHome.Host.start_link/1`, which validates the absolute private root and
  its startup configuration before acquiring the single Store.

  The application owns its top-level supervisor; the installed per-user or
  embedded host owns process lifecycle and supplies private configuration before
  startup. Changing a setting is not hot reload of a running Host.
  `WotexHome.Host` separately selects sealed profile-authoring and generator
  policy data; neither file creates a live device capture, source publisher or
  model adapter. The additional opt-in `mqtt-source-v1.json` can start one live
  MQTT publisher from private authoring policy and, when required, a separately
  sealed broker credential. `WotexHome.Host.MQTTConfiguration` owns that startup
  selection; invalid present policy refuses Host startup rather than falling
  back to inert authoring. No file is hot-reloaded. Dispatch still requires the
  explicit host setting and current Store qualification guards.
  """

  use Application

  alias WotexHome.Host

  @impl true
  def start(_type, args) do
    native = Keyword.get(args, :native_mqtt_credential)

    children =
      case Application.get_env(:wotex_home, :data_dir) ||
             System.get_env("WOTEX_HOME_DATA_DIR") do
        nil -> []
        directory -> [{Host, data_dir: directory, native_mqtt_credential: native}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: WotexHome.Supervisor)
  end
end
