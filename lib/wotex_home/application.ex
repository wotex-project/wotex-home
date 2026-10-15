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
  MQTT publisher from private authoring policy and the selected anonymous,
  sealed-file or native Keychain credential mode.
  `WotexHome.Host.MQTTConfiguration` owns that startup selection; invalid present
  policy refuses Host startup rather than falling back to inert authoring.
  No file is hot-reloaded. Dispatch still requires the
  explicit host setting and current Store qualification guards.

  `start/2` accepts a private `:native_mqtt_credential` capability in its start
  arguments for the installed native parent's composition. That parent uses
  `WotexHome.NativeSetup.CoreHost` and the nonsecret
  `WOTEX_HOME_NATIVE_MQTT_BOOTSTRAP=1` flag to exchange one source-bound pair on
  its original child pipes before application startup. The flag is not a secret
  or signing proof. Ordinary application startup does not retrieve Keychain
  custody; Keychain policy without a matching capability refuses before
  Store/socket acquisition. Native credentials enter neither application
  environment nor ordinary API request fields.
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
