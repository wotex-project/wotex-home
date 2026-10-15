defmodule Woh.Tool.NativeExternalProfileLive do
  @moduledoc false

  alias Woh.Tool.{Command, NativeFixture}
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.LocalAPI.{Client, Frame, Server}

  alias WotexHome.Profiles.{
    AuthoringObject,
    Custody,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ReaderSelection
  }

  @owner __MODULE__.Store

  def run(project) do
    root =
      Path.join("/private/tmp", "external-profile-native-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "client")

    try do
      with :ok <-
             NativeFixture.compile(project, "NativeExternalProfileReadSmoke.swift", executable, [
               "NativeExternalProfileClient"
             ]) do
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
    {:ok, revision} = Store.revision(store)
    revision
  end

  defp read(
         executable,
         socket,
         credential,
         category,
         expected,
         epoch_or_count,
         operation_or_state \\ "",
         sha \\ ""
       ) do
    mode =
      Enum.join(["live-" <> category, expected, epoch_or_count, operation_or_state, sha], "|")

    case Command.run_diagnostic(
           executable,
           [socket, mode],
           16_384,
           10_000,
           Base.encode64(credential) <> "\n"
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.raise("native external-profile #{category}/#{expected} Store read failed: #{reason}")
    end
  end

  defp revision_race(root, executable, socket, credential, store, category, receipt) do
    path = Path.join(root, "race-#{category}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    domain =
      if category == "catalogue", do: "external_profiles", else: "external_inspection_status"

    before = revision(store)

    proxy =
      Task.async(fn ->
        for operation <- ["controller_identity", domain, "controller_identity"] do
          {:ok, peer} = :gen_tcp.accept(listener, 5000)

          try do
            {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(peer, 4, 5000)
            {:ok, body} = :gen_tcp.recv(peer, size, 5000)
            {:ok, request} = Frame.decode_request(body)
            ^operation = request["operation"]
            {:ok, response} = Client.request(socket, request)

            if operation == domain do
              {:ok, _, _} = Store.provision_principal(store, "race:#{category}", ["read"], [])
            end

            {:ok, frame} = Frame.encode_response(response)
            :ok = :gen_tcp.send(peer, frame)
          after
            :gen_tcp.close(peer)
          end
        end

        :ok
      end)

    try do
      if category == "catalogue" do
        read(executable, path, credential, category, "guard", 1)
      else
        original(executable, path, credential, category, receipt)
      end

      :ok = Task.await(proxy, 10_000)
      true = revision(store) == before + 1
    after
      if Process.alive?(proxy.pid), do: Task.shutdown(proxy, :brutal_kill)
      :gen_tcp.close(listener)
      File.rm(path)
    end
  end

  defp original(executable, socket, credential, kind, receipt),
    do:
      read(
        executable,
        socket,
        credential,
        kind,
        "valid",
        receipt["authority_epoch"],
        receipt["operation_id"],
        receipt["input_sha256"]
      )

  defp owner(parent, executable, family) do
    root = Path.join(parent, family)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    source = fixture("external-source-selections")[family]["inputs"]
    r = source["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, selection} = ExternalSourceSelection.new(source["source"], reader, source["channels"])
    {:ok, custody} = Custody.start_link(root: custody_root, store_owner: @owner)
    {:ok, sources} = ExternalSourceOwner.start_link(publisher: self())
    {:ok, _} = ExternalSourceOwner.publish(sources, selection)
    {:ok, source_catalogue} = ExternalSourceOwner.catalogue(sources)

    {:ok, reports} =
      WotexHome.Profiles.ExternalReportOwner.start_link(
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

      {:ok, inspected} =
        Store.inspect_external_profile(store, credential, %{
          "authority_epoch" => 1,
          "operation_id" => "inspection:1",
          "expected_revision" => current,
          "inspection" => Map.put(objects, "reader_basis_sha256", reader.data["basis_sha256"])
        })

      {:ok, barrier} =
        Store.begin_maintenance(store, credential, 1, "maintenance:1", inspected["revision"])

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

      {:ok, approved} = Store.change_external_trust(store, credential, approve)

      input = %{
        "authority_epoch" => 1,
        "operation_id" => "selection:1",
        "expected_revision" => approved["revision"],
        "action" => "select",
        "target_id" => "sensor:external",
        "artifact_digest" => artifact,
        "expected_trust_revision" => approved["revision"],
        "expected_policy_generation" => approved["policy_generation"],
        "expected_selection_revision" => 0,
        "expected_resource_revision" => 0,
        "source_ref" => source["source"]["source_ref"],
        "source_owner_epoch" => source_catalogue["owner_epoch"],
        "source_selection_sha256" => selection.sha256,
        "objects" => objects,
        "acknowledgement" => "operator_external_selection"
      }

      {:ok, selected} = Store.change_external_target(store, credential, input)
      socket = Path.join(root, "ipc/home.sock")

      {:ok, server} =
        Server.start_link(
          authority: Authority.new(store: store, profile_custody: custody),
          socket_path: socket
        )

      try do
        before = revision(store)
        read(executable, socket, credential, "catalogue", "valid", 1, "approved")
        original(executable, socket, credential, "inspection", inspected)
        original(executable, socket, credential, "trust", approved)
        original(executable, socket, credential, "target", selected)

        for kind <- ~w(inspection trust target),
            do: read(executable, socket, credential, kind, "missing", 1, "absent:read")

        ^before = revision(store)
        revision_race(root, executable, socket, credential, store, "catalogue", inspected)
        revision_race(root, executable, socket, credential, store, "inspection", inspected)

        {:ok, target_revoke} =
          Store.change_external_target(
            store,
            credential,
            Map.merge(input, %{
              "action" => "revoke",
              "operation_id" => "selection:2",
              "expected_revision" => revision(store),
              "expected_selection_revision" => selected["revision"],
              "expected_resource_revision" => selected["resource_revision"],
              "source_ref" => nil,
              "source_owner_epoch" => nil,
              "source_selection_sha256" => nil,
              "objects" => nil,
              "acknowledgement" => nil
            })
          )

        {:ok, revoked} =
          Store.change_external_trust(
            store,
            credential,
            Map.merge(approve, %{
              "action" => "revoke",
              "operation_id" => "trust:2",
              "expected_revision" => revision(store),
              "expected_trust_revision" => approved["revision"],
              "expected_policy_generation" => approved["policy_generation"],
              "inspection_ref" => nil,
              "acknowledgement" => nil
            })
          )

        before = revision(store)
        # Reconciliation must survive unavailable live publishers.
        stop(reports)
        stop(sources)
        false = Process.alive?(reports)
        false = Process.alive?(sources)
        read(executable, socket, credential, "catalogue", "valid", 1, "revoked")
        original(executable, socket, credential, "inspection", inspected)
        original(executable, socket, credential, "trust", approved)
        original(executable, socket, credential, "trust", revoked)
        original(executable, socket, credential, "target", selected)
        original(executable, socket, credential, "target", target_revoke)
        ^before = revision(store)

        {:ok, _} =
          Store.change_external_trust(
            store,
            credential,
            Map.merge(approve, %{
              "operation_id" => "trust:3",
              "expected_revision" => revision(store),
              "expected_trust_revision" => revoked["revision"],
              "expected_policy_generation" => revoked["policy_generation"]
            })
          )

        {:ok, auditor, _} =
          Store.provision_principal(store, "auditor:1", ["enroll:review", "profile:manage"], [])

        {:ok, denied, _} = Store.provision_principal(store, "reader:1", ["read"], [])
        {:ok, manager, _} = Store.provision_principal(store, "manager:1", ["profile:manage"], [])
        before = revision(store)
        read(executable, socket, denied, "catalogue", "refused", 0)
        read(executable, socket, manager, "catalogue", "valid", 1, "approved")
        read(executable, socket, manager, "inspection", "missing", 1, inspected["operation_id"])
        read(executable, socket, manager, "trust", "missing", 1, approved["operation_id"])
        read(executable, socket, manager, "target", "refused", 1, selected["operation_id"])

        for kind <- ~w(inspection trust target) do
          read(executable, socket, denied, kind, "refused", 1, "absent:read")
          read(executable, socket, auditor, kind, "missing", 1, "absent:read")
        end

        ^before = revision(store)
        {:ok, _} = Store.revoke_principal(store, "operator:1")
        before = revision(store)
        read(executable, socket, auditor, "catalogue", "valid", 1, "author_unavailable")
        read(executable, socket, credential, "catalogue", "unauthorized", 0)

        for {kind, receipt} <- [
              {"inspection", inspected},
              {"trust", approved},
              {"target", selected}
            ] do
          read(executable, socket, credential, kind, "unauthorized", 1, receipt["operation_id"])
          read(executable, socket, auditor, kind, "missing", 1, receipt["operation_id"])
        end

        ^before = revision(store)
        {:ok, %{dispatch_enabled: false}} = Store.health(store)
      after
        stop(server)
      end
    after
      Enum.each([store, reports, sources, custody], &stop/1)
    end
  end
end
