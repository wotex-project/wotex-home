defmodule WotexHome.MQTT.LogFilter do
  @moduledoc """
  Suppresses EMQTT diagnostics that can contain private packets or client state.

  `install/0` installs a stateless primary Logger filter before MQTT client
  startup. It returns `:ok` for a new installation or the identical existing
  filter. A conflicting registration under its reserved ID, or an installation
  failure, returns `{:error, :mqtt_logging_unavailable}` so the client can refuse
  startup.

  The filter is node-wide and remains installed after a publisher stops. It
  drops events whose call site is EMQTT and the recognized OTP termination/crash
  reports naming that callback module, including other EMQTT clients on the
  node. Unrelated events continue through the existing Logger filters.

  The filter retains no credentials, payloads or process registry and changes
  no Logger levels. It covers these diagnostic shapes; callers still own
  keeping private packet or credential data out of their own logs.
  """

  @id :wotex_home_private_emqtt
  @doc "Installs the exact privacy filter or refuses a conflicting registration."
  def install do
    entry = {&__MODULE__.filter/2, :emqtt}

    case :logger.add_primary_filter(@id, entry) do
      :ok ->
        :ok

      {:error, {:already_exist, _}} ->
        if List.keyfind(:logger.get_primary_config().filters, @id, 0) == {@id, entry},
          do: :ok,
          else: {:error, :mqtt_logging_unavailable}

      _ ->
        {:error, :mqtt_logging_unavailable}
    end
  end

  @doc false
  def filter(%{meta: %{mfa: {:emqtt, _, _}}}, :emqtt), do: :stop

  def filter(%{msg: {:report, %{label: {:gen_statem, :terminate}, modules: modules}}}, :emqtt)
      when is_list(modules) do
    if :emqtt in modules, do: :stop, else: :ignore
  end

  def filter(%{msg: {:report, %{label: {:proc_lib, :crash}, report: [own | _]}}}, :emqtt)
      when is_list(own) do
    case List.keyfind(own, :initial_call, 0) do
      {:initial_call, {:emqtt, _, _}} -> :stop
      _ -> :ignore
    end
  end

  def filter(_, _), do: :ignore
end
