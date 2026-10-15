defmodule WotexHome.Host.MQTTInstallation do
  @moduledoc """
  Owns the temporary MQTT publisher and source/report custody of one Host.

  `WotexHome.Host` starts this temporary child after the single Store and private
  profile custody, using the sealed snapshot selected by
  `WotexHome.Host.MQTTConfiguration`. `start_link/1` returns `{:ok, pid}` only
  after creating the publisher, source owner and report owner and completing
  `WotexHome.MQTT.Publisher.attach/4`. Source custody precedes connection setup;
  Host starts its API only after installation succeeds.

  Partial setup failure kills every newly owned process and stops initialization
  with `:mqtt_installation_unavailable`. The publisher receives a resolver over
  a private credential seal rather than a decoded username/password pair. This
  installation retains owned-process references, and process diagnostics redact
  its state and failure reason.

  Publisher, client, source/report owner or Store loss is terminal. The linked
  composition retires all owned children and does not reconnect or restore
  transient reports. Its temporary child specification is removed on an
  in-place Store restart, so MQTT remains unavailable in that Host incarnation.
  A full Host startup selects current sealed files and fresh source epochs;
  installation does not automatically reselect a target.

  Store alone authorizes current target use and durable observation admission.
  Broker attachment supplies no profile trust, device authentication, physical
  qualification or dispatch permission.
  """

  use GenServer
  alias WotexHome.{Authority, MQTT.Publisher}
  alias WotexHome.Host.MQTTConfiguration.Snapshot
  alias WotexHome.Profiles.{ExternalSourceOwner, ExternalReportOwner}

  def start_link(%Snapshot{} = snapshot),
    do: GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)

  def child_spec(snapshot),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [snapshot]}, restart: :temporary}

  @impl true
  def init(snapshot) do
    Process.flag(:trap_exit, true)

    steps = [
      {:publisher, fn _ -> Publisher.start_link(snapshot.prepared.publisher) end},
      {:sources,
       fn s ->
         ExternalSourceOwner.start_link(
           publisher: s.publisher,
           name: WotexHome.Host.ExternalSources
         )
       end},
      {:reports,
       fn s ->
         ExternalReportOwner.start_link(
           publisher: s.publisher,
           source_owner: s.sources,
           store_owner: WotexHome.Host.store(),
           name: WotexHome.Host.ExternalReports
         )
       end}
    ]

    result =
      Enum.reduce_while(steps, {:ok, %{}}, fn {key, start}, {:ok, owned} ->
        case safely(fn -> start.(owned) end) do
          {:ok, pid} -> {:cont, {:ok, Map.put(owned, key, pid)}}
          _ -> {:halt, {:error, owned}}
        end
      end)

    case result do
      {:ok, owned} ->
        case safely(fn ->
               Publisher.attach(
                 owned.publisher,
                 Authority.new(store: WotexHome.Host.store()),
                 owned.sources,
                 owned.reports
               )
             end) do
          :ok ->
            {:ok, owned}

          _ ->
            cleanup(owned)
            {:stop, :mqtt_installation_unavailable}
        end

      {:error, owned} ->
        cleanup(owned)
        {:stop, :mqtt_installation_unavailable}
    end
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_mqtt_installation)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :mqtt_installation_unavailable)

  @impl true
  def handle_info({:EXIT, pid, _}, owned) do
    if pid in Map.values(owned), do: {:stop, :normal, owned}, else: {:noreply, owned}
  end

  def handle_info(_, owned), do: {:noreply, owned}
  @impl true
  def terminate(_, owned), do: cleanup(owned)

  defp safely(fun) do
    fun.()
  rescue
    _ -> :refused
  catch
    _, _ -> :refused
  end

  defp cleanup(owned) do
    Enum.each(Map.values(owned), fn pid ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end)

    :ok
  end
end
