defmodule WotexHome.AuthoringOperatorTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Exchange, Frame, Server}
  alias WotexHome.Profiles.{AuthoringImport, AuthoringObject, Custody}
  @owner __MODULE__.Store

  setup do
    root = Path.join("/private/tmp", "authoring-operators-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_path = Path.join(root, "profiles")
    File.mkdir!(custody_path)
    File.chmod!(custody_path, 0o700)
    custody = start_supervised!({Custody, root: custody_path, store_owner: @owner})

    store =
      start_supervised!(
        {Store, path: Path.join(root, "home.sqlite"), name: @owner, profile_custody: custody}
      )

    {:ok, credential, 1} = Store.provision_principal(store, "author:1", ["profile:manage"], [])
    encoded = Base.url_encode64(credential, padding: false)
    credential_path = private(root, "credential", encoded)
    authority = Authority.new(store: store, profile_custody: custody)

    %{
      root: root,
      custody: custody,
      store: store,
      authority: authority,
      credential: credential,
      encoded: encoded,
      credential_path: credential_path
    }
  end

  defp private(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  defp base(c, operation),
    do: %{"api_version" => 1, "operation" => operation, "credential" => c.encoded}

  defp input(bytes, revision \\ 1) do
    {:ok, object} = AuthoringObject.new("source", bytes)
    {:ok, summary} = AuthoringObject.summary(object)

    %{
      "authority_epoch" => 1,
      "operation_id" => "import:1",
      "expected_revision" => revision,
      "object" => summary
    }
  end

  defp roundtrip(c, request) do
    {:ok, frame} = Frame.encode_request(request)
    {:ok, <<_::32, body::binary>>} = Server.route_frame(c.authority, frame)
    {:ok, response} = Frame.decode_response(body)
    response
  end

  @tag requires_socket: true
  test "Store loss retires owned uploads and removes the endpoint without a cleanup race", c do
    socket = Path.join(c.root, "retire.sock")

    server =
      start_supervised!(
        Supervisor.child_spec({Server, authority: c.authority, socket_path: socket},
          restart: :temporary
        )
      )

    monitor = Process.monitor(server)
    stop_supervised!(Store)
    assert_receive {:DOWN, ^monitor, :process, ^server, reason}, 5000
    assert reason in [:normal, :authoring_upload_owner_stopped]
    refute File.exists?(socket)
  end

  @tag requires_socket: true
  test "full binary import/read/CLI replay survives payload and upload-owner loss", c do
    socket = Path.join(c.root, "home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    flags = ["--socket", socket, "--credential-file", c.credential_path]
    bytes = :binary.copy(<<0, 255>>, 131_072)
    input = input(bytes)
    original = private(c.root, "original.json", JSON.encode!(input))
    payload = private(c.root, "payload.bin", bytes)

    output =
      capture_io(fn ->
        assert 0 == CLI.main(flags ++ ["authoring-object-import", original, payload])
      end)

    receipt = JSON.decode!(output)["authoring_object_receipt"]
    assert {:ok, ^receipt} = Store.import_authoring_object(c.store, c.credential, input, bytes)
    assert receipt["revision"] == 2

    assert {:ok, %{"payload" => ^bytes}} =
             Authority.read_authoring_object(
               c.authority,
               c.credential,
               input["object"]["object_digest"]
             )

    destination = Path.join(c.root, "output.bin")

    output =
      capture_io(fn ->
        assert 0 ==
                 CLI.main(
                   flags ++
                     ["authoring-object-read", input["object"]["object_digest"], destination]
                 )
      end)

    assert File.read!(destination) == bytes
    assert Bitwise.band(File.stat!(destination).mode, 0o777) == 0o600
    refute output =~ "payload_base64"

    capture_io(:stderr, fn ->
      assert 1 ==
               CLI.main(
                 flags ++ ["authoring-object-read", input["object"]["object_digest"], destination]
               )
    end)

    File.rm!(payload)
    stop_supervised(Server)
    start_supervised!({Server, authority: c.authority, socket_path: socket})

    output =
      capture_io(fn ->
        assert 0 == CLI.main(flags ++ ["authoring-object-import", original, payload])
      end)

    assert JSON.decode!(output)["authoring_object_receipt"] == receipt
    assert {:ok, 2} = Store.revision(c.store)
    changed = Map.put(input, "expected_revision", 2)

    assert {:ok, %{"reason" => "authoring_operation_conflict"}} =
             Client.request(
               socket,
               Map.merge(base(c, "authoring_object_import"), %{
                 "input" => changed,
                 "upload_ref" => nil
               })
             )
  end

  test "closed wrappers and current permission precede upload state and originals", c do
    bytes = "operator-source"

    request =
      Map.merge(base(c, "authoring_object_import"), %{
        "input" => input(bytes),
        "upload_ref" => nil
      })

    assert %{"reason" => "authoring_upload_required"} = roundtrip(c, request)

    assert %{"reason" => "unsupported_operation_or_fields"} =
             roundtrip(c, Map.put(request, "payload", bytes))

    assert %{"reason" => "unsupported_operation_or_fields"} =
             roundtrip(c, Map.delete(request, "upload_ref"))

    {:ok, reader, _} = Store.provision_principal(c.store, "reader:1", ["read"], [])
    denied = Map.put(request, "credential", Base.url_encode64(reader, padding: false))
    assert %{"reason" => "permission_denied"} = roundtrip(c, denied)
    assert {:ok, 2} = Store.revision(c.store)

    for operation <-
          ~w(authoring_object_status authoring_candidate_status authoring_review_status) do
      request =
        Map.merge(base(c, operation), %{"authority_epoch" => 1, "operation_id" => "absent:1"})

      assert %{"outcome" => "not_found"} = roundtrip(c, request)
      assert %{"outcome" => "error"} = roundtrip(c, Map.put(request, "authority_epoch", 0))
    end
  end

  test "current authorization precedes unavailable custody and revocation closes a ready upload",
       c do
    upload = %{
      "upload_id" => "upload:1",
      "purpose" => "import_payload",
      "payload_bytes" => 1,
      "payload_sha256" => :crypto.hash(:sha256, "x") |> Base.encode16(case: :lower)
    }

    {:ok, reader, _} = Store.provision_principal(c.store, "reader:1", ["read"], [])

    assert {:error, :permission_denied} =
             Authority.begin_authoring_upload(c.authority, reader, upload)

    assert {:error, :authoring_upload_unavailable} =
             Authority.begin_authoring_upload(c.authority, c.credential, upload)

    owner = start_supervised!({WotexHome.Profiles.AuthoringUpload, store_owner: c.store})
    authority = Authority.with_authoring_uploads(c.authority, owner)
    assert {:ok, first} = Authority.begin_authoring_upload(authority, c.credential, upload)
    ref = Map.take(first, ~w(owner_epoch upload_id))

    assert {:ok, %{"state" => "ready"}} =
             Authority.append_authoring_upload(authority, c.credential, ref, 0, "x")

    assert {:ok, _} = Store.revoke_principal(c.store, "author:1")

    assert {:error, :unauthorized} =
             Authority.authoring_upload_status(authority, c.credential, "upload:1")

    assert {:error, :unauthorized} =
             Authority.cancel_authoring_upload(authority, c.credential, ref)

    assert {:error, :unauthorized} =
             Authority.import_authoring_upload(authority, c.credential, input("x", 3), ref)

    assert {:error, :permission_denied} =
             Store.authoring_object_status(c.store, reader, 1, "import:1")

    assert {:ok, %{object_count: 0}} = Custody.inventory(c.custody)
  end

  @tag requires_socket: true
  test "every tagged payload ceiling reaches Store without reducing its byte contract", c do
    socket = Path.join(c.root, "home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    flags = ["--socket", socket, "--credential-file", c.credential_path]

    for {kind, size} <- [
          {"source", 262_144},
          {"draft", 262_144},
          {"bundle", 262_144},
          {"contract", 262_144},
          {"fixture", 65_536},
          {"envelope", 65_536},
          {"profile", 65_536},
          {"definition", 65_536}
        ] do
      bytes = :binary.copy(<<255>>, size)
      {:ok, object} = AuthoringObject.new(kind, bytes)
      {:ok, summary} = AuthoringObject.summary(object)
      {:ok, revision} = Store.revision(c.store)

      original = %{
        "authority_epoch" => 1,
        "operation_id" => "import:" <> kind,
        "expected_revision" => revision,
        "object" => summary
      }

      file = private(c.root, "original.json", JSON.encode!(original))
      payload = private(c.root, "payload.bin", bytes)

      output =
        capture_io(fn ->
          assert 0 == CLI.main(flags ++ ["authoring-object-import", file, payload])
        end)

      receipt = JSON.decode!(output)["authoring_object_receipt"]
      assert receipt["revision"] == revision + 1 and receipt["object"] == summary

      assert {:ok, %{"payload" => ^bytes}} =
               Store.read_authoring_object(c.store, c.credential, summary["object_digest"])
    end

    assert {:ok, 9} = Store.revision(c.store)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  @tag requires_socket: true
  test "source passage CLI preserves explicit UTF-8 bytes without exporting another actor's source",
       c do
    bytes = "source evidence: αβ\n"
    {:ok, receipt} = Store.import_authoring_object(c.store, c.credential, input(bytes), bytes)
    socket = Path.join(c.root, "home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})

    selector = %{
      "source_ref" => receipt["object"]["object_digest"],
      "offset" => 0,
      "length" => byte_size(bytes)
    }

    file = private(c.root, "selectors.json", JSON.encode!([selector]))
    flags = ["--socket", socket, "--credential-file", c.credential_path]

    output =
      capture_io(fn -> assert 0 == CLI.main(flags ++ ["authoring-source-passages", file]) end)

    assert [passage] = JSON.decode!(output)["authoring_passages"]

    assert passage["text"] == bytes and
             passage["passage_sha256"] ==
               :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    {:ok, other, _} = Store.provision_principal(c.store, "author:other", ["profile:manage"], [])

    request =
      Map.merge(base(c, "authoring_source_passages"), %{
        "selectors" => [selector],
        "credential" => Base.url_encode64(other, padding: false)
      })

    assert {:ok, %{"outcome" => "not_found"}} = Client.request(socket, request)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "large local documents keep socket ceiling and strict duplicate checks", c do
    assert {:error, :request_too_large} = Frame.decode_request(String.duplicate("x", 65_537))
    assert {:error, :duplicate_member} = Frame.decode_document(~s({"a":1,"a":2}), 262_144)

    assert {:ok, _} =
             Frame.decode_document(
               JSON.encode!(%{"text" => String.duplicate("x", 131_072)}),
               262_144
             )

    for command <- ~w(authoring-object-status authoring-candidate-status authoring-review-status),
        bad <- ~w(0 -1 1x 9223372036854775808) do
      assert {:error, :usage} = CLI.build_request([command, bad, "operation:1"], c.encoded)
    end

    path = private(c.root, "original.json", JSON.encode!(input("x")))

    assert {:ok, request} =
             CLI.build_request(
               ["authoring-object-import", path, Path.join(c.root, "absent")],
               c.encoded
             )

    assert request["upload_ref"] == nil
    File.chmod!(path, 0o644)

    assert {:error, :invalid_authoring_original_file} =
             CLI.build_request(
               ["authoring-object-import", path, Path.join(c.root, "absent")],
               c.encoded
             )
  end

  test "original probes are reads; real commit dispatch failures are uncertain", c do
    deadline = System.monotonic_time(:millisecond) - 1

    import =
      Map.merge(base(c, "authoring_object_import"), %{"input" => input("x"), "upload_ref" => nil})

    assert %{"reason" => "request_timeout"} = Exchange.perform(c.authority, import, deadline)

    assert %{"reason" => "outcome_unknown"} =
             Exchange.perform(c.authority, Map.put(import, "upload_ref", %{}), deadline)

    for operation <- ~w(authoring_candidate_assess authoring_candidate_review) do
      assert %{"reason" => "outcome_unknown"} =
               Exchange.perform(c.authority, base(c, operation), deadline)
    end

    assert %{"reason" => "request_timeout"} =
             Exchange.perform(
               c.authority,
               Map.put(base(c, "authoring_candidate_review"), "input_ref", nil),
               deadline
             )

    assert {:ok, 1} = Store.revision(c.store)
  end

  test "a successful chunk reply with a stale cursor cannot trigger an exact retry", c do
    bytes = "x"
    original = input(bytes)

    probe =
      Map.merge(base(c, "authoring_object_import"), %{"input" => original, "upload_ref" => nil})

    peer = start_supervised!({Agent, fn -> %{operations: [], upload: nil} end})

    send = fn _, request ->
      Agent.get_and_update(peer, fn state ->
        operation = request["operation"]
        state = %{state | operations: state.operations ++ [operation]}

        case operation do
          "authoring_object_import" ->
            {{:ok,
              %{"api_version" => 1, "outcome" => "error", "reason" => "authoring_upload_required"}},
             state}

          "authoring_upload_begin" ->
            status =
              Map.merge(request["upload"], %{
                "format" => "home-authoring-upload-v1",
                "owner_epoch" => String.duplicate("a", 32),
                "next_offset" => 0,
                "state" => "uploading",
                "remaining_ms" => 59000
              })

            {{:ok, %{"api_version" => 1, "outcome" => "ok", "authoring_upload" => status}},
             %{state | upload: status}}

          "authoring_upload_chunk" ->
            {{:ok, %{"api_version" => 1, "outcome" => "ok", "authoring_upload" => state.upload}},
             state}
        end
      end)
    end

    assert {:error, :authoring_upload_unavailable} =
             WotexHome.CLI.Authoring.perform(
               "unused",
               ["authoring-object-import", "unused", "unused"],
               probe,
               send,
               fn _, _, _ -> {:ok, bytes} end
             )

    assert Agent.get(peer, & &1.operations) ==
             ~w(authoring_object_import authoring_upload_begin authoring_upload_chunk)
  end

  test "object output refuses links and verifies exact raw bytes before writing", c do
    bytes = "private-source-canary"
    original = input(bytes)
    {:ok, receipt} = Store.import_authoring_object(c.store, c.credential, original, bytes)

    response =
      roundtrip(
        c,
        Map.put(
          base(c, "authoring_object_read"),
          "object_digest",
          original["object"]["object_digest"]
        )
      )

    destination = Path.join(c.root, "safe.bin")
    File.ln_s!(Path.join(c.root, "missing-target"), destination)

    assert {:error, :authoring_output_exists} =
             WotexHome.CLI.Authoring.write_object(response, destination)

    refute File.exists?(Path.join(c.root, "missing-target"))
    File.rm!(destination)

    broken =
      put_in(
        response,
        ["authoring_object", "payload_base64"],
        Base.url_encode64("wrong", padding: false)
      )

    assert {:error, _} = WotexHome.CLI.Authoring.write_object(broken, destination)
    refute File.exists?(destination)
    assert {:ok, ^receipt} = Store.authoring_object_status(c.store, c.credential, 1, "import:1")
    assert {:ok, 2} = Store.revision(c.store)
    assert {:ok, doc} = AuthoringImport.encode(original)
    assert byte_size(doc) <= 4096
  end

  for mode <- ~w(chunk-before chunk-after commit-after) do
    @drop_mode mode
    @tag requires_socket: true
    test "#{@drop_mode} lost reply recovers cursor or exact durable original", c do
      socket = Path.join(c.root, "real.sock")
      start_supervised!({Server, authority: c.authority, socket_path: socket})
      proxy = Path.join(c.root, "proxy.sock")

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

      File.chmod!(proxy, 0o600)
      dropped = start_supervised!({Agent, fn -> false end})
      peer = Task.async(fn -> proxy_loop(listener, socket, dropped, @drop_mode) end)
      bytes = :binary.copy(<<0, 255>>, 32_769)
      original = input(bytes)
      file = private(c.root, "original.json", JSON.encode!(original))
      payload = private(c.root, "payload.bin", bytes)
      flags = ["--socket", proxy, "--credential-file", c.credential_path]

      try do
        if @drop_mode == "commit-after" do
          output =
            capture_io(:stderr, fn ->
              assert 3 == CLI.main(flags ++ ["authoring-object-import", file, payload])
            end)

          assert output =~ "authoring-object-status 1 import:1"
          refute output =~ c.encoded
        else
          capture_io(fn ->
            assert 0 == CLI.main(flags ++ ["authoring-object-import", file, payload])
          end)
        end

        assert Agent.get(dropped, & &1)

        assert {:ok, receipt} =
                 Store.authoring_object_status(c.store, c.credential, 1, "import:1")

        assert receipt["revision"] == 2

        assert {:ok, %{"payload" => ^bytes}} =
                 Store.read_authoring_object(
                   c.store,
                   c.credential,
                   original["object"]["object_digest"]
                 )

        assert {:ok, 2} = Store.revision(c.store)

        output =
          capture_io(fn ->
            assert 0 == CLI.main(flags ++ ["authoring-object-status", "1", "import:1"])
          end)

        assert JSON.decode!(output)["authoring_object_receipt"] == receipt
      after
        :gen_tcp.close(listener)
        Task.shutdown(peer, :brutal_kill)
      end
    end
  end

  defp proxy_loop(listener, destination, dropped, mode) do
    case :gen_tcp.accept(listener, 10_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 3000),
               {:ok, bytes} <- :gen_tcp.recv(peer, size, 3000),
               {:ok, request} <- Frame.decode_request(bytes) do
            target? =
              if mode == "commit-after",
                do:
                  request["operation"] == "authoring_object_import" and
                    request["upload_ref"] != nil,
                else: request["operation"] == "authoring_upload_chunk"

            drop? =
              target? and Agent.get_and_update(dropped, fn previous -> {not previous, true} end)

            unless drop? and mode == "chunk-before" do
              {:ok, response} = Client.request(destination, request)

              unless drop? do
                {:ok, frame} = Frame.encode_response(response)
                :ok = :gen_tcp.send(peer, frame)
              end
            end
          end
        after
          :gen_tcp.close(peer)
        end

        proxy_loop(listener, destination, dropped, mode)

      _ ->
        :ok
    end
  end
end
