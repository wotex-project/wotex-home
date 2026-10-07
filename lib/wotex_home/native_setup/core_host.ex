defmodule WotexHome.NativeSetup.CoreHost do
  @moduledoc "Private native-parent OTP entry; starts and stops only its own normal Home host."
  alias WotexHome.Host
  alias WotexHome.NativeSetup.Bridge

  def main do
    if running_home?() do
      {:error, :native_setup_unavailable}
    else
      run_owned()
    end
  end

  defp running_home? do
    is_pid(Process.whereis(WotexHome.Supervisor)) or is_pid(Host.store()) or
      Enum.any?(Application.started_applications(), fn {name, _, _} -> name == :wotex_home end)
  end

  defp run_owned do
    status =
      with directory when is_binary(directory) <- System.get_env("WOTEX_HOME_DATA_DIR"),
           true <- Path.type(directory) == :absolute,
           :ok <- :io.setopts(:standard_io, binary: true, encoding: :latin1),
           :ok <- own_logger(),
           {:ok, _} <- Application.ensure_all_started(:wotex_home) do
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
          Application.stop(:wotex_home)
          Logger.flush()
        end
      else
        _ -> 1
      end

    if status != 0, do: IO.puts(:stderr, "native core channel unavailable")
    System.stop(status)
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
