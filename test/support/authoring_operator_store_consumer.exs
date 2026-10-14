System.fetch_env!("HOME_AUTHORING_ARCHIVE_EBINS")
|> JSON.decode!()
|> Enum.each(fn path ->
  true = Code.prepend_path(path)
end)

# Home's ordinary test project does not contain these optional dependency
# implementations when it consolidates protocols. Restore OTP/Elixir's original
# dynamic protocol for this isolated archive-backed process only.
:code.purge(String.Chars)

{:module, String.Chars} =
  :code.load_abs(
    Path.join(:code.lib_dir(:elixir, :ebin), "Elixir.String.Chars")
    |> String.to_charlist()
  )

defmodule HomeAuthoringOperatorStoreArchiveTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Profiles.{AuthoringContract, AuthoringObject, Custody}
  @owner __MODULE__.Store

  defp fixture(family),
    do: JSON.decode!(File.read!("test/fixtures/profiles/" <> family <> ".json"))

  setup_all do
    if :os.type() == {:unix, :darwin} do
      root = Path.join("/private/tmp", "authoring-read-sdk-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)
      executable = Path.join(root, "native-client")

      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(root, "cache"),
        "-framework",
        "Security",
        Path.expand("native/macos/Sources/LocalHealthClient.swift"),
        Path.expand("native/macos/Sources/NativeAuthoringReadClient.swift"),
        Path.expand("native/macos/Tests/NativeAuthoringReadLiveSmoke.swift"),
        "-o",
        executable
      ]

      assert {:ok, _} = Woh.Tool.Command.run_diagnostic("swiftc", args, 1_048_576, 90_000)
      %{native_authoring_executable: executable}
    else
      %{native_authoring_executable: nil}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "candidate-archive-#{System.unique_integer([:positive])}")
    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root, store_owner: @owner})
    v = fixture("temperature")

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", %{
        "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
        "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
        "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
      })

    limits = fixture("authoring-mechanics")["temperature"]["limits"]
    {:ok, contract} = AuthoringContract.export(installed, limits)

    {:ok, reader} =
      WotexHome.Profiles.ReaderSelection.new(installed, v["capture"], v["reader_limits"])

    path = Path.join(root, "home.sqlite")

    store =
      start_supervised!(
        {Store,
         path: path,
         profile_custody: custody,
         authoring_contract: contract,
         authoring_capture: v["capture"],
         external_reader: reader,
         name: @owner}
      )

    {:ok, credential, 1} = Store.provision_principal(store, "author:1", ["profile:manage"], [])

    %{
      root: root,
      path: path,
      store: store,
      custody: custody,
      credential: credential,
      contract: contract,
      reader: reader,
      authority: Authority.new(store: store, profile_custody: custody)
    }
  end

  defp import(c, kind, bytes, revision, operation) do
    {:ok, o} = AuthoringObject.new(kind, bytes)
    {:ok, s} = AuthoringObject.summary(o)

    {:ok, r} =
      Store.import_authoring_object(
        c.store,
        c.credential,
        %{
          "authority_epoch" => 1,
          "operation_id" => operation,
          "expected_revision" => revision,
          "object" => s
        },
        bytes
      )

    %{"object_digest" => s["object_digest"], "first_revision" => r["first_revision"]}
  end

  defp input(c, ref, revision, operation \\ "candidate:1") do
    %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "request" => %{
        "mode" => "manual",
        "contract_digest" => c.contract.contract_sha256,
        "base_draft_ref" => ref,
        "source_refs" => [],
        "fixture_refs" => [],
        "instruction" => "manual review",
        "limits" => c.contract.inputs["limits"]
      }
    }
  end

  defp draft(family), do: fixture("authoring-mechanics")[family]["draft_bytes"]

  defp private(c, name, bytes) do
    path = Path.join(c.root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  defp socket(c) do
    path = Path.join(c.root, "home.sock")
    start_supervised!({WotexHome.LocalAPI.Server, authority: c.authority, socket_path: path})
    encoded = Base.url_encode64(c.credential, padding: false)
    file = private(c, "credential", encoded)
    {path, ["--socket", path, "--credential-file", file], encoded}
  end

  defp dropped_commit(c, socket, flags, command, original_file, status_command, operation) do
    proxy = Path.join(c.root, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

    File.chmod!(proxy, 0o600)
    dropped = start_supervised!({Agent, fn -> false end}, id: {:drop, operation})

    peer =
      Task.async(fn ->
        proxy_loop(listener, socket, dropped, String.replace(command, "-", "_"))
      end)

    proxy_flags = List.replace_at(flags, 1, proxy)

    try do
      output =
        capture_io(:stderr, fn ->
          assert 3 == CLI.main(proxy_flags ++ [command, original_file])
        end)

      assert output =~ status_command <> " 1 " <> operation
      refute output =~ Base.url_encode64(c.credential, padding: false)
      assert Agent.get(dropped, & &1)

      output =
        capture_io(fn ->
          assert 0 == CLI.main(proxy_flags ++ [status_command, "1", operation])
        end)

      member = String.replace(status_command, "-status", "-receipt") |> String.replace("-", "_")
      JSON.decode!(output)[member]
    after
      :gen_tcp.close(listener)
      Task.shutdown(peer, :brutal_kill)
      File.rm(proxy)
    end
  end

  defp proxy_loop(listener, destination, dropped, operation) do
    case :gen_tcp.accept(listener, 10_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 3000),
               {:ok, bytes} <- :gen_tcp.recv(peer, size, 3000),
               {:ok, request} <- WotexHome.LocalAPI.Frame.decode_request(bytes) do
            target =
              request["operation"] == operation and
                (operation != "authoring_candidate_review" or request["input_ref"] != nil)

            drop = target and Agent.get_and_update(dropped, fn old -> {not old, true} end)
            {:ok, response} = WotexHome.LocalAPI.Client.request(destination, request)

            unless drop do
              {:ok, frame} = WotexHome.LocalAPI.Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
            end
          end
        after
          :gen_tcp.close(peer)
        end

        proxy_loop(listener, destination, dropped, operation)

      _ ->
        :ok
    end
  end

  for family <- ~w(temperature research) do
    @family family
    test "#{@family} CLI candidate and complete review retain exactly the Authority originals",
         c do
      source_vector = fixture("authoring-sources")[@family]
      source = import(c, "source", source_vector["source"]["payload"], 1, "source:1")
      draft = import(c, "draft", draft(@family), 2, "draft:1")

      {fixtures, revision} =
        Enum.map_reduce(
          Enum.with_index(fixture("authoring-fixtures")[@family]["fixtures"]),
          3,
          fn {data, n}, rev ->
            ref = import(c, "fixture", JSON.encode!(data), rev, "fixture:#{n}")
            {ref, rev + 1}
          end
        )

      envelope =
        import(c, "envelope", JSON.encode!(fixture(@family)["envelope"]), revision, "envelope:1")

      original =
        input(c, draft, revision + 1)
        |> put_in(["request", "source_refs"], [source])
        |> put_in(["request", "fixture_refs"], Enum.sort_by(fixtures, & &1["object_digest"]))

      {socket, flags, encoded} = socket(c)
      file = private(c, "candidate.json", JSON.encode!(original))

      candidate =
        dropped_commit(
          c,
          socket,
          flags,
          "authoring-candidate-assess",
          file,
          "authoring-candidate-status",
          "candidate:1"
        )

      assert {:ok, ^candidate} =
               Authority.assess_authoring_candidate(c.authority, c.credential, original)

      assert candidate["disposition"] == "compatible" and
               candidate["source_review"] == "not_assessed"

      review = %{
        "authority_epoch" => 1,
        "operation_id" => "review:1",
        "expected_revision" => candidate["revision"],
        "review" => %{
          "mode" => "complete",
          "candidate_ref" =>
            Map.take(
              candidate,
              ~w(authority_epoch operation_id revision input_sha256 assessment_sha256)
            ),
          "evidence" => source_vector["evidence"],
          "unresolved_paths" => [],
          "envelope_ref" => envelope
        }
      }

      file = private(c, "review.json", JSON.encode!(review))

      receipt =
        dropped_commit(
          c,
          socket,
          flags,
          "authoring-candidate-review",
          file,
          "authoring-review-status",
          "review:1"
        )

      assert {:ok, ^receipt} =
               Authority.review_authoring_candidate(c.authority, c.credential, review)

      assert receipt["source_review"] == "attributed" and receipt["fixture_status"] == "passed" and
               receipt["proposal_status"] == "complete"

      assert {:ok, doc} = WotexHome.Profiles.AuthoringReview.encode(review)

      request = %{
        "api_version" => 1,
        "operation" => "authoring_candidate_review",
        "credential" => encoded,
        "authority_epoch" => 1,
        "operation_id" => "review:1",
        "input_sha256" => :crypto.hash(:sha256, doc) |> Base.encode16(case: :lower),
        "input_ref" => nil
      }

      stop_supervised(WotexHome.LocalAPI.Server)
      start_supervised!({WotexHome.LocalAPI.Server, authority: c.authority, socket_path: socket})

      assert {:ok, %{"authoring_review_receipt" => ^receipt}} =
               WotexHome.LocalAPI.Client.request(socket, request)

      output =
        capture_io(fn -> assert 0 == CLI.main(flags ++ ["authoring-candidate-review", file]) end)

      assert JSON.decode!(output)["authoring_review_receipt"] == receipt
      assert {:ok, receipt_revision} = Store.revision(c.store)
      assert receipt_revision == receipt["revision"]

      if executable = c.native_authoring_executable do
        assert {:ok, output} =
                 Woh.Tool.Command.run_diagnostic(
                   executable,
                   [socket, source["object_digest"]],
                   65_536,
                   10_000,
                   encoded <> "\n"
                 )

        native = JSON.decode!(output)
        assert native["authoring_candidate_receipt"] == candidate
        assert native["authoring_review_receipt"] == receipt
        assert native["object_digest"] == source["object_digest"]
        assert native["first_revision"] == source["first_revision"]
        assert native["payload_bytes"] == byte_size(source_vector["source"]["payload"])

        assert native["payload_sha256"] ==
                 :crypto.hash(:sha256, source_vector["source"]["payload"])
                 |> Base.encode16(case: :lower)

        assert {:ok, ^receipt_revision} = Store.revision(c.store)
      end

      assert {:ok, %{"reason" => "authoring_operation_conflict"}} =
               WotexHome.LocalAPI.Client.request(
                 socket,
                 Map.put(request, "input_sha256", String.duplicate("0", 64))
               )

      for {command, expected} <- [
            {"authoring-candidate-status", candidate},
            {"authoring-review-status", receipt}
          ] do
        operation =
          if command == "authoring-candidate-status", do: "candidate:1", else: "review:1"

        output = capture_io(fn -> assert 0 == CLI.main(flags ++ [command, "1", operation]) end)

        assert JSON.decode!(output)[
                 String.replace(command, "-status", "-receipt") |> String.replace("-", "_")
               ] == expected
      end

      assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)

      assert {:ok, [[0]]} =
               SQL.query(
                 :sys.get_state(c.store).db,
                 "SELECT COUNT(*) FROM profile_external_artifacts"
               )

      # Exercise an accepted review original larger than a socket frame without
      # claiming that repeated ambiguous attribution proves source truth.
      first_evidence = hd(source_vector["evidence"])

      large_evidence =
        for n <- 0..255 do
          Map.put(
            first_evidence,
            "locator",
            "line:" <>
              String.pad_leading(Integer.to_string(n), 4, "0") <> String.duplicate("x", 240)
          )
        end

      large =
        review
        |> Map.put("operation_id", "review:large")
        |> Map.put("expected_revision", receipt["revision"])
        |> put_in(["review", "evidence"], large_evidence)

      assert {:ok, canonical} = WotexHome.Profiles.AuthoringReview.encode(large)
      assert byte_size(canonical) > 65_536 and byte_size(canonical) <= 131_072
      file = private(c, "large-review.json", JSON.encode!(large))

      output =
        capture_io(fn -> assert 0 == CLI.main(flags ++ ["authoring-candidate-review", file]) end)

      large_receipt = JSON.decode!(output)["authoring_review_receipt"]

      assert {:ok, ^large_receipt} =
               Authority.review_authoring_candidate(c.authority, c.credential, large)

      refute large_receipt["proposal_status"] == "complete"

      assert large_receipt["input_sha256"] ==
               :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    end
  end
end
