defmodule WotexHome.GenerationInstallationTest do
  @moduledoc false

  use ExUnit.Case, async: false
  import Bitwise
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, Host}
  alias WotexHome.Durable.Store
  alias WotexHome.Host.{GenerationConfiguration, GenerationInstallation, ProfileConfiguration}
  alias WotexHome.LocalAPI.Client
  alias WotexHome.Profiles.{AuthoringObject, GenerationProvider}

  defmodule Provider do
    @moduledoc false

    use GenServer
    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    def init(observer), do: {:ok, observer}

    def handle_call({:generate_profile, document, ceiling}, from, observer) do
      send(observer, {:provider_call, from, document, ceiling})
      {:noreply, observer}
    end
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))
  defp vector(family \\ "temperature"), do: fixture("generation-installation")[family]

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()

    directory =
      Path.join(temporary, "generation-installation-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  defp write(directory, name, bytes) do
    path = Path.join(directory, name)
    if File.exists?(path), do: File.chmod!(path, 0o600)
    File.write!(path, bytes)
    File.chmod!(path, 0o400)
    path
  end

  defp policies(family \\ "temperature") do
    {:ok, policies} = GenerationConfiguration.decode(vector(family)["document"])
    policies
  end

  defp provider(policy) do
    pid = start_supervised!({Provider, self()}, id: make_ref())
    {:ok, provider} = GenerationProvider.new(policy.input["provider"], pid)
    provider
  end

  defp boot(directory, options \\ []) do
    assert {:ok, host} = Host.start_link([data_dir: directory] ++ options)
    Process.unlink(host)
    on_exit(fn -> if Process.alive?(host), do: Supervisor.stop(host) end)
    host
  end

  defp authoring_file(directory, family) do
    data = %{
      "format" => "wotex-home.profile-authoring-installation@1",
      "installed" => Map.take(fixture(family), ~w(bindings contracts home_contracts)),
      "authoring_limits" => fixture("authoring-mechanics")[family]["limits"]
    }

    write(directory, ProfileConfiguration.filename(), JSON.encode!(data))
  end

  defp seed(family) do
    store = Host.store()

    {:ok, credential, 1} =
      Store.provision_principal(store, "author:fixture", ["read", "profile:manage"], [])

    for revision <- 2..6,
        do:
          assert(
            {:ok, _, ^revision} =
              Store.provision_principal(store, "reader:#{revision}", ["read"], [])
          )

    objects = fixture("generation-inputs")[family]["objects"]
    import_object(store, credential, Enum.find(objects, &(&1["kind"] == "source")), 6)
    assert {:ok, _, 8} = Store.provision_principal(store, "reader:8", ["read"], [])
    import_object(store, credential, Enum.find(objects, &(&1["kind"] == "fixture")), 8)
    credential
  end

  defp import_object(store, credential, row, revision) do
    bytes = Base.decode64!(row["payload_base64"])
    {:ok, object} = AuthoringObject.new(row["kind"], bytes)
    {:ok, summary} = AuthoringObject.summary(object)

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "import:" <> row["kind"],
      "expected_revision" => revision,
      "object" => summary
    }

    assert {:ok, receipt} = Store.import_authoring_object(store, credential, input, bytes)
    assert receipt["first_revision"] == row["reference"]["first_revision"]
  end

  defp prepare(family, credential) do
    {:ok, revision} = Store.revision(Host.store())

    input =
      Map.put(
        fixture("generation-preparations")[family]["request"],
        "expected_revision",
        revision
      )

    assert {:ok, receipt} =
             Authority.prepare_authoring_generation(Host.authority(), credential, input)

    {input, receipt}
  end

  defp attempt(preparation) do
    {:ok, revision} = Store.revision(Host.store())

    %{
      "authority_epoch" => 1,
      "operation_id" => "attempt:installed",
      "expected_revision" => revision,
      "preparation_operation_id" => preparation["operation_id"],
      "preparation_sha256" => preparation["input_sha256"],
      "attempt" => 1,
      "previous_operation_id" => nil,
      "repair_export" => false
    }
  end

  defp eventually(check, attempts \\ 300)
  defp eventually(_, 0), do: flunk("bounded host transition did not complete")

  defp eventually(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(check, attempts - 1)
        )
  end

  defp status(credential),
    do:
      Authority.authoring_generation_attempt_status(
        Host.authority(),
        credential,
        1,
        "attempt:installed"
      )

  test "independent documents reconstruct exact policy/provider hashes for both families" do
    for family <- ~w(temperature research) do
      v = vector(family)
      assert {:ok, [policy]} = GenerationConfiguration.decode(v["document"])
      assert policy.sha256 == v["policy_sha256"]
      assert policy.provider_sha256 == v["provider_sha256"]
      assert Base.encode16(:crypto.hash(:sha256, v["document"]), case: :lower) == v["sha256"]
      capability = provider(policy)

      assert {:ok, %{policies: [^policy], providers: [^capability]}} =
               GenerationInstallation.prepare(%{policies: [policy], providers: [capability]})
    end

    assert {:ok, %{policies: [], providers: []}} = GenerationInstallation.prepare(nil)
  end

  test "closed native and file installation rejects malformed bounds, identities and order" do
    [policy] = policies()
    capability = provider(policy)
    good = %{policies: [policy], providers: [capability]}
    changed = %{capability | provider_sha256: String.duplicate("b", 64)}
    other_pid = start_supervised!({Provider, self()}, id: :other_provider)

    {:ok, unselected} =
      GenerationProvider.new(Map.put(policy.input["provider"], "id", "other:provider"), other_pid)

    for bad <- [
          true,
          %{},
          %{good | policies: [policy, policy]},
          Map.put(good, :extra, true),
          %{good | policies: [policy | nil]},
          %{good | providers: [capability, capability]},
          %{good | providers: [changed]},
          %{good | providers: [unselected]},
          %{good | providers: ["registered"]},
          %{good | policies: []}
        ] do
      assert {:error, :invalid_generation_installation} = GenerationInstallation.prepare(bad)
    end

    data = vector()["data"]

    for bad <- [
          Map.put(data, "extra", true),
          Map.delete(data, "policies"),
          Map.put(data, "format", "unknown"),
          put_in(data, ["policies", Access.at(0), "remote_export"], 1),
          put_in(data, ["policies", Access.at(0), "limits", "max_passages"], 2.0),
          put_in(data, ["policies", Access.at(0), "limits", "max_passages"], true),
          put_in(data, ["policies", Access.at(0), "passages", Access.at(0), "offset"], 262_145),
          Map.put(data, "policies", [policy.input, policy.input])
        ] do
      assert {:error, :invalid_generation_configuration} =
               GenerationConfiguration.decode(JSON.encode!(bad))
    end

    for bytes <- [
          "",
          <<255>>,
          "{\"format\":\"x\",\"format\":\"y\"}",
          String.duplicate("[", 9) <> "0" <> String.duplicate("]", 9)
        ] do
      assert {:error, _} = GenerationConfiguration.decode(bytes)
    end

    assert {:error, :authoring_limit} =
             GenerationConfiguration.decode(String.duplicate("x", 1_048_577))

    document = vector()["document"]

    assert {:ok, [_]} =
             GenerationConfiguration.decode(
               document <> String.duplicate(" ", 1_048_576 - byte_size(document))
             )

    too_many_nodes =
      JSON.encode!(%{
        "format" => "wotex-home.generation-policies@1",
        "policies" => [],
        "noise" => List.duplicate(List.duplicate(0, 256), 129)
      })

    assert {:error, :authoring_limit} = GenerationConfiguration.decode(too_many_nodes)

    raw =
      for n <- 1..32,
          do:
            Map.put(
              policy.input,
              "principal_id",
              "author:" <> String.pad_leading(to_string(n), 2, "0")
            )

    assert {:ok, loaded} =
             GenerationConfiguration.decode(JSON.encode!(%{data | "policies" => raw}))

    assert length(loaded) == 32

    assert {:error, :authoring_limit} =
             GenerationConfiguration.decode(
               JSON.encode!(%{data | "policies" => raw ++ [hd(raw)]})
             )

    assert {:error, :invalid_generation_configuration} =
             GenerationConfiguration.decode(
               JSON.encode!(%{data | "policies" => Enum.reverse(raw)})
             )
  end

  test "publication preserves exact bytes and exposes only digest and aggregate counts", c do
    v = vector()
    source = write(c.directory, "input.json", v["document"])
    expected = %{sha256: v["sha256"], policies: 1, principals: 1, providers: 1}
    assert {:ok, ^expected} = GenerationConfiguration.publish(c.directory, source)
    assert {:ok, ^expected} = GenerationConfiguration.publish(c.directory, source)
    target = Path.join(c.directory, GenerationConfiguration.filename())
    assert File.read!(target) == v["document"]
    assert band(File.stat!(target).mode, 0o777) == 0o400
    assert File.stat!(target).links == 1
    assert {:ok, snapshot} = GenerationConfiguration.load(c.directory)
    assert :ok = GenerationConfiguration.check(snapshot, c.directory)
    refute inspect(snapshot) =~ "author:fixture"
    refute inspect(snapshot) =~ c.directory
    other = write(c.directory, "other.json", vector("research")["document"])

    assert {:error, :generation_configuration_exists} =
             GenerationConfiguration.publish(c.directory, other)

    output =
      capture_io(fn -> Mix.Tasks.Woh.Profile.Generation.Install.run([c.directory, source]) end)

    assert JSON.decode!(output)["sha256"] == v["sha256"]

    for private <- [
          c.directory,
          "author:fixture",
          "generator:fixture",
          hd(v["data"]["policies"])["passages"] |> hd() |> get_in(["reference", "object_digest"])
        ],
        do: refute(output =~ private)

    refute File.exists?(Path.join(c.directory, "home.sqlite"))
  end

  test "seals reject same-size mutation, replacement, removal and absence appearance", c do
    assert {:ok, absence} = GenerationConfiguration.load(c.directory)
    assert :ok = GenerationConfiguration.check(absence, c.directory)
    bytes = vector()["document"]
    target = write(c.directory, GenerationConfiguration.filename(), bytes)

    assert {:error, :generation_configuration_changed} =
             GenerationConfiguration.check(absence, c.directory)

    assert {:ok, original} = GenerationConfiguration.load(c.directory)
    changed = String.replace(bytes, "author:fixture", "author:fixturX")
    assert byte_size(changed) == byte_size(bytes)
    write(c.directory, GenerationConfiguration.filename(), changed)

    assert {:error, :generation_configuration_changed} =
             GenerationConfiguration.check(original, c.directory)

    File.rm!(target)

    assert {:error, :generation_configuration_changed} =
             GenerationConfiguration.check(original, c.directory)

    write(c.directory, GenerationConfiguration.filename(), bytes)

    assert {:error, :generation_configuration_changed} =
             GenerationConfiguration.check(original, c.directory)
  end

  test "absence pins existing root identities and rejects unsafe modes and aliases", c do
    assert {:ok, absence} = GenerationConfiguration.load(c.directory)
    File.chmod!(c.directory, 0o755)

    assert {:error, :generation_configuration_changed} =
             GenerationConfiguration.check(absence, c.directory)

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.load(c.directory)

    File.chmod!(c.directory, 0o700)
    old = c.directory <> "-original"
    File.rename!(c.directory, old)
    File.mkdir!(c.directory)
    File.chmod!(c.directory, 0o700)

    assert {:error, :generation_configuration_changed} =
             GenerationConfiguration.check(absence, c.directory)

    File.rm_rf!(old)
    alias_path = c.directory <> "-alias"
    File.ln_s!(c.directory, alias_path)

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.load(alias_path)

    File.rm!(alias_path)
  end

  test "Host child construction rejects changed selected files and dead capabilities before resources",
       c do
    assert {:ok, absence} = GenerationConfiguration.load(c.directory)
    target = write(c.directory, GenerationConfiguration.filename(), vector()["document"])

    assert {:stop, :generation_configuration_changed} =
             Host.init({[data_dir: c.directory], :absent, {:private, absence, []}})

    assert {:ok, selected} = GenerationConfiguration.load(c.directory)
    File.chmod!(target, 0o600)

    assert {:stop, :generation_configuration_changed} =
             Host.init({[data_dir: c.directory], :absent, {:private, selected, []}})

    [policy] = policies()
    capability = provider(policy)
    Process.exit(capability.pid, :kill)
    eventually(fn -> not Process.alive?(capability.pid) end)

    assert {:stop, :invalid_generation_installation} =
             Host.init(
               {[data_dir: c.directory], :absent,
                {:native, %{policies: [policy], providers: [capability]}}}
             )

    for name <- ["home.sqlite", "ipc", "profiles"],
        do: refute(File.exists?(Path.join(c.directory, name)))
  end

  test "private file rejects modes, symlinks, hardlinks and unsafe ancestors", c do
    source = write(c.directory, "source.json", vector()["document"])
    target = write(c.directory, GenerationConfiguration.filename(), vector()["document"])

    for mode <- [0o600, 0o440, 0o644] do
      File.chmod!(target, mode)

      assert {:error, :generation_configuration_unavailable} =
               GenerationConfiguration.load(c.directory)
    end

    File.chmod!(target, 0o400)
    link = Path.join(c.directory, "link")
    File.ln!(target, link)

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.load(c.directory)

    File.rm!(link)
    File.rm!(target)
    File.ln_s!(source, target)

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.load(c.directory)

    File.rm!(target)
    write(c.directory, GenerationConfiguration.filename(), vector()["document"])
    File.chmod!(c.directory, 0o755)

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.load(c.directory)
  end

  test "file/directory sync failures and competing publication preserve foreign bytes", c do
    input = write(c.directory, "input.json", vector()["document"])
    target = Path.join(c.directory, GenerationConfiguration.filename())

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.publish(c.directory, input, fn _ -> {:error, :eio} end)

    refute File.exists?(target)

    directory_failure = fn file ->
      {:ok, record} = :file.read_file_info(file)

      if File.Stat.from_record(record).type == :directory,
        do: {:error, :eio},
        else: :file.sync(file)
    end

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.publish(c.directory, input, directory_failure)

    refute File.exists?(target)
    other = write(c.directory, "other.json", vector("research")["document"])

    results =
      [input, other]
      |> Task.async_stream(&GenerationConfiguration.publish(c.directory, &1), max_concurrency: 2)
      |> Enum.map(fn {:ok, x} -> x end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :generation_configuration_exists})) == 1
    assert File.read!(target) in [File.read!(input), File.read!(other)]
  end

  @tag requires_socket: true
  test "invalid installations refuse before resources and explicit nil/native suppress bad disk",
       c do
    missing = Path.join(c.directory, "new-root")

    assert {:error, :invalid_generation_installation} =
             Host.start_link(
               data_dir: missing,
               generation_installation: %{policies: [], providers: ["name"]}
             )

    refute File.exists?(missing)
    write(c.directory, GenerationConfiguration.filename(), "{\"private-canary\":\"invalid\"}")
    assert {:error, :invalid_generation_configuration} = Host.start_link(data_dir: c.directory)

    for name <- ["home.sqlite", "ipc", "profiles"],
        do: refute(File.exists?(Path.join(c.directory, name)))

    host = boot(c.directory, generation_installation: nil)
    assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
    Supervisor.stop(host)
    [policy] = policies()
    capability = provider(policy)

    host =
      boot(c.directory, generation_installation: %{policies: [policy], providers: [capability]})

    {:ok, credential, 1} =
      Store.provision_principal(Host.store(), "author:fixture", ["profile:manage"], [])

    assert {:ok, %{"policies" => [%{"provider_present" => true}]}} =
             Authority.authoring_generation_options(Host.authority(), credential)

    refute_receive {:provider_call, _, _, _}, 20
    Supervisor.stop(host)
  end

  @tag requires_socket: true
  test "file-only ordinary Host can prepare but cannot hand off without a capability", c do
    authoring_file(c.directory, "temperature")
    write(c.directory, GenerationConfiguration.filename(), vector()["document"])
    host = boot(c.directory)
    credential = seed("temperature")
    assert {:ok, options} = Authority.authoring_generation_options(Host.authority(), credential)
    assert hd(options["policies"])["provider_present"] == false
    {_, preparation} = prepare("temperature", credential)

    assert {:error, :generation_unavailable} =
             Authority.start_authoring_generation(
               Host.authority(),
               credential,
               attempt(preparation)
             )

    assert {:ok, ^options} =
             Authority.authoring_generation_options(Host.authority(), credential)
             |> same_revision(options)

    assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
    refute_receive {:provider_call, _, _, _}, 20
    Supervisor.stop(host)
  end

  defp same_revision({:ok, current}, old),
    do: {:ok, Map.put(current, "store_revision", old["store_revision"])}

  @tag requires_socket: true
  test "private policies and exact native adapter deliver both inert families through actual Host",
       c do
    for family <- ~w(temperature research) do
      directory = Path.join(c.directory, family)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      authoring_file(directory, family)
      write(directory, GenerationConfiguration.filename(), vector(family)["document"])
      [policy] = policies(family)
      capability = provider(policy)

      host =
        boot(directory, generation_installation: %{policies: :private, providers: [capability]})

      credential = seed(family)
      socket = Path.join(directory, "ipc/home.sock")

      assert {:ok, %{"outcome" => "ok", "authoring_generation_options" => options}} =
               Client.request(socket, %{
                 "api_version" => 1,
                 "operation" => "authoring_generation_options",
                 "credential" => Base.url_encode64(credential, padding: false)
               })

      assert hd(options["policies"])["policy_sha256"] == vector(family)["policy_sha256"]
      assert hd(options["policies"])["provider_present"] == true
      {preparation_input, preparation} = prepare(family, credential)
      input = attempt(preparation)

      assert {:ok, original} =
               Authority.start_authoring_generation(Host.authority(), credential, input)

      assert_receive {:provider_call, from, document, 262_144}, 3000
      assert document == fixture("generation-attempts")[family]["handoff_document"]
      bytes = fixture("authoring-mechanics")[family]["draft_bytes"]
      GenServer.reply(from, {:ok, bytes})
      eventually(fn -> match?({:ok, %{"state" => "candidate"}}, status(credential)) end)
      assert {:ok, %{"original" => ^original, "result" => result}} = status(credential)
      assert result["assessment"]["source_review"] == "not_assessed"
      assert result["assessment"]["fixture_status"] == "not_supplied"

      assert {:ok, ^original} =
               Authority.start_authoring_generation(Host.authority(), credential, input)

      assert {:ok, ^preparation} =
               Authority.prepare_authoring_generation(
                 Host.authority(),
                 credential,
                 preparation_input
               )

      refute_receive {:provider_call, _, _, _}, 20
      assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
      assert Host.external_sources() == nil and Host.external_reports() == nil
      Supervisor.stop(host)
    end
  end

  @tag requires_socket: true
  test "child restart retains selected policy and originals, full restart explicitly removes installation",
       c do
    authoring_file(c.directory, "temperature")
    write(c.directory, GenerationConfiguration.filename(), vector()["document"])
    [policy] = policies()
    capability = provider(policy)

    host =
      boot(c.directory, generation_installation: %{policies: :private, providers: [capability]})

    credential = seed("temperature")
    {preparation_input, preparation} = prepare("temperature", credential)
    input = attempt(preparation)

    assert {:ok, original} =
             Authority.start_authoring_generation(Host.authority(), credential, input)

    assert_receive {:provider_call, _, _, _}, 3000
    old_store = Host.store()

    write(
      c.directory,
      GenerationConfiguration.filename(),
      JSON.encode!(%{"format" => "wotex-home.generation-policies@1", "policies" => []})
    )

    Process.exit(old_store, :kill)
    eventually(fn -> is_pid(Host.store()) and Host.store() != old_store end)

    assert {:ok, %{"policies" => [%{"policy_sha256" => sha}]}} =
             Authority.authoring_generation_options(Host.authority(), credential)

    assert sha == policy.sha256

    assert {:ok, %{"original" => ^original, "state" => "unknown", "result" => nil}} =
             status(credential)

    assert {:ok, ^original} =
             Authority.start_authoring_generation(Host.authority(), credential, input)

    refute_receive {:provider_call, _, _, _}, 20
    Supervisor.stop(host)
    host = boot(c.directory)

    assert {:ok, %{"policies" => []}} =
             Authority.authoring_generation_options(Host.authority(), credential)

    assert {:ok, ^preparation} =
             Authority.prepare_authoring_generation(
               Host.authority(),
               credential,
               preparation_input
             )

    assert {:ok, ^original} =
             Authority.start_authoring_generation(Host.authority(), credential, input)

    assert {:ok, %{"original" => ^original, "state" => "unknown"}} = status(credential)
    refute_receive {:provider_call, _, _, _}, 20
    Supervisor.stop(host)
  end

  @tag requires_socket: true
  test "adapter death changes metadata without stopping Host or ordinary reads", c do
    [policy] = policies()
    capability = provider(policy)

    host =
      boot(c.directory, generation_installation: %{policies: [policy], providers: [capability]})

    {:ok, credential, 1} =
      Store.provision_principal(Host.store(), "author:fixture", ["profile:manage"], [])

    Process.exit(capability.pid, :kill)
    eventually(fn -> not Process.alive?(capability.pid) end)

    assert {:ok, %{"policies" => [%{"provider_present" => false}]}} =
             Authority.authoring_generation_options(Host.authority(), credential)

    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(Host.store())
    assert Process.alive?(host)

    assert {:error, :invalid_generation_installation} =
             GenerationInstallation.prepare(%{policies: [policy], providers: [capability]})

    Supervisor.stop(host)
  end

  test "failed publication cleanup preserves a foreign replacement", c do
    source = write(c.directory, "input.json", vector()["document"])
    target = Path.join(c.directory, GenerationConfiguration.filename())
    foreign = vector("research")["document"]

    sync = fn file ->
      {:ok, record} = :file.read_file_info(file)

      if File.Stat.from_record(record).type == :directory do
        File.rm!(target)
        write(c.directory, GenerationConfiguration.filename(), foreign)
        {:error, :eio}
      else
        :file.sync(file)
      end
    end

    assert {:error, :generation_configuration_unavailable} =
             GenerationConfiguration.publish(c.directory, source, sync)

    assert File.read!(target) == foreign
    assert File.stat!(target).links == 1
  end

  test "fresh Mix installer loads paths without starting invalid Home configuration", c do
    input = write(c.directory, "input.json", vector()["document"])
    trap = Path.join(c.directory, "trap")
    File.mkdir!(trap)
    File.chmod!(trap, 0o700)
    write(trap, GenerationConfiguration.filename(), "{\"private-canary\":\"invalid\"}")

    assert {:ok, output} =
             Woh.Tool.Command.run(
               "elixir",
               [
                 System.find_executable("mix"),
                 "woh.profile.generation.install",
                 c.directory,
                 input
               ],
               16384,
               15000,
               [{"MIX_ENV", "test"}, {"WOTEX_HOME_GIT_DEPS", "1"}, {"WOTEX_HOME_DATA_DIR", trap}]
             )

    assert output =~ vector()["sha256"]
    refute output =~ "private-canary"
    refute output =~ "author:fixture"
    refute File.exists?(Path.join(trap, "home.sqlite"))
    refute File.exists?(Path.join(c.directory, "home.sqlite"))
  end

  @tag requires_socket: true
  test "fresh ordinary Application selects private policies and refuses invalid present data",
       c do
    for {name, bytes, valid} <- [
          {"valid-app", vector()["document"], true},
          {"invalid-app", "{\"private-canary\":\"invalid\"}", false}
        ] do
      directory = Path.join(c.directory, name)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      write(directory, GenerationConfiguration.filename(), bytes)

      script =
        if valid do
          """
          {:ok, _} = Application.ensure_all_started(:wotex_home)
          store = WotexHome.Host.store()
          {:ok, credential, _} = WotexHome.Durable.Store.provision_principal(store, "author:fixture", ["profile:manage"], [])
          {:ok, options} = WotexHome.Durable.Store.authoring_generation_options(store, credential)
          {:ok, health} = WotexHome.Durable.Store.health(store)
          IO.puts(JSON.encode!(%{policies: length(options["policies"]), present: hd(options["policies"])["provider_present"], dispatch: health.dispatch_enabled}))
          """
        else
          """
          case Application.ensure_all_started(:wotex_home) do
            {:error, _} -> IO.puts("generation-startup-refused")
            _ -> raise "invalid generation startup accepted"
          end
          """
        end

      assert {:ok, output} =
               Woh.Tool.Command.run(
                 "elixir",
                 [System.find_executable("mix"), "run", "--no-start", "-e", script],
                 16384,
                 15000,
                 [
                   {"MIX_ENV", "test"},
                   {"WOTEX_HOME_GIT_DEPS", "1"},
                   {"WOTEX_HOME_DATA_DIR", directory}
                 ]
               )

      refute output =~ "private-canary"

      if valid do
        assert output =~ ~s("policies":1)
        assert output =~ ~s("present":false)
        assert output =~ ~s("dispatch":false)
        assert File.exists?(Path.join(directory, "home.sqlite"))
      else
        assert output =~ "generation-startup-refused"

        for path <- ["home.sqlite", "profiles", "ipc"],
            do: refute(File.exists?(Path.join(directory, path)))
      end
    end
  end
end
