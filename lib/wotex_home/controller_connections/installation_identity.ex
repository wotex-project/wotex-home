defmodule WotexHome.ControllerConnections.InstallationIdentity do
  @moduledoc """
  Explicit, immutable per-install controller TLS custody.

  Trusted local setup supplies a certificate interval in whole UTC seconds.
  Creation publishes one private record, never replaces it and starts no host
  or listener. Reading checks the closed certificate/key profile independently
  of its current validity; serving additionally requires normal OTP validation.
  This material grants no principal, Thing permission or clock qualification.
  """
  require Record
  alias WotexHome.Profiles.Codec, as: Profiles
  alias WotexHome.Recovery.PrivateFile

  for tag <- [
        :OTPCertificate,
        :OTPTBSCertificate,
        :OTPSubjectPublicKeyInfo,
        :PublicKeyAlgorithm,
        :SignatureAlgorithm,
        :Validity,
        :Extension,
        :BasicConstraints,
        :ECPrivateKey
      ] do
    Record.defrecordp(
      Macro.underscore(Atom.to_string(tag)) |> String.to_atom(),
      tag,
      Record.extract(tag, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
    )
  end

  @format "wotex-home.controller-installation-identity.v1"
  @maximum 8_192
  @last_utc 253_402_300_799
  @maximum_span 366 * 86_400
  @curve {1, 2, 840, 10045, 3, 1, 7}
  @signature {1, 2, 840, 10045, 4, 3, 2}
  @ec {1, 2, 840, 10045, 2, 1}
  @enforce_keys [:controller_id, :name, :first, :last, :leaf, :anchor, :key, :seal]
  defstruct @enforce_keys

  def create(path, %{not_before: first, not_after: last} = interval)
      when map_size(interval) == 2 do
    if interval?(first, last) do
      create_record(path, first, last)
    else
      {:error, :invalid_controller_certificate_interval}
    end
  end

  def create(_, _), do: {:error, :invalid_controller_certificate_interval}

  def read(path) do
    with {:ok, bytes, seal} <- PrivateFile.read_sealed(path, @maximum),
         {:ok, identity} <- decode(bytes, seal),
         do: {:ok, identity},
         else: (_ -> unavailable())
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def check(%__MODULE__{seal: %PrivateFile.Seal{path: path}} = original) do
    with {:ok, ^original} <- read(path), do: :ok, else: (_ -> unavailable())
  end

  def check(_), do: unavailable()

  def descriptor(%__MODULE__{} = identity) do
    with :ok <- check(identity) do
      {:ok,
       %{
         "controller_id" => identity.controller_id,
         "identity" => ["dns", identity.name],
         "leaf_pin" => digest(identity.leaf),
         "trust_anchor" => Base.url_encode64(identity.anchor, padding: false)
       }}
    end
  end

  def descriptor(_), do: unavailable()

  # Only the trusted socket owner receives these secret-bearing OTP options.
  # Never include them in diagnostics, application responses or discovery.
  def server_options(%__MODULE__{} = identity) do
    with :ok <- check(identity),
         {:ok, _} <- :public_key.pkix_path_validation(identity.anchor, [identity.leaf], []),
         now = System.os_time(:second),
         true <- identity.first <= now and now <= identity.last do
      {:ok,
       [
         cert: identity.leaf,
         key: {:ECPrivateKey, identity.key},
         versions: [:"tlsv1.3"],
         session_tickets: :disabled,
         early_data: :disabled,
         max_handshake_size: 65_536,
         log_level: :none,
         active: false,
         mode: :binary,
         packet: 0,
         send_timeout: 1_000,
         send_timeout_close: true
       ]}
    else
      {:error, :controller_identity_unavailable} = error -> error
      _ -> {:error, :controller_certificate_invalid}
    end
  rescue
    _ -> {:error, :controller_certificate_invalid}
  catch
    _, _ -> {:error, :controller_certificate_invalid}
  end

  def server_options(_), do: unavailable()

  defp create_record(path, first, last) do
    controller = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    name = service_name(controller)
    ca = :public_key.generate_key({:namedCurve, @curve})
    key = :public_key.generate_key({:namedCurve, @curve})
    anchor = certificate(ca, ca, controller, name, first, last, true)
    leaf = certificate(key, ca, controller, name, first, last, false)
    encoded_key = :public_key.der_encode(:ECPrivateKey, key)

    bytes =
      JSON.encode!([
        @format,
        controller,
        ["dns", name],
        first,
        last,
        encode64(leaf),
        encode64(anchor),
        encode64(encoded_key)
      ])

    with {:ok, _} <- decode(bytes, nil),
         :ok <- PrivateFile.write(path, bytes, @maximum),
         do: read(path)
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp decode(bytes, seal) do
    with true <- String.valid?(bytes),
         {[@format, controller, ["dns", name], first, last, leaf, anchor, key] = record,
          {0, 0, []}, ""} <- JSON.decode(bytes, {0, 0, []}, decoders()),
         true <- JSON.encode!(record) == bytes,
         true <- Profiles.digest?(controller) and name == service_name(controller),
         true <- interval?(first, last),
         {:ok, leaf} <- decode64(leaf, 2_048),
         {:ok, anchor} <- decode64(anchor, 2_048),
         {:ok, key} <- decode64(key, 256),
         true <- certificates?(controller, name, first, last, leaf, anchor, key) do
      {:ok,
       %__MODULE__{
         controller_id: controller,
         name: name,
         first: first,
         last: last,
         leaf: leaf,
         anchor: anchor,
         key: key,
         seal: seal
       }}
    else
      _ -> unavailable()
    end
  end

  defp certificates?(controller, name, first, last, leaf, anchor, key_der) do
    ca = :public_key.pkix_decode_cert(anchor, :otp)
    server = :public_key.pkix_decode_cert(leaf, :otp)
    key = :public_key.der_decode(:ECPrivateKey, key_der)
    ca_tbs = otp_certificate(ca, :tbsCertificate)
    leaf_tbs = otp_certificate(server, :tbsCertificate)
    ca_public = public_key(ca_tbs)
    leaf_public = public_key(leaf_tbs)

    :public_key.pkix_encode(:OTPCertificate, ca, :otp) == anchor and
      :public_key.pkix_encode(:OTPCertificate, server, :otp) == leaf and
      :public_key.der_encode(:ECPrivateKey, key) == key_der and
      certificate_profile?(ca, controller, name, first, last, true) and
      certificate_profile?(server, controller, name, first, last, false) and
      ca_public != leaf_public and
      :public_key.pkix_verify(anchor, ca_public) and
      :public_key.pkix_verify(leaf, ca_public) and
      key_profile?(key) and key_matches?(key, leaf_public)
  end

  defp certificate_profile?(cert, controller, name, first, last, ca?) do
    tbs = otp_certificate(cert, :tbsCertificate)
    serial = otptbs_certificate(tbs, :serialNumber)
    info = otptbs_certificate(tbs, :subjectPublicKeyInfo)
    {:ECPoint, point} = otp_subject_public_key_info(info, :subjectPublicKey)

    otptbs_certificate(tbs, :version) == :v3 and
      is_integer(serial) and serial in 1..340_282_366_920_938_463_463_374_607_431_768_211_455 and
      otp_certificate(cert, :signatureAlgorithm) == signature_algorithm(algorithm: @signature) and
      otptbs_certificate(tbs, :signature) == signature_algorithm(algorithm: @signature) and
      otptbs_certificate(tbs, :issuer) == subject(controller, name, true) and
      otptbs_certificate(tbs, :subject) == subject(controller, name, ca?) and
      otptbs_certificate(tbs, :validity) == span(first, last) and
      otptbs_certificate(tbs, :issuerUniqueID) == :asn1_NOVALUE and
      otptbs_certificate(tbs, :subjectUniqueID) == :asn1_NOVALUE and
      otptbs_certificate(tbs, :extensions) == extensions(ca?, name) and
      otp_subject_public_key_info(info, :algorithm) ==
        public_key_algorithm(algorithm: @ec, parameters: {:namedCurve, @curve}) and
      is_binary(point) and byte_size(point) == 65 and binary_part(point, 0, 1) == <<4>>
  end

  defp key_profile?(key),
    do:
      ec_private_key(key, :version) == :ecPrivkeyVer1 and
        ec_private_key(key, :parameters) == {:namedCurve, @curve} and
        ec_private_key(key, :attributes) == :asn1_NOVALUE and
        byte_size(ec_private_key(key, :privateKey)) == 32 and
        byte_size(ec_private_key(key, :publicKey)) == 65

  defp key_matches?(key, public) do
    challenge = :crypto.strong_rand_bytes(32)

    {:ECPoint, ec_private_key(key, :publicKey)} == elem(public, 0) and
      :public_key.verify(challenge, :sha256, :public_key.sign(challenge, :sha256, key), public)
  end

  defp public_key(tbs) do
    info = otptbs_certificate(tbs, :subjectPublicKeyInfo)
    {otp_subject_public_key_info(info, :subjectPublicKey), {:namedCurve, @curve}}
  end

  defp certificate(key, signer, controller, name, first, last, ca?) do
    # The high bit keeps the random serial positive and nonzero, below 2^128.
    <<_bit::1, rest::127>> = :crypto.strong_rand_bytes(16)

    tbs =
      otptbs_certificate(
        version: :v3,
        serialNumber: Bitwise.bor(rest, Bitwise.bsl(1, 127)),
        signature: signature_algorithm(algorithm: @signature),
        issuer: subject(controller, name, true),
        subject: subject(controller, name, ca?),
        validity: span(first, last),
        subjectPublicKeyInfo:
          otp_subject_public_key_info(
            algorithm: public_key_algorithm(algorithm: @ec, parameters: {:namedCurve, @curve}),
            subjectPublicKey: {:ECPoint, ec_private_key(key, :publicKey)}
          ),
        extensions: extensions(ca?, name)
      )

    :public_key.pkix_sign(tbs, signer)
  end

  defp subject(controller, name, ca?),
    do:
      {:rdnSequence,
       [
         [
           {:AttributeTypeAndValue, {2, 5, 4, 3},
            {:utf8String, if(ca?, do: "WoTEx Home anchor", else: name)}}
         ],
         [
           {:AttributeTypeAndValue, {2, 5, 4, 5}, String.to_charlist(controller)}
         ]
       ]}

  defp extensions(ca?, name) do
    [
      extension(
        extnID: {2, 5, 29, 19},
        critical: true,
        extnValue:
          basic_constraints(cA: ca?, pathLenConstraint: if(ca?, do: 0, else: :asn1_NOVALUE))
      ),
      extension(
        extnID: {2, 5, 29, 15},
        critical: true,
        extnValue: if(ca?, do: [:keyCertSign, :cRLSign], else: [:digitalSignature])
      )
    ] ++
      if ca?,
        do: [],
        else: [
          extension(
            extnID: {2, 5, 29, 37},
            critical: false,
            extnValue: [{1, 3, 6, 1, 5, 5, 7, 3, 1}]
          ),
          extension(
            extnID: {2, 5, 29, 17},
            critical: false,
            extnValue: [{:dNSName, String.to_charlist(name)}]
          )
        ]
  end

  defp span(first, last),
    do: validity(notBefore: time(first), notAfter: time(last))

  defp time(seconds) do
    date = DateTime.from_unix!(seconds)

    if date.year < 2050,
      do: {:utcTime, Calendar.strftime(date, "%y%m%d%H%M%SZ") |> String.to_charlist()},
      else: {:generalTime, Calendar.strftime(date, "%Y%m%d%H%M%SZ") |> String.to_charlist()}
  end

  defp interval?(first, last),
    do:
      is_integer(first) and is_integer(last) and first in 0..@last_utc and
        last > first and last <= @last_utc and last - first <= @maximum_span

  defp service_name(controller), do: "home-" <> binary_part(controller, 0, 32) <> ".local"
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp encode64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode64(value, maximum) when is_binary(value) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- byte_size(bytes) in 1..maximum and encode64(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> unavailable())
  end

  defp decode64(_, _), do: unavailable()

  defp decoders do
    [
      array_start: fn
        {depth, _, _} when depth < 2 -> {depth + 1, 0, []}
        _ -> reject()
      end,
      array_push: fn
        value, {depth, count, values} when count < 8 -> {depth, count + 1, [value | values]}
        _, _ -> reject()
      end,
      array_finish: fn {_, _, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: fn _ -> reject() end,
      string: fn value -> if byte_size(value) <= 2_731, do: value, else: reject() end,
      integer: fn value ->
        if byte_size(value) <= 12 do
          number = String.to_integer(value)
          if number in 0..@last_utc, do: number, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end

  defp unavailable, do: {:error, :controller_identity_unavailable}
  defp reject, do: throw(:controller_identity_unavailable)
end

defimpl Inspect, for: WotexHome.ControllerConnections.InstallationIdentity do
  def inspect(_, _), do: Inspect.Algebra.string("#ControllerInstallationIdentity<private>")
end
