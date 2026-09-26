defmodule WotexHome.Lifx.InterviewPath do
  @moduledoc """
  Bounded read-only LIFX identity interview through a caller-owned transport.

  A completed interview is reported identity, not enrollment or attestation.
  This module opens no socket and does not choose a network interface.
  """

  alias WotexHome.Discovery.{Candidate, Interview}
  alias WotexHome.Lifx.{InterviewSession, Ledger}

  @max_datagrams 16
  @max_i64 9_223_372_036_854_775_807

  @spec run(Candidate.t(), binary(), Ledger.t(), keyword()) ::
          {:ok, Interview.t(), Ledger.t()} | {:error, atom(), Ledger.t()}
  def run(%Candidate{} = candidate, target, %Ledger{} = ledger, opts) when is_list(opts) do
    with {:ok, {transport, handle}, clock, ttl_ms} <- options(opts),
         {:ok, issued_ms} <- clock_time(clock),
         {:ok, session} <- InterviewSession.new(candidate, target),
         {:ok, queries, session, issued_ledger} <-
           InterviewSession.issue(session, ledger, issued_ms, ttl_ms) do
      case send_queries(transport, handle, candidate.source_endpoint, queries) do
        :ok ->
          await(
            session,
            issued_ledger,
            transport,
            handle,
            clock,
            issued_ms,
            System.monotonic_time(:millisecond),
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

  def run(_candidate, _target, %Ledger{} = ledger, _opts),
    do: {:error, :invalid_interview_path, ledger}

  defp options(opts) do
    transport = Keyword.get(opts, :transport)
    clock = Keyword.get(opts, :clock)
    ttl_ms = Keyword.get(opts, :timeout_ms)

    if Keyword.keyword?(opts) and
         Enum.sort(Keyword.keys(opts)) ==
           Enum.sort(~w(transport clock timeout_ms)a) and
         match?({module, _handle} when is_atom(module), transport) and
         function_exported?(elem(transport, 0), :send, 3) and
         function_exported?(elem(transport, 0), :recv, 2) and is_function(clock, 0) and
         is_integer(ttl_ms) and ttl_ms in 1..5_000 do
      {module, handle} = transport
      {:ok, {module, handle}, clock, ttl_ms}
    else
      {:error, :invalid_interview_path}
    end
  end

  defp clock_time(clock) do
    case clock.() do
      {boot_ms, utc_ms}
      when is_integer(boot_ms) and boot_ms >= 0 and boot_ms <= @max_i64 and
             is_integer(utc_ms) and utc_ms >= 0 and utc_ms <= @max_i64 ->
        {:ok, boot_ms}

      _ ->
        {:error, :invalid_interview_clock}
    end
  rescue
    _ -> {:error, :invalid_interview_clock}
  catch
    _, _ -> {:error, :invalid_interview_clock}
  end

  defp send_queries(transport, handle, endpoint, queries) do
    with :ok <- safe_send(transport, handle, endpoint, queries.version),
         :ok <- safe_send(transport, handle, endpoint, queries.host_firmware) do
      :ok
    end
  end

  defp safe_send(transport, handle, endpoint, packet) do
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

  defp safe_recv(transport, handle, timeout_ms) do
    transport.recv(handle, timeout_ms)
  rescue
    _ -> {:error, :transport_unavailable}
  catch
    _, _ -> {:error, :transport_unavailable}
  end

  defp await(session, ledger, transport, handle, clock, issued_ms, started, ttl_ms, seen) do
    remaining = ttl_ms - (System.monotonic_time(:millisecond) - started)

    cond do
      remaining <= 0 ->
        {:error, :interview_timeout, ledger}

      seen >= @max_datagrams ->
        {:error, :datagram_budget_exhausted, ledger}

      true ->
        case safe_recv(transport, handle, remaining) do
          {:ok, endpoint, bytes} when is_binary(endpoint) and is_binary(bytes) ->
            case clock_time(clock) do
              {:ok, received_ms} when received_ms >= issued_ms ->
                accept_or_continue(
                  session,
                  ledger,
                  transport,
                  handle,
                  clock,
                  issued_ms,
                  started,
                  ttl_ms,
                  seen,
                  endpoint,
                  bytes,
                  received_ms
                )

              _ ->
                {:error, :invalid_interview_clock, ledger}
            end

          {:error, :timeout} ->
            {:error, :interview_timeout, ledger}

          {:error, reason} when is_atom(reason) ->
            {:error, reason, ledger}

          _ ->
            {:error, :invalid_transport_result, ledger}
        end
    end
  end

  defp accept_or_continue(
         session,
         ledger,
         transport,
         handle,
         clock,
         issued_ms,
         started,
         ttl_ms,
         seen,
         endpoint,
         bytes,
         received_ms
       ) do
    {session, ledger} =
      case InterviewSession.accept(session, ledger, endpoint, bytes, received_ms) do
        {:ok, next_session, next_ledger} -> {next_session, next_ledger}
        {:error, _reason, next_session, next_ledger} -> {next_session, next_ledger}
      end

    case InterviewSession.finish(session) do
      {:ok, interview} ->
        {:ok, interview, ledger}

      {:error, :incomplete_interview} ->
        await(
          session,
          ledger,
          transport,
          handle,
          clock,
          issued_ms,
          started,
          ttl_ms,
          seen + 1
        )

      {:error, reason} ->
        {:error, reason, ledger}
    end
  end
end
