defmodule WotexHome.Profiles.ExternalReportOwner do
  @moduledoc """
  Holds decoded reports from one publisher for consumption by one Store.

  Trusted host composition binds the publisher, source owner, Store and receipt
  clock. Only that publisher may publish or cancel a report; only the configured
  Store may checkout and finish it. The owner validates report shape and source
  correspondence before lending the exact decoded report for one operation.

  Custody is transient and bounded. Expiry, source changes or monitored-owner
  loss retire use, and a restart creates a new epoch rather than replaying
  reports. Publication here is buffering, not interpretation, durable admission
  or a claim that a physical device is qualified.
  """

  use GenServer
  alias WotexHome.{Id, Profiles.EnvelopeCodec}
  alias WotexHome.Profiles.ExternalSourceOwner

  @fields ~w(binding capture_epoch channel_id continuity profile_sha256 quality quality_reason receipt_time sequence source_epoch source_ref source_time value)
  @active [:pending, :checked_out]
  @minimum -9_223_372_036_854_775_808
  @maximum 9_223_372_036_854_775_807
  @uint_max 18_446_744_073_709_551_615

  def start_link(options) when is_list(options) do
    if options?(options) and Process.alive?(options[:publisher]) and
         Process.alive?(options[:source_owner]),
       do:
         GenServer.start_link(
           __MODULE__,
           options,
           if(options[:name] == nil, do: [], else: [name: options[:name]])
         ),
       else: {:error, :invalid_external_report_owner}
  end

  def start_link(_), do: {:error, :invalid_external_report_owner}

  def child_spec(options),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :temporary}

  @doc "Returns the explicit host receipt-clock epoch and canonical current microseconds."
  def receipt_clock(server), do: GenServer.call(server, :clock, 5000)
  @doc "Buffers a publisher's exact decoded report, without interpreting or admitting it."
  def publish(server, id, source, source_sha, report),
    do: GenServer.call(server, {:publish, id, source, source_sha, report}, 5000)

  def catalogue(server), do: GenServer.call(server, :catalogue, 5000)
  def status(server, id), do: GenServer.call(server, {:status, id}, 5000)
  def checkout(server, id), do: GenServer.call(server, {:checkout, id}, 5000)
  def validate(server, id, caller), do: GenServer.call(server, {:validate, id, caller}, 5000)
  def finish(server, id), do: GenServer.call(server, {:finish, id}, 5000)
  def cancel(server, id), do: GenServer.call(server, {:cancel, id}, 5000)

  @impl true
  def init(options) do
    ttl = Keyword.get(options, :ttl_ms, 60000)

    state = %{
      publisher: options[:publisher],
      source_owner: options[:source_owner],
      store_owner: options[:store_owner],
      publisher_monitor: Process.monitor(options[:publisher]),
      source_monitor: Process.monitor(options[:source_owner]),
      owner_epoch: nonce(),
      started: now(),
      ttl: ttl * 1000,
      limit: Keyword.get(options, :report_limit, 128),
      max_bytes: Keyword.get(options, :max_bytes, 4_194_304),
      entries: %{},
      correlations: %{}
    }

    Process.send_after(self(), :expire, min(ttl, 1000))
    {:ok, state}
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_external_report_owner) |> Map.put(:message, :redacted)

  @impl true
  def handle_call(:clock, _, state),
    do:
      {:reply, {:ok, %{"epoch" => state.owner_epoch, "monotonic_us" => Integer.to_string(now())}},
       reconcile(state)}

  def handle_call(:catalogue, _, state) do
    state = reconcile(state)
    receipts = state.entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {_, e} -> e.summary end)
    {:reply, {:ok, %{"owner_epoch" => state.owner_epoch, "receipts" => receipts}}, state}
  end

  def handle_call({:status, id}, _, state) do
    state = reconcile(state)
    result = if Id.valid?(id), do: lookup(state, id), else: invalid_lease()
    {:reply, result, state}
  end

  def handle_call({:publish, id, source, sha, report}, {caller, _}, state)
      when caller == state.publisher do
    state = reconcile(state)

    with :ok <- report_shape(id, source, sha, report),
         before = if(state.entries[id] == nil, do: sources(state), else: nil),
         {:ok, document} <- document(report),
         digest = report_sha(document) do
      case state.entries[id] do
        nil ->
          publish_new(state, id, source, sha, report, document, digest, before)

        e ->
          if e.summary["source_ref"] == source and e.summary["source_selection_sha256"] == sha and
               e.summary["report_sha256"] == digest,
             do: {:reply, {:ok, e.summary}, state},
             else: {:reply, {:error, :external_report_conflict}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:publish, _, _, _, _}, _, state),
    do: {:reply, {:error, :external_report_publisher_denied}, reconcile(state)}

  def handle_call({:checkout, id}, {caller, _}, state) do
    state = reconcile(state)

    with :ok <- store(state, caller), {:ok, e} <- entry(state, id), :ok <- active(e) do
      cond do
        e.state == :pending ->
          checked = %{
            e
            | state: :checked_out,
              summary: Map.put(e.summary, "state", "checked_out"),
              caller: caller,
              monitor: Process.monitor(caller)
          }

          {:reply, {:ok, borrowed(checked)}, put_in(state.entries[id], checked)}

        e.caller == caller ->
          {:reply, {:ok, borrowed(e)}, state}

        true ->
          {:reply, {:error, :external_report_busy}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:validate, id, expected}, {caller, _}, state) do
    state = reconcile(state)

    with :ok <- store(state, caller),
         {:ok, e} <- entry(state, id),
         :ok <- active(e),
         true <-
           e.state == :checked_out and e.caller == caller and expected == caller and
             Process.alive?(caller),
         do: {:reply, {:ok, guard(e)}, state},
         else: (
           false -> {:reply, {:error, :external_report_busy}, state}
           error -> {:reply, error, state}
         )
  end

  def handle_call({:finish, id}, {caller, _}, state) do
    state = reconcile(state)

    with :ok <- store(state, caller), {:ok, e} <- entry(state, id) do
      cond do
        e.state == :consumed ->
          {:reply, :ok, state}

        e.state == :checked_out and e.caller == caller ->
          {:reply, :ok, retire(state, id, :consumed)}

        e.state in @active ->
          {:reply, {:error, :external_report_busy}, state}

        true ->
          {:reply, retired(), state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cancel, id}, {caller, _}, state) when caller == state.publisher do
    state = reconcile(state)

    with {:ok, e} <- entry(state, id) do
      case e.state do
        :pending -> {:reply, :ok, retire(state, id, :cancelled)}
        :cancelled -> {:reply, :ok, state}
        :checked_out -> {:reply, {:error, :external_report_busy}, state}
        _ -> {:reply, retired(), state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cancel, _}, _, state),
    do: {:reply, {:error, :external_report_publisher_denied}, reconcile(state)}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state)
      when ref == state.publisher_monitor or ref == state.source_monitor,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    state =
      Enum.reduce(state.entries, state, fn {id, e}, acc ->
        if e.monitor == ref, do: retire(acc, id, :cancelled), else: acc
      end)

    {:noreply, reconcile(state)}
  end

  def handle_info(:expire, state) do
    Process.send_after(self(), :expire, min(div(state.ttl, 1000), 1000))
    {:noreply, reconcile(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp publish_new(state, id, source, source_sha, report, document, digest, before) do
    with correlation = correlation(report),
         true <- correlation == nil or not Map.has_key?(state.correlations, correlation),
         {:ok, received} <- receipt_time(state, report),
         {:ok, initial} <- before,
         {:ok, catalogue} <- sources(state),
         :ok <- same_epoch(initial["owner_epoch"], catalogue["owner_epoch"]),
         current when is_map(current) <-
           Enum.find(catalogue["sources"], &(&1["source_ref"] == source)),
         initial_current = Enum.find(initial["sources"], &(&1["source_ref"] == source)),
         true <-
           initial_current == current and
             current["source_selection_sha256"] == source_sha and
             current["data"]["source_epoch"] == report["source_epoch"],
         :ok <- capacity(state, byte_size(document)) do
      summary = %{
        "format" => "wotex-home.external-transport-receipt@1",
        "report_id" => id,
        "owner_epoch" => state.owner_epoch,
        "source_owner_epoch" => catalogue["owner_epoch"],
        "source_ref" => source,
        "source_selection_sha256" => source_sha,
        "channel_id" => report["channel_id"],
        "source_epoch" => report["source_epoch"],
        "sequence" => report["sequence"],
        "report_sha256" => digest,
        "state" => "pending"
      }

      e = %{
        summary: summary,
        state: :pending,
        report: report,
        document: document,
        received: received,
        deadline: received + state.ttl,
        caller: nil,
        monitor: nil
      }

      state = %{
        state
        | entries: Map.put(state.entries, id, e),
          correlations:
            if(correlation,
              do: Map.put(state.correlations, correlation, id),
              else: state.correlations
            )
      }

      {:reply, {:ok, summary}, state}
    else
      false ->
        reason =
          cond do
            report["receipt_time"]["epoch"] != state.owner_epoch ->
              :invalid_external_report_clock

            correlation(report) != nil and Map.has_key?(state.correlations, correlation(report)) ->
              :external_report_duplicate

            true ->
              :stale_external_source
          end

        {:reply, {:error, reason}, state}

      nil ->
        {:reply, :not_found, state}

      error ->
        {:reply, error, state}
    end
  end

  defp receipt_time(state, report) do
    case decimal(report["receipt_time"]["monotonic_us"], @minimum, @maximum) do
      {:ok, received} ->
        cond do
          report["receipt_time"]["epoch"] != state.owner_epoch or received < state.started or
              received > now() ->
            {:error, :invalid_external_report_clock}

          now() >= received + state.ttl ->
            retired()

          true ->
            {:ok, received}
        end

      _ ->
        {:error, :invalid_external_report_clock}
    end
  end

  defp same_epoch(epoch, epoch), do: :ok
  defp same_epoch(_, _), do: {:error, :external_source_owner_changed}

  defp report_shape(id, source, sha, report) do
    if Id.valid?(id) and Id.valid?(source) and EnvelopeCodec.digest?(sha) and
         EnvelopeCodec.keys?(report, @fields) and
         Id.valid?(report["channel_id"]) and report["source_ref"] == source and
         epoch?(report["source_epoch"]) and
         (report["sequence"] == nil or match?({:ok, _}, decimal(report["sequence"], 0, @uint_max))) and
         EnvelopeCodec.keys?(report["receipt_time"], ~w(epoch monotonic_us)) and
         epoch?(report["receipt_time"]["epoch"]) and
         match?({:ok, _}, decimal(report["receipt_time"]["monotonic_us"], @minimum, @maximum)),
       do: :ok,
       else: {:error, :invalid_external_transport_report}
  end

  defp document(report) do
    case apply(Wotex.JSON, :encode, [
           report,
           [
             max_bytes: 65536,
             max_depth: 8,
             max_nodes: 4096,
             max_collection_size: 256,
             max_string_bytes: 4096
           ]
         ]) do
      {:ok, bytes} when byte_size(bytes) <= 65536 ->
        {:ok, bytes}

      {:ok, _} ->
        {:error, :external_profile_limit}

      {:error, %{code: c}}
      when c in [
             :input_limit,
             :numeric_limit,
             :byte_limit_exceeded,
             :depth_limit_exceeded,
             :node_limit_exceeded,
             :collection_limit_exceeded,
             :string_limit_exceeded
           ] ->
        {:error, :external_profile_limit}

      _ ->
        {:error, :invalid_external_transport_report}
    end
  rescue
    e in UndefinedFunctionError ->
      if e.module == Wotex.JSON and e.function == :encode and e.arity == 2,
        do: {:error, :profiles_producer_unavailable},
        else: {:error, :invalid_external_transport_report}
  end

  defp reconcile(state) do
    catalogue = sources(state)

    Enum.reduce(state.entries, state, fn {id, e}, acc ->
      if e.state in @active do
        cond do
          now() >= e.deadline -> retire(acc, id, :expired)
          not current_source?(catalogue, e.summary) -> retire(acc, id, :invalidated)
          true -> acc
        end
      else
        acc
      end
    end)
  end

  defp sources(state) do
    ExternalSourceOwner.catalogue(state.source_owner)
  catch
    :exit, _ -> {:error, :external_source_unavailable}
  end

  defp current_source?({:ok, c}, s),
    do:
      c["owner_epoch"] == s["source_owner_epoch"] and
        Enum.any?(
          c["sources"],
          &(&1["source_ref"] == s["source_ref"] and
              &1["source_selection_sha256"] == s["source_selection_sha256"])
        )

  defp current_source?(_, _), do: false

  defp retire(state, id, status) do
    e = state.entries[id]
    if e.monitor, do: Process.demonitor(e.monitor, [:flush])

    put_in(state.entries[id], %{
      e
      | state: status,
        summary: Map.put(e.summary, "state", Atom.to_string(status)),
        report: nil,
        document: nil,
        received: nil,
        deadline: nil,
        caller: nil,
        monitor: nil
    })
  end

  defp entry(state, id) do
    cond do
      not Id.valid?(id) -> invalid_lease()
      state.entries[id] == nil -> :not_found
      true -> {:ok, state.entries[id]}
    end
  end

  defp lookup(state, id) do
    case entry(state, id) do
      {:ok, e} -> {:ok, e.summary}
      error -> error
    end
  end

  defp active(e), do: if(e.state in @active, do: :ok, else: retired())

  defp store(state, caller),
    do:
      if(resolve(state.store_owner) == caller,
        do: :ok,
        else: {:error, :external_report_store_denied}
      )

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: Process.whereis(name)

  defp capacity(state, added) do
    entries = state.entries |> Map.values() |> Enum.filter(&(&1.state in @active))

    if map_size(state.entries) < 1024 and length(entries) < state.limit and
         added + Enum.sum(Enum.map(entries, &byte_size(&1.document))) <= state.max_bytes,
       do: :ok,
       else: {:error, :external_report_capacity}
  end

  defp borrowed(e), do: %{report: e.report, document: e.document, guard: guard(e)}

  defp guard(e),
    do: %{
      report_id: e.summary["report_id"],
      owner_epoch: e.summary["owner_epoch"],
      source_owner_epoch: e.summary["source_owner_epoch"],
      source_ref: e.summary["source_ref"],
      source_selection_sha256: e.summary["source_selection_sha256"],
      report_sha256: e.summary["report_sha256"],
      receipt_monotonic_us: e.received,
      expires_at_us: e.deadline,
      checkout_pid: e.caller
    }

  defp correlation(%{"sequence" => nil}), do: nil
  defp correlation(r), do: {r["source_ref"], r["source_epoch"], r["channel_id"], r["sequence"]}

  defp decimal(s, minimum, maximum) when is_binary(s) and byte_size(s) <= 20 do
    case Integer.parse(s) do
      {n, ""} when n >= minimum and n <= maximum ->
        if Integer.to_string(n) == s, do: {:ok, n}, else: :error

      _ ->
        :error
    end
  end

  defp decimal(_, _, _), do: :error

  defp options?(o) do
    Keyword.keyword?(o) and length(Keyword.keys(o)) == length(Enum.uniq(Keyword.keys(o))) and
      Enum.all?(
        Keyword.keys(o),
        &(&1 in [
            :name,
            :publisher,
            :source_owner,
            :store_owner,
            :report_limit,
            :ttl_ms,
            :max_bytes
          ])
      ) and
      is_pid(o[:publisher]) and is_pid(o[:source_owner]) and
      (is_pid(o[:store_owner]) or (is_atom(o[:store_owner]) and o[:store_owner] != nil)) and
      name?(o[:name]) and integer?(Keyword.get(o, :report_limit, 128), 1, 256) and
      integer?(Keyword.get(o, :ttl_ms, 60000), 100, 60000) and
      integer?(Keyword.get(o, :max_bytes, 4_194_304), 1, 4_194_304)
  end

  defp name?(n) when is_nil(n) or is_atom(n), do: true
  defp name?({:global, _}), do: true
  defp name?({:via, m, _}) when is_atom(m), do: true
  defp name?(_), do: false
  defp integer?(n, a, b), do: is_integer(n) and n in a..b

  defp epoch?(n),
    do: is_binary(n) and byte_size(n) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, n)

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp report_sha(b),
    do:
      Base.encode16(:crypto.hash(:sha256, "wotex-home.external-transport-report@1\n" <> b),
        case: :lower
      )

  defp now, do: System.monotonic_time(:microsecond)
  defp invalid_lease, do: {:error, :invalid_external_report_lease}
  defp retired, do: {:error, :external_report_retired}
end
