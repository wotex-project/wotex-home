defmodule WotexHome.PrivateProfileConfigurationTest do
  @moduledoc false

  use ExUnit.Case, async: false
  import Bitwise
  alias WotexHome.{Host, Authority}
  alias WotexHome.Host.{ProfileConfiguration, ProfileInstallation}
  alias WotexHome.Profiles.{AuthoringObject, AuthoringContract}
  alias WotexHome.Durable.Store
  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp data(family \\ "temperature") do
    v = fixture(family)

    %{
      "format" => "wotex-home.profile-authoring-installation@1",
      "installed" => Map.take(v, ~w(bindings contracts home_contracts)),
      "authoring_limits" => fixture("authoring-mechanics")[family]["limits"]
    }
  end

  defp changed_data(family),
    do: put_in(data(family), ["authoring_limits", "max_check_steps"], 999_999)

  defp root do
    path =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "private-profile-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp write(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o400)
    path
  end

  setup do
    path = root()
    on_exit(fn -> File.rm_rf!(path) end)
    %{root: path}
  end

  test "closed authoring-only data reconstructs both families without capture or publisher" do
    for family <- ~w(temperature research) do
      assert {:ok, input, prepared} = ProfileConfiguration.decode(JSON.encode!(data(family)))
      assert input.mode == :authoring
      assert prepared.capture == nil && prepared.reader == nil && prepared.publisher == nil
      assert {:ok, summary} = AuthoringContract.to_map(prepared.authoring)

      assert summary["contract_sha256"] ==
               fixture("authoring-mechanics")[family]["contract_sha256"]

      assert :ok =
               WotexHome.Profiles.ProducerIdentity.check_current(
                 prepared.authoring.inputs["installed"]["producer"]
               )
    end

    base = data()

    variants = [
      Map.put(base, "extra", true),
      Map.put(base, "format", "unknown"),
      Map.put(base, "capture", %{}),
      Map.put(base, "publisher", "pid"),
      put_in(base, ["installed", "producer"], %{}),
      put_in(base, ["authoring_limits", "max_check_steps"], true),
      put_in(base, ["authoring_limits", "max_check_steps"], 2.0),
      put_in(base, ["authoring_limits", "reader", "max_nodes"], 4097),
      put_in(base, ["installed", "bindings"], [%{}]),
      Map.delete(base, "installed")
    ]

    for value <- variants,
        do: assert(match?({:error, _}, ProfileConfiguration.decode(JSON.encode!(value))))

    for bytes <- [
          "",
          <<255>>,
          "{\"format\":\"x\",\"format\":\"y\"}",
          String.duplicate("x", 262_145),
          String.duplicate("[", 9) <> "0" <> String.duplicate("]", 9)
        ] do
      assert {:error, _} = ProfileConfiguration.decode(bytes)
    end

    assert {:error, :invalid_profile_installation} =
             ProfileInstallation.prepare(%{
               mode: :authoring,
               installed: base["installed"],
               authoring_limits: base["authoring_limits"],
               capture: nil
             })
  end

  test "publication is exact, immutable, idempotent and redacted", c do
    bytes = JSON.encode!(data())
    input = write(c.root, "input.json", bytes)
    assert {:ok, summary} = ProfileConfiguration.publish(c.root, input)
    target = Path.join(c.root, ProfileConfiguration.filename())
    assert File.read!(target) == bytes
    assert band(File.stat!(target).mode, 0o777) == 0o400
    assert File.stat!(target).links == 1
    assert {:ok, ^summary} = ProfileConfiguration.publish(c.root, input)
    assert {:ok, snapshot} = ProfileConfiguration.load(c.root)
    assert :ok = ProfileConfiguration.check(snapshot, c.root)
    refute inspect(snapshot) =~ "bindings"
    refute inspect(snapshot) =~ "urn:example:binding"
    other = write(c.root, "other.json", JSON.encode!(changed_data("research")))
    assert {:error, :profile_configuration_exists} = ProfileConfiguration.publish(c.root, other)
    assert File.read!(target) == bytes

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Woh.Profile.Authoring.Install.run([c.root, input])
      end)

    assert output =~ summary.sha256
    refute output =~ c.root
    refute output =~ "urn:example:binding"
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end

  test "same-size changes, replacement, absence appearance and unsafe custody refuse", c do
    bytes = JSON.encode!(data())
    input = write(c.root, "input.json", bytes)
    assert {:ok, :absent} = ProfileConfiguration.load(c.root)
    assert :ok = ProfileConfiguration.check(:absent, c.root)
    assert {:ok, _} = ProfileConfiguration.publish(c.root, input)
    target = Path.join(c.root, ProfileConfiguration.filename())
    assert {:error, :profile_configuration_changed} = ProfileConfiguration.check(:absent, c.root)
    assert {:ok, snapshot} = ProfileConfiguration.load(c.root)
    changed = String.replace(bytes, "register", "registeX")
    assert byte_size(changed) == byte_size(bytes)
    File.chmod!(target, 0o600)
    File.write!(target, changed)
    File.chmod!(target, 0o400)
    assert {:error, :profile_configuration_changed} = ProfileConfiguration.check(snapshot, c.root)
    File.chmod!(target, 0o600)
    File.write!(target, bytes)
    File.chmod!(target, 0o400)
    File.rm!(target)
    write(c.root, ProfileConfiguration.filename(), bytes)
    assert {:error, :profile_configuration_changed} = ProfileConfiguration.check(snapshot, c.root)

    for mode <- [0o600, 0o440, 0o644] do
      File.chmod!(target, mode)
      assert {:error, :profile_configuration_unavailable} = ProfileConfiguration.load(c.root)
    end

    File.chmod!(target, 0o400)
    link = Path.join(c.root, "linked")
    File.ln!(target, link)
    assert {:error, :profile_configuration_unavailable} = ProfileConfiguration.load(c.root)
    File.rm!(link)
    File.rm!(target)
    File.ln_s!(input, target)
    assert {:error, :profile_configuration_unavailable} = ProfileConfiguration.load(c.root)
    File.rm!(target)
    write(c.root, ProfileConfiguration.filename(), bytes)
    File.chmod!(c.root, 0o755)
    assert {:error, :profile_configuration_unavailable} = ProfileConfiguration.load(c.root)
  end

  test "failed sync and concurrent publication never replace foreign bytes", c do
    input = write(c.root, "input.json", JSON.encode!(data()))

    assert {:error, :profile_configuration_unavailable} =
             ProfileConfiguration.publish(c.root, input, fn _ -> {:error, :eio} end)

    refute File.exists?(Path.join(c.root, ProfileConfiguration.filename()))
    other = write(c.root, "other.json", JSON.encode!(changed_data("research")))

    results =
      [input, other]
      |> Task.async_stream(&ProfileConfiguration.publish(c.root, &1), max_concurrency: 2)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :profile_configuration_exists})) == 1

    assert File.read!(Path.join(c.root, ProfileConfiguration.filename())) in [
             File.read!(input),
             File.read!(other)
           ]
  end

  test "directory sync failure removes only its own publication and fresh Mix install starts no host",
       c do
    input = write(c.root, "input.json", JSON.encode!(data()))

    sync = fn file ->
      case :file.read_file_info(file) do
        {:ok, record} ->
          if File.Stat.from_record(record).type == :directory,
            do: {:error, :eio},
            else: :file.sync(file)

        error ->
          error
      end
    end

    assert {:error, :profile_configuration_unavailable} =
             ProfileConfiguration.publish(c.root, input, sync)

    refute File.exists?(Path.join(c.root, ProfileConfiguration.filename()))
    trap = Path.join(c.root, "startup-trap")
    File.mkdir!(trap)
    File.chmod!(trap, 0o700)
    write(trap, ProfileConfiguration.filename(), "{\"private-canary\":\"not valid\"}")
    env = [{"MIX_ENV", "test"}, {"WOTEX_HOME_GIT_DEPS", "1"}, {"WOTEX_HOME_DATA_DIR", trap}]

    assert {:ok, output} =
             Woh.Tool.Command.run(
               "elixir",
               [System.find_executable("mix"), "woh.profile.authoring.install", c.root, input],
               16384,
               15000,
               env
             )

    assert output =~ "contract_sha256"
    refute output =~ "private-canary"
    refute File.exists?(Path.join(trap, "home.sqlite"))
    refute File.exists?(Path.join(c.root, "home.sqlite"))
    assert File.read!(Path.join(c.root, ProfileConfiguration.filename())) == File.read!(input)
  end

  @tag requires_socket: true
  test "default host selects sealed authoring file, child restart keeps basis and explicit nil overrides",
       c do
    for family <- ~w(temperature research) do
      directory = Path.join(c.root, family)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      write(directory, ProfileConfiguration.filename(), JSON.encode!(data(family)))
      assert {:ok, host} = Host.start_link(data_dir: directory)

      try do
        store = Host.store()
        assert Host.external_sources() == nil && Host.external_reports() == nil

        {:ok, credential, 1} =
          Store.provision_principal(store, "author:#{family}", ["read", "profile:manage"], [])

        assert {:ok, export} = Store.authoring_contract_export(store, credential)
        assert {:ok, %{dispatch_enabled: false}} = Store.health(store)

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

        envelope =
          import(
            store,
            credential,
            "envelope",
            JSON.encode!(fixture(family)["envelope"]),
            "envelope:1"
          )

        {:ok, revision} = Store.revision(store)

        candidate_input = %{
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
        }

        assert {:ok, candidate} =
                 Authority.assess_authoring_candidate(
                   Host.authority(),
                   credential,
                   candidate_input
                 )

        assert candidate["disposition"] == "compatible" &&
                 candidate["capture_status"] == "not_supplied"

        reference =
          Map.take(
            candidate,
            ~w(authority_epoch operation_id revision input_sha256 assessment_sha256)
          )

        {:ok, revision} = Store.revision(store)

        review_input = %{
          "authority_epoch" => 1,
          "expected_revision" => revision,
          "operation_id" => "review:1",
          "review" => %{
            "mode" => "source",
            "candidate_ref" => reference,
            "evidence" => fixture("authoring-sources")[family]["evidence"],
            "unresolved_paths" => [],
            "envelope_ref" => nil
          }
        }

        assert {:ok, receipt} = Store.review_authoring_candidate(store, credential, review_input)

        assert receipt["source_review"] == "attributed" &&
                 receipt["proposal_status"] == "incomplete"

        {:ok, revision} = Store.revision(store)

        complete =
          review_input
          |> Map.put("expected_revision", revision)
          |> Map.put("operation_id", "review:complete")
          |> put_in(["review", "mode"], "complete")
          |> put_in(["review", "envelope_ref"], envelope)

        assert {:error, :authoring_capture_unavailable} =
                 Store.review_authoring_candidate(store, credential, complete)

        assert {:ok, ^revision} = Store.revision(store)
        # A full Host startup selects new disk data; a Store child restart stays pinned.
        path = Path.join(directory, ProfileConfiguration.filename())
        File.rm!(path)
        write(directory, ProfileConfiguration.filename(), JSON.encode!(changed_data(family)))
        monitor = Process.monitor(store)
        Process.exit(store, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^store, :killed}, 5000
        assert eventually(fn -> is_pid(Host.store()) && Host.store() != store end)
        assert {:ok, after_restart} = Store.authoring_contract_export(Host.store(), credential)
        assert after_restart["summary"] == export["summary"]

        assert {:ok, ^candidate} =
                 Store.authoring_candidate_status(Host.store(), credential, 1, "candidate:1")

        assert Host.external_sources() == nil && Host.external_reports() == nil
      after
        Supervisor.stop(host)
      end

      assert {:ok, host} = Host.start_link(data_dir: directory)

      try do
        {:ok, new_credential, _} =
          Store.provision_principal(Host.store(), "new:#{family}", ["profile:manage"], [])

        assert {:ok, changed} = Store.authoring_contract_export(Host.store(), new_credential)

        assert changed["summary"]["limits"]["max_check_steps"] == 999_999

        refute changed["summary"]["contract_sha256"] ==
                 fixture("authoring-mechanics")[family]["contract_sha256"]
      after
        Supervisor.stop(host)
      end

      assert {:ok, host} = Host.start_link(data_dir: directory, profile_installation: nil)

      try do
        assert Host.external_sources() == nil

        assert {:ok, credential, _} =
                 Store.provision_principal(
                   Host.store(),
                   "absent:#{family}",
                   ["profile:manage"],
                   []
                 )

        assert {:error, :authoring_unavailable} =
                 Store.authoring_contract_export(Host.store(), credential)
      after
        Supervisor.stop(host)
      end
    end
  end

  @tag requires_socket: true
  test "bad present configuration prevents durable and IPC acquisition", c do
    for {name, bytes, mode} <- [
          {"malformed", "{", 0o400},
          {"permission", JSON.encode!(data()), 0o644},
          {"unknown", JSON.encode!(Map.put(data(), "capture", %{})), 0o400}
        ] do
      directory = Path.join(c.root, name)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      path = write(directory, ProfileConfiguration.filename(), bytes)
      File.chmod!(path, mode)
      assert {:error, _} = Host.start_link(data_dir: directory)
      refute File.exists?(Path.join(directory, "home.sqlite"))
      refute File.exists?(Path.join(directory, "ipc/home.sock"))
    end
  end

  @tag requires_socket: true
  @tag timeout: 60_000
  test "fresh ordinary Application and native-parent startup select only private data-root policy",
       c do
    script = Path.join(c.root, "application.exs")

    File.write!(script, ~S"""
    System.delete_env("WOTEX_HOME_LIFX_INTERFACE")
    result = Application.ensure_all_started(:wotex_home)
    case hd(System.argv()) do
      "valid" ->
        {:ok, _} = result
        store = WotexHome.Host.store()
        true = is_pid(store)
        nil = WotexHome.Host.external_sources()
        nil = WotexHome.Host.external_reports()
        {:ok, credential, 1} = WotexHome.Durable.Store.provision_principal(store, "author:boot", ["read", "profile:manage"], [])
        {:ok, export} = WotexHome.Durable.Store.authoring_contract_export(store, credential)
        "wotex-home.authoring-contract-export@1" = export["format"]
        {:ok, %{dispatch_enabled: false}} = WotexHome.Durable.Store.health(store)
        :ok = Application.stop(:wotex_home)
        IO.puts("configured")
      "invalid" ->
        {:error, _} = result
        nil = WotexHome.Host.store()
        IO.puts("refused")
    end
    """)

    paths = Enum.map(:code.get_path(), &List.to_string/1)
    arguments = Enum.flat_map(paths, &["-pa", &1])

    for mode <- ~w(valid invalid) do
      directory = Path.join(c.root, mode)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)

      document =
        if mode == "valid",
          do: JSON.encode!(data()),
          else: JSON.encode!(Map.put(data(), "private-canary", "must not print"))

      write(directory, ProfileConfiguration.filename(), document)
      env = [{"WOTEX_HOME_DATA_DIR", directory}, {"WOTEX_HOME_LIFX_INTERFACE", ""}]

      assert {:ok, output} =
               Woh.Tool.Command.run("elixir", arguments ++ [script, mode], 16384, 15000, env)

      assert output =~ if(mode == "valid", do: "configured", else: "refused")
      refute output =~ "private-canary"
      refute output =~ "urn:example:binding"
      assert File.exists?(Path.join(directory, "home.sqlite")) == (mode == "valid")
    end

    native_root = Path.join(c.root, "native-parent")
    File.mkdir!(native_root)
    File.chmod!(native_root, 0o700)
    write(native_root, ProfileConfiguration.filename(), JSON.encode!(data()))

    python = ~S"""
    import json, os, struct, subprocess, sys
    env = dict(os.environ)
    env['WOTEX_HOME_DATA_DIR'] = sys.argv[3]
    env.pop('WOTEX_HOME_LIFX_INTERFACE', None)
    args = [sys.argv[1]]
    for path in json.loads(sys.argv[2]): args += ['-pa', path]
    args += ['-e', 'WotexHome.NativeSetup.CoreHost.main()']
    body = b'["wotex-home.native-setup-authority.v1","identity"]'
    child = subprocess.run(args, input=struct.pack('>I',len(body))+body, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=15)
    assert child.returncode == 0
    assert 4 < len(child.stdout) < 4096 and len(child.stderr) < 16384
    size = struct.unpack('>I',child.stdout[:4])[0]
    response = json.loads(child.stdout[4:4+size])
    assert response[0] == 'wotex-home.native-setup-authority.v1' and response[1] == 'identity'
    assert len(child.stdout) == 4+size
    assert os.path.exists(sys.argv[3]+'/home.sqlite')
    print('native-configured')
    """

    assert {:ok, output} =
             Woh.Tool.Command.run(
               "python3",
               ["-c", python, System.find_executable("elixir"), JSON.encode!(paths), native_root],
               16384,
               20000
             )

    assert output =~ "native-configured"
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

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(fun, attempts - 1)
          )
      )
end
