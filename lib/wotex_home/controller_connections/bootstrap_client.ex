defmodule WotexHome.ControllerConnections.BootstrapClient do
  @moduledoc """
  One selected-invitation TLS bootstrap exchange; no retry or credential custody.

  Inputs are trusted client-side invitation/clock/approved-scope selections,
  never public setup routes. Certificate validation finishes before the first
  application byte. A lost/invalid reply after sending is outcome_unknown and
  requires local reconciliation; it cannot replay credential delivery.
  """
  alias WotexHome.ControllerConnections.{CertificateClock, Codec, TLSIdentity}
  @handshake_ms 5_000
  @request_ms 5_000

  def run(invitation, request, clock, approved_access \\ Codec.default_access()) do
    with {:ok, _} <- Codec.encode("invitation", invitation),
         {:ok, frame} <- Codec.encode_frame("request", request),
         true <- Codec.access?(approved_access),
         true <-
           Enum.all?(
             ~w(controller_id invitation_id bootstrap_secret),
             &(invitation[&1] == request[&1])
           ),
         {:ok, trust} <- TLSIdentity.new(invitation),
         {:ok, _} <- CertificateClock.bounds(clock),
         {:ok, _} <- TLSIdentity.options(trust, clock) do
      finite(fn parent, reference, deadline ->
        exchange(
          invitation["endpoint"],
          trust,
          request,
          frame,
          clock,
          approved_access,
          {parent, reference, deadline}
        )
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_controller_connection_record}
    end
  end

  # Isolate socket ownership and cap even an unexpectedly blocked platform call.
  # Killing this owner closes its socket. No timeout can start another exchange.
  defp finite(callback) do
    parent = self()
    reference = make_ref()
    deadline = System.monotonic_time(:millisecond) + @handshake_ms

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            callback.(parent, reference, deadline)
          rescue
            _ -> {:error, :outcome_unknown}
          catch
            _, _ -> {:error, :outcome_unknown}
          end

        send(parent, {reference, result})
      end)

    await(pid, monitor, reference, deadline, :tls_handshake_timeout)
  end

  defp await(pid, monitor, reference, deadline, timeout_reason) do
    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :outcome_unknown}

      {^reference, :authenticated, request_deadline} ->
        await(pid, monitor, reference, request_deadline, :outcome_unknown)
    after
      remaining(deadline) ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        flush(reference)
        {:error, timeout_reason}
    end
  end

  defp flush(reference) do
    receive do
      {^reference, _} -> flush(reference)
      {^reference, _, _} -> flush(reference)
    after
      0 -> :ok
    end
  end

  defp exchange(endpoint, trust, request, frame, clock, access, {parent, reference, deadline}) do
    notification = make_ref()

    with {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, options} <- TLSIdentity.options(trust, clock, {self(), notification}),
         {:ok, host, family, port} <- endpoint(endpoint),
         true <- remaining(deadline) > 0 do
      case :ssl.connect(host, port, [family | options], remaining(deadline)) do
        {:ok, socket} ->
          try do
            with :ok <- TLSIdentity.check_socket(socket, trust, clock),
                 true <- remaining(deadline) > 0 do
              request_deadline = System.monotonic_time(:millisecond) + @request_ms
              send(parent, {reference, :authenticated, request_deadline})
              send_and_receive(socket, request, frame, clock, access, request_deadline)
            else
              {:error, _} = error -> error
              _ -> {:error, :tls_handshake_timeout}
            end
          after
            :ssl.close(socket)
          end

        {:error, _} ->
          receive do
            {^notification, reason} -> {:error, reason}
          after
            0 ->
              {:error,
               if(remaining(deadline) == 0,
                 do: :tls_handshake_timeout,
                 else: :tls_peer_unverified
               )}
          end
      end
    else
      {:error, :tls_clock_uncertain} = error -> error
      {:error, :tls_client_interface_required} = error -> error
      false -> {:error, :tls_handshake_timeout}
      _ -> {:error, :tls_connection_unavailable}
    end
  end

  defp send_and_receive(socket, request, frame, clock, access, deadline) do
    # The last pre-send clock check follows successful TLS/name/pin validation.
    with {:ok, _} <- CertificateClock.bounds(clock) do
      with :ok <- :ssl.send(socket, frame),
           {:ok, header} <- :ssl.recv(socket, 4, remaining(deadline)),
           {:ok, size} <- Codec.frame_size(header),
           {:ok, body} <- :ssl.recv(socket, size, remaining(deadline)),
           true <- remaining(deadline) > 0,
           {:ok, _} <- CertificateClock.bounds(clock),
           {:ok, value} <- Codec.verify_response(body, request, access) do
        {:ok, value}
      else
        _ -> {:error, :outcome_unknown}
      end
    end
  end

  defp endpoint(["dns", name, port]) do
    # Resolve with the platform resolver inside the handshake owner/deadline.
    # Pick one address; neither a failed handshake nor a lost reply retries it.
    host = String.to_charlist(name)

    case :inet.getaddrs(host, :inet6) do
      {:ok, [address | _]} ->
        address_endpoint(address, :inet6, port)

      _ ->
        case :inet.getaddrs(host, :inet) do
          {:ok, [address | _]} -> address_endpoint(address, :inet, port)
          _ -> {:error, :tls_connection_unavailable}
        end
    end
  end

  defp endpoint([kind, name, port]) when kind in ["ipv4", "ipv6"] do
    with {:ok, address} <- :inet.parse_address(String.to_charlist(name)) do
      # Scope IDs belong to the client, not an invitation. Until that explicit
      # selection is composed, link-local IPv6 cannot fall back to another route.
      address_endpoint(address, if(kind == "ipv6", do: :inet6, else: :inet), port)
    end
  end

  defp endpoint(_), do: {:error, :invalid_controller_connection_record}

  defp address_endpoint({first, _, _, _, _, _, _, _}, _, _) when first in 0xFE80..0xFEBF,
    do: {:error, :tls_client_interface_required}

  defp address_endpoint(address, family, port), do: {:ok, address, family, port}
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
