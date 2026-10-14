defmodule WotexHome.ExternalProfileOperatorTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Exchange, Frame, Server}

  defp vectors(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp base(c, operation),
    do: %{"api_version" => 1, "operation" => operation, "credential" => c.encoded}

  setup do
    root =
      Path.join(System.tmp_dir!(), "external-operators-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, path: Path.join(root, "home.sqlite")})

    {:ok, credential, 1} =
      Store.provision_principal(store, "operator:1", ["enroll:review", "profile:manage"], [])

    encoded = Base.url_encode64(credential, padding: false)

    %{
      root: root,
      store: store,
      credential: credential,
      encoded: encoded,
      authority: Authority.new(store: store)
    }
  end

  for {command, operation, field, fixture, key} <- [
        {"external-profile-inspect", "external_profile_inspect", "inspection",
         "external-inspections", "input"},
        {"external-target-change", "external_target_change", "change",
         "external-target-selections", "select"},
        {"external-trust-change", "external_trust_change", "change", "external-trust", "approve"}
      ] do
    test "#{command} preserves both original inputs and rejects unsafe or malformed files", c do
      for family <- ~w(temperature research) do
        value = vectors(unquote(fixture))[family][unquote(key)]
        value = if unquote(key) in ["approve", "select"], do: value["input"], else: value
        path = Path.join(c.root, "original.json")
        File.write!(path, JSON.encode!(value))
        File.chmod!(path, 0o600)
        request = Map.put(base(c, unquote(operation)), unquote(field), value)
        assert {:ok, ^request} = CLI.build_request([unquote(command), path], c.encoded)
        File.chmod!(path, 0o644)
        assert {:error, _} = CLI.build_request([unquote(command), path], c.encoded)
        File.chmod!(path, 0o600)
        File.write!(path, JSON.encode!(Map.put(value, "extra", true)))
        assert {:error, _} = CLI.build_request([unquote(command), path], c.encoded)
        File.write!(path, ~s({"operation_id":"one","operation_id":"two"}))
        assert {:error, _} = CLI.build_request([unquote(command), path], c.encoded)
        File.write!(path, String.duplicate("x", 32769))
        assert {:error, _} = CLI.build_request([unquote(command), path], c.encoded)
      end
    end

    @tag requires_socket: true
    test "#{command} reports a lost transport as original-scoped uncertainty", c do
      value = vectors(unquote(fixture))["temperature"][unquote(key)]
      value = if unquote(key) in ["approve", "select"], do: value["input"], else: value
      path = Path.join(c.root, "original.json")
      File.write!(path, JSON.encode!(value))
      File.chmod!(path, 0o600)
      credential_file = Path.join(c.root, "credential")
      File.write!(credential_file, c.encoded)
      File.chmod!(credential_file, 0o600)
      socket = Path.join(c.root, "drop.sock")

      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          {:ifaddr, {:local, String.to_charlist(socket)}},
          {:active, false}
        ])

      File.chmod!(socket, 0o600)
      on_exit(fn -> :gen_tcp.close(listener) end)

      peer =
        Task.async(fn ->
          {:ok, connection} = :gen_tcp.accept(listener, 3000)
          {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(connection, 4, 3000)
          {:ok, _} = :gen_tcp.recv(connection, size, 3000)
          :gen_tcp.close(connection)
        end)

      flags = ["--socket", socket, "--credential-file", credential_file]

      output =
        capture_io(:stderr, fn -> assert 3 == CLI.main(flags ++ [unquote(command), path]) end)

      status =
        case unquote(operation) do
          "external_profile_inspect" -> "external-inspection-status"
          "external_trust_change" -> "external-trust-status"
          "external_target_change" -> "external-target-status"
        end

      assert output =~ "#{status} #{value["authority_epoch"]} #{value["operation_id"]}"
      refute output =~ c.encoded
      assert :ok = Task.await(peer, 3000)
      assert {:ok, 1} = Store.revision(c.store)
    end
  end

  test "status CLI enforces positive signed epochs and closed catalogue wrappers", c do
    assert {:ok, request} = CLI.build_request(["external-profiles"], c.encoded)
    assert request == base(c, "external_profiles")

    for command <- ~w(external-inspection-status external-trust-status external-target-status) do
      assert {:ok, r} = CLI.build_request([command, "1", "original:1"], c.encoded)
      assert r["authority_epoch"] == 1 and r["operation_id"] == "original:1"

      for bad <- ~w(0 -1 9223372036854775808 1x) do
        assert {:error, _} = CLI.build_request([command, bad, "original:1"], c.encoded)
      end

      assert {:error, _} = CLI.build_request([command, "1", "bad/id"], c.encoded)
    end
  end

  test "framed routes retain current permission, exact wrappers and owned-reference guards",
       c do
    assert {:ok, catalogue} = Authority.external_profile_catalogue(c.authority, c.credential)

    assert %{"api_version" => 1, "outcome" => "ok", "external_profile_catalogue" => ^catalogue} =
             roundtrip(c, base(c, "external_profiles"))

    for operation <- ~w(external_inspection_status external_trust_status external_target_status) do
      request =
        Map.merge(base(c, operation), %{"authority_epoch" => 1, "operation_id" => "absent:1"})

      assert %{"api_version" => 1, "outcome" => "not_found"} = roundtrip(c, request)

      assert %{"reason" => "unsupported_operation_or_fields"} =
               roundtrip(c, Map.put(request, "extra", true))

      assert %{"outcome" => "error"} = roundtrip(c, Map.put(request, "authority_epoch", 0))
    end

    inspection =
      vectors("external-inspections")["temperature"]["input"] |> Map.put("expected_revision", 1)

    request = Map.put(base(c, "external_profile_inspect"), "inspection", inspection)
    assert %{"outcome" => "not_found"} = roundtrip(c, request)
    {:ok, reader, _} = Store.provision_principal(c.store, "reader:1", ["read"], [])

    denied =
      Map.put(
        base(c, "external_profiles"),
        "credential",
        Base.url_encode64(reader, padding: false)
      )

    assert %{"reason" => "permission_denied"} = roundtrip(c, denied)
  end

  test "expired mutation dispatch is uncertain while status remains a read failure", c do
    deadline = System.monotonic_time(:millisecond) - 1

    for operation <- ~w(external_profile_inspect external_trust_change external_target_change) do
      assert %{"reason" => "outcome_unknown"} =
               Exchange.perform(c.authority, base(c, operation), deadline)
    end

    for operation <-
          ~w(external_inspection_status external_trust_status external_target_status external_profiles) do
      assert %{"reason" => "request_timeout"} =
               Exchange.perform(c.authority, base(c, operation), deadline)
    end

    assert {:ok, 1} = Store.revision(c.store)
  end

  test "actual Store-call failure reports both external mutations as uncertain", c do
    stop_supervised(Store)

    for {operation, field, input} <- [
          {"external_profile_inspect", "inspection",
           vectors("external-inspections")["temperature"]["input"]},
          {"external_trust_change", "change",
           vectors("external-trust")["temperature"]["approve"]["input"]},
          {"external_target_change", "change",
           vectors("external-target-selections")["temperature"]["select"]["input"]}
        ] do
      assert %{"api_version" => 1, "outcome" => "error", "reason" => "outcome_unknown"} =
               Exchange.perform(
                 c.authority,
                 Map.put(base(c, operation), field, input),
                 System.monotonic_time(:millisecond) + 1000
               )
    end

    assert %{"reason" => "operation_unavailable"} =
             Exchange.perform(
               c.authority,
               base(c, "external_profiles"),
               System.monotonic_time(:millisecond) + 1000
             )
  end

  @tag requires_socket: true
  test "real private socket and CLI expose the same empty current catalogue and scoped missing originals",
       c do
    socket = Path.join(c.root, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})

    assert {:ok, %{"outcome" => "ok", "external_profile_catalogue" => catalogue}} =
             Client.request(socket, base(c, "external_profiles"))

    assert catalogue["items"] == [] and catalogue["policy_generation"] == 0
    path = Path.join(c.root, "credential")
    File.write!(path, c.encoded)
    File.chmod!(path, 0o600)
    flags = ["--socket", socket, "--credential-file", path]
    output = capture_io(fn -> assert 0 == CLI.main(flags ++ ["external-profiles"]) end)
    assert JSON.decode!(output)["external_profile_catalogue"] == catalogue

    for command <- ~w(external-inspection-status external-trust-status external-target-status) do
      output = capture_io(fn -> assert 4 == CLI.main(flags ++ [command, "1", "absent:1"]) end)
      assert JSON.decode!(output)["outcome"] == "not_found"
    end
  end

  defp roundtrip(c, request) do
    {:ok, frame} = Frame.encode_request(request)
    {:ok, <<size::unsigned-big-32, body::binary>>} = Server.route_frame(c.authority, frame)
    assert byte_size(body) == size
    {:ok, response} = Frame.decode_response(body)
    response
  end
end
