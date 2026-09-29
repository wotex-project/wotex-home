defmodule WotexHome.Lifx.ReadPath do
  @moduledoc """
  Bounded read-only GetColor exchange through a caller-owned datagram transport.

  This module owns LIFX session correlation and commits only declared reports.
  It opens no socket, selects no interface and grants no command authority.
  The transport adapter must own its interface, endpoint and receive limits.

  `run/6` composes the pure read session with a durable Store report batch.
  Only a reply from the selected endpoint with a live ledger key can produce
  observations. A timeout or uncertain send leaves the issued key reserved.
  """

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{Ledger, ReadSession}
  alias WotexHome.Semantics.Thing

  @max_datagrams 16
  @max_i64 9_223_372_036_854_775_807

  @doc "Issue one read, ignore at most 16 unrelated datagrams and commit its validated reports."
  @spec run(
          GenServer.server(),
          Candidate.t(),
          binary(),
          Thing.t(),
          Ledger.t(),
          keyword()
        ) ::
          {:ok | :duplicate, [WotexHome.Semantics.Observation.t()], [non_neg_integer()],
           Ledger.t()}
          | {:error, atom(), Ledger.t()}
  def run(store, %Candidate{} = candidate, target, %Thing{} = thing, %Ledger{} = ledger, opts)
      when is_list(opts) do
    with {:ok, {transport, handle}, clock, source_epoch, source_sequence, boot_epoch, ttl_ms} <-
           options(opts),
         {:ok, {issued_ms, _utc_ms}} <- time(clock),
         {:ok, session} <- ReadSession.new(candidate, target, thing),
         {:ok, packet, session, issued_ledger} <-
           ReadSession.issue(session, ledger, issued_ms, ttl_ms) do
      case send_packet(transport, handle, candidate.source_endpoint, packet) do
        :ok ->
          started = System.monotonic_time(:millisecond)

          await_report(
            store,
            session,
            issued_ledger,
            transport,
            handle,
            clock,
            source_epoch,
            source_sequence,
            boot_epoch,
            issued_ms,
            started,
            ttl_ms,
            0
          )

        {:error, reason} ->
          {:error, reason, issued_ledger}
      end
    else
      {:error, reason} -> {:error, reason, ledger}
    end
  end

  def run(_store, _candidate, _target, _thing, %Ledger{} = ledger, _opts),
    do: {:error, :invalid_read_path, ledger}

  defp options(opts) do
    if Keyword.keyword?(opts) and
         Enum.sort(Keyword.keys(opts)) ==
           Enum.sort(~w(transport clock source_epoch source_sequence boot_epoch timeout_ms)a) do
      transport = Keyword.fetch!(opts, :transport)
      clock = Keyword.fetch!(opts, :clock)
      source_epoch = Keyword.fetch!(opts, :source_epoch)
      source_sequence = Keyword.fetch!(opts, :source_sequence)
      boot_epoch = Keyword.fetch!(opts, :boot_epoch)
      ttl_ms = Keyword.fetch!(opts, :timeout_ms)

      if match?({module, _handle} when is_atom(module), transport) and
           function_exported?(elem(transport, 0), :send, 3) and
           function_exported?(elem(transport, 0), :recv, 2) and is_function(clock, 0) and
           WotexHome.Id.valid?(source_epoch) and WotexHome.Id.valid?(boot_epoch) and
           is_integer(source_sequence) and source_sequence >= 0 and
           source_sequence <= @max_i64 and is_integer(ttl_ms) and ttl_ms in 1..5_000 do
        {module, handle} = transport
        {:ok, {module, handle}, clock, source_epoch, source_sequence, boot_epoch, ttl_ms}
      else
        {:error, :invalid_read_path}
      end
    else
      {:error, :invalid_read_path}
    end
  end

  defp time(clock) do
    case safe_time(clock) do
      {monotonic_ms, utc_ms}
      when is_integer(monotonic_ms) and monotonic_ms >= 0 and monotonic_ms <= @max_i64 and
             is_integer(utc_ms) and utc_ms >= 0 and utc_ms <= @max_i64 ->
        {:ok, {monotonic_ms, utc_ms}}

      _ ->
        {:error, :invalid_read_clock}
    end
  end

  defp safe_time(clock) do
    clock.()
  rescue
    _ -> :invalid
  catch
    _, _ -> :invalid
  end

  defp send_packet(transport, handle, endpoint, packet) do
    case transport.send(handle, endpoint, packet) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_transport_result}
    end
  rescue
    _ -> {:error, :transport_unavailable}
  catch
    _, _ -> {:error, :transport_unavailable}
  end

  defp await_report(
         store,
         session,
         ledger,
         transport,
         handle,
         clock,
         source_epoch,
         source_sequence,
         boot_epoch,
         issued_ms,
         started,
         ttl_ms,
         seen
       ) do
    remaining = ttl_ms - (System.monotonic_time(:millisecond) - started)

    cond do
      remaining <= 0 ->
        {:error, :read_timeout, ledger}

      seen >= @max_datagrams ->
        {:error, :datagram_budget_exhausted, ledger}

      true ->
        case receive_packet(transport, handle, remaining) do
          {:ok, endpoint, bytes} when is_binary(endpoint) and is_binary(bytes) ->
            within_deadline? = System.monotonic_time(:millisecond) - started < ttl_ms

            with true <- within_deadline?,
                 {:ok, {received_ms, received_utc_ms}} <- time(clock),
                 true <- received_ms >= issued_ms,
                 metadata = %{
                   "source_epoch" => source_epoch,
                   "source_sequence" => source_sequence,
                   "boot_epoch" => boot_epoch,
                   "received_time_utc_ms" => received_utc_ms,
                   "received_monotonic_ms" => received_ms
                 },
                 {:ok, reports, next_ledger} <-
                   ReadSession.accept(session, ledger, endpoint, bytes, received_ms, metadata) do
              commit_reports(store, session.thing, reports, next_ledger)
            else
              {:error, :invalid_read_clock} ->
                {:error, :invalid_read_clock, ledger}

              false ->
                if within_deadline?,
                  do: {:error, :invalid_read_clock, ledger},
                  else: {:error, :read_timeout, ledger}

              {:error, _reason, next_ledger} ->
                await_report(
                  store,
                  session,
                  next_ledger,
                  transport,
                  handle,
                  clock,
                  source_epoch,
                  source_sequence,
                  boot_epoch,
                  issued_ms,
                  started,
                  ttl_ms,
                  seen + 1
                )
            end

          {:error, :timeout} ->
            {:error, :read_timeout, ledger}

          {:error, reason} when is_atom(reason) ->
            {:error, reason, ledger}

          _ ->
            {:error, :invalid_transport_result, ledger}
        end
    end
  end

  defp receive_packet(transport, handle, timeout_ms) do
    transport.recv(handle, timeout_ms)
  rescue
    _ -> {:error, :transport_unavailable}
  catch
    _, _ -> {:error, :transport_unavailable}
  end

  defp commit_reports(store, thing, reports, ledger) do
    try do
      case Store.record_batch(store, thing, reports) do
        {:ok, revisions} -> {:ok, reports, revisions, ledger}
        {:duplicate, revisions} -> {:duplicate, reports, revisions, ledger}
        {:error, reason} -> {:error, reason, ledger}
      end
    catch
      :exit, _ -> {:error, :store_unavailable, ledger}
    end
  end
end
