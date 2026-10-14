defmodule WotexHome.PrivateProfileNativeReviewTest do
  use ExUnit.Case, async: false
  alias WotexHome.Host
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.AuthoringObject
  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp write(root, name, bytes, mode \\ 0o600) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, mode)
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
          "expected_revision" => revision,
          "operation_id" => operation,
          "object" => summary
        },
        bytes
      )

    %{"object_digest" => summary["object_digest"], "first_revision" => receipt["first_revision"]}
  end

  @tag requires_socket: true
  @tag timeout: 120_000
  test "native complete review without installed capture resolves its known refusal" do
    root =
      Path.join("/private/tmp", "private-profile-native-#{System.unique_integer([:positive])}")

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
      data = Path.join(root, family)
      File.mkdir!(data)
      File.chmod!(data, 0o700)

      write(
        data,
        WotexHome.Host.ProfileConfiguration.filename(),
        JSON.encode!(%{
          "format" => "wotex-home.profile-authoring-installation@1",
          "installed" => Map.take(v, ~w(bindings contracts home_contracts)),
          "authoring_limits" => fixture("authoring-mechanics")[family]["limits"]
        }),
        0o400
      )

      {:ok, host} = Host.start_link(data_dir: data)

      try do
        store = Host.store()

        {:ok, credential, 1} =
          Store.provision_principal(store, "author:#{family}", ["read", "profile:manage"], [])

        draft =
          import(
            store,
            credential,
            "draft",
            fixture("authoring-mechanics")[family]["draft_bytes"],
            "draft:1"
          )

        source =
          import(
            store,
            credential,
            "source",
            fixture("authoring-sources")[family]["source"]["payload"],
            "source:1"
          )

        envelope =
          import(store, credential, "envelope", JSON.encode!(v["envelope"]), "envelope:1")

        {:ok, export} = Store.authoring_contract_export(store, credential)
        {:ok, revision} = Store.revision(store)

        {:ok, candidate} =
          Store.assess_authoring_candidate(store, credential, %{
            "authority_epoch" => 1,
            "expected_revision" => revision,
            "operation_id" => "candidate:1",
            "request" => %{
              "mode" => "manual",
              "contract_digest" => export["summary"]["contract_sha256"],
              "base_draft_ref" => draft,
              "source_refs" => [source],
              "fixture_refs" => [],
              "instruction" => "",
              "limits" => export["summary"]["limits"]
            }
          })

        native = Path.join(root, family <> "-native")
        File.mkdir!(native)
        File.chmod!(native, 0o700)
        file = write(native, "candidate.json", JSON.encode!(candidate))

        write(
          native,
          "review-content.json",
          JSON.encode!(%{
            "mode" => "complete",
            "evidence" => fixture("authoring-sources")[family]["evidence"],
            "unresolved_paths" => [],
            "envelope_ref" => envelope
          })
        )

        {:ok, before} = Store.revision(store)

        assert {:ok, "refused\n"} =
                 Woh.Tool.Command.run_diagnostic(
                   executable,
                   [Path.join(data, "ipc/home.sock"), native, file, "submit-refused"],
                   16384,
                   15000,
                   Base.url_encode64(credential, padding: false) <> "\n"
                 )

        assert {:ok, ^before} = Store.revision(store)

        assert ["wotex-home.native-pending.v6", _, []] =
                 JSON.decode!(File.read!(Path.join(native, "native-pending-v1.json")))

        assert Host.external_sources() == nil && Host.external_reports() == nil
      after
        Supervisor.stop(host)
      end
    end
  end
end
