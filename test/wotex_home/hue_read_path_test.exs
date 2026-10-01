defmodule WotexHome.HueReadPathTest do
  use ExUnit.Case
  alias WotexHome.Hue.{BridgeTLS, ReadInputs, ReadPath}
  alias WotexHome.Lifx.IPv4Scope
  @bridge "0123456789abcdef"
  @key "fixture_key_1234567890"

  setup_all do
    directory = Path.join(System.tmp_dir!(), "woh-hue-tls-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    cert = Path.join(directory, "peer.pem")
    key = Path.join(directory, "peer.key")
    ca = Path.join(directory, "ca.pem")
    ca_key = Path.join(directory, "ca.key")
    csr = Path.join(directory, "peer.csr")
    extensions = Path.join(directory, "peer.ext")

    File.write!(
      extensions,
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:#{@bridge}\n"
    )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          ca_key,
          "-out",
          ca,
          "-sha256",
          "-days",
          "1",
          "-subj",
          "/CN=Home Fixture CA"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-new",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key,
          "-out",
          csr,
          "-subj",
          "/CN=#{@bridge}"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csr,
          "-CA",
          ca,
          "-CAkey",
          ca_key,
          "-CAcreateserial",
          "-out",
          cert,
          "-days",
          "1",
          "-sha256",
          "-extfile",
          extensions
        ],
        stderr_to_stdout: true
      )

    legacy = Path.join(directory, "legacy.pem")
    legacy_ext = Path.join(directory, "legacy.ext")

    File.write!(
      legacy_ext,
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
    )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csr,
          "-CA",
          ca,
          "-CAkey",
          ca_key,
          "-CAcreateserial",
          "-out",
          legacy,
          "-days",
          "1",
          "-sha256",
          "-extfile",
          legacy_ext
        ],
        stderr_to_stdout: true
      )

    wrong_san = Path.join(directory, "wrong-san.pem")
    expired = Path.join(directory, "expired.pem")
    wrong_ext = Path.join(directory, "wrong-san.ext")
    File.write!(wrong_ext, File.read!(extensions) |> String.replace(@bridge, "ffffffffffffffff"))

    for {destination, days, ext} <- [{wrong_san, "1", wrong_ext}] do
      {_, 0} =
        System.cmd(
          "openssl",
          [
            "x509",
            "-req",
            "-in",
            csr,
            "-CA",
            ca,
            "-CAkey",
            ca_key,
            "-CAcreateserial",
            "-out",
            destination,
            "-days",
            days,
            "-sha256",
            "-extfile",
            ext
          ],
          stderr_to_stdout: true
        )
    end

    index = Path.join(directory, "index")
    serial = Path.join(directory, "serial")
    config = Path.join(directory, "ca.cnf")
    File.write!(index, "")
    File.write!(serial, "01\n")

    File.write!(
      config,
      "[ca]\ndefault_ca=fixture\n[fixture]\ndatabase=#{index}\nnew_certs_dir=#{directory}\ncertificate=#{ca}\nprivate_key=#{ca_key}\nserial=#{serial}\ndefault_md=sha256\npolicy=policy\n[policy]\ncommonName=supplied\n[server]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
    )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "ca",
          "-config",
          config,
          "-batch",
          "-in",
          csr,
          "-startdate",
          "20200101000000Z",
          "-enddate",
          "20210101000000Z",
          "-out",
          expired,
          "-extensions",
          "server",
          "-notext"
        ],
        stderr_to_stdout: true
      )

    File.chmod!(key, 0o600)
    File.chmod!(ca_key, 0o600)
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(cert))
    [{:Certificate, ca_der, :not_encrypted}] = :public_key.pem_decode(File.read!(ca))

    trust = %{
      bridge_id: @bridge,
      ca_der: ca_der,
      peer_sha256: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)
    }

    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 8)

    %{
      cert: cert,
      legacy: legacy,
      wrong_san: wrong_san,
      expired: expired,
      key: key,
      ca: ca,
      directory: directory,
      trust: trust,
      scope: scope
    }
  end

  @tag requires_socket: true
  test "verified selected TLS peer receives exactly one read with the resolved key", c do
    {port, task} = peer(c, 200, ~s({"errors":[],"data":[]}))
    assert {:ok, []} = ReadPath.run(c.scope, {127, 0, 0, 1}, port, c.trust, @key, :lights)
    assert {:request, bytes} = Task.await(task)
    assert bytes =~ "GET /clip/v2/resource/light HTTP/1.1\r\n"
    assert bytes =~ "hue-application-key: #{@key}\r\n"
    refute bytes =~ "POST"
    refute bytes =~ "PUT"
  end

  @tag requires_socket: true
  test "changed certificate pin sends no HTTP or application key", c do
    {port, task} = peer(c, 200, ~s({"errors":[],"data":[]}))
    trust = %{c.trust | peer_sha256: String.duplicate("0", 64)}

    assert {:error, :bridge_identity_changed} =
             ReadPath.run(c.scope, {127, 0, 0, 1}, port, trust, @key, :lights)

    assert :no_http = Task.await(task)
  end

  @tag requires_socket: true
  test "a CA-verified legacy CN requires the exact pin and exact bridge ID", c do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(c.legacy))
    trust = %{c.trust | peer_sha256: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)}
    legacy = %{c | cert: c.legacy}
    {port, task} = peer(legacy, 200, ~s({"errors":[],"data":[]}))
    assert {:ok, []} = ReadPath.run(c.scope, {127, 0, 0, 1}, port, trust, @key, :lights)
    assert {:request, _} = Task.await(task)

    for bad <- [
          %{trust | bridge_id: "ffffffffffffffff"},
          %{trust | peer_sha256: String.duplicate("0", 64)}
        ] do
      {port, task} = peer(legacy, 200, ~s({"errors":[],"data":[]}))

      assert {:error, :tls_unverified} =
               ReadPath.run(c.scope, {127, 0, 0, 1}, port, bad, @key, :lights)

      assert :no_http = Task.await(task)
    end
  end

  @tag requires_socket: true
  test "matching CN and exact pin cannot forgive a SAN mismatch or expiry", c do
    for certificate <- [c.wrong_san, c.expired] do
      [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(certificate))
      trust = %{c.trust | peer_sha256: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)}
      {port, task} = peer(%{c | cert: certificate}, 200, ~s({"errors":[],"data":[]}))

      assert {:error, :tls_unverified} =
               ReadPath.run(c.scope, {127, 0, 0, 1}, port, trust, @key, :lights)

      assert :no_http = Task.await(task)
    end
  end

  @tag requires_socket: true
  test "a different bridge hostname fails TLS before any key leaves the client", c do
    {port, task} = peer(c, 200, ~s({"errors":[],"data":[]}))
    trust = %{c.trust | bridge_id: "ffffffffffffffff"}

    assert {:error, :tls_unverified} =
             ReadPath.run(c.scope, {127, 0, 0, 1}, port, trust, @key, :lights)

    assert :no_http = Task.await(task)
  end

  @tag requires_socket: true
  test "authentication, redirects and response ceilings fail without retry", c do
    for {status, body, error} <- [
          {403, "", :authentication_required},
          {302, "", :unexpected_http_status},
          {200, String.duplicate("x", 262_145), :response_too_large}
        ] do
      {port, task} = peer(c, status, body)

      assert {:error, ^error} =
               ReadPath.run(c.scope, {127, 0, 0, 1}, port, c.trust, @key, :lights)

      assert {:request, _} = Task.await(task)
    end
  end

  test "unreviewed inputs, key injection and out-of-scope addresses cannot connect", c do
    assert {:error, :invalid_bridge_trust} = BridgeTLS.options(%{c.trust | ca_der: "garbage"})

    assert {:error, :invalid_bridge_trust} =
             BridgeTLS.options(Map.put(c.trust, :verify, :verify_none))

    assert {:error, :invalid_read_target} =
             ReadPath.run(c.scope, {192, 168, 1, 2}, 443, c.trust, @key, :lights)

    assert {:error, :invalid_read_target} =
             ReadPath.run(c.scope, {127, 0, 0, 1}, 443, c.trust, @key <> "\r\nX: y", :lights)
  end

  test "lab key files are private, bounded and cannot be replaced with a symlink", c do
    key = Path.join(c.directory, "application-key-#{System.unique_integer([:positive])}")
    File.write!(key, @key <> "\n")
    File.chmod!(key, 0o600)
    assert {:ok, trust, @key} = ReadInputs.load(c.ca, key, @bridge, c.trust.peer_sha256)
    assert trust == c.trust
    File.chmod!(key, 0o644)

    assert {:error, :invalid_hue_input_file} =
             ReadInputs.load(c.ca, key, @bridge, c.trust.peer_sha256)

    File.chmod!(key, 0o600)
    link = key <> ".link"
    File.ln_s!(key, link)

    assert {:error, :invalid_hue_input_file} =
             ReadInputs.load(c.ca, link, @bridge, c.trust.peer_sha256)

    File.write!(key, @key <> "\r\nOther: header")

    assert {:error, :invalid_hue_input_file} =
             ReadInputs.load(c.ca, key, @bridge, c.trust.peer_sha256)
  end

  defp peer(c, status, body) do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        certfile: String.to_charlist(c.cert),
        keyfile: String.to_charlist(c.key),
        reuseaddr: true
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :ssl.transport_accept(listener, 2_000)

          try do
            case :ssl.handshake(socket, 2_000) do
              {:ok, ready} ->
                case request(ready, "") do
                  {:ok, bytes} ->
                    response =
                      "HTTP/1.1 #{status} Fixture\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
                        body

                    _ = :ssl.send(ready, response)
                    {:request, bytes}

                  _ ->
                    :no_http
                end

              _ ->
                :no_http
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

  defp request(socket, bytes) when byte_size(bytes) <= 4_096 do
    if String.contains?(bytes, "\r\n\r\n") do
      {:ok, bytes}
    else
      case :ssl.recv(socket, 0, 2_000) do
        {:ok, chunk} -> request(socket, bytes <> chunk)
        error -> error
      end
    end
  end
end
