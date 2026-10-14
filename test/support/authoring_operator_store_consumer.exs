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
  @moduledoc false

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
      mutation = Path.join(root, "native-mutation")

      sources =
        Path.wildcard(Path.expand("native/macos/Sources/*.swift"))
        |> Enum.map(&Path.basename(&1, ".swift"))
        |> Enum.reject(&(&1 == "WotexHomeApp"))

      mutation_args =
        Enum.take(args, 10) ++
          Enum.map(sources, &Path.expand("native/macos/Sources/#{&1}.swift")) ++
          [
            Path.expand("native/macos/Tests/NativeAuthoringMutationLiveSmoke.swift"),
            "-o",
            mutation
          ]

      assert {:ok, _} =
               Woh.Tool.Command.run_diagnostic("swiftc", mutation_args, 1_048_576, 90_000)

      %{native_authoring_executable: executable, native_mutation_executable: mutation}
    else
      %{native_authoring_executable: nil, native_mutation_executable: nil}
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

  defp proxy_loop(listener, destination, dropped, operation, publication \\ nil) do
    case :gen_tcp.accept(listener, 10_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 3000),
               {:ok, bytes} <- :gen_tcp.recv(peer, size, 3000),
               {:ok, request} <- WotexHome.LocalAPI.Frame.decode_request(bytes) do
            target =
              request["operation"] == operation and
                (operation != "authoring_candidate_review" or request["input_ref"] != nil) and
                (operation != "authoring_object_import" or request["upload_ref"] != nil)

            if target and publication do
              {root, kind, original, payload} = publication

              ["wotex-home.native-pending.v6", _, entries] =
                JSON.decode!(File.read!(Path.join(root, "native-pending-v1.json")))

              [
                [
                  "authoring",
                  _,
                  _,
                  ["authoring_operation", ^kind, ^original, retained_payload],
                  ["pending"]
                ]
              ] = entries

              assert retained_payload ==
                       if(payload, do: Base.url_encode64(payload, padding: false), else: nil)
            end

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

        proxy_loop(listener, destination, dropped, operation, publication)

      _ ->
        :ok
    end
  end

  defp native_commit(c, socket, kind, original, payload \\ nil) do
    codec =
      %{
        "import" => WotexHome.Profiles.AuthoringImport,
        "candidate" => WotexHome.Profiles.AuthoringCandidate,
        "review" => WotexHome.Profiles.AuthoringReview
      }[kind]

    {:ok, canonical} = codec.encode(original)
    root = Path.join(c.root, "native-" <> kind)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    private(%{root: root}, "original.json", JSON.encode!(original))
    if payload, do: private(%{root: root}, "payload.bin", payload)
    proxy = Path.join(c.root, "native-proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

    File.chmod!(proxy, 0o600)
    {:ok, dropped} = Agent.start_link(fn -> false end)

    operation =
      if kind == "import",
        do: "authoring_object_import",
        else:
          if(kind == "candidate",
            do: "authoring_candidate_assess",
            else: "authoring_candidate_review"
          )

    peer =
      Task.async(fn ->
        proxy_loop(listener, socket, dropped, operation, {root, kind, canonical, payload})
      end)

    encoded = Base.url_encode64(c.credential, padding: false) <> "\n"

    try do
      assert {:error, first} =
               Woh.Tool.Command.run_diagnostic(
                 c.native_mutation_executable,
                 [proxy, root, "panel-submit", kind],
                 16_384,
                 15_000,
                 encoded
               )

      assert first =~ "status 3" and first =~ "unconfirmed"
      assert Agent.get(dropped, & &1)
      {:ok, before} = Store.revision(c.store)

      assert {:ok, "resolved\n"} =
               Woh.Tool.Command.run_diagnostic(
                 c.native_mutation_executable,
                 [proxy, root, if(kind == "candidate", do: "retry", else: "lookup"), kind],
                 16_384,
                 15_000,
                 encoded
               )

      assert {:ok, ^before} = Store.revision(c.store)

      ["wotex-home.native-pending.v6", _, []] =
        JSON.decode!(File.read!(Path.join(root, "native-pending-v1.json")))
    after
      :gen_tcp.close(listener)
      Task.shutdown(peer, :brutal_kill)
      Agent.stop(dropped)
      File.rm(proxy)
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

      if c.native_mutation_executable do
        {:ok, revision} = Store.revision(c.store)

        native_candidate =
          original
          |> Map.put("operation_id", "candidate:native")
          |> Map.put("expected_revision", revision)

        native_commit(c, socket, "candidate", native_candidate)

        assert {:ok, native_receipt} =
                 Store.authoring_candidate_status(c.store, c.credential, 1, "candidate:native")

        assert native_receipt["disposition"] == "compatible"

        native_review =
          review
          |> Map.put("operation_id", "review:native")
          |> Map.put("expected_revision", native_receipt["revision"])
          |> put_in(
            ["review", "candidate_ref"],
            Map.take(
              native_receipt,
              ~w(authority_epoch operation_id revision input_sha256 assessment_sha256)
            )
          )

        native_commit(c, socket, "review", native_review)

        assert {:ok, reviewed} =
                 Store.authoring_review_status(c.store, c.credential, 1, "review:native")

        assert reviewed["proposal_status"] == "complete"
        assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
      end
    end
  end

  test "native full binary import is published before commit and recovered in another process",
       c do
    if c.native_mutation_executable do
      {socket, _, _} = socket(c)
      bytes = :binary.copy(<<255>>, 262_144)
      {:ok, object} = AuthoringObject.new("source", bytes)
      {:ok, summary} = AuthoringObject.summary(object)

      original = %{
        "authority_epoch" => 1,
        "operation_id" => "import:native",
        "expected_revision" => 1,
        "object" => summary
      }

      native_commit(c, socket, "import", original, bytes)

      assert {:ok, receipt} =
               Store.authoring_object_status(c.store, c.credential, 1, "import:native")

      assert receipt["object"] == summary and receipt["revision"] == 2

      assert {:ok, %{"payload" => ^bytes}} =
               Store.read_authoring_object(c.store, c.credential, summary["object_digest"])

      assert {:ok, 2} = Store.revision(c.store)
    end
  end

  test "native failed publication sends no mutation and revoked capture keeps its complete original",
       c do
    if c.native_mutation_executable do
      {socket, _, encoded} = socket(c)
      root = Path.join(c.root, "native-publication")
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      bytes = "private-publication-canary"
      {:ok, object} = AuthoringObject.new("source", bytes)
      {:ok, summary} = AuthoringObject.summary(object)

      original = %{
        "authority_epoch" => 1,
        "operation_id" => "import:publication",
        "expected_revision" => 1,
        "object" => summary
      }

      private(%{root: root}, "original.json", JSON.encode!(original))
      private(%{root: root}, "payload.bin", bytes)
      lock = private(%{root: root}, "native-pending-v1.lock", "")
      File.chmod!(lock, 0o644)

      run = fn mode ->
        Woh.Tool.Command.run_diagnostic(
          c.native_mutation_executable,
          [socket, root, mode, "import"],
          16_384,
          15_000,
          encoded <> "\n"
        )
      end

      assert {:error, diagnostic} = run.("submit")
      refute diagnostic =~ encoded
      assert {:ok, 1} = Store.revision(c.store)

      assert :not_found =
               Store.authoring_object_status(c.store, c.credential, 1, "import:publication")

      refute File.exists?(Path.join(root, "native-pending-v1.json"))
      File.chmod!(lock, 0o600)
      assert {:ok, "retained\n"} = run.("capture")
      journal = File.read!(Path.join(root, "native-pending-v1.json"))
      {:ok, canonical} = WotexHome.Profiles.AuthoringImport.encode(original)

      [
        "wotex-home.native-pending.v6",
        _,
        [
          [
            "authoring",
            _,
            _,
            ["authoring_operation", "import", ^canonical, retained],
            ["pending"]
          ]
        ]
      ] = JSON.decode!(journal)

      assert retained == Base.url_encode64(bytes, padding: false)
      assert {:ok, 1} = Store.revision(c.store)
      assert {:ok, 2} = Store.revoke_principal(c.store, "author:1")
      assert {:error, refusal} = run.("retry")
      refute refusal =~ encoded
      assert File.read!(Path.join(root, "native-pending-v1.json")) == journal
      assert {:ok, 2} = Store.revision(c.store)
      assert {:ok, %{object_count: 0}} = Custody.inventory(c.custody)
    end
  end

  test "native first definite candidate refusal resolves only its newly published local record",
       c do
    if c.native_mutation_executable do
      {socket, _, encoded} = socket(c)
      root = Path.join(c.root, "native-refused")
      File.mkdir!(root)
      File.chmod!(root, 0o700)

      owned = import(c, "draft", draft("temperature"), 1, "draft:refusal")

      original =
        input(c, owned, 2, "candidate:refused")
        |> put_in(["request", "base_draft_ref", "first_revision"], 3)

      assert {:error, :stale_authoring_reference} =
               Authority.assess_authoring_candidate(c.authority, c.credential, original)

      private(%{root: root}, "original.json", JSON.encode!(original))

      assert {:ok, "refused\n"} =
               Woh.Tool.Command.run_diagnostic(
                 c.native_mutation_executable,
                 [socket, root, "panel-refused", "candidate"],
                 16_384,
                 15_000,
                 encoded <> "\n"
               )

      ["wotex-home.native-pending.v6", 2, []] =
        JSON.decode!(File.read!(Path.join(root, "native-pending-v1.json")))

      assert {:ok, 2} = Store.revision(c.store)

      assert :not_found =
               Store.authoring_candidate_status(c.store, c.credential, 1, "candidate:refused")
    end
  end
end
