defmodule WotexHome.NativeManualDraftTest do
  @moduledoc false

  use ExUnit.Case, async: false
  @moduletag skip: :os.type() != {:unix, :darwin}
  alias WotexHome.{Host, Profiles.AuthoringObject}
  alias WotexHome.Durable.Store

  @tag requires_socket: true
  @tag timeout: 120_000
  test "manual draft decisions construct verified originals for two actual producer families" do
    root = Path.join("/private/tmp", "native-manual-draft-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    sources =
      Path.wildcard("native/macos/Sources/*.swift")
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(WotexHomeApp LocalHealthClient)))

    executable = Path.join(root, "client")

    assert :ok =
             Woh.Tool.NativeFixture.compile(
               File.cwd!(),
               "NativeAuthoringMutationLiveSmoke.swift",
               executable,
               sources
             )

    fixture = fn name -> JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json")) end

    for family <- ~w(temperature research) do
      input = fixture.(family)

      config = %{
        installed: Map.take(input, ~w(bindings contracts home_contracts)),
        capture: input["capture"],
        reader_limits: input["reader_limits"],
        authoring_limits: fixture.("authoring-mechanics")[family]["limits"],
        publisher: self()
      }

      data_dir = Path.join(root, "host-" <> family)
      assert {:ok, host} = Host.start_link(data_dir: data_dir, profile_installation: config)

      try do
        {:ok, credential, 1} =
          Store.provision_principal(
            Host.store(),
            "author:#{family}",
            ["read", "profile:manage"],
            []
          )

        native_root = Path.join(root, "native-" <> family)
        File.mkdir!(native_root)
        File.chmod!(native_root, 0o700)
        bytes = fixture.("authoring-mechanics")[family]["draft_bytes"]
        File.write!(Path.join(native_root, "draft.json"), bytes)
        File.chmod!(Path.join(native_root, "draft.json"), 0o600)

        proxy = Path.join(root, family <> "-proxy.sock")

        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

        File.chmod!(proxy, 0o600)
        {:ok, evidence} = Agent.start_link(fn -> [] end)

        peer =
          Task.async(fn ->
            proxy_loop(
              listener,
              Path.join(data_dir, "ipc/home.sock"),
              native_root,
              bytes,
              evidence
            )
          end)

        result =
          Woh.Tool.Command.run_diagnostic(
            executable,
            [proxy, native_root, "manual-draft", family],
            16384,
            15000,
            Base.url_encode64(credential, padding: false) <> "\n"
          )

        :gen_tcp.close(listener)
        Task.await(peer, 5000)
        File.rm!(proxy)
        assert {:ok, output} = result
        publications = Agent.get(evidence, & &1)
        Agent.stop(evidence)

        assert Enum.sort(publications) == [
                 {"candidate", 2},
                 {"candidate", 4},
                 {"import", 1},
                 {"import", 1},
                 {"import", 3},
                 {"import", 3}
               ]

        result = JSON.decode!(output)
        {:ok, object} = AuthoringObject.new("draft", bytes)
        {:ok, summary} = AuthoringObject.summary(object)
        assert result["object_digest"] == summary["object_digest"]

        assert result["first_revision"] == 2 and result["import_revision"] == 2 and
                 result["candidate_revision"] == 3

        assert {:ok, imported} =
                 Store.authoring_object_status(
                   Host.store(),
                   credential,
                   1,
                   result["import_operation"]
                 )

        assert imported["object"] == summary

        assert {:ok, candidate} =
                 Store.authoring_candidate_status(
                   Host.store(),
                   credential,
                   1,
                   result["candidate_operation"]
                 )

        assert candidate["input_sha256"] == result["candidate_input_sha256"]

        assert candidate["basis_sha256"] == result["basis_sha256"] and
                 candidate["disposition"] == "compatible"

        assert result["repeat_import_revision"] == 4 and result["repeat_candidate_revision"] == 5
        assert {:ok, 5} = Store.revision(Host.store())

        assert ["wotex-home.native-pending.v6", _, []] =
                 JSON.decode!(File.read!(Path.join(native_root, "native-pending-v1.json")))

        lost_root = Path.join(root, "lost-" <> family)
        File.mkdir!(lost_root)
        File.chmod!(lost_root, 0o700)
        File.write!(Path.join(lost_root, "draft.json"), bytes)
        File.chmod!(Path.join(lost_root, "draft.json"), 0o600)

        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

        File.chmod!(proxy, 0o600)
        {:ok, evidence} = Agent.start_link(fn -> [] end)
        {:ok, dropped} = Agent.start_link(fn -> false end)

        peer =
          Task.async(fn ->
            proxy_loop(
              listener,
              Path.join(data_dir, "ipc/home.sock"),
              lost_root,
              bytes,
              evidence,
              dropped
            )
          end)

        lost =
          Woh.Tool.Command.run_diagnostic(
            executable,
            [proxy, lost_root, "manual-draft-lost", family],
            16384,
            15000,
            Base.url_encode64(credential, padding: false) <> "\n"
          )

        :gen_tcp.close(listener)
        Task.await(peer, 5000)
        assert {:error, reason} = lost
        assert reason =~ "status 3" and reason =~ "unconfirmed"
        assert Agent.get(dropped, & &1)
        assert [{"import", 5}, {"import", 5}] == Agent.get(evidence, & &1)
        Agent.stop(evidence)
        Agent.stop(dropped)
        assert {:ok, 6} = Store.revision(Host.store())

        [
          "wotex-home.native-pending.v6",
          _,
          [["authoring", _, _, ["authoring_operation", "import", original, _], ["pending"]]]
        ] =
          JSON.decode!(File.read!(Path.join(lost_root, "native-pending-v1.json")))

        {:ok, retained} = WotexHome.Profiles.AuthoringImport.decode(original)

        assert {:ok, _} =
                 Store.authoring_object_status(
                   Host.store(),
                   credential,
                   1,
                   retained["operation_id"]
                 )

        assert {:ok, "resolved\n"} =
                 Woh.Tool.Command.run_diagnostic(
                   executable,
                   [Path.join(data_dir, "ipc/home.sock"), lost_root, "lookup", family],
                   16384,
                   15000,
                   Base.url_encode64(credential, padding: false) <> "\n"
                 )

        assert {:ok, 6} = Store.revision(Host.store())

        assert ["wotex-home.native-pending.v6", _, []] =
                 JSON.decode!(File.read!(Path.join(lost_root, "native-pending-v1.json")))

        File.rm!(proxy)
        basis_root = Path.join(root, "basis-" <> family)
        File.mkdir!(basis_root)
        File.chmod!(basis_root, 0o700)
        File.write!(Path.join(basis_root, "draft.json"), bytes)
        File.chmod!(Path.join(basis_root, "draft.json"), 0o600)

        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

        File.chmod!(proxy, 0o600)
        {:ok, evidence} = Agent.start_link(fn -> [] end)
        {:ok, basis_count} = Agent.start_link(fn -> 0 end)

        peer =
          Task.async(fn ->
            proxy_loop(
              listener,
              Path.join(data_dir, "ipc/home.sock"),
              basis_root,
              bytes,
              evidence,
              nil,
              basis_count
            )
          end)

        refused =
          Woh.Tool.Command.run_diagnostic(
            executable,
            [proxy, basis_root, "manual-draft-basis", family],
            16384,
            15000,
            Base.url_encode64(credential, padding: false) <> "\n"
          )

        :gen_tcp.close(listener)
        Task.await(peer, 5000)
        assert {:ok, "refused\n"} = refused
        assert Agent.get(evidence, & &1) == []
        assert Agent.get(basis_count, & &1) == 2
        Agent.stop(evidence)
        Agent.stop(basis_count)
        assert {:ok, 6} = Store.revision(Host.store())
        refute File.exists?(Path.join(basis_root, "native-pending-v1.json"))
      after
        Supervisor.stop(host)
      end
    end
  end

  defp proxy_loop(
         listener,
         destination,
         root,
         payload,
         evidence,
         dropped \\ nil,
         basis_count \\ nil
       ) do
    case :gen_tcp.accept(listener, 10000) do
      {:ok, peer} ->
        try do
          {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 3000)
          {:ok, bytes} = :gen_tcp.recv(peer, size, 3000)
          {:ok, request} = WotexHome.LocalAPI.Frame.decode_request(bytes)

          if request["operation"] in ~w(authoring_object_import authoring_candidate_assess) do
            [
              "wotex-home.native-pending.v6",
              _,
              [["authoring", _, _, ["authoring_operation", kind, original, stored], ["pending"]]]
            ] = JSON.decode!(File.read!(Path.join(root, "native-pending-v1.json")))

            decoded =
              case kind do
                "import" ->
                  assert stored == Base.url_encode64(payload, padding: false)
                  {:ok, decoded} = WotexHome.Profiles.AuthoringImport.decode(original)
                  assert decoded == request["input"]
                  decoded

                "candidate" ->
                  assert stored == nil
                  {:ok, decoded} = WotexHome.Profiles.AuthoringCandidate.decode(original)
                  assert decoded == request["input"]
                  decoded
              end

            Agent.update(evidence, &[{kind, decoded["expected_revision"]} | &1])
          end

          {:ok, response} = WotexHome.LocalAPI.Client.request(destination, request)

          response =
            if basis_count != nil and request["operation"] == "authoring_contract_export" and
                 Agent.get_and_update(basis_count, fn n -> {n == 1, n + 1} end) do
              put_in(
                response,
                ["authoring_contract", "summary", "basis_sha256"],
                String.duplicate("0", 64)
              )
            else
              response
            end

          drop =
            dropped != nil and request["operation"] == "authoring_object_import" and
              request["upload_ref"] != nil and
              Agent.get_and_update(dropped, fn old -> {not old, true} end)

          unless drop do
            {:ok, frame} = WotexHome.LocalAPI.Frame.encode_response(response)
            :ok = :gen_tcp.send(peer, frame)
          end
        after
          :gen_tcp.close(peer)
        end

        proxy_loop(listener, destination, root, payload, evidence, dropped, basis_count)

      _ ->
        :ok
    end
  end
end
