defmodule WotexHome.Host do
  @moduledoc """
  Opt-in same-user supervisor for the durable Store and local socket.

  This is the Elixir host process skeleton. It does not install a LaunchAgent,
  provision a Keychain identity, connect a device, or enable dispatch.

  `start_link/1` takes ownership of the configured private directory,
  establishes the single Store writer and exposes the local API socket.
  Starting a second writer against the same directory must fail. The caller
  owns lifecycle and local credential bootstrap.
  """

  use Supervisor
  import Bitwise

  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Server

  @store_name WotexHome.Host.Store

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

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec store() :: pid() | nil
  def store, do: Process.whereis(@store_name)

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
