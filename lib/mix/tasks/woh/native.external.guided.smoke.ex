defmodule Woh.Tool.NativeExternalGuided do
  @moduledoc false

  alias Woh.Tool.{Command, NativeFixture}
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.LocalAPI.{Client, Frame, Server}

  alias WotexHome.Profiles.{
    Custody,
    AuthoringObject,
    ReaderSelection,
    ExternalSourceOwner,
    ExternalSourceSelection
  }

  @owner __MODULE__.Store

  def run(project) do
    root =
      Path.join(
        "/private/tmp",
        "external-guided-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "guided")

    sources =
      Path.wildcard(Path.join(project, "native/macos/Sources/*.swift"))
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(WotexHomeApp LocalHealthClient)))

    try do
      with :ok <-
             NativeFixture.compile(
               project,
               "NativeExternalProfileGuidedSmoke.swift",
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

  defp owner(parent, executable, family) do
    root = directory(parent, family)
    custody_root = directory(root, "objects")
    source = fixture("external-source-selections")[family]["inputs"]
    r = source["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, selection} = ExternalSourceSelection.new(source["source"], reader, source["channels"])
    {:ok, custody} = Custody.start_link(root: custody_root, store_owner: @owner)
    {:ok, sources} = ExternalSourceOwner.start_link(publisher: self())
    {:ok, _} = ExternalSourceOwner.publish(sources, selection)

    {:ok, store} =
      Store.start_link(
        path: Path.join(root, "home.sqlite"),
        name: @owner,
        profile_custody: custody,
        external_reader: reader,
        external_source_owner: sources
      )

    try do
      {:ok, credential, _} =
        Store.provision_principal(
          store,
          "operator:guided",
          ~w(profile:manage enroll:review host:maintain),
          []
        )

      objects = imports(store, credential, family)
      authority = Authority.new(store: store, profile_custody: custody)
      socket = Path.join(root, "ipc/home.sock")
      {:ok, server} = Server.start_link(authority: authority, socket_path: socket)

      c = %{
        root: root,
        executable: executable,
        family: family,
        store: store,
        credential: credential,
        objects: objects,
        authority: authority,
        socket: socket,
        reader: reader,
        sources: sources,
        selection: selection,
        custody: custody
      }

      try do
        first = inspection(c, "inspection:guided")
        :ok = native(c, directory(root, "paired"), "paired", "inspection", first, nil)

        for mode <- ~w(reader delayed stale retire cancel failed-publication failed-resolution) do
          input = inspection(c, "inspection:#{mode}")

          if mode == "failed-publication" do
            before = revision(store)
            :ok = native(c, directory(root, mode), mode, "inspection", input, nil)
            ^before = revision(store)
          else
            :ok = proxy(c, mode, "inspection", input, nil)
          end
        end

        # A missing historical inspection stops before artifact, journal or mutation.
        missing =
          fixture("external-trust")[family]["approve"]["input"]
          |> Map.put("operation_id", "approve:missing")
          |> Map.put("expected_revision", revision(store))
          |> put_in(["inspection_ref", "operation_id"], "inspection:absent")

        :ok = proxy(c, "missing", "approve", missing, missing["inspection_ref"])
        first = inspection(c, "inspection:guided")
        :ok = proxy(c, "lost", "inspection", first, nil)

        {:ok, inspected} =
          Authority.external_inspection_status(authority, credential, 1, first["operation_id"])

        reference =
          Map.take(
            inspected,
            ~w(authority_epoch operation_id revision input_sha256 result_sha256)
          )

        {:ok, _} =
          Store.begin_maintenance(store, credential, 1, "maintenance:guided", revision(store))

        digest = fixture("external-trust")[family]["artifact_digest"]

        approve =
          Map.merge(common(c, "approve:guided"), %{
            "action" => "approve",
            "artifact_digest" => digest,
            "expected_trust_revision" => 0,
            "expected_policy_generation" => 0,
            "inspection_ref" => reference,
            "acknowledgement" => "operator_digest_approval"
          })

        :ok = proxy(c, "lost", "approve", approve, reference)

        {:ok, approved} =
          Authority.external_trust_status(authority, credential, 1, approve["operation_id"])

        {:ok, catalogue} = Authority.external_source_catalogue(authority, credential)
        [source] = catalogue["sources"]

        select =
          Map.merge(common(c, "select:owner"), %{
            "action" => "select",
            "target_id" => "sensor:guided",
            "artifact_digest" => digest,
            "expected_trust_revision" => approved["revision"],
            "expected_policy_generation" => approved["policy_generation"],
            "expected_selection_revision" => 0,
            "expected_resource_revision" => 0,
            "source_ref" => source["source_ref"],
            "source_owner_epoch" => catalogue["owner_epoch"],
            "source_selection_sha256" => source["source_selection_sha256"],
            "objects" => objects,
            "acknowledgement" => "operator_external_selection"
          })

        :ok = proxy(c, "owner", "select", select, reference)
        :ok = proxy(c, "unavailable", "select", select, reference)
        select = Map.put(select, "operation_id", "select:guided")
        :ok = proxy(c, "lost", "select", select, reference)

        {:ok, selected} =
          Authority.external_target_status(authority, credential, 1, select["operation_id"])

        stop(sources)
        :sys.replace_state(store, &%{&1 | external_reader: nil, profile_custody: nil})

        revoke_target =
          Map.merge(
            select,
            Map.merge(common(c, "revoke-target:guided"), %{
              "action" => "revoke",
              "expected_selection_revision" => selected["revision"],
              "expected_resource_revision" => selected["resource_revision"],
              "source_ref" => nil,
              "source_owner_epoch" => nil,
              "source_selection_sha256" => nil,
              "objects" => nil,
              "acknowledgement" => nil
            })
          )

        :ok = proxy(c, "submit", "revokeTarget", revoke_target, nil)

        revoke_trust =
          Map.merge(
            approve,
            Map.merge(common(c, "revoke-trust:guided"), %{
              "action" => "revoke",
              "expected_trust_revision" => approved["revision"],
              "expected_policy_generation" => approved["policy_generation"],
              "inspection_ref" => nil,
              "acknowledgement" => nil
            })
          )

        :ok = proxy(c, "submit", "revokeTrust", revoke_trust, nil)
        true = :sys.get_state(custody).leases == %{}
        {:ok, %{dispatch_enabled: false}} = Store.health(store)
      after
        stop(server)
      end
    after
      Enum.each([store, sources, custody], &stop/1)
    end
  end

  defp common(c, operation),
    do: %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision(c.store)
    }

  defp inspection(c, operation),
    do:
      Map.put(
        common(c, operation),
        "inspection",
        Map.put(c.objects, "reader_basis_sha256", c.reader.data["basis_sha256"])
      )

  defp native(c, root, mode, method, input, reference) do
    rendering = c.family == "temperature" and mode in ~w(lost reader missing submit)

    stdin =
      Base.encode64(c.credential) <>
        "\n" <>
        JSON.encode!(%{
          "method" => method,
          "input" => input,
          "inspection_ref" => reference,
          "render" => rendering
        }) <> "\n"

    case Command.run_diagnostic(c.executable, [c.socket, root, mode], 16384, 45_000, stdin) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("guided #{method}/#{mode} failed: #{reason}")
    end
  end

  defp kind("inspection"), do: "inspection"
  defp kind(method) when method in ~w(approve revokeTrust), do: "trust"
  defp kind(_), do: "target"

  defp group(method, input, ref) do
    initial = [
      {"controller_identity", %{}},
      {"external_profile_context", %{}},
      {"external_profiles", %{}}
    ]

    history =
      if method in ~w(approve select),
        do: [
          {"external_inspection_status", Map.take(ref, ~w(authority_epoch operation_id))},
          {"external_inspection_artifact", %{"inspection_ref" => ref}}
        ],
        else: []

    target =
      if method in ~w(select revokeTarget),
        do: [{"external_target_basis", Map.take(input, ~w(target_id))}],
        else: []

    sources = if method == "select", do: [{"external_source_catalogue", %{}}], else: []

    initial ++
      history ++
      target ++
      sources ++
      [
        {"external_profile_context", %{}},
        {"external_#{kind(method)}_status", Map.take(input, ~w(authority_epoch operation_id))},
        {"controller_identity", %{}}
      ]
  end

  defp proxy(c, mode, method, input, ref) do
    root = directory(c.root, "#{method}-#{mode}")
    socket = Path.join(root, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(socket)}])

    File.chmod!(socket, 0o600)

    prefix =
      if method == "select",
        do: [
          {"controller_identity", %{}},
          {"external_source_catalogue", %{}},
          {"controller_identity", %{}}
        ],
        else: []

    group = group(method, input, ref)
    n = length(group)
    p = length(prefix)

    original_status =
      {"external_#{kind(method)}_status", Map.take(input, ~w(authority_epoch operation_id))}

    mutation =
      {if(method == "inspection",
         do: "external_profile_inspect",
         else: "external_#{kind(method)}_change"
       ), %{if(method == "inspection", do: "inspection", else: "change") => input}}

    submit =
      prefix ++
        group ++
        group ++
        [{"controller_identity", %{}}, {"controller_identity", %{}}, original_status, mutation]

    operations =
      case mode do
        "reader" ->
          Enum.take(group, 4)

        "missing" ->
          Enum.take(group, 4)

        "unavailable" ->
          prefix ++ Enum.take(group, 8)

        "delayed" ->
          group

        m when m in ~w(stale owner) ->
          prefix ++ group ++ group

        m when m in ~w(retire cancel) ->
          prefix ++
            group ++
            group ++ [{"controller_identity", %{}}, {"controller_identity", %{}}, original_status]

        "lost" ->
          submit

        _ ->
          submit ++ [{"controller_identity", %{}}]
      end

    before = revision(c.store)

    task =
      Task.async(fn ->
        for {{operation, fields}, index} <- Enum.with_index(operations) do
          {:ok, peer} = :gen_tcp.accept(listener, 30_000)

          try do
            {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(peer, 4, 5000)
            {:ok, body} = :gen_tcp.recv(peer, size, 5000)
            {:ok, request} = Frame.decode_request(body)

            expected =
              Map.merge(
                %{
                  "api_version" => 1,
                  "credential" => Base.url_encode64(c.credential, padding: false),
                  "operation" => operation
                },
                fields
              )

            if request != expected,
              do: Mix.raise("guided #{method}/#{mode} request #{index} differed")

            if mode == "reader" and index == 3,
              do: :sys.replace_state(c.store, &%{&1 | external_reader: nil})

            if mode == "unavailable" and index == p + 6,
              do: :sys.replace_state(c.store, &%{&1 | external_source_owner: nil})

            {:ok, response} = Client.request(c.socket, request)

            cond do
              mode == "stale" and index == p + n - 1 ->
                {:ok, _, _} = Store.provision_principal(c.store, "race:#{method}", ["read"], [])

              mode == "owner" and index == p + n - 1 ->
                {:ok, replacement} = ExternalSourceOwner.start_link(publisher: self())
                {:ok, _} = ExternalSourceOwner.publish(replacement, c.selection)
                :sys.replace_state(c.store, &%{&1 | external_source_owner: replacement})

              (mode == "delayed" and index == n - 1) or
                  (mode in ~w(retire cancel) and index == length(operations) - 1) ->
                File.write!(Path.join(root, "held"), "")
                wait_file(Path.join(root, "released"), System.monotonic_time(:millisecond) + 5000)

              mode == "failed-resolution" and index == length(operations) - 1 ->
                file = Path.join(root, "pending/native-pending-v1.json")
                [format, revision, entries] = JSON.decode!(File.read!(file))
                File.write!(file, JSON.encode!([format, revision + 1, entries]))
                File.chmod!(file, 0o600)

              true ->
                :ok
            end

            if operation == elem(mutation, 0) do
              "ok" = response["outcome"]
            end

            unless mode == "lost" and operation == elem(mutation, 0) do
              {:ok, frame} = Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
            end
          after
            :gen_tcp.close(peer)
          end
        end

        :ok
      end)

    try do
      :ok = native(%{c | socket: socket}, root, mode, method, input, ref)
      :ok = Task.await(task, 10_000)

      if mode in ~w(lost failed-resolution) do
        :ok = native(c, root, "recover", method, input, ref)
      end

      after_revision = revision(c.store)

      cond do
        mode == "stale" ->
          true = after_revision == before + 1

        mode in ~w(reader missing delayed retire cancel owner unavailable) ->
          true = after_revision == before

        true ->
          true = after_revision > before
      end

      :ok
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
      if mode == "reader", do: :sys.replace_state(c.store, &%{&1 | external_reader: c.reader})

      if mode == "unavailable",
        do: :sys.replace_state(c.store, &%{&1 | external_source_owner: c.sources})

      if mode == "owner" do
        owner = :sys.get_state(c.store).external_source_owner
        :sys.replace_state(c.store, &%{&1 | external_source_owner: c.sources})
        if owner != c.sources, do: stop(owner)
      end
    end
  end

  defp wait_file(path, deadline) do
    cond do
      File.regular?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Mix.raise("guided held reply was not released")

      true ->
        Process.sleep(5)
        wait_file(path, deadline)
    end
  end

  defp imports(store, credential, family) do
    data = fixture(family)

    docs =
      [{"envelope", data["envelope"]}, {"profile", data["profile"]}] ++
        Enum.map(data["definitions"], &{"definition", &1})

    handles =
      Enum.with_index(docs)
      |> Enum.map(fn {{kind, value}, index} ->
        {:ok, bytes} = Wotex.JSON.encode(value)
        {:ok, object} = AuthoringObject.new(kind, bytes)
        {:ok, summary} = AuthoringObject.summary(object)

        {:ok, receipt} =
          Store.import_authoring_object(
            store,
            credential,
            %{
              "authority_epoch" => 1,
              "operation_id" => "import:#{index}",
              "expected_revision" => revision(store),
              "object" => summary
            },
            bytes
          )

        %{
          "object_digest" => summary["object_digest"],
          "first_revision" => receipt["first_revision"]
        }
      end)

    [envelope, profile | definitions] = handles

    %{
      "envelope_ref" => envelope,
      "profile" => %{"reference" => data["envelope"]["profile"], "object_ref" => profile},
      "definitions" =>
        Enum.zip_with(
          data["envelope"]["definitions"],
          definitions,
          &%{"reference" => &1, "object_ref" => &2}
        )
    }
  end
end

defmodule Mix.Tasks.Woh.Native.External.Guided.Smoke do
  @moduledoc """
  Checks guided external-profile decisions through the shared native app model.

  Run from the repository root with an Apple Silicon macOS Swift 6 toolchain
  and AppKit rendering support:

      mix woh.native.external.guided.smoke

  The task compiles shared application models and views into a fixture executable
  targeting macOS 15. Temperature and research families use disposable
  `WotexHome.Durable.Store` instances, `WotexHome.Authority` and private
  `WotexHome.LocalAPI.Server` sockets. Private forwarding peers check exact
  request sequences while injecting changed reader/source/revision, held replies
  and lost replies. Cases exercise separate confirmation, cancellation,
  retirement, pending publication/resolution failures and exact status recovery
  across inspection, trust and target decisions. Fixture credentials reach the
  executable through stdin.

  Selected temperature-family form states are mounted in AppKit windows and
  captured under `_build/native/external-guided-*.png` at widths from 480 to
  1,320 points, including responsive breakpoints. Normal and 1.4-times whole-panel
  scaling provide layout stress; these captures do not exercise OS text-size
  preferences or establish a completed visual accessibility review.

  Success reports both-family Store, race/recovery and mounted checks; reported
  check failures raise `Mix.Error`. Evidence covers shared app code in a fixture
  process. Installed app lifecycle, signing, OS accessibility settings and
  physical-device qualification remain separate checks.
  """

  use Mix.Task
  @shortdoc "Check selected guided external profile decisions"
  @requirements ["loadpaths"]
  def run([]) do
    case Woh.Tool.NativeExternalGuided.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "guided external decisions passed both-family Store, race/recovery and mounted layout checks"
        )

      {:error, reason} ->
        Mix.raise("guided external checks failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.guided.smoke")
end
