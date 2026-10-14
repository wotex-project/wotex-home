defmodule WotexHome.NativeAuthoringReviewPreparationTest do
  use ExUnit.Case, async: false
  alias WotexHome.{Host, Profiles.AuthoringObject}
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.AuthoringReview

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp private(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  defp import(store, credential, kind, bytes, operation) do
    {:ok, object} = AuthoringObject.new(kind, bytes)
    {:ok, summary} = AuthoringObject.summary(object)
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

  @tag requires_socket: true
  @tag timeout: 120_000
  test "native review preparation derives both independent candidate references and publishes exact originals" do
    root = Path.join("/private/tmp", "native-review-#{System.unique_integer([:positive])}")
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
               "NativeAuthoringReviewPreparationLiveSmoke.swift",
               executable,
               sources
             )

    for family <- ~w(temperature research) do
      v = fixture(family)

      config = %{
        installed: Map.take(v, ~w(bindings contracts home_contracts)),
        capture: v["capture"],
        reader_limits: v["reader_limits"],
        authoring_limits: fixture("authoring-mechanics")[family]["limits"],
        publisher: self()
      }

      data_dir = Path.join(root, family)
      {:ok, host} = Host.start_link(data_dir: data_dir, profile_installation: config)

      try do
        store = Host.store()

        {:ok, credential, 1} =
          Store.provision_principal(store, "author:#{family}", ["read", "profile:manage"], [])

        source =
          import(
            store,
            credential,
            "source",
            fixture("authoring-sources")[family]["source"]["payload"],
            "source:1"
          )

        draft =
          import(
            store,
            credential,
            "draft",
            fixture("authoring-mechanics")[family]["draft_bytes"],
            "draft:1"
          )

        fixtures =
          for {f, n} <- Enum.with_index(fixture("authoring-fixtures")[family]["fixtures"]),
              do: import(store, credential, "fixture", JSON.encode!(f), "fixture:#{n}")

        envelope =
          import(store, credential, "envelope", JSON.encode!(v["envelope"]), "envelope:1")

        {:ok, export} = Store.authoring_contract_export(store, credential)
        {:ok, revision} = Store.revision(store)

        candidate_input = %{
          "authority_epoch" => 1,
          "operation_id" => "candidate:1",
          "expected_revision" => revision,
          "request" => %{
            "mode" => "manual",
            "contract_digest" => export["summary"]["contract_sha256"],
            "base_draft_ref" => draft,
            "source_refs" => [source],
            "fixture_refs" => Enum.sort_by(fixtures, & &1["object_digest"]),
            "instruction" => "",
            "limits" => export["summary"]["limits"]
          }
        }

        {:ok, candidate} = Store.assess_authoring_candidate(store, credential, candidate_input)

        for mode <- ~w(source complete) do
          native_root = Path.join(root, family <> "-" <> mode)
          File.mkdir!(native_root)
          File.chmod!(native_root, 0o700)
          candidate_file = private(native_root, "candidate.json", JSON.encode!(candidate))

          content = %{
            "mode" => mode,
            "evidence" => fixture("authoring-sources")[family]["evidence"],
            "unresolved_paths" => [],
            "envelope_ref" => if(mode == "complete", do: envelope, else: nil)
          }

          private(native_root, "review-content.json", JSON.encode!(content))
          {:ok, before} = Store.revision(store)
          proxy = Path.join(root, family <> "-" <> mode <> ".sock")

          {:ok, listener} =
            :gen_tcp.listen(0, [
              :binary,
              active: false,
              ifaddr: {:local, String.to_charlist(proxy)}
            ])

          File.chmod!(proxy, 0o600)
          {:ok, captured} = Agent.start_link(fn -> nil end)

          peer =
            Task.async(fn ->
              proxy_loop(listener, Path.join(data_dir, "ipc/home.sock"), native_root, captured)
            end)

          result =
            Woh.Tool.Command.run_diagnostic(
              executable,
              [proxy, native_root, candidate_file, mode],
              16384,
              15000,
              Base.url_encode64(credential, padding: false) <> "\n"
            )

          :gen_tcp.close(listener)
          Task.await(peer, 5000)
          assert {:ok, output} = result
          received = JSON.decode!(output)
          original = Agent.get(captured, & &1)
          Agent.stop(captured)
          {:ok, decoded} = AuthoringReview.decode(original)
          assert decoded["expected_revision"] == before

          assert decoded["review"]["candidate_ref"] ==
                   Map.take(
                     candidate,
                     ~w(authority_epoch operation_id revision input_sha256 assessment_sha256)
                   )

          assert Map.delete(decoded["review"], "candidate_ref") == content

          assert {:ok, receipt} =
                   Store.authoring_review_status(store, credential, 1, received["operation_id"])

          assert receipt["input_sha256"] ==
                   :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)

          assert receipt["source_review"] == "attributed"

          assert receipt["proposal_status"] ==
                   if(mode == "complete", do: "complete", else: "incomplete")

          assert {:ok, after_revision} = Store.revision(store)
          assert after_revision == before + 1

          assert ["wotex-home.native-pending.v6", _, []] =
                   JSON.decode!(File.read!(Path.join(native_root, "native-pending-v1.json")))
        end

        lost_root = Path.join(root, family <> "-lost")
        File.mkdir!(lost_root)
        File.chmod!(lost_root, 0o700)
        candidate_file = private(lost_root, "candidate.json", JSON.encode!(candidate))

        private(
          lost_root,
          "review-content.json",
          JSON.encode!(%{
            "mode" => "source",
            "evidence" => fixture("authoring-sources")[family]["evidence"],
            "unresolved_paths" => [],
            "envelope_ref" => nil
          })
        )

        {:ok, before_lost} = Store.revision(store)
        proxy = Path.join(root, family <> "-lost.sock")

        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(proxy)}])

        File.chmod!(proxy, 0o600)
        {:ok, captured} = Agent.start_link(fn -> nil end)
        {:ok, dropped} = Agent.start_link(fn -> false end)

        peer =
          Task.async(fn ->
            proxy_loop(
              listener,
              Path.join(data_dir, "ipc/home.sock"),
              lost_root,
              captured,
              nil,
              dropped
            )
          end)

        lost =
          Woh.Tool.Command.run_diagnostic(
            executable,
            [proxy, lost_root, candidate_file, "lost"],
            16384,
            15000,
            Base.url_encode64(credential, padding: false) <> "\n"
          )

        :gen_tcp.close(listener)
        Task.await(peer, 5000)
        assert {:error, lost_reason} = lost
        assert lost_reason =~ "status 3" and lost_reason =~ "unconfirmed"
        assert Agent.get(dropped, & &1)
        original = Agent.get(captured, & &1)
        Agent.stop(captured)
        Agent.stop(dropped)
        {:ok, decoded} = AuthoringReview.decode(original)

        assert {:ok, receipt} =
                 Store.authoring_review_status(store, credential, 1, decoded["operation_id"])

        assert receipt["revision"] == before_lost + 1

        assert {:ok, "resolved\n"} =
                 Woh.Tool.Command.run_diagnostic(
                   executable,
                   [Path.join(data_dir, "ipc/home.sock"), lost_root, candidate_file, "lookup"],
                   16384,
                   15000,
                   Base.url_encode64(credential, padding: false) <> "\n"
                 )

        assert {:ok, after_lost} = Store.revision(store)
        assert after_lost == before_lost + 1

        assert ["wotex-home.native-pending.v6", _, []] =
                 JSON.decode!(File.read!(Path.join(lost_root, "native-pending-v1.json")))

        for fault <-
              ~w(candidate-missing candidate-invalid candidate-future stale-basis watermark) do
          native_root = Path.join(root, family <> "-" <> fault)
          File.mkdir!(native_root)
          File.chmod!(native_root, 0o700)
          candidate_file = private(native_root, "candidate.json", JSON.encode!(candidate))

          content = %{
            "mode" => "source",
            "evidence" => fixture("authoring-sources")[family]["evidence"],
            "unresolved_paths" => [],
            "envelope_ref" => nil
          }

          private(native_root, "review-content.json", JSON.encode!(content))
          {:ok, before} = Store.revision(store)
          proxy = Path.join(root, family <> "-" <> fault <> ".sock")

          {:ok, listener} =
            :gen_tcp.listen(0, [
              :binary,
              active: false,
              ifaddr: {:local, String.to_charlist(proxy)}
            ])

          File.chmod!(proxy, 0o600)
          {:ok, captured} = Agent.start_link(fn -> nil end)

          peer =
            Task.async(fn ->
              proxy_loop(
                listener,
                Path.join(data_dir, "ipc/home.sock"),
                native_root,
                captured,
                fault
              )
            end)

          result =
            Woh.Tool.Command.run_diagnostic(
              executable,
              [proxy, native_root, candidate_file, "refused"],
              16384,
              15000,
              Base.url_encode64(credential, padding: false) <> "\n"
            )

          :gen_tcp.close(listener)
          Task.await(peer, 5000)
          assert {:ok, "refused\n"} = result
          assert Agent.get(captured, & &1) == nil
          Agent.stop(captured)
          assert {:ok, ^before} = Store.revision(store)
          refute File.exists?(Path.join(native_root, "native-pending-v1.json"))
        end

        base_content = %{
          "mode" => "source",
          "evidence" => [],
          "unresolved_paths" => [],
          "envelope_ref" => nil
        }

        invalid_files = [
          JSON.encode!(Map.put(base_content, "extra", true)),
          "{\"mode\":\"source\",\"mode\":\"source\"}",
          JSON.encode!(%{
            base_content
            | "evidence" => [
                %{
                  "instance_path" => "/profile/binding",
                  "source_ref" => source["object_digest"],
                  "locator" => "bad\nlocator"
                }
              ]
          }),
          JSON.encode!(%{
            base_content
            | "unresolved_paths" => ["/profile/binding", "/profile/binding"]
          }),
          String.duplicate("x", 131_073)
        ]

        for {bytes, n} <- Enum.with_index(invalid_files) do
          native_root = Path.join(root, family <> "-invalid-#{n}")
          File.mkdir!(native_root)
          File.chmod!(native_root, 0o700)
          candidate_file = private(native_root, "candidate.json", JSON.encode!(candidate))
          private(native_root, "review-content.json", bytes)
          {:ok, before} = Store.revision(store)

          assert {:ok, "refused\n"} =
                   Woh.Tool.Command.run_diagnostic(
                     executable,
                     [
                       Path.join(data_dir, "ipc/home.sock"),
                       native_root,
                       candidate_file,
                       "refused"
                     ],
                     16384,
                     15000,
                     Base.url_encode64(credential, padding: false) <> "\n"
                   )

          assert {:ok, ^before} = Store.revision(store)
          refute File.exists?(Path.join(native_root, "native-pending-v1.json"))
        end
      after
        Supervisor.stop(host)
      end
    end
  end

  defp proxy_loop(listener, destination, root, captured, fault \\ nil, dropped \\ nil) do
    case :gen_tcp.accept(listener, 10000) do
      {:ok, peer} ->
        try do
          {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 3000)
          {:ok, bytes} = :gen_tcp.recv(peer, size, 3000)
          {:ok, request} = WotexHome.LocalAPI.Frame.decode_request(bytes)

          if request["operation"] in ~w(authoring_upload_begin authoring_candidate_review) do
            [
              "wotex-home.native-pending.v6",
              _,
              [["authoring", _, _, ["authoring_operation", "review", original, nil], ["pending"]]]
            ] = JSON.decode!(File.read!(Path.join(root, "native-pending-v1.json")))

            {:ok, _} = AuthoringReview.decode(original)
            Agent.update(captured, fn _ -> original end)
          end

          {:ok, response} = WotexHome.LocalAPI.Client.request(destination, request)

          response =
            case {fault, request["operation"]} do
              {"candidate-missing", "authoring_candidate_status"} ->
                %{"api_version" => 1, "outcome" => "not_found"}

              {"candidate-invalid", "authoring_candidate_status"} ->
                put_in(response, ["authoring_candidate_receipt", "disposition"], "invalid")

              {"candidate-future", "authoring_candidate_status"} ->
                put_in(response, ["authoring_candidate_receipt", "revision"], 999_999)

              {"stale-basis", "authoring_candidate_status"} ->
                put_in(
                  response,
                  ["authoring_candidate_receipt", "basis_sha256"],
                  String.duplicate("0", 64)
                )

              {"watermark", "controller_identity"} ->
                put_in(response, ["controller_identity", "store_revision"], 0)

              _ ->
                response
            end

          drop =
            dropped != nil and request["operation"] == "authoring_candidate_review" and
              request["input_ref"] != nil and
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
