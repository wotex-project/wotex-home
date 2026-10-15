defmodule Woh.Tool.NativeExternalMutationLive do
  @moduledoc false

  alias Woh.Tool.{Command, NativeFixture, NativePairedRecoverySources}
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.LocalAPI.{Client, Frame, Server}

  alias WotexHome.Profiles.{
    AuthoringObject,
    Custody,
    ExternalReportOwner,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ReaderSelection
  }

  @owner __MODULE__.Store

  def run(project) do
    root = Path.join("/private/tmp", "external-sdk-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "client")

    sources =
      Enum.uniq(["NativePendingCoordinator" | NativePairedRecoverySources.names()]) --
        ["LocalHealthClient"]

    try do
      with :ok <-
             NativeFixture.compile(
               project,
               "NativeExternalProfileMutationLiveSmoke.swift",
               executable,
               sources
             ) do
        for family <- ~w(temperature research), do: owner(root, executable, family)
        :ok
      end
    after
      File.rm_rf!(root)
    end
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))
  defp stop(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid))

  defp revision(store) do
    {:ok, value} = Store.revision(store)
    value
  end

  defp directory(parent, name) do
    path = Path.join(parent, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp native(executable, socket, credential, journal, mode, kind, input) do
    stdin =
      Base.encode64(credential) <>
        "\n" <> JSON.encode!(%{"kind" => kind, "input" => input}) <> "\n"

    case Command.run_diagnostic(executable, [socket, journal, mode], 16_384, 15_000, stdin) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.raise("external SDK #{kind}/#{mode} Store workflow failed: #{reason}")
    end
  end

  defp lost(parent, executable, socket, credential, journal, kind, input, mode \\ "lost") do
    path = Path.join(parent, "lost-#{kind}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    mutation =
      if kind == "inspection", do: "external_profile_inspect", else: "external_#{kind}_change"

    operations = [
      "controller_identity",
      "controller_identity",
      "controller_identity",
      "external_#{kind}_status",
      mutation
    ]

    proxy =
      Task.async(fn ->
        for operation <- operations do
          {:ok, peer} = :gen_tcp.accept(listener, 5000)

          try do
            {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(peer, 4, 5000)
            {:ok, body} = :gen_tcp.recv(peer, size, 5000)
            {:ok, request} = Frame.decode_request(body)
            ^operation = request["operation"]
            {:ok, response} = Client.request(socket, request)

            if operation != mutation do
              {:ok, frame} = Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
            else
              "ok" = response["outcome"]
            end
          after
            :gen_tcp.close(peer)
          end
        end

        :ok
      end)

    try do
      :ok = native(executable, path, credential, journal, mode, kind, input)
      :ok = Task.await(proxy, 10_000)
    after
      if Process.alive?(proxy.pid), do: Task.shutdown(proxy, :brutal_kill)
      :gen_tcp.close(listener)
      File.rm(path)
    end
  end

  defp owner(parent, executable, family) do
    root = directory(parent, family)
    source = fixture("external-source-selections")[family]["inputs"]
    r = source["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, selection} = ExternalSourceSelection.new(source["source"], reader, source["channels"])
    {:ok, custody} = Custody.start_link(root: directory(root, "profiles"), store_owner: @owner)
    {:ok, sources} = ExternalSourceOwner.start_link(publisher: self())
    {:ok, _} = ExternalSourceOwner.publish(sources, selection)
    {:ok, catalogue} = ExternalSourceOwner.catalogue(sources)

    {:ok, reports} =
      ExternalReportOwner.start_link(
        publisher: self(),
        source_owner: sources,
        store_owner: @owner
      )

    {:ok, store} =
      Store.start_link(
        path: Path.join(root, "home.sqlite"),
        name: @owner,
        profile_custody: custody,
        external_reader: reader,
        external_source_owner: sources,
        external_report_owner: reports
      )

    try do
      {:ok, credential, first} =
        Store.provision_principal(
          store,
          "operator:1",
          ~w(enroll:review host:maintain profile:manage),
          []
        )

      v = fixture(family)

      docs =
        [{"envelope", v["envelope"]}, {"profile", v["profile"]}] ++
          Enum.map(v["definitions"], &{"definition", &1})

      {handles, current} =
        Enum.map_reduce(Enum.with_index(docs), first, fn {{kind, data}, index}, current ->
          {:ok, bytes} = Wotex.JSON.encode(data)
          {:ok, object} = AuthoringObject.new(kind, bytes)
          {:ok, summary} = AuthoringObject.summary(object)

          {:ok, receipt} =
            Store.import_authoring_object(
              store,
              credential,
              %{
                "authority_epoch" => 1,
                "operation_id" => "import:#{index}",
                "expected_revision" => current,
                "object" => summary
              },
              bytes
            )

          {%{
             "object_digest" => summary["object_digest"],
             "first_revision" => receipt["first_revision"]
           }, receipt["revision"]}
        end)

      [envelope, profile | definitions] = handles

      objects = %{
        "envelope_ref" => envelope,
        "profile" => %{"reference" => v["envelope"]["profile"], "object_ref" => profile},
        "definitions" =>
          Enum.zip_with(
            v["envelope"]["definitions"],
            definitions,
            &%{"reference" => &1, "object_ref" => &2}
          )
      }

      socket = Path.join(root, "ipc/home.sock")

      {:ok, server} =
        Server.start_link(
          authority: Authority.new(store: store, profile_custody: custody),
          socket_path: socket
        )

      try do
        inspection = %{
          "authority_epoch" => 1,
          "operation_id" => "inspection:1",
          "expected_revision" => current,
          "inspection" => Map.put(objects, "reader_basis_sha256", reader.data["basis_sha256"])
        }

        inspection_journal = directory(root, "inspection")

        :ok =
          lost(root, executable, socket, credential, inspection_journal, "inspection", inspection)

        true = revision(store) == current + 1
        {:ok, inspected} = Store.external_inspection_status(store, credential, 1, "inspection:1")
        before = revision(store)

        :ok =
          native(
            executable,
            socket,
            credential,
            inspection_journal,
            "lookup",
            "inspection",
            inspection
          )

        ^before = revision(store)
        {:ok, barrier} = Store.begin_maintenance(store, credential, 1, "maintenance:1", before)

        artifact =
          fixture("external-target-selections")[family]["select"]["input"]["artifact_digest"]

        approve = %{
          "authority_epoch" => 1,
          "operation_id" => "trust:1",
          "expected_revision" => barrier.revision,
          "action" => "approve",
          "artifact_digest" => artifact,
          "expected_trust_revision" => 0,
          "expected_policy_generation" => 0,
          "inspection_ref" =>
            Map.take(
              inspected,
              ~w(authority_epoch operation_id revision input_sha256 result_sha256)
            ),
          "acknowledgement" => "operator_digest_approval"
        }

        trust_journal = directory(root, "trust")
        before = revision(store)
        :ok = native(executable, socket, credential, trust_journal, "stage", "trust", approve)

        :ok =
          native(
            executable,
            socket,
            credential,
            trust_journal,
            "lookup-missing",
            "trust",
            approve
          )

        ^before = revision(store)

        :ok =
          lost(
            root,
            executable,
            socket,
            credential,
            trust_journal,
            "trust",
            approve,
            "retry-lost"
          )

        true = revision(store) == before + 1
        {:ok, approved} = Store.external_trust_status(store, credential, 1, "trust:1")
        before = revision(store)
        :ok = native(executable, socket, credential, trust_journal, "retry", "trust", approve)
        ^before = revision(store)

        target = %{
          "authority_epoch" => 1,
          "operation_id" => "selection:1",
          "expected_revision" => revision(store),
          "action" => "select",
          "target_id" => "sensor:external",
          "artifact_digest" => artifact,
          "expected_trust_revision" => approved["revision"],
          "expected_policy_generation" => approved["policy_generation"],
          "expected_selection_revision" => 0,
          "expected_resource_revision" => 0,
          "source_ref" => source["source"]["source_ref"],
          "source_owner_epoch" => catalogue["owner_epoch"],
          "source_selection_sha256" => selection.sha256,
          "objects" => objects,
          "acknowledgement" => "operator_external_selection"
        }

        target_journal = directory(root, "target")
        :ok = lost(root, executable, socket, credential, target_journal, "target", target)
        {:ok, selected} = Store.external_target_status(store, credential, 1, "selection:1")
        stop(reports)
        stop(sources)
        before = revision(store)
        :ok = native(executable, socket, credential, target_journal, "retry", "target", target)
        ^before = revision(store)

        revoke_target =
          Map.merge(target, %{
            "operation_id" => "selection:2",
            "expected_revision" => before,
            "action" => "revoke",
            "expected_selection_revision" => selected["revision"],
            "expected_resource_revision" => selected["resource_revision"],
            "source_ref" => nil,
            "source_owner_epoch" => nil,
            "source_selection_sha256" => nil,
            "objects" => nil,
            "acknowledgement" => nil
          })

        :ok =
          native(
            executable,
            socket,
            credential,
            directory(root, "target-revoke"),
            "submit",
            "target",
            revoke_target
          )

        {:ok, revoked_target} = Store.external_target_status(store, credential, 1, "selection:2")
        true = revoked_target["resource_revision"] == 1
        true = revoked_target["binding_revision"] == selected["binding_revision"]

        revoke_trust =
          Map.merge(approve, %{
            "operation_id" => "trust:2",
            "expected_revision" => revision(store),
            "action" => "revoke",
            "expected_trust_revision" => approved["revision"],
            "expected_policy_generation" => approved["policy_generation"],
            "inspection_ref" => nil,
            "acknowledgement" => nil
          })

        :ok =
          native(
            executable,
            socket,
            credential,
            directory(root, "trust-revoke"),
            "submit",
            "trust",
            revoke_trust
          )

        acknowledgements(root, executable, socket, credential, store, inspection)
        {:ok, %{dispatch_enabled: false}} = Store.health(store)
      after
        stop(server)
      end
    after
      Enum.each([store, reports, sources, custody], &stop/1)
    end
  end

  defp acknowledgements(root, executable, socket, credential, store, inspection) do
    before = revision(store)

    absent =
      Map.merge(inspection, %{
        "operation_id" => "absent:inspection",
        "expected_revision" => before
      })

    journal = directory(root, "absent")
    :ok = native(executable, socket, credential, journal, "stage", "inspection", absent)
    :ok = native(executable, socket, credential, journal, "lookup-missing", "inspection", absent)
    :ok = native(executable, socket, credential, journal, "ack-absent", "inspection", absent)
    ^before = revision(store)

    stale =
      Map.merge(absent, %{"operation_id" => "stale:inspection", "expected_revision" => before - 1})

    journal = directory(root, "stale")
    :ok = native(executable, socket, credential, journal, "refused", "inspection", stale)
    ^before = revision(store)
    :ok = native(executable, socket, credential, journal, "ack-absent", "inspection", stale)
    ^before = revision(store)
    failed = Map.put(absent, "operation_id", "failed:publication")

    :ok =
      native(
        executable,
        socket,
        credential,
        directory(root, "failed"),
        "failed-publication",
        "inspection",
        failed
      )

    ^before = revision(store)
    denied = Map.put(absent, "operation_id", "denied:inspection")
    journal = directory(root, "denied")
    :ok = native(executable, socket, credential, journal, "stage", "inspection", denied)

    {:ok, auditor, _} =
      Store.provision_principal(store, "operator:other", ~w(enroll:review profile:manage), [])

    before = revision(store)
    :ok = native(executable, socket, auditor, journal, "denied", "inspection", denied)
    ^before = revision(store)
    {:ok, _} = Store.revoke_principal(store, "operator:1")
    before = revision(store)
    :ok = native(executable, socket, credential, journal, "denied", "inspection", denied)
    ^before = revision(store)
  end
end
