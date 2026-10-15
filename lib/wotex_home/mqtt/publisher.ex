defmodule WotexHome.MQTT.Publisher do
  @moduledoc """
  Owns one explicitly configured MQTT source and its original report admissions.

  Trusted host composition calls `start_link/1` with the closed native inputs
  checked by `WotexHome.MQTT.Configuration`. Success is `{:ok, pid}` for an idle
  process with a new source epoch; it opens no broker connection yet. `source/1`
  returns `{:ok, selection}` for installation. Bind this publisher PID into
  `WotexHome.Profiles.ExternalSourceOwner` and
  `WotexHome.Profiles.ExternalReportOwner`, then call `attach/4` with the actual
  `WotexHome.Authority` and both owner PIDs after Store startup.

  Attachment rechecks the immutable configuration, publishes source custody and
  opens one clean MQTT 3.1.1 connection, returning `:ok` only after subscription.
  It is one-shot: later attachments return `{:error, :mqtt_already_attached}`;
  failed initial attachment stops the child. Neither construction nor attachment
  selects a target or grants observation authority.

  Each delivery becomes one report per matching channel through
  `Wotex.Binding.MQTT.JSONProjection`. Missing fields produce unknown reports;
  bounded malformed or unrepresentable JSON produces invalid reports. Oversized
  raw deliveries retire the publisher before report construction. Exact
  receipt times and original IDs enter transient report custody before
  `WotexHome.Authority.accept_external_report/2` performs durable admission.
  Store checks the current target, trust, policy and freshness. Continuity is
  retained for retained deliveries, otherwise replayed when DUP is set, and
  baseline otherwise. Host receipt order supplies no device sequence or device
  authentication.

  Queued admission batches and the active/uncertain batch share a four-batch
  bound, with one admission worker active. Five-second watchdogs bound attachment
  and each admission worker. `status/1` returns `{:ok, status}` with payload-free
  phase, counters and uncertain original identities.
  `reconcile/1` returns `:ok` after starting an uncertain batch again with exactly
  the same IDs and clocks; status must establish its eventual disposition.
  Other phases return `{:error, :mqtt_not_uncertain}`. Process exits and public
  call timeouts return `{:error, :mqtt_publisher_unavailable}`.

  Owner/connection loss, rejected delivery custody or queue overload is terminal.
  This temporary child does not reconnect, restore custody or automatically
  reselect a target. It owns the broker client without receiving a Store
  connection or an operator bearer credential.
  """

  use GenServer
  alias Wotex.Binding.MQTT.{Delivery, JSONProjection}
  alias WotexHome.Authority
  alias WotexHome.MQTT.{Configuration, Connection}
  alias WotexHome.Profiles.{ExternalReportOwner, ExternalSourceOwner}

  @doc "Starts an idle publisher from the closed native configuration."
  def start_link(config) do
    epoch = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    case Configuration.check(config, epoch) do
      {:ok, checked} -> GenServer.start_link(__MODULE__, {config, checked, epoch})
      error -> error
    end
  end

  def child_spec(config),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, restart: :temporary}

  @doc "Returns the checked source selection for trusted native host composition."
  def source(server), do: call(server, :source)
  @doc "Returns payload-free phase, counters and uncertain original identities."
  def status(server), do: call(server, :status)
  @doc "Publishes source custody and connects once, using the current Authority and owners."
  def attach(server, authority, sources, reports),
    do: call(server, {:attach, authority, sources, reports})

  @doc "Retries the uncertain batch using its exact original report epoch and IDs."
  def reconcile(server), do: call(server, :reconcile)

  defp call(server, request) do
    GenServer.call(server, request, 6_000)
  catch
    :exit, _ -> {:error, :mqtt_publisher_unavailable}
  end

  @impl true
  def init({config, checked, epoch}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       config: config,
       checked: checked,
       epoch: epoch,
       phase: :idle,
       received: 0,
       accepted: 0,
       refused: 0,
       queue: :queue.new(),
       active: nil,
       uncertain: [],
       connection: nil,
       monitors: [],
       authority: nil,
       reports: nil,
       report_epoch: nil
     }}
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_mqtt_publisher)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :mqtt_publisher_stopped)

  @impl true
  def handle_call(:source, _, s), do: {:reply, {:ok, s.checked.selection}, s}

  def handle_call(:status, _, s) do
    {:reply,
     {:ok,
      %{
        phase: s.phase,
        received: s.received,
        accepted: s.accepted,
        refused: s.refused,
        pending_frames: pending(s),
        uncertain: s.uncertain
      }}, s}
  end

  def handle_call({:attach, _, _, _}, _, %{phase: phase} = s) when phase != :idle,
    do: {:reply, {:error, :mqtt_already_attached}, s}

  def handle_call({:attach, authority, sources, reports}, _, s) do
    watchdog = watchdog(self())
    token = make_ref()
    result = safe_attach(s, authority, sources, reports, token)
    send(watchdog, :done)

    case result do
      {:ok, connection, clock, monitors} ->
        {:reply, :ok,
         %{
           s
           | phase: :running,
             connection: connection,
             monitors: monitors,
             authority: authority,
             reports: reports,
             report_epoch: clock["epoch"]
         }}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, s}
    end
  end

  def handle_call(:reconcile, _, %{phase: :uncertain} = s) do
    {:reply, :ok, launch(%{s | phase: :running, uncertain: []}, s.uncertain)}
  end

  def handle_call(:reconcile, _, s), do: {:reply, {:error, :mqtt_not_uncertain}, s}

  defp safe_attach(s, %Authority{} = authority, sources, reports, token) do
    with store when is_pid(store) <- Authority.owner(authority),
         true <- Enum.all?([store, sources, reports], &(is_pid(&1) and Process.alive?(&1))),
         {:ok, checked} <- Configuration.check(s.config, s.epoch),
         true <- checked == s.checked,
         monitors = Enum.map([store, sources, reports], &Process.monitor/1),
         {:ok, _} <- ExternalSourceOwner.publish(sources, checked.selection),
         {:ok, clock} <- ExternalReportOwner.receipt_clock(reports),
         {:ok, connection} <- Connection.open(s.config.connection, checked.topics, self(), token) do
      {:ok, connection, clock, monitors}
    else
      {:error, reason}
      when reason in [
             :mqtt_connection_unavailable,
             :mqtt_logging_unavailable,
             :invalid_mqtt_connection,
             :invalid_mqtt_publisher
           ] ->
        {:error, reason}

      _ ->
        {:error, :mqtt_owner_unavailable}
    end
  rescue
    _ -> {:error, :mqtt_owner_unavailable}
  catch
    _, _ -> {:error, :mqtt_owner_unavailable}
  end

  defp safe_attach(_, _, _, _, _), do: {:error, :mqtt_owner_unavailable}

  @impl true
  def handle_info(
        {:mqtt_frame, token, client, n, received, msg},
        %{connection: %{token: token, client: client}} = s
      ) do
    if Process.alive?(client) and pending(s) < 4 and
         Configuration.local_present?(s.config.connection.local_address) do
      case originals(s, n, received, msg) do
        {:ok, originals} ->
          Connection.release(s.connection)
          s = %{s | received: s.received + 1, queue: :queue.in(originals, s.queue)}
          {:noreply, advance(s)}

        _ ->
          {:stop, :normal, s}
      end
    else
      {:stop, :normal, s}
    end
  end

  def handle_info(
        {:mqtt_fault, token, client},
        %{connection: %{token: token, client: client}} = s
      ),
      do: {:stop, :normal, s}

  def handle_info(
        {:admitted, ref, worker, counts},
        %{active: %{ref: ref, worker: worker} = active} = s
      ) do
    send(active.watchdog, :done)
    Process.demonitor(active.monitor, [:flush])
    {accepted, refused} = counts
    s = %{s | active: nil, accepted: s.accepted + accepted, refused: s.refused + refused}
    {:noreply, advance(s)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{active: %{monitor: ref} = active} = s) do
    send(active.watchdog, :done)
    {:noreply, %{s | phase: :uncertain, active: nil, uncertain: active.originals}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    if ref in s.monitors, do: {:stop, :normal, s}, else: {:noreply, s}
  end

  def handle_info({:EXIT, client, _}, %{connection: %{client: client}} = s),
    do: {:stop, :normal, s}

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if s.connection, do: Process.exit(s.connection.client, :kill)

    if s.active do
      send(s.active.watchdog, :done)
      Process.exit(s.active.worker, :kill)
    end

    :ok
  end

  defp originals(s, n, received, msg) do
    {:ok, delivery} =
      Delivery.new(msg.payload, topic: msg.topic, qos: msg.qos, retain: msg.retain)

    s.checked.plans
    |> Enum.with_index()
    |> Enum.filter(fn {plan, _} -> plan["selector"]["topic"] == msg.topic end)
    |> Enum.reduce_while({:ok, []}, fn {plan, index}, {:ok, originals} ->
      {quality, reason, value} = project(delivery, plan["selector"])

      report = %{
        "binding" => s.checked.projection["binding"],
        "capture_epoch" => s.checked.projection["capture_epoch"],
        "channel_id" => plan["channel_id"],
        "continuity" =>
          cond do
            msg.retain -> "retained"
            msg.dup -> "replayed"
            true -> "baseline"
          end,
        "profile_sha256" => s.checked.projection["profile_sha256"],
        "quality" => quality,
        "quality_reason" => reason,
        "receipt_time" => %{
          "epoch" => s.report_epoch,
          "monotonic_us" => Integer.to_string(received)
        },
        "sequence" => Integer.to_string(n),
        "source_epoch" => s.epoch,
        "source_ref" => s.checked.selection.data["source_ref"],
        "source_time" => nil,
        "value" => value
      }

      id = "mqtt:#{s.epoch}:#{n}:#{index}"

      case ExternalReportOwner.publish(
             s.reports,
             id,
             report["source_ref"],
             s.checked.selection.sha256,
             report
           ) do
        {:ok, _} ->
          {:cont,
           {:ok, originals ++ [%{"report_owner_epoch" => s.report_epoch, "report_id" => id}]}}

        _ ->
          {:halt, :refused}
      end
    end)
  rescue
    _ -> :refused
  catch
    _, _ -> :refused
  end

  defp project(delivery, selector) do
    case JSONProjection.project(delivery, selector) do
      {:ok, value, _} ->
        {"usable", nil, value}

      {:error, %{code: :profile_value_missing}} ->
        {"unknown", "missing_value", %{"type" => "null"}}

      {:error, %{code: code}}
      when code in [:json_invalid_input, :json_unsupported_value, :json_output_limit] ->
        {"invalid", "invalid_payload", %{"type" => "null"}}
    end
  end

  defp pending(s),
    do: :queue.len(s.queue) + if(s.active == nil and s.uncertain == [], do: 0, else: 1)

  defp advance(%{phase: :running, active: nil} = s) do
    case :queue.out(s.queue) do
      {{:value, originals}, queue} -> launch(%{s | queue: queue}, originals)
      {:empty, _} -> s
    end
  end

  defp advance(s), do: s

  defp launch(s, originals) do
    parent = self()
    ref = make_ref()
    authority = s.authority

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          counts =
            try do
              Enum.reduce(originals, {0, 0}, fn original, {ok, refused} ->
                case Authority.accept_external_report(authority, original) do
                  {:ok, _} -> {ok + 1, refused}
                  {:error, reason} when is_atom(reason) -> {ok, refused + 1}
                  _ -> exit(:mqtt_admission_uncertain)
                end
              end)
            catch
              _, _ -> exit(:mqtt_admission_uncertain)
            end

          send(parent, {:admitted, ref, self(), counts})
        end,
        [:link, :monitor]
      )

    %{
      s
      | active: %{
          worker: worker,
          monitor: monitor,
          ref: ref,
          originals: originals,
          watchdog: watchdog(worker)
        }
    }
  end

  defp watchdog(owner) do
    spawn(fn ->
      monitor = Process.monitor(owner)

      receive do
        :done -> Process.demonitor(monitor, [:flush])
        {:DOWN, ^monitor, :process, ^owner, _} -> :ok
      after
        5_000 -> Process.exit(owner, :kill)
      end
    end)
  end
end
