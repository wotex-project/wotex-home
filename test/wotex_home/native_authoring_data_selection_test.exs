defmodule WotexHome.NativeAuthoringDataSelectionTest do
  use ExUnit.Case, async: false
  alias WotexHome.Host
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.{AuthoringCandidate, AuthoringReview}

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp private(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  defp directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp run(executable, socket, root, credential, mode, kind \\ "source") do
    Woh.Tool.Command.run_diagnostic(
      executable,
      [socket, root, mode, kind],
      16384,
      15000,
      Base.url_encode64(credential, padding: false) <> "\n"
    )
  end

  defp independent_digest(kind, bytes) do
    tag =
      Enum.find_index(
        ~w(source draft bundle fixture contract envelope profile definition),
        &(&1 == kind)
      ) + 1

    raw = :crypto.hash(:sha256, bytes)

    :crypto.hash(:sha256, <<"WOHA", 1, tag, byte_size(bytes)::32, raw::binary, bytes::binary>>)
    |> Base.encode16(case: :lower)
  end

  @tag requires_socket: true
  @tag timeout: 180_000
  test "native inert imports, selected assessment and complete review retain exact private originals" do
    root = directory("/private/tmp", "native-data-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    sources =
      Path.wildcard("native/macos/Sources/*.swift")
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(WotexHomeApp LocalHealthClient)))

    executable = Path.join(root, "client")

    assert :ok =
             Woh.Tool.NativeFixture.compile(
               File.cwd!(),
               "NativeAuthoringDataSelectionLiveSmoke.swift",
               executable,
               sources
             )

    # No installed profile authoring producer: inert custody remains independently useful.
    data = Path.join(root, "default-host")
    {:ok, host} = Host.start_link(data_dir: data)

    try do
      store = Host.store()

      {:ok, credential, 1} =
        Store.provision_principal(store, "author:data", ["read", "profile:manage"], [])

      socket = Path.join(data, "ipc/home.sock")

      for kind <- ~w(source draft bundle fixture contract envelope profile definition) do
        native = directory(root, "data-" <> kind)
        bytes = <<0, 255, 1, 13, 10>> <> kind
        private(native, "payload.bin", bytes)
        {:ok, before} = Store.revision(store)
        {:ok, captured} = Agent.start_link(fn -> [] end)
        proxy = Path.join(root, kind <> ".sock")
        {listener, task} = proxy(proxy, socket, native, captured)
        result = run(executable, proxy, native, credential, "data", kind)
        stop_proxy(listener, task)
        assert {:ok, output} = result
        receipt = JSON.decode!(output)
        digest = independent_digest(kind, bytes)
        assert receipt["object_digest"] == digest

        assert receipt["payload_sha256"] ==
                 Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        assert receipt["first_revision"] == before + 1
        assert {:ok, object} = Store.read_authoring_object(store, credential, digest)
        assert object["payload"] == bytes
        originals = Agent.get(captured, & &1)

        assert Enum.any?(originals, fn {"import", original} ->
                 {:ok, input} = WotexHome.Profiles.AuthoringImport.decode(original)
                 input["object"]["kind"] == kind and input["expected_revision"] == before
               end)

        Agent.stop(captured)
      end

      large = directory(root, "maximum-source")
      large_bytes = :binary.copy(<<255>>, 262_144)
      private(large, "payload.bin", large_bytes)
      assert {:ok, output} = run(executable, socket, large, credential, "data")
      assert JSON.decode!(output)["object_digest"] == independent_digest("source", large_bytes)

      # Identical data preserves historical object first revision under a fresh operation.
      repeated = directory(root, "repeat")
      private(repeated, "payload.bin", <<0, 255, 1, 13, 10>> <> "source")
      assert {:ok, output} = run(executable, socket, repeated, credential, "data")
      assert JSON.decode!(output)["first_revision"] == 2

      for {fault, bytes, mode} <- [
            {"empty", "", 0o600},
            {"oversize", String.duplicate("x", 65537), 0o600},
            {"permissions", "x", 0o644}
          ] do
        native = directory(root, "file-" <> fault)
        file = private(native, "payload.bin", bytes)
        File.chmod!(file, mode)
        {:ok, before} = Store.revision(store)

        assert {:ok, "refused\n"} =
                 run(executable, socket, native, credential, "file-refused", "fixture")

        assert {:ok, ^before} = Store.revision(store)
        refute File.exists?(Path.join(native, "native-pending-v1.json"))
      end

      lost = directory(root, "lost")
      private(lost, "payload.bin", "lost bytes")
      {:ok, captured} = Agent.start_link(fn -> [] end)
      {:ok, dropped} = Agent.start_link(fn -> false end)
      proxy = Path.join(root, "lost.sock")
      {listener, task} = proxy(proxy, socket, lost, captured, nil, dropped)
      {:ok, before} = Store.revision(store)
      result = run(executable, proxy, lost, credential, "lost")
      stop_proxy(listener, task)
      assert {:error, reason} = result
      assert reason =~ "status 3"
      assert reason =~ "unconfirmed"
      assert Agent.get(dropped, & &1)
      assert {:ok, "resolved\n"} = run(executable, socket, lost, credential, "lookup")
      assert {:ok, after_lost} = Store.revision(store)
      assert after_lost == before + 1
      Agent.stop(captured)
      Agent.stop(dropped)
    after
      Supervisor.stop(host)
    end

    for family <- ~w(temperature research) do
      v = fixture(family)
      data = Path.join(root, family)

      config = %{
        installed: Map.take(v, ~w(bindings contracts home_contracts)),
        capture: v["capture"],
        reader_limits: v["reader_limits"],
        authoring_limits: fixture("authoring-mechanics")[family]["limits"],
        publisher: self()
      }

      {:ok, host} = Host.start_link(data_dir: data, profile_installation: config)

      try do
        store = Host.store()

        {:ok, credential, 1} =
          Store.provision_principal(store, "author:#{family}", ["read", "profile:manage"], [])

        native = directory(root, family <> "-pipeline")
        private(native, "draft.json", fixture("authoring-mechanics")[family]["draft_bytes"])
        source_bytes = fixture("authoring-sources")[family]["source"]["payload"]
        private(native, "source.bin", source_bytes)
        fixtures = fixture("authoring-fixtures")[family]["fixtures"]

        for {f, n} <- Enum.with_index(fixtures),
            do: private(native, "fixture-#{n}.json", JSON.encode!(f))

        private(native, "envelope.json", JSON.encode!(v["envelope"]))

        private(
          native,
          "review-content.json",
          JSON.encode!(%{
            "mode" => "complete",
            "evidence" => fixture("authoring-sources")[family]["evidence"],
            "unresolved_paths" => [],
            "envelope_ref" => nil
          })
        )

        {:ok, captured} = Agent.start_link(fn -> [] end)
        socket = Path.join(data, "ipc/home.sock")
        proxy = Path.join(root, family <> ".sock")
        {listener, task} = proxy(proxy, socket, native, captured)
        result = run(executable, proxy, native, credential, "pipeline")
        stop_proxy(listener, task)
        assert {:ok, output} = result
        report = JSON.decode!(output)
        originals = Agent.get(captured, & &1)
        Agent.stop(captured)

        {"candidate", candidate_original} =
          Enum.find(originals, fn {kind, _} -> kind == "candidate" end)

        {:ok, candidate_input} = AuthoringCandidate.decode(candidate_original)
        selection = JSON.decode!(File.read!(Path.join(native, "selections.json")))
        assert Map.take(candidate_input["request"], ~w(source_refs fixture_refs)) == selection

        assert hd(selection["source_refs"])["object_digest"] ==
                 independent_digest("source", source_bytes)

        assert Enum.map(selection["fixture_refs"], & &1["object_digest"]) ==
                 Enum.sort(Enum.map(fixtures, &independent_digest("fixture", JSON.encode!(&1))))

        assert {:ok, candidate} =
                 Store.authoring_candidate_status(
                   store,
                   credential,
                   1,
                   report["candidate"]["operation_id"]
                 )

        assert candidate["input_sha256"] ==
                 Base.encode16(:crypto.hash(:sha256, candidate_original), case: :lower)

        assert candidate["disposition"] == "compatible"

        assert {:ok, review} =
                 Store.authoring_review_status(store, credential, 1, report["review_operation"])

        assert review["proposal_status"] == "complete"
        assert review["source_review"] == "attributed"

        source = hd(selection["source_refs"])
        fixture = hd(selection["fixture_refs"])

        {:ok, other_credential, _} =
          Store.provision_principal(store, "other:#{family}", ["read", "profile:manage"], [])

        other =
          import_handle(
            store,
            other_credential,
            "source",
            "other principal source",
            "other:source"
          )

        malformed = [
          {"missing",
           %{
             "source_refs" => [
               %{"object_digest" => String.duplicate("0", 64), "first_revision" => 1}
             ],
             "fixture_refs" => []
           }},
          {"wrong-kind", %{"source_refs" => [fixture], "fixture_refs" => []}},
          {"revision",
           put_in(selection, ["source_refs"], [
             %{source | "first_revision" => source["first_revision"] + 1}
           ])},
          {"duplicate", %{selection | "source_refs" => [source, source]}},
          {"unsorted", %{selection | "fixture_refs" => Enum.reverse(selection["fixture_refs"])}},
          {"unknown", Map.put(selection, "extra", nil)},
          {"boolean", put_in(selection, ["source_refs"], [%{source | "first_revision" => true}])},
          {"float", put_in(selection, ["source_refs"], [%{source | "first_revision" => 2.0}])},
          {"overflow",
           put_in(selection, ["source_refs"], [
             %{source | "first_revision" => 9_223_372_036_854_775_808}
           ])},
          {"too-many", %{selection | "source_refs" => List.duplicate(source, 33)}},
          {"missing-field", %{"source_refs" => []}},
          {"other-owner", %{"source_refs" => [other], "fixture_refs" => []}},
          {"handle-extra", %{selection | "source_refs" => [Map.put(source, "extra", nil)]}},
          {"zero", %{selection | "source_refs" => [%{source | "first_revision" => 0}]}},
          {"negative", %{selection | "source_refs" => [%{source | "first_revision" => -1}]}}
        ]

        for {fault, content} <-
              malformed ++
                [{"duplicate-key", :duplicate}, {"oversize", :oversize}, {"utf8", :utf8}] do
          child = directory(root, family <> "-" <> fault)
          private(child, "draft.json", fixture("authoring-mechanics")[family]["draft_bytes"])

          bytes =
            case content do
              :duplicate -> ~s({"source_refs":[],"source_refs":[],"fixture_refs":[]})
              :oversize -> String.duplicate(" ", 16385)
              :utf8 -> <<255>>
              map -> JSON.encode!(map)
            end

          private(child, "selections.json", bytes)
          {:ok, before} = Store.revision(store)

          assert {:ok, "refused\n"} =
                   run(executable, socket, child, credential, "selection-refused")

          assert {:ok, after_refused} = Store.revision(store)
          # Explicit draft import only; no candidate.
          assert after_refused == before + 1
        end

        if family == "temperature" do
          # The real Store refuses retained frames above this same ceiling. A hostile peer
          # supplies independently valid frames to exercise the client aggregate guard.
          objects =
            for n <- 1..17, into: %{} do
              bytes = <<n>> <> :binary.copy(<<255>>, 262_143)
              digest = independent_digest("source", bytes)

              summary = %{
                "kind" => "source",
                "object_digest" => digest,
                "payload_sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
                "payload_bytes" => byte_size(bytes)
              }

              {digest,
               %{
                 "object" => summary,
                 "first_revision" => 1,
                 "payload_base64" => Base.url_encode64(bytes, padding: false)
               }}
            end

          handles =
            objects
            |> Map.keys()
            |> Enum.sort()
            |> Enum.map(&%{"object_digest" => &1, "first_revision" => 1})

          child = directory(root, "aggregate-peer")
          private(child, "draft.json", fixture("authoring-mechanics")[family]["draft_bytes"])

          private(
            child,
            "selections.json",
            JSON.encode!(%{"source_refs" => handles, "fixture_refs" => []})
          )

          {:ok, captured} = Agent.start_link(fn -> [] end)
          peer_socket = Path.join(root, "aggregate.sock")
          {listener, task} = proxy(peer_socket, socket, child, captured, objects)
          {:ok, before} = Store.revision(store)
          result = run(executable, peer_socket, child, credential, "selection-refused")
          stop_proxy(listener, task)
          assert {:ok, "refused\n"} = result

          assert Enum.count(Agent.get(captured, & &1), fn {kind, _} ->
                   kind == "aggregate-read"
                 end) == 16

          refute Enum.any?(Agent.get(captured, & &1), fn {kind, _} -> kind == "candidate" end)
          Agent.stop(captured)
          assert {:ok, after_refused} = Store.revision(store)
          assert after_refused == before + 1
        end

        for fault <- ~w(object-hash watermark) do
          child = directory(root, family <> "-peer-" <> fault)
          private(child, "draft.json", fixture("authoring-mechanics")[family]["draft_bytes"])
          private(child, "selections.json", JSON.encode!(selection))
          {:ok, captured} = Agent.start_link(fn -> [] end)
          peer_socket = Path.join(root, family <> "-peer-" <> fault <> ".sock")
          {listener, task} = proxy(peer_socket, socket, child, captured, fault)
          {:ok, before} = Store.revision(store)
          result = run(executable, peer_socket, child, credential, "selection-refused")
          stop_proxy(listener, task)
          assert {:ok, "refused\n"} = result
          assert Enum.all?(Agent.get(captured, & &1), fn {kind, _} -> kind == "import" end)
          Agent.stop(captured)
          assert {:ok, after_refused} = Store.revision(store)

          injected =
            if fault == "watermark",
              do: length(selection["source_refs"]) + length(selection["fixture_refs"]),
              else: 0

          assert after_refused == before + 1 + injected
        end
      after
        Supervisor.stop(host)
      end
    end
  end

  defp import_handle(store, credential, kind, bytes, operation) do
    {:ok, object} = WotexHome.Profiles.AuthoringObject.new(kind, bytes)
    {:ok, summary} = WotexHome.Profiles.AuthoringObject.summary(object)
    {:ok, revision} = Store.revision(store)

    {:ok, receipt} =
      Store.import_authoring_object(
        store,
        credential,
        %{
          "authority_epoch" => 1,
          "operation_id" => operation,
          "expected_revision" => revision,
          "object" => summary
        },
        bytes
      )

    %{"object_digest" => summary["object_digest"], "first_revision" => receipt["first_revision"]}
  end

  defp proxy(path, destination, root, captured, fault \\ nil, dropped \\ nil) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    {listener,
     Task.async(fn -> proxy_loop(listener, destination, root, captured, fault, dropped) end)}
  end

  defp stop_proxy(listener, task) do
    :gen_tcp.close(listener)
    Task.await(task, 5000)
  end

  defp proxy_loop(listener, destination, root, captured, fault, dropped) do
    case :gen_tcp.accept(listener, 10000) do
      {:ok, peer} ->
        try do
          {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 3000)
          {:ok, bytes} = :gen_tcp.recv(peer, size, 3000)
          {:ok, request} = WotexHome.LocalAPI.Frame.decode_request(bytes)

          if request["operation"] in ~w(authoring_upload_begin authoring_object_import authoring_candidate_assess authoring_candidate_review) do
            [
              "wotex-home.native-pending.v6",
              _,
              [["authoring", _, _, ["authoring_operation", kind, original, payload], ["pending"]]]
            ] =
              JSON.decode!(File.read!(Path.join(root, "native-pending-v1.json")))

            case kind do
              "import" ->
                {:ok, input} = WotexHome.Profiles.AuthoringImport.decode(original)
                assert is_binary(payload)

                assert Base.url_decode64!(payload, padding: false) |> byte_size() ==
                         input["object"]["payload_bytes"]

              "candidate" ->
                assert {:ok, _} = AuthoringCandidate.decode(original)

              "review" ->
                assert {:ok, _} = AuthoringReview.decode(original)
            end

            Agent.update(captured, fn originals -> Enum.uniq([{kind, original} | originals]) end)
          end

          {:ok, response} = WotexHome.LocalAPI.Client.request(destination, request)

          response =
            case {fault, request["operation"]} do
              {objects, "authoring_object_read"} when is_map(objects) ->
                Agent.update(captured, &[{"aggregate-read", request["object_digest"]} | &1])

                %{
                  "api_version" => 1,
                  "outcome" => "ok",
                  "authoring_object" => Map.fetch!(objects, request["object_digest"])
                }

              {"object-hash", "authoring_object_read"} ->
                put_in(
                  response,
                  ["authoring_object", "object", "payload_sha256"],
                  String.duplicate("0", 64)
                )

              {"watermark", "authoring_object_read"} ->
                # A concurrent Store change after the first contract read must fence the final identity bracket.
                {:ok, _, _} =
                  Store.provision_principal(
                    Host.store(),
                    "changed:#{System.unique_integer([:positive])}",
                    ["read"],
                    []
                  )

                response

              _ ->
                response
            end

          drop =
            dropped != nil and request["operation"] == "authoring_object_import" and
              Map.has_key?(response, "authoring_object_receipt") and
              Agent.get_and_update(dropped, fn old -> {not old, true} end)

          unless drop do
            {:ok, frame} = WotexHome.LocalAPI.Frame.encode_response(response)
            :ok = :gen_tcp.send(peer, frame)
          end
        after
          :gen_tcp.close(peer)
        end

        proxy_loop(listener, destination, root, captured, fault, dropped)

      _ ->
        :ok
    end
  end
end
