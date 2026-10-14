defmodule WotexHome.NativeMappingEditorTest do
  use ExUnit.Case, async: false
  alias WotexHome.Host
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.{AuthoringImport, AuthoringCandidate}
  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp private(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp fields(family, mode) do
    draft = JSON.decode!(fixture("authoring-mechanics")[family]["draft_bytes"])
    p = draft["profile"]

    sections = %{
      "id" => p["id"],
      "version" => p["version"],
      "fingerprint" => JSON.encode!(p["fingerprint"]),
      "channels" =>
        if(mode == "invalid", do: "[]", else: " \n" <> JSON.encode!(p["channels"]) <> "\n "),
      "definitions" => JSON.encode!(draft["definitions"]),
      "requires" => JSON.encode!(p["requires"]),
      "annotations" => ""
    }

    binding = p["binding"]

    ref =
      "{\"id\":" <>
        JSON.encode!(binding["id"]) <>
        ",\"sha256\":" <>
        JSON.encode!(binding["sha256"]) <>
        ",\"version\":" <> JSON.encode!(binding["version"]) <> "}"

    expected =
      "{\"format\":\"wotex.profile.draft@1\",\"profile\":{\"format\":\"wotex.profile@1\",\"id\":" <>
        JSON.encode!(p["id"]) <>
        ",\"version\":" <>
        JSON.encode!(p["version"]) <>
        ",\"binding\":" <>
        ref <>
        ",\"fingerprint\":" <>
        sections["fingerprint"] <>
        ",\"channels\":" <>
        sections["channels"] <>
        ",\"requires\":" <>
        sections["requires"] <> "},\"definitions\":" <> sections["definitions"] <> "}"

    {sections, expected}
  end

  defp run(executable, socket, root, mode, credential) do
    Woh.Tool.Command.run_diagnostic(
      executable,
      [socket, root, mode],
      16384,
      20000,
      Base.url_encode64(credential, padding: false) <> "\n"
    )
  end

  @tag requires_socket: true
  @tag timeout: 180_000
  test "mapping editor composes exact private drafts on one current installed context" do
    root = directory("/private/tmp", "native-mapping-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    sources =
      Path.wildcard("native/macos/Sources/*.swift")
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(WotexHomeApp LocalHealthClient)))

    executable = Path.join(root, "client")

    assert :ok =
             Woh.Tool.NativeFixture.compile(
               File.cwd!(),
               "NativeMappingEditorLiveSmoke.swift",
               executable,
               sources
             )

    for {family, scenario} <-
          for(
            f <- ~w(temperature research),
            s <- ~w(normal invalid lost basis grammar identity cas revoked),
            do: {f, s}
          ) do
      v = fixture(family)

      config = %{
        installed: Map.take(v, ~w(bindings contracts home_contracts)),
        capture: v["capture"],
        reader_limits: v["reader_limits"],
        authoring_limits: fixture("authoring-mechanics")[family]["limits"],
        publisher: self()
      }

      data = Path.join(root, family <> "-" <> scenario <> "-host")
      {:ok, host} = Host.start_link(data_dir: data, profile_installation: config)

      try do
        store = Host.store()

        {:ok, credential, 1} =
          Store.provision_principal(store, "author:#{family}", ["read", "profile:manage"], [])

        native = directory(root, family <> "-" <> scenario)
        {sections, expected} = fields(family, scenario)
        private(native, "fields.json", JSON.encode!(sections))
        socket = Path.join(data, "ipc/home.sock")
        proxy = Path.join(root, family <> "-" <> scenario <> ".sock")

        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

        File.chmod!(proxy, 0o600)

        {:ok, state} =
          Agent.start_link(fn -> %{originals: [], identities: 0, exports: 0, dropped: false} end)

        task =
          Task.async(fn ->
            proxy_loop(listener, socket, native, store, state, scenario, family)
          end)

        mode =
          case scenario do
            "basis" -> "basis-refused"
            "cas" -> "cas-refused"
            s when s in ~w(grammar identity revoked) -> "context-refused"
            other -> other
          end

        result = run(executable, proxy, native, mode, credential)
        :gen_tcp.close(listener)
        Task.await(task, 5000)
        captured = Agent.get(state, & &1)
        Agent.stop(state)

        if scenario in ~w(normal invalid) do
          assert {:ok, output} = result
          report = JSON.decode!(output)
          import = Enum.find(captured.originals, fn {kind, _, _} -> kind == "import" end)
          assert {"import", document, payload} = import
          assert payload == expected
          assert {:ok, original} = AuthoringImport.decode(document)
          raw = :crypto.hash(:sha256, expected)
          digest = hash(<<"WOHA", 1, 2, byte_size(expected)::32, raw::binary, expected::binary>>)
          assert original["object"]["object_digest"] == digest
          assert report["object_digest"] == digest
          assert report["first_revision"] == 2 and report["import_revision"] == 2
          assert {:ok, object} = Store.read_authoring_object(store, credential, digest)
          assert object["payload"] == expected

          assert {:ok, candidate} =
                   Store.authoring_candidate_status(
                     store,
                     credential,
                     1,
                     report["candidate_operation"]
                   )

          assert candidate["disposition"] ==
                   if(scenario == "invalid", do: "invalid", else: "compatible")

          assert report["candidate_revision"] == 3
          assert {:ok, 3} = Store.revision(store)

          assert ["wotex-home.native-pending.v6", _, []] =
                   JSON.decode!(File.read!(Path.join(native, "native-pending-v1.json")))
        else
          if scenario == "lost" do
            assert {:error, reason} = result
            assert reason =~ "status 3" and reason =~ "unconfirmed"
            assert captured.dropped
            assert {:ok, 2} = Store.revision(store)
            assert {:ok, "resolved\n"} = run(executable, socket, native, "lookup", credential)
            assert {:ok, 2} = Store.revision(store)
          else
            assert {:ok, "refused\n"} = result
            assert captured.originals == []
            assert {:ok, revision} = Store.revision(store)
            assert revision == if(scenario in ~w(cas revoked), do: 2, else: 1)
            refute File.exists?(Path.join(native, "native-pending-v1.json"))
          end
        end
      after
        Supervisor.stop(host)
      end
    end
  end

  defp proxy_loop(listener, destination, root, store, state, scenario, family) do
    case :gen_tcp.accept(listener, 10000) do
      {:ok, peer} ->
        try do
          {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 3000)
          {:ok, bytes} = :gen_tcp.recv(peer, size, 3000)
          {:ok, request} = WotexHome.LocalAPI.Frame.decode_request(bytes)

          index =
            case request["operation"] do
              "controller_identity" ->
                Agent.get_and_update(state, fn s ->
                  {s.identities + 1, %{s | identities: s.identities + 1}}
                end)

              "authoring_contract_export" ->
                Agent.get_and_update(state, fn s ->
                  {s.exports + 1, %{s | exports: s.exports + 1}}
                end)

              _ ->
                0
            end

          if scenario == "cas" and request["operation"] == "controller_identity" and index == 5 do
            {:ok, _, _} = Store.provision_principal(store, "cas:#{family}", ["read"], [])
          end

          if request["operation"] in ~w(authoring_upload_begin authoring_object_import authoring_candidate_assess) do
            [
              "wotex-home.native-pending.v6",
              _,
              [["authoring", _, _, ["authoring_operation", kind, original, payload], ["pending"]]]
            ] =
              JSON.decode!(File.read!(Path.join(root, "native-pending-v1.json")))

            decoded =
              case kind do
                "import" ->
                  assert {:ok, v} = AuthoringImport.decode(original)
                  v

                "candidate" ->
                  assert {:ok, v} = AuthoringCandidate.decode(original)
                  v
              end

            assert decoded["expected_revision"] >= 1
            binary = if payload, do: Base.url_decode64!(payload, padding: false), else: nil

            Agent.update(state, fn s ->
              %{s | originals: Enum.uniq([{kind, original, binary} | s.originals])}
            end)
          end

          {:ok, response} = WotexHome.LocalAPI.Client.request(destination, request)

          response =
            case {scenario, request["operation"]} do
              {"basis", "authoring_contract_export"} when index == 2 ->
                put_in(
                  response,
                  ["authoring_contract", "summary", "basis_sha256"],
                  String.duplicate("0", 64)
                )

              {"identity", "controller_identity"} when index == 2 ->
                put_in(response, ["controller_identity", "owner_id"], String.duplicate("0", 64))

              {"revoked", "authoring_contract_export"} ->
                {:ok, _} = Store.revoke_principal(store, "author:#{family}")
                response

              {"grammar", "authoring_contract_export"} ->
                raw =
                  Base.url_decode64!(response["authoring_contract"]["contract_base64"],
                    padding: false
                  )

                doc =
                  JSON.decode!(raw)
                  |> put_in(
                    ["schemas", "draft", "properties", "format", "const"],
                    "wotex.profile.draft@2"
                  )

                changed = JSON.encode!(doc)

                response
                |> put_in(
                  ["authoring_contract", "contract_base64"],
                  Base.url_encode64(changed, padding: false)
                )
                |> put_in(["authoring_contract", "summary", "contract_raw_sha256"], hash(changed))
                |> put_in(
                  ["authoring_contract", "summary", "contract_sha256"],
                  hash("wotex.profile.authoring-contract@1\n" <> changed)
                )

              _ ->
                response
            end

          drop =
            scenario == "lost" and request["operation"] == "authoring_object_import" and
              Map.has_key?(response, "authoring_object_receipt") and
              Agent.get_and_update(state, fn s -> {not s.dropped, %{s | dropped: true}} end)

          unless drop do
            {:ok, frame} = WotexHome.LocalAPI.Frame.encode_response(response)
            :ok = :gen_tcp.send(peer, frame)
          end
        after
          :gen_tcp.close(peer)
        end

        proxy_loop(listener, destination, root, store, state, scenario, family)

      _ ->
        :ok
    end
  end
end
