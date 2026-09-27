defmodule WotexHome.Host do
  @moduledoc """
  Opt-in same-user supervisor for the durable Store and local socket.

  This is the Elixir host process skeleton. An explicitly configured LIFX
  interface starts a supervised read-only capture owner, but does not enroll
  or command a device. Installation, Keychain custody and dispatch require
  separate qualification.

  `start_link/1` takes ownership of the configured private directory,
  establishes the single Store writer and exposes the local API socket.
  Starting a second writer against the same directory must fail. The caller
  owns lifecycle and local credential bootstrap. Set the trusted
  `:lifx_capture_interface` application value or `WOTEX_HOME_LIFX_INTERFACE`
  environment value to add read-only LIFX capture on that named interface.
  The setting is absent by default; it never enables a device write path.
  """

  use Supervisor
  import Bitwise

  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.CaptureSession
  alias WotexHome.LocalAPI.Server

  @store_name WotexHome.Host.Store
  @capture_name WotexHome.Host.LifxCapture

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

    children = [
      {Store,
       path: Path.join(data_dir, "home.sqlite"),
       name: @store_name,
       qualification_case_keys: Application.get_env(:wotex_home, :qualification_case_keys, %{}),
       qualification_decision_keys:
         Application.get_env(:wotex_home, :qualification_decision_keys, %{})},
      {Server, store: @store_name, socket_path: Path.join(data_dir, "ipc/home.sock")}
    ]

    children =
      case Application.get_env(:wotex_home, :lifx_capture_interface) ||
             System.get_env("WOTEX_HOME_LIFX_INTERFACE") do
        nil ->
          children

        interface ->
          children ++ [{CaptureSession, interface_name: interface, name: @capture_name}]
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec store() :: pid() | nil
  def store, do: Process.whereis(@store_name)

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
