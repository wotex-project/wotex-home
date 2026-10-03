defmodule WotexHome.Host do
  @moduledoc """
  Opt-in same-user supervisor for the durable Store and local socket.

  This is the Elixir host process skeleton. An explicitly configured LIFX
  interface starts a supervised read-only network capture owner. A current
  reviewer may consume its evidence through packaged enrollment, but capture
  alone never enrolls or commands a device. The supervised direct-power worker remains disabled
  unless trusted configuration sets `:lifx_power_dispatch_enabled`; Store
  qualification and current guards still gate every execution. Installation,
  Keychain custody and physical evidence remain separate qualification work.

  `start_link/1` takes ownership of the configured private directory,
  establishes the single Store writer and exposes the local API socket.
  Starting a second writer against the same directory must fail. The caller
  owns lifecycle and local credential bootstrap. Set the trusted
  `:lifx_capture_interface` application value or `WOTEX_HOME_LIFX_INTERFACE`
  environment value to add read-only LIFX capture on that named interface.
  The setting is absent by default; it never enables a device write path.
  Trusted `:component_preview` options can add an import-free native preview
  runner as the last child. It starts no device session and commits no facts;
  its failure never restarts earlier Store or driver children.
  """

  use Supervisor
  import Bitwise

  alias WotexHome.Authority
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.CaptureSession
  alias WotexHome.LocalAPI.Server

  @store_name WotexHome.Host.Store
  @capture_name WotexHome.Host.LifxCapture
  @review_gate_name WotexHome.Host.ReviewGate
  @power_supervisor_name WotexHome.Host.LifxPowerSupervisor
  @component_runner_name WotexHome.Host.ComponentRunner

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    data_dir = Keyword.get(opts, :data_dir)

    with true <- is_binary(data_dir) and Path.type(data_dir) == :absolute,
         :ok <- private_data_directory(data_dir) do
      Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    else
      _ -> {:error, :invalid_host_directory}
    end
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)

    authority = authority()

    children = [
      {Store,
       path: Path.join(data_dir, "home.sqlite"),
       name: @store_name,
       qualification_case_keys: Application.get_env(:wotex_home, :qualification_case_keys, %{}),
       qualification_decision_keys:
         Application.get_env(:wotex_home, :qualification_decision_keys, %{})},
      {ReviewGate, name: @review_gate_name},
      {Task.Supervisor, name: @power_supervisor_name},
      {Server, authority: authority, socket_path: Path.join(data_dir, "ipc/home.sock")}
    ]

    children =
      case Application.get_env(:wotex_home, :lifx_capture_interface) ||
             System.get_env("WOTEX_HOME_LIFX_INTERFACE") do
        nil ->
          children

        interface ->
          children ++ [{CaptureSession, interface_name: interface, name: @capture_name}]
      end

    children =
      case Application.get_env(:wotex_home, :component_preview) do
        nil ->
          children

        opts ->
          children ++
            [{WotexHome.Plugins.Runner, Keyword.put(opts, :name, @component_runner_name)}]
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec store() :: pid() | nil
  def store, do: Process.whereis(@store_name)

  @doc "Returns the transport-independent application boundary for this host."
  @spec authority() :: Authority.t()
  def authority do
    Authority.new(
      store: @store_name,
      capture: @capture_name,
      review_gate: @review_gate_name,
      power_supervisor: @power_supervisor_name,
      power_dispatch: Application.get_env(:wotex_home, :lifx_power_dispatch_enabled, false),
      component_runner: @component_runner_name
    )
  end

  @doc "Returns the opt-in read-only LIFX capture owner, if one is running."
  @spec lifx_capture() :: pid() | nil
  def lifx_capture, do: Process.whereis(@capture_name)

  defp private_data_directory(directory) do
    case File.lstat(directory) do
      {:error, :enoent} ->
        case File.mkdir(directory) do
          :ok ->
            case File.chmod(directory, 0o700) do
              :ok ->
                :ok

              _ ->
                _ = File.rmdir(directory)
                {:error, :invalid_host_directory}
            end

          _ ->
            {:error, :invalid_host_directory}
        end

      {:ok, stat} ->
        if stat.type == :directory and (stat.mode &&& 0o777) == 0o700,
          do: :ok,
          else: {:error, :invalid_host_directory}

      _ ->
        {:error, :invalid_host_directory}
    end
  end
end
