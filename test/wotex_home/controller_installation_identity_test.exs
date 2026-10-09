defmodule WotexHome.ControllerInstallationIdentityTest do
  use ExUnit.Case, async: true
  import Bitwise
  require Record
  alias WotexHome.ControllerConnections.{CertificateClock, InstallationIdentity, TLSIdentity}
  alias WotexHome.Recovery.PrivateFile

  Record.defrecordp(
    :ec_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-installation-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    now = System.os_time(:second)

    %{
      root: root,
      path: Path.join(root, "identity"),
      interval: %{not_before: now - 60, not_after: now + 86_400}
    }
  end

  test "one atomic private record retains its identity, key and public descriptor", c do
    assert {:ok, original} = InstallationIdentity.create(c.path, c.interval)
    assert {:ok, ^original} = InstallationIdentity.read(c.path)
    assert :ok = InstallationIdentity.check(original)
    assert band(File.stat!(c.path).mode, 0o777) == 0o400
    assert File.stat!(c.path).links == 1
    assert File.stat!(c.path).size <= 8_192
    assert File.ls!(c.root) == ["identity"]
    assert {:ok, public} = InstallationIdentity.descriptor(original)
    assert Enum.sort(Map.keys(public)) == ~w(controller_id identity leaf_pin trust_anchor)
    assert public["controller_id"] == original.controller_id
    assert public["identity"] == ["dns", original.name]
    assert public["leaf_pin"] == Base.encode16(:crypto.hash(:sha256, original.leaf), case: :lower)
    assert byte_size(original.key) <= 256
    assert inspect(original) == "#ControllerInstallationIdentity<private>"
    refute JSON.encode!(public) =~ Base.url_encode64(original.key, padding: false)
    assert {:error, :private_custody_exists} = InstallationIdentity.create(c.path, c.interval)
    assert {:ok, ^original} = InstallationIdentity.read(c.path)
  end

  test "independent installations share no controller ID, anchor, pin or private key", c do
    assert {:ok, first} = InstallationIdentity.create(c.path, c.interval)
    assert {:ok, second} = InstallationIdentity.create(Path.join(c.root, "second"), c.interval)

    for field <- [:controller_id, :name, :leaf, :anchor, :key],
        do: refute(Map.fetch!(first, field) == Map.fetch!(second, field))

    assert :ok = InstallationIdentity.check(first)
  end

  test "concurrent creation publishes exactly one complete identity and no scratch files", c do
    results =
      1..12
      |> Task.async_stream(fn _ -> InstallationIdentity.create(c.path, c.interval) end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :private_custody_exists})) == 11
    assert {:ok, ^winner} = InstallationIdentity.read(c.path)
    assert File.ls!(c.root) == ["identity"]
  end

  test "closed certificate intervals reject malformed, overlong and terminal dates before publication",
       c do
    for interval <- [
          nil,
          %{},
          Map.put(c.interval, :extra, true),
          %{not_before: -1, not_after: 1},
          %{not_before: 0.0, not_after: 1},
          %{not_before: 1, not_after: 1},
          %{not_before: 2, not_after: 1},
          %{not_before: 0, not_after: 366 * 86_400 + 1},
          %{not_before: 253_402_300_799, not_after: 253_402_300_799},
          %{not_before: 253_402_300_798, not_after: 253_402_300_800}
        ] do
      assert {:error, :invalid_controller_certificate_interval} =
               InstallationIdentity.create(c.path, interval)

      assert File.ls!(c.root) == []
    end
  end

  test "expired and future custody stays readable but cannot serve or silently regenerate", c do
    for {first, last} <- [{1_577_836_800, 1_577_923_200}, {2_524_608_000, 2_524_694_400}] do
      path = Path.join(c.root, Integer.to_string(first))

      assert {:ok, identity} =
               InstallationIdentity.create(path, %{not_before: first, not_after: last})

      assert {:ok, ^identity} = InstallationIdentity.read(path)
      assert {:ok, _} = InstallationIdentity.descriptor(identity)

      assert {:error, :controller_certificate_invalid} =
               InstallationIdentity.server_options(identity)

      assert {:error, :private_custody_exists} = InstallationIdentity.create(path, c.interval)
      assert {:ok, ^identity} = InstallationIdentity.read(path)
    end
  end

  test "the 2050 boundary and final supported year retain canonical certificate time", c do
    for {first, last} <- [{2_524_521_599, 2_524_608_000}, {253_402_214_399, 253_402_300_799}] do
      path = Path.join(c.root, Integer.to_string(first))

      assert {:ok, identity} =
               InstallationIdentity.create(path, %{not_before: first, not_after: last})

      assert {:ok, ^identity} = InstallationIdentity.read(path)

      assert {:error, :controller_certificate_invalid} =
               InstallationIdentity.server_options(identity)
    end
  end

  test "changed files, identical-byte replacement and forged loaded state fence serving", c do
    assert {:ok, original} = InstallationIdentity.create(c.path, c.interval)
    assert {:ok, _} = InstallationIdentity.server_options(original)

    assert {:error, :controller_identity_unavailable} =
             InstallationIdentity.server_options(%{original | key: :crypto.strong_rand_bytes(32)})

    bytes = File.read!(c.path)
    File.rename!(c.path, Path.join(c.root, "original"))
    assert :ok = PrivateFile.write(c.path, bytes, 8_192)
    assert {:error, :controller_identity_unavailable} = InstallationIdentity.check(original)
    assert {:error, :controller_identity_unavailable} = InstallationIdentity.descriptor(original)

    assert {:error, :controller_identity_unavailable} =
             InstallationIdentity.server_options(original)

    assert {:ok, replacement} = InstallationIdentity.read(c.path)
    assert replacement.seal != original.seal
    File.chmod!(c.root, 0o755)
    assert {:error, :controller_identity_unavailable} = InstallationIdentity.read(c.path)

    assert {:error, :controller_identity_unavailable} =
             InstallationIdentity.server_options(replacement)
  end

  test "permissive modes, hard links, symlinks and absent custody are refused", c do
    assert {:error, :controller_identity_unavailable} = InstallationIdentity.read(c.path)
    assert {:ok, identity} = InstallationIdentity.create(c.path, c.interval)

    for mode <- [0o600, 0o440, 0o644, 0o700] do
      File.chmod!(c.path, mode)
      assert {:error, :controller_identity_unavailable} = InstallationIdentity.read(c.path)

      assert {:error, :controller_identity_unavailable} =
               InstallationIdentity.server_options(identity)
    end

    File.chmod!(c.path, 0o400)
    linked = Path.join(c.root, "linked")
    File.ln!(c.path, linked)
    assert {:error, :controller_identity_unavailable} = InstallationIdentity.read(c.path)
    File.rm!(linked)
    File.ln_s!(c.path, linked)
    assert {:error, :controller_identity_unavailable} = InstallationIdentity.read(linked)
    assert {:error, :private_custody_exists} = InstallationIdentity.create(linked, c.interval)
  end

  test "bounded canonical record refuses malformed JSON and substituted signed fields or key",
       c do
    assert {:ok, original} = InstallationIdentity.create(c.path, c.interval)
    assert {:ok, other} = InstallationIdentity.create(Path.join(c.root, "other"), c.interval)
    bytes = File.read!(c.path)
    record = JSON.decode!(bytes)

    alterations = [
      fn r -> List.replace_at(r, 0, "unknown") end,
      fn r -> List.replace_at(r, 1, other.controller_id) end,
      fn r ->
        List.replace_at(
          r,
          1,
          binary_part(original.controller_id, 0, 32) <> String.duplicate("0", 32)
        )
      end,
      fn r -> List.replace_at(r, 2, ["dns", "rogue.local"]) end,
      fn r -> List.replace_at(r, 3, c.interval.not_before + 1) end,
      fn r -> List.replace_at(r, 4, c.interval.not_after - 1) end,
      fn r -> List.replace_at(r, 5, Base.url_encode64(other.leaf, padding: false)) end,
      fn r -> List.replace_at(r, 6, Base.url_encode64(other.anchor, padding: false)) end,
      fn r -> List.replace_at(r, 7, Base.url_encode64(other.key, padding: false)) end,
      fn r -> List.replace_at(r, 7, r |> Enum.at(7) |> Kernel.<>("=")) end,
      fn r -> r ++ [true] end
    ]

    malformed =
      [
        bytes <> "\n",
        " " <> bytes,
        "{}",
        "null",
        <<255>>,
        "[",
        "[[]]",
        :binary.copy("x", 8_193),
        String.duplicate("[", 2_000) <> String.duplicate("]", 2_000),
        "[" <> String.duplicate("0,", 1_000) <> "0]"
      ] ++ Enum.map(alterations, &(record |> &1.() |> JSON.encode!()))

    for {value, index} <- Enum.with_index(malformed) do
      path = Path.join(c.root, "bad-#{index}")
      File.write!(path, value)
      File.chmod!(path, 0o400)
      assert {:error, :controller_identity_unavailable} = InstallationIdentity.read(path)
    end

    assert {:ok, ^original} = InstallationIdentity.read(c.path)
  end

  @tag requires_socket: true
  test "generated private identity authenticates a real pinned OTP TLS 1.3 peer", c do
    assert {:ok, identity} = InstallationIdentity.create(c.path, c.interval)
    assert {:ok, public} = InstallationIdentity.descriptor(identity)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, options} = InstallationIdentity.server_options(identity)
    {:ok, listener} = :ssl.listen(0, [ip: {127, 0, 0, 1}] ++ options)
    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {_, port}} = :ssl.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, accepted} = :ssl.transport_accept(listener, 5_000)
        {:ok, socket} = :ssl.handshake(accepted, 5_000)
        :ssl.send(socket, "private fixture\n")
        :ssl.close(socket)
      end)

    invitation =
      Map.merge(public, %{
        "endpoint" => ["ipv4", "127.0.0.1", port],
        "invitation_id" => String.duplicate("1", 64),
        "bootstrap_secret" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      })

    now = System.os_time(:millisecond)
    {:ok, clock} = CertificateClock.new(now - 100, now + 100)
    {:ok, trust} = TLSIdentity.new(invitation)
    {:ok, client_options} = TLSIdentity.options(trust, clock)
    assert {:ok, client} = :ssl.connect({127, 0, 0, 1}, port, client_options, 5_000)
    assert :ok = TLSIdentity.check_socket(client, trust, clock)
    assert {:ok, "private fixture\n"} = :ssl.recv(client, 0, 5_000)
    :ssl.close(client)
    assert :ok = Task.await(server, 5_000)
  end

  test "independent OpenSSL validates signature, name and server purpose without the Home client",
       c do
    assert {:ok, identity} = InstallationIdentity.create(c.path, c.interval)
    ca = Path.join(c.root, "anchor.pem")
    leaf = Path.join(c.root, "leaf.pem")
    File.write!(ca, :public_key.pem_encode([{:Certificate, identity.anchor, :not_encrypted}]))
    File.write!(leaf, :public_key.pem_encode([{:Certificate, identity.leaf, :not_encrypted}]))

    {_, status} =
      System.cmd(
        "openssl",
        [
          "verify",
          "-CAfile",
          ca,
          "-purpose",
          "sslserver",
          "-verify_hostname",
          identity.name,
          leaf
        ],
        stderr_to_stdout: true
      )

    assert status == 0

    {_, wrong_name} =
      System.cmd(
        "openssl",
        [
          "verify",
          "-CAfile",
          ca,
          "-purpose",
          "sslserver",
          "-verify_hostname",
          "rogue.local",
          leaf
        ],
        stderr_to_stdout: true
      )

    assert wrong_name != 0

    {_, wrong_purpose} =
      System.cmd("openssl", ["verify", "-CAfile", ca, "-purpose", "sslclient", leaf],
        stderr_to_stdout: true
      )

    assert wrong_purpose != 0
  end

  test "damaged certificate signatures, trailing DER, altered key point and private scalar are refused",
       c do
    assert {:ok, original} = InstallationIdentity.create(c.path, c.interval)
    record = JSON.decode!(File.read!(c.path))
    key = :public_key.der_decode(:ECPrivateKey, original.key)

    key_variants = [
      ec_key(key, privateKey: :crypto.strong_rand_bytes(32)),
      ec_key(key, publicKey: <<4>> <> :crypto.strong_rand_bytes(64)),
      ec_key(key, parameters: {:namedCurve, {1, 3, 132, 0, 34}}),
      ec_key(key, version: 2)
    ]

    documents =
      for {index, der} <- [{5, original.leaf}, {6, original.anchor}, {7, original.key}],
          changed <- [flip_last_byte(der), der <> <<0>>],
          do: List.replace_at(record, index, Base.url_encode64(changed, padding: false))

    documents =
      documents ++
        Enum.map(key_variants, fn key ->
          List.replace_at(
            record,
            7,
            Base.url_encode64(:public_key.der_encode(:ECPrivateKey, key), padding: false)
          )
        end)

    for {document, index} <- Enum.with_index(documents) do
      path = Path.join(c.root, "damaged-#{index}")
      assert :ok = PrivateFile.write(path, JSON.encode!(document), 8_192)
      assert {:error, :controller_identity_unavailable} = InstallationIdentity.read(path)
    end
  end

  defp flip_last_byte(bytes) do
    size = byte_size(bytes) - 1
    <<prefix::binary-size(size), final>> = bytes
    prefix <> <<bxor(final, 1)>>
  end
end
