defmodule WotexHome.ControllerConnections.TLSIdentity do
  @moduledoc """
  Closed controller TLS trust, with no bootstrap secret or bearer in TLS state.

  OTP validates the chain, purpose, signature and current wall-clock validity.
  The verify callback never overrides a bad certificate. SAN identity, the
  complete leaf DER pin and a live uncertainty interval are additional checks.
  """
  alias WotexHome.ControllerConnections.{CertificateClock, Codec}
  @enforce_keys [:controller, :identity, :pin, :anchor]
  defstruct @enforce_keys

  def new(invitation) do
    with {:ok, _} <- Codec.encode("invitation", invitation),
         {:ok, anchor} <- Base.url_decode64(invitation["trust_anchor"], padding: false),
         certificate <- :public_key.pkix_decode_cert(anchor, :otp),
         true <- :public_key.pkix_encode(:OTPCertificate, certificate, :otp) == anchor do
      {:ok,
       %__MODULE__{
         controller: invitation["controller_id"],
         identity: invitation["identity"],
         pin: invitation["leaf_pin"],
         anchor: anchor
       }}
    else
      _ -> {:error, :invalid_controller_tls_trust}
    end
  rescue
    _ -> {:error, :invalid_controller_tls_trust}
  catch
    _, _ -> {:error, :invalid_controller_tls_trust}
  end

  def options(trust, clock, notification \\ nil)

  def options(%__MODULE__{} = trust, clock, notification) do
    with {:ok, _} <- CertificateClock.bounds(clock),
         true <- CertificateClock.covers?(trust.anchor, clock) do
      [kind, identity] = trust.identity

      {:ok,
       [
         verify: :verify_peer,
         cacerts: [trust.anchor],
         versions: [:"tlsv1.3"],
         server_name_indication:
           if(kind == "dns", do: String.to_charlist(identity), else: :disable),
         verify_fun:
           {&__MODULE__.verify/4, %{trust: trust, clock: clock, notification: notification}},
         session_tickets: :disabled,
         depth: 4,
         max_handshake_size: 65_536,
         log_level: :none,
         active: false,
         mode: :binary,
         packet: 0,
         send_timeout: 1_000,
         send_timeout_close: true
       ]}
    else
      _ -> {:error, :tls_clock_uncertain}
    end
  end

  def options(_, _, _), do: {:error, :invalid_controller_tls_trust}

  @doc false
  def verify(_certificate, _der, {:bad_cert, _} = error, state),
    do: fail(error, :tls_peer_unverified, state)

  def verify(_certificate, _der, {:extension, _}, state), do: {:unknown, state}

  def verify(certificate, der, event, state) when event in [:valid, :valid_peer] do
    cond do
      not CertificateClock.covers?(certificate, state.clock) ->
        fail({:bad_cert, :tls_clock_uncertain}, :tls_clock_uncertain, state)

      event == :valid_peer and not name?(certificate, state.trust.identity) ->
        fail({:bad_cert, :hostname_check_failed}, :tls_peer_unverified, state)

      event == :valid_peer and digest(der) != state.trust.pin ->
        fail({:bad_cert, :tls_pin_changed}, :tls_pin_changed, state)

      true ->
        {:valid, state}
    end
  rescue
    _ -> fail({:bad_cert, :invalid_certificate}, :tls_peer_unverified, state)
  catch
    _, _ -> fail({:bad_cert, :invalid_certificate}, :tls_peer_unverified, state)
  end

  def verify(_, _, _, state),
    do: fail({:bad_cert, :invalid_certificate}, :tls_peer_unverified, state)

  def check_socket(socket, %__MODULE__{} = trust, clock) do
    with {:ok, _} <- CertificateClock.bounds(clock),
         {:ok, [protocol: :"tlsv1.3"]} <- :ssl.connection_information(socket, [:protocol]),
         {:ok, der} <- :ssl.peercert(socket),
         true <- name?(der, trust.identity) do
      cond do
        digest(der) != trust.pin ->
          {:error, :tls_pin_changed}

        not CertificateClock.covers?(der, clock) or
            not CertificateClock.covers?(trust.anchor, clock) ->
          {:error, :tls_clock_uncertain}

        true ->
          :ok
      end
    else
      {:error, :tls_clock_uncertain} = error -> error
      _ -> {:error, :tls_peer_unverified}
    end
  rescue
    _ -> {:error, :tls_peer_unverified}
  catch
    _, _ -> {:error, :tls_peer_unverified}
  end

  defp name?(cert, ["dns", name]),
    do:
      :public_key.pkix_verify_hostname(cert, [{:dns_id, String.to_charlist(name)}],
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )

  defp name?(cert, [kind, name]) when kind in ["ipv4", "ipv6"],
    do: :public_key.pkix_verify_hostname(cert, [{:ip, String.to_charlist(name)}])

  defp name?(_, _), do: false
  defp digest(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  defp fail(error, reason, state) do
    case state.notification do
      {pid, reference} when is_pid(pid) and is_reference(reference) ->
        send(pid, {reference, reason})

      _ ->
        :ok
    end

    {:fail, error}
  end
end

defimpl Inspect, for: WotexHome.ControllerConnections.TLSIdentity do
  def inspect(_, _), do: Inspect.Algebra.string("#ControllerTLSIdentity<private>")
end
