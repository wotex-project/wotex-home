defmodule WotexHome.NativeSetup.CoreHost do
  @moduledoc """
  Runs the normal Home host owned by one private native-parent process.

  `main/0` is an entry point for the dedicated Core VM. It requires an absolute
  `WOTEX_HOME_DATA_DIR` and refuses an already running Home application with
  `{:error, :native_setup_unavailable}`. It owns its Host resources and serves
  `WotexHome.NativeSetup.Bridge` on the original parent's framed channel rather
  than attaching to another controller.

  With the nonsecret `WOTEX_HOME_NATIVE_MQTT_BOOTSTRAP=1` flag, required
  dependencies start first, then `WotexHome.NativeSetup.MQTTBootstrap.run/2`
  completes before Store/socket acquisition. Its source-bound capability passes
  through `WotexHome.Application.start/2` arguments to Host, not an environment
  variable or public API field. Without the flag, normal application startup
  applies; Keychain policy without a matching native capability fails closed.
  The flag enables the exchange and is not proof of signing or Keychain access.

  Known Logger handlers are routed to stderr before serving so diagnostics
  cannot corrupt framed stdout. Channel completion stops only the supervisor
  and native credential owner acquired here. This owned run terminates the VM
  with status 0 on success or 1 with a fixed diagnostic on failure.

  `WotexHome.NativeSetup.MQTTProvisioning` also uses this module's internal
  foreground stdio/Logger preparation and dependency startup. Foreground
  preparation refuses an already running Home; these helpers do not themselves
  start Home or open its Store. They are internal entry-point infrastructure.

  Installed profile and MQTT policy retain the normal `WotexHome.Host` checks.
  The entry point creates no target grant or physical qualification, and a new
  native Core startup requires a fresh bootstrap for Keychain mode.
  """

  alias WotexHome.Host
  alias WotexHome.NativeSetup.Bridge

  def main do
    if running_home?() do
      {:error, :native_setup_unavailable}
    else
      run_owned()
    end
  end

  @doc false
  def running_home? do
    is_pid(Process.whereis(WotexHome.Supervisor)) or is_pid(Host.store()) or
      Enum.any?(Application.started_applications(), fn {name, _, _} -> name == :wotex_home end)
  end

  @doc false
  def prepare_foreground do
    with false <- running_home?(),
         :ok <- :io.setopts(:standard_io, binary: true, encoding: :latin1),
         :ok <- own_logger(),
         do: :ok,
         else: (_ -> {:error, :native_setup_unavailable})
  end

  @doc false
  def start_dependencies do
    Application.load(:wotex_home)
    dependencies = Application.spec(:wotex_home, :applications)

    with :ok <-
           Enum.reduce_while(dependencies, :ok, fn app, _ ->
             case Application.ensure_all_started(app) do
               {:ok, _} -> {:cont, :ok}
               _ -> {:halt, :error}
             end
           end),
         do: own_logger()
  end

  defp run_owned do
    status =
      with directory when is_binary(directory) <- System.get_env("WOTEX_HOME_DATA_DIR"),
           true <- Path.type(directory) == :absolute,
           :ok <- :io.setopts(:standard_io, binary: true, encoding: :latin1),
           :ok <- own_logger(),
           {:ok, owned} <- start_home(directory) do
        try do
          if own_logger() == :ok and logger_owned?() and is_pid(Host.store()) do
            case Bridge.run(Host.authority()) do
              :ok -> 0
              _ -> 1
            end
          else
            1
          end
        rescue
          _ -> 1
        catch
          _, _ -> 1
        after
          stop_home(owned)
          Logger.flush()
        end
      else
        _ -> 1
      end

    if status != 0, do: IO.puts(:stderr, "native core channel unavailable")
    System.stop(status)
  end

  defp start_home(directory) do
    if System.get_env("WOTEX_HOME_NATIVE_MQTT_BOOTSTRAP") == "1" do
      with :ok <- start_dependencies(),
           {:ok, credential} <- WotexHome.NativeSetup.MQTTBootstrap.run(directory) do
        case WotexHome.Application.start(:normal, native_mqtt_credential: credential) do
          {:ok, supervisor} ->
            {:ok, {:native, supervisor, credential}}

          error ->
            WotexHome.MQTT.NativeCredential.stop(credential)
            error
        end
      end
    else
      with {:ok, _} <- Application.ensure_all_started(:wotex_home), do: {:ok, :application}
    end
  end

  defp stop_home(:application), do: Application.stop(:wotex_home)

  defp stop_home({:native, supervisor, credential}) do
    try do
      Supervisor.stop(supervisor)
    after
      WotexHome.MQTT.NativeCredential.stop(credential)
    end
  end

  # Handler output type is immutable after installation. Replace only the
  # default/OTP SSL handlers in this new VM, preserving their other settings.
  defp own_logger do
    with true <- known_handlers?(),
         :ok <-
           Enum.reduce_while(:logger.get_handler_ids(), :ok, fn id, _ ->
             case stderr_handler(id) do
               :ok -> {:cont, :ok}
               _ -> {:halt, {:error, :logger_unavailable}}
             end
           end),
         true <- logger_owned?() do
      :ok
    else
      _ -> {:error, :logger_unavailable}
    end
  end

  defp stderr_handler(id) do
    case :logger.get_handler_config(id) do
      {:ok, %{module: :logger_std_h, config: %{type: :standard_error}}} ->
        :ok

      {:ok, %{module: :logger_std_h, config: %{type: :standard_io} = config} = value} ->
        options =
          value
          |> Map.drop([:id, :module])
          |> Map.put(:config, Map.put(config, :type, :standard_error))

        with :ok <- :logger.remove_handler(id),
             do: :logger.add_handler(id, :logger_std_h, options)

      _ ->
        {:error, :logger_unavailable}
    end
  end

  defp known_handlers? do
    ids = :logger.get_handler_ids()
    :default in ids and Enum.all?(ids, &(&1 in [:default, :ssl_handler]))
  end

  defp logger_owned? do
    known_handlers?() and
      Enum.all?(:logger.get_handler_ids(), fn id ->
        match?(
          {:ok, %{module: :logger_std_h, config: %{type: :standard_error}}},
          :logger.get_handler_config(id)
        )
      end)
  end
end
