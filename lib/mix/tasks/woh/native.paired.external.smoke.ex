defmodule Mix.Tasks.Woh.Native.Paired.External.Smoke do
  @moduledoc """
  Checks paired external-profile preparation and original recovery over pinned TLS.

  Run from the repository root with an Apple Silicon macOS Swift 6 toolchain:

      mix woh.native.paired.external.smoke

  The task compiles shared native sources for macOS 15 and pairs disposable
  controllers against `WotexHome.Authority`, `WotexHome.Durable.Store`, profile
  custody and loopback `WotexHome.ControllerConnections.Server` TLS listeners.
  Temperature and research families compare guided and complete-file preparation
  for inspection, trust approval/revocation and target selection/revocation.
  Each original is submitted once, its committed reply is discarded, and a
  separate native process resolves it by status without replay. Inspection
  recovery also follows a Store/listener restart.

  Checks cover lookup, exact retry and explicit absence acknowledgement. Scope
  refusals precede private document loading; cancellation and unknown-outcome
  acknowledgement are invalid for these originals. Revoked credentials leave
  retained journal state unchanged. Actual unsigned session factories refuse
  before clock or Keychain work.

  Fixture keys use private temporary files and stdin, never command arguments.
  Raw-key transport and file checks create no signed app seal. Installed signed
  success, OS accessibility and physical publisher qualification remain separate
  evidence. Reported native fixture failures raise `Mix.Error`.
  """

  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Check paired external profile originals over TLS"
  alias Woh.Tool.{Command, NativeFixture}
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.ControllerConnections.{InstallationIdentity, PairingReview, Server}

  alias WotexHome.Profiles.{
    Custody,
    ReaderSelection,
    ExternalSourceSelection,
    ExternalSourceOwner,
    AuthoringObject
  }

  @owner __MODULE__.Store
  @peer WotexHome.TestSupport.ControllerTLSFixture
  @compile {:no_warn_undefined, WotexHome.TestSupport.ControllerTLSFixture}

  def run([]) do
    Code.require_file("test/support/controller_tls_fixture.exs")

    root =
      directory(
        "/private/tmp",
        "paired-external-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    executable = Path.join(root, "paired")

    sources =
      Path.wildcard("native/macos/Sources/*.swift")
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(LocalHealthClient WotexHomeApp)))

    try do
      case NativeFixture.compile(
             File.cwd!(),
             "NativePairedExternalProfileSmoke.swift",
             executable,
             sources
           ) do
        :ok -> for family <- ~w(temperature research), do: family(root, executable, family)
        {:error, reason} -> Mix.raise(reason)
      end

      Mix.shell().info(
        "paired external both-family originals, TLS/Store restart, scope refusals and unsigned factories passed"
      )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.paired.external.smoke")
  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp directory(parent, name) do
    path = Path.join(parent, name)
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp revision(store) do
    {:ok, value} = Store.revision(store)
    value
  end

  defp stop(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid))

  defp start(root, identity, binding, reader, selection) do
    {:ok, custody} = Custody.start_link(root: directory(root, "objects"), store_owner: @owner)
    {:ok, source} = ExternalSourceOwner.start_link(publisher: self())
    {:ok, _} = ExternalSourceOwner.publish(source, selection)

    {:ok, store} =
      Store.start_link(
        name: @owner,
        path: Path.join(root, "home.sqlite"),
        profile_custody: custody,
        external_reader: reader,
        external_source_owner: source
      )

    {:ok, reviews} = PairingReview.start_link(store_owner: store)
    authority = Authority.new(store: store, pairing_reviews: reviews, profile_custody: custody)

    {:ok, server} =
      Server.start_link(enabled: true, authority: authority, identity: identity, binding: binding)

    %{
      store: store,
      custody: custody,
      source: source,
      reviews: reviews,
      authority: authority,
      server: server
    }
  end

  defp stop_owner(c), do: Enum.each([c.server, c.reviews, c.store, c.source, c.custody], &stop/1)

  defp family(parent, executable, family) do
    root = directory(parent, family)
    native = directory(root, "native")
    input = fixture("external-source-selections")[family]["inputs"]
    r = input["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, selection} = ExternalSourceSelection.new(input["source"], reader, input["channels"])
    now = System.os_time(:second)

    {:ok, identity} =
      InstallationIdentity.create(Path.join(root, "owner.identity"), %{
        not_before: now - 60,
        not_after: now + 86400
      })

    {:ok, interfaces} = :inet.getifaddrs()

    {interface, _} =
      Enum.find(interfaces, fn {_, props} ->
        {127, 0, 0, 1} in Keyword.get_values(props, :addr)
      end)

    {:ok, reserved} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(reserved)
    :gen_tcp.close(reserved)
    binding = %{interface: List.to_string(interface), address: {127, 0, 0, 1}, port: port}
    first = start(root, identity, binding, reader, selection)

    try do
      {:ok, template} = Server.template(first.server)
      {:ok, admin, invitation} = Authority.pairing_open(first.authority, template)

      request =
        @peer.request()
        |> Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)))

      {:ok, reference} = Authority.pairing_prepare(first.authority, admin, request)

      {:ok, _} =
        Authority.pairing_approve(first.authority, admin, reference, %{
          "permissions" => ~w(enroll:review host:maintain profile:manage),
          "target_ids" => []
        })

      invoke(executable, %{
        "mode" => "stage",
        "directory" => native,
        "invitation" => @peer.invitation_body(invitation),
        "bootstrap" => bootstrap(request)
      })

      credential = File.read!(Path.join(native, "raw-fixture.key"))
      objects = imports(first.store, credential, family)

      c =
        Map.merge(first, %{
          native: native,
          executable: executable,
          credential: credential,
          objects: objects,
          reader: reader
        })

      inspection = inspection(c, "inspection:paired")
      invoke(c, "unsigned", "inspection", inspection)
      before = revision(c.store)
      invoke(c, "lost", "inspection", inspection)
      true = revision(c.store) == before + 1
      stop_owner(first)
      restarted = start(root, identity, binding, reader, selection)
      c = Map.merge(c, restarted)

      try do
        before = revision(c.store)
        invoke(c, "recover", "inspection", inspection)
        ^before = revision(c.store)

        {:ok, inspected} =
          Authority.external_inspection_status(
            c.authority,
            credential,
            1,
            inspection["operation_id"]
          )

        ref =
          Map.take(
            inspected,
            ~w(authority_epoch operation_id revision input_sha256 result_sha256)
          )

        {:ok, _} =
          Store.begin_maintenance(
            c.store,
            credential,
            1,
            "maintenance:paired-external",
            revision(c.store)
          )

        digest = fixture("external-trust")[family]["artifact_digest"]

        approve =
          Map.merge(common(c, "approve:paired"), %{
            "action" => "approve",
            "artifact_digest" => digest,
            "expected_trust_revision" => 0,
            "expected_policy_generation" => 0,
            "inspection_ref" => ref,
            "acknowledgement" => "operator_digest_approval"
          })

        lost(c, "trust", approve, ref)

        {:ok, trusted} =
          Authority.external_trust_status(c.authority, credential, 1, approve["operation_id"])

        {:ok, sources} = Authority.external_source_catalogue(c.authority, credential)
        [source] = sources["sources"]

        select =
          Map.merge(common(c, "select:paired"), %{
            "action" => "select",
            "target_id" => "sensor:paired",
            "artifact_digest" => digest,
            "expected_trust_revision" => trusted["revision"],
            "expected_policy_generation" => trusted["policy_generation"],
            "expected_selection_revision" => 0,
            "expected_resource_revision" => 0,
            "source_ref" => source["source_ref"],
            "source_owner_epoch" => sources["owner_epoch"],
            "source_selection_sha256" => source["source_selection_sha256"],
            "objects" => objects,
            "acknowledgement" => "operator_external_selection"
          })

        lost(c, "target", select, ref)

        {:ok, selected} =
          Authority.external_target_status(c.authority, credential, 1, select["operation_id"])

        stop(c.source)
        :sys.replace_state(c.store, &%{&1 | external_reader: nil, profile_custody: nil})

        target =
          Map.merge(
            select,
            Map.merge(common(c, "revoke-target:paired"), %{
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

        lost(c, "target", target)

        trust =
          Map.merge(
            approve,
            Map.merge(common(c, "revoke-trust:paired"), %{
              "action" => "revoke",
              "expected_trust_revision" => trusted["revision"],
              "expected_policy_generation" => trusted["policy_generation"],
              "inspection_ref" => nil,
              "acknowledgement" => nil
            })
          )

        lost(c, "trust", trust)
        absent = inspection(c, "inspection:absent")
        before = revision(c.store)
        invoke(c, "absence", "inspection", absent)
        ^before = revision(c.store)
        invoke(c, "unsigned", "target", target)
        # Leave a complete original, then revoke the paired principal in Store.
        invoke(c, "unsigned", "inspection", absent)

        {:ok, scope} = Store.controller_scope(c.store, credential)
        {:ok, _} = Store.revoke_principal(c.store, scope.principal_id)

        invoke(c, "revoked", "inspection", absent, nil, "unsigned:" <> absent["operation_id"])
        {:ok, %{dispatch_enabled: false}} = Store.health(c.store)
      after
        stop_owner(restarted)
      end
    after
      stop_owner(first)
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

  defp lost(c, kind, original, ref \\ nil) do
    before = revision(c.store)
    invoke(c, "lost", kind, original, ref)
    true = revision(c.store) == before + 1
    invoke(c, "recover", kind, original, ref)
    true = revision(c.store) == before + 1
  end

  defp invoke(c, mode, kind, original, ref \\ nil, journal \\ nil) do
    invoke(c.executable, %{
      "directory" => c.native,
      "mode" => mode,
      "kind" => kind,
      "input" => original,
      "inspection_ref" => ref,
      "journal" =>
        journal ||
          if(mode == "unsigned", do: "unsigned:", else: "original:") <> original["operation_id"]
    })
  end

  defp invoke(executable, input) do
    body = JSON.encode!(input)

    case Command.run_diagnostic(
           executable,
           [],
           16384,
           45000,
           <<byte_size(body)::32, body::binary>>
         ) do
      {:ok, output} ->
        if String.trim(output) != "paired external fixture passed",
          do: Mix.raise("paired external fixture incomplete")

      {:error, reason} ->
        Mix.raise("paired external #{input["mode"]} failed: #{reason}")
    end
  end

  defp bootstrap(request),
    do:
      JSON.encode!([
        "wotex-home.controller-bootstrap-request.v1",
        1,
        request["controller_id"],
        request["invitation_id"],
        request["client_id"],
        request["request_id"],
        Base.url_encode64(request["client_label"], padding: false),
        request["bootstrap_secret"]
      ])

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
