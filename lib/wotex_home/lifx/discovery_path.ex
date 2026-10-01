defmodule WotexHome.Lifx.DiscoveryPath do
  @moduledoc """
  One bounded LIFX GetService window through a caller-owned selected-interface transport.

  The caller chooses and owns the IPv4 interface/prefix and the datagram socket.
  Returned candidates are untrusted introductions, never enrollment or authority.

  `run/6` sends one GetService broadcast and collects a finite set of
  responses through the supplied transport. Keep that socket bound to the
  selected interface; candidates from another source scope must not be mixed
  into the same review window.
  """

  alias WotexHome.Lifx.{DiscoveryWindow, IPv4Scope, Transport}

  @max_datagrams 256
  @max_i64 9_223_372_036_854_775_807

  @spec run(
          String.t(),
          String.t(),
          IPv4Scope.t(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, [WotexHome.Discovery.Candidate.t()], DiscoveryWindow.t()}
          | {:error, atom(), DiscoveryWindow.t() | nil}
  def run(interface_id, receive_epoch, %IPv4Scope{} = scope, source, sequence, opts)
      when is_list(opts) do
    with {:ok, transport, handle, clock, duration_ms} <- options(opts),
         broadcast = "#{:inet.ntoa(scope.broadcast)}:56700",
         :ok <- Transport.check({transport, handle}, broadcast, :discovery),
         {:ok, now_ms} <- clock_time(clock),
         {:ok, window, query} <-
           DiscoveryWindow.new(
             interface_id,
             receive_epoch,
             scope,
             source,
             sequence,
             now_ms,
             duration_ms
           ) do
      case safe_send(transport, handle, broadcast, query) do
        :ok -> collect(window, transport, handle, clock, System.monotonic_time(:millisecond), 0)
        {:error, reason} -> {:error, reason, window}
      end
    else
      {:error, reason} -> {:error, reason, nil}
    end
  end

  def run(_interface_id, _receive_epoch, _scope, _source, _sequence, _opts),
    do: {:error, :invalid_discovery_path, nil}

  defp options(opts) do
    if Keyword.keyword?(opts) and
         Enum.sort(Keyword.keys(opts)) ==
           Enum.sort(~w(transport clock duration_ms)a) do
      transport = Keyword.fetch!(opts, :transport)
      clock = Keyword.fetch!(opts, :clock)
      duration_ms = Keyword.fetch!(opts, :duration_ms)

      case transport do
        {module, handle}
        when is_atom(module) and is_function(clock, 0) and is_integer(duration_ms) and
               duration_ms in 100..10_000 ->
          if function_exported?(module, :send, 3) and function_exported?(module, :recv, 2),
            do: {:ok, module, handle, clock, duration_ms},
            else: {:error, :invalid_discovery_path}

        _ ->
          {:error, :invalid_discovery_path}
      end
    else
      {:error, :invalid_discovery_path}
    end
  end

  defp clock_time(clock) do
    case clock.() do
      {boot_ms, utc_ms}
      when is_integer(boot_ms) and boot_ms >= 0 and boot_ms <= @max_i64 and
             is_integer(utc_ms) and utc_ms >= 0 and utc_ms <= @max_i64 ->
        {:ok, boot_ms}

      _ ->
        {:error, :invalid_discovery_clock}
    end
  rescue
    _ -> {:error, :invalid_discovery_clock}
  catch
    _, _ -> {:error, :invalid_discovery_clock}
  end

  defp safe_send(transport, handle, endpoint, bytes) do
    case transport.send(handle, endpoint, bytes) do
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

  defp collect(window, transport, handle, clock, started, seen) do
    remaining =
      window.deadline_ms - window.start_ms - (System.monotonic_time(:millisecond) - started)

    cond do
      remaining <= 0 ->
        {:ok, DiscoveryWindow.candidates(window), window}

      seen >= @max_datagrams ->
        {:error, :datagram_budget_exhausted, window}

      true ->
        case safe_recv(transport, handle, remaining) do
          {:ok, endpoint, bytes} when is_binary(endpoint) and is_binary(bytes) ->
            if System.monotonic_time(:millisecond) - started >=
                 window.deadline_ms - window.start_ms do
              {:ok, DiscoveryWindow.candidates(window), window}
            else
              with {:ok, {address, port}} <- parse_endpoint(endpoint),
                   {:ok, now_ms} <- clock_time(clock),
                   true <- now_ms >= window.start_ms do
                next_window =
                  case DiscoveryWindow.accept(window, bytes, address, port, now_ms) do
                    {:ok, _candidate, updated} -> updated
                    {:error, _reason, updated} -> updated
                  end

                collect(next_window, transport, handle, clock, started, seen + 1)
              else
                {:error, :invalid_discovery_clock} ->
                  {:error, :invalid_discovery_clock, window}

                false ->
                  {:error, :invalid_discovery_clock, window}

                _ ->
                  collect(window, transport, handle, clock, started, seen + 1)
              end
            end

          {:error, :timeout} ->
            {:ok, DiscoveryWindow.candidates(window), window}

          {:error, reason} when is_atom(reason) ->
            {:error, reason, window}

          _ ->
            {:error, :invalid_transport_result, window}
        end
    end
  end

  defp parse_endpoint(endpoint) do
    case if(is_binary(endpoint) and byte_size(endpoint) <= 64 and String.valid?(endpoint),
           do: String.split(endpoint, ":"),
           else: []
         ) do
      [address, port_text] ->
        with {:ok, parsed} <- :inet.parse_ipv4_address(String.to_charlist(address)),
             {port, ""} <- Integer.parse(port_text),
             true <- port in 1..65_535 do
          {:ok, {parsed, port}}
        else
          _ -> {:error, :invalid_endpoint}
        end

      _ ->
        {:error, :invalid_endpoint}
    end
  end
end
