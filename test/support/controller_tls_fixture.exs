defmodule WotexHome.TestSupport.ControllerTLSFixture do
  @moduledoc false
  # Independent peer: platform-generated synthetic certificates and literal
  # wire arrays. Never uses the client trust callback or production wire codec.
  def create(directory) do
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    ca = Path.join(directory, "ca.pem")
    ca_key = Path.join(directory, "ca.key")
    key = Path.join(directory, "peer.key")
    csr = Path.join(directory, "peer.csr")
    root(ca, ca_key)

    command([
      "req",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-keyout",
      key,
      "-out",
      csr,
      "-subj",
      "/CN=home.example"
    ])

    File.chmod!(key, 0o600)
    index = Path.join(directory, "index")
    serial = Path.join(directory, "serial")
    config = Path.join(directory, "ca.cnf")
    File.write!(index, "")
    File.write!(serial, "01\n")

    File.write!(config, """
    [ca]
    default_ca=fixture
    [fixture]
    database=#{index}
    new_certs_dir=#{directory}
    certificate=#{ca}
    private_key=#{ca_key}
    serial=#{serial}
    default_md=sha256
    policy=policy
    unique_subject=no
    [policy]
    commonName=supplied
    """)

    today = DateTime.utc_now()
    first = date(DateTime.add(today, -86_400))
    last = date(DateTime.add(today, 86_400))

    variants = [
      {"valid", "DNS:home.example,IP:127.0.0.1,IP:::1", "serverAuth", first, last, ""},
      {"changed", "DNS:home.example,IP:127.0.0.1,IP:::1", "serverAuth", first, last, ""},
      {"wrong_name", "DNS:rogue.example", "serverAuth", first, last, ""},
      {"common_name_only", nil, "serverAuth", first, last, ""},
      {"uri_name_only", "URI:https://home.example", "serverAuth", first, last, ""},
      {"wrong_purpose", "DNS:home.example", "clientAuth", first, last, ""},
      {"expired", "DNS:home.example", "serverAuth", "20200101000000Z", "20210101000000Z", ""},
      {"future", "DNS:home.example", "serverAuth", "20400101000000Z", "20410101000000Z", ""},
      {"unknown_critical", "DNS:home.example", "serverAuth", first, last,
       "1.2.3.4=critical,DER:01:01:FF\n"}
    ]

    certificates =
      Map.new(variants, fn {name, san, eku, lower, upper, extra} ->
        extensions = Path.join(directory, name <> ".ext")
        cert = Path.join(directory, name <> ".pem")

        File.write!(
          extensions,
          "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=#{eku}\n" <>
            if(san, do: "subjectAltName=#{san}\n", else: "") <> extra
        )

        command([
          "ca",
          "-config",
          config,
          "-batch",
          "-in",
          csr,
          "-startdate",
          lower,
          "-enddate",
          upper,
          "-out",
          cert,
          "-extfile",
          extensions,
          "-notext"
        ])

        {name, cert}
      end)

    other_ca = Path.join(directory, "other-ca.pem")
    other_key = Path.join(directory, "other-ca.key")
    root(other_ca, other_key)
    unknown = Path.join(directory, "unknown_ca.pem")

    command([
      "x509",
      "-req",
      "-in",
      csr,
      "-CA",
      other_ca,
      "-CAkey",
      other_key,
      "-CAcreateserial",
      "-out",
      unknown,
      "-days",
      "1",
      "-sha256",
      "-extfile",
      Path.join(directory, "valid.ext")
    ])

    der = der(certificates["valid"])
    size = byte_size(der) - 1
    <<prefix::binary-size(size), final>> = der
    corrupted = prefix <> <<Bitwise.bxor(final, 1)>>
    corrupt = Path.join(directory, "corrupt.pem")
    File.write!(corrupt, :public_key.pem_encode([{:Certificate, corrupted, :not_encrypted}]))

    %{
      directory: directory,
      ca: der(ca),
      key: key,
      certificates: Map.merge(certificates, %{"unknown_ca" => unknown, "corrupt" => corrupt})
    }
  end

  defp root(cert, key) do
    command([
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-keyout",
      key,
      "-out",
      cert,
      "-sha256",
      "-days",
      "2",
      "-subj",
      "/CN=Controller Fixture CA",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign"
    ])

    File.chmod!(key, 0o600)
  end

  defp command(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> raise "synthetic controller certificate generation failed"
    end
  end

  defp date(value), do: Calendar.strftime(value, "%Y%m%d%H%M%SZ")

  def der(path) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(path))
    der
  end

  def invitation(fixture, port, variant \\ "valid", identity \\ ["dns", "home.example"]) do
    %{
      "controller_id" => String.duplicate("1", 64),
      "identity" => identity,
      "leaf_pin" => hash(der(fixture.certificates[variant])),
      "trust_anchor" => Base.url_encode64(fixture.ca, padding: false),
      "endpoint" => ["ipv4", "127.0.0.1", port],
      "invitation_id" => String.duplicate("2", 64),
      "bootstrap_secret" => Base.url_encode64(:binary.copy(<<3>>, 32), padding: false)
    }
  end

  def request do
    %{
      "controller_id" => String.duplicate("1", 64),
      "invitation_id" => String.duplicate("2", 64),
      "client_id" => String.duplicate("4", 64),
      "request_id" => String.duplicate("5", 64),
      "client_label" => "Fixture client",
      "bootstrap_secret" => Base.url_encode64(:binary.copy(<<3>>, 32), padding: false)
    }
  end

  def request_body do
    q = request()

    JSON.encode!([
      "wotex-home.controller-bootstrap-request.v1",
      1,
      q["controller_id"],
      q["invitation_id"],
      q["client_id"],
      q["request_id"],
      Base.url_encode64(q["client_label"], padding: false),
      q["bootstrap_secret"]
    ])
  end

  def invitation_body(invitation) do
    JSON.encode!([
      "wotex-home.controller-invitation.v1",
      1,
      invitation["controller_id"],
      invitation["identity"],
      invitation["leaf_pin"],
      invitation["trust_anchor"],
      invitation["endpoint"],
      invitation["invitation_id"],
      invitation["bootstrap_secret"]
    ])
  end

  def response(mode \\ :paired) do
    q = request()

    payload =
      case mode do
        :refused ->
          ["refused", "confirmation_denied"]

        :widened ->
          [
            "paired",
            String.duplicate("6", 64),
            String.duplicate("7", 64),
            1,
            "paired-client",
            1,
            ["host:maintain", "read"],
            [],
            Base.url_encode64(:binary.copy(<<8>>, 32), padding: false)
          ]

        _ ->
          [
            "paired",
            String.duplicate("6", 64),
            String.duplicate("7", 64),
            1,
            "paired-client",
            1,
            ["read"],
            [],
            Base.url_encode64(:binary.copy(<<8>>, 32), padding: false)
          ]
      end

    digest = if mode == :wrong_digest, do: String.duplicate("0", 64), else: hash(request_body())

    JSON.encode!([
      "wotex-home.controller-bootstrap-response.v1",
      1,
      q["controller_id"],
      q["invitation_id"],
      q["client_id"],
      q["request_id"],
      digest,
      payload
    ])
  end

  def hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  def peer(fixture, variant \\ "valid", mode \\ :paired, opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    {:ok, listener} =
      :ssl.listen(0, [
        family,
        :binary,
        active: false,
        ip: ip,
        certfile: String.to_charlist(fixture.certificates[variant]),
        keyfile: String.to_charlist(fixture.key),
        reuseaddr: true,
        log_level: :none,
        versions: Keyword.get(opts, :versions, [:"tlsv1.3"]),
        session_tickets: :disabled,
        early_data: :disabled
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :ssl.transport_accept(listener, 7_000)

          try do
            case :ssl.handshake(socket, 7_000) do
              {:ok, ready} ->
                case receive_request(ready) do
                  {:ok, body} ->
                    send_response(ready, mode)

                    case :ssl.transport_accept(listener, 150) do
                      {:error, :timeout} ->
                        {:request, body}

                      {:ok, repeated} ->
                        :ssl.close(repeated)
                        :repeated_connection

                      _ ->
                        :peer_failure
                    end

                  _ ->
                    :no_application_bytes
                end

              _ ->
                :no_application_bytes
            end
          after
            :ssl.close(socket)
          end
        after
          :ssl.close(listener)
        end
      end)

    {port, task}
  end

  defp receive_request(socket) do
    with {:ok, <<size::32>>} <- :ssl.recv(socket, 4, 7_000),
         true <- size in 1..8_192,
         {:ok, body} <- :ssl.recv(socket, size, 7_000),
         do: {:ok, body}
  end

  defp send_response(_, :lost), do: :ok

  defp send_response(socket, :slow_header) do
    :ok = :ssl.send(socket, <<0>>)
    :ssl.recv(socket, 1, 7_000)
  end

  defp send_response(socket, :slow_body) do
    :ok = :ssl.send(socket, <<100::32, "[">>)
    :ssl.recv(socket, 1, 7_000)
  end

  defp send_response(socket, :oversize), do: :ssl.send(socket, <<8_193::32>>)
  defp send_response(socket, :empty), do: :ssl.send(socket, <<0::32>>)
  defp send_response(socket, :truncated), do: :ssl.send(socket, <<100::32, "[">>)

  defp send_response(socket, mode) do
    body = response(mode)

    if mode == :fragmented do
      for byte <- :binary.bin_to_list(<<byte_size(body)::32, body::binary>>),
          do: :ssl.send(socket, <<byte>>)
    else
      :ssl.send(socket, <<byte_size(body)::32, body::binary>>)
    end
  end
end
