defmodule WotexHome.Hue.BridgeTLS do
  @moduledoc """
  Explicit trust inputs for a selected local Hue bridge.

  Provision a reviewed bridge ID, CA certificate DER and exact peer SHA-256
  fingerprint before resolving an application key. Discovery cannot mint these
  inputs. OTP verifies the chain, validity and bridge-ID hostname; a second
  exact certificate check precedes every authenticated HTTP request. Certificate
  rotation requires a new review. No global trust setting or downgrade exists.
  """
  alias WotexHome.Hue.V2
  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :attribute,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @keys ~w(bridge_id ca_der peer_sha256)a

  def options(trust) when is_map(trust) do
    with true <- Enum.sort(Map.keys(trust)) == @keys,
         true <- V2.bridge_id?(trust.bridge_id),
         true <- is_binary(trust.peer_sha256) and trust.peer_sha256 =~ ~r/\A[0-9a-f]{64}\z/,
         true <- is_binary(trust.ca_der) and byte_size(trust.ca_der) in 1..16_384,
         _certificate <- :public_key.pkix_decode_cert(trust.ca_der, :otp) do
      {:ok,
       [
         verify: :verify_peer,
         cacerts: [trust.ca_der],
         server_name_indication: String.to_charlist(trust.bridge_id),
         verify_fun: {&__MODULE__.verify/3, trust},
         versions: [:"tlsv1.3", :"tlsv1.2"]
       ]}
    else
      _ -> {:error, :invalid_bridge_trust}
    end
  rescue
    _ -> {:error, :invalid_bridge_trust}
  catch
    _, _ -> {:error, :invalid_bridge_trust}
  end

  def options(_), do: {:error, :invalid_bridge_trust}

  @doc false
  def verify(cert, {:bad_cert, :hostname_check_failed} = reason, trust) do
    if legacy_identity?(cert, trust), do: {:valid, trust}, else: {:fail, reason}
  end

  def verify(_cert, {:bad_cert, _} = reason, _trust), do: {:fail, reason}
  def verify(_cert, {:extension, _}, trust), do: {:unknown, trust}
  def verify(_cert, event, trust) when event in [:valid, :valid_peer], do: {:valid, trust}

  # Older BSB002 certificates have a bridge-ID CN and no SAN. OTP 28 no
  # longer matches CN implicitly. This exact pinned peer exception accepts
  # only missing SAN, never a mismatching SAN or another validation error.
  defp legacy_identity?(cert, trust) do
    raw = :public_key.pkix_encode(:OTPCertificate, cert, :otp)
    digest = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    record = certificate(cert, :tbsCertificate)
    {:rdnSequence, subject} = tbs(record, :subject)

    names =
      for rdn <- subject,
          attr <- rdn,
          attribute(attr, :type) == {2, 5, 4, 3},
          do: attribute(attr, :value)

    extensions = tbs(record, :extensions)

    no_san =
      extensions == :asn1_NOVALUE or
        (is_list(extensions) and
           Enum.all?(extensions, &(extension(&1, :extnID) != {2, 5, 29, 17})))

    digest == trust.peer_sha256 and no_san and Enum.map(names, &cn/1) == [trust.bridge_id]
  rescue
    _ -> false
  end

  defp cn({:utf8String, name}) when is_binary(name), do: name
  defp cn({:printableString, name}) when is_list(name), do: to_string(name)
  defp cn(_), do: nil

  def check_socket(socket, local, trust) do
    with {:ok, _} <- options(trust),
         {:ok, {^local, port}} when port > 0 <- :ssl.sockname(socket),
         {:ok, certificate} <- :ssl.peercert(socket),
         digest = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower),
         true <- digest == trust.peer_sha256 do
      :ok
    else
      _ -> {:error, :bridge_identity_changed}
    end
  end
end
