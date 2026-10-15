defmodule WotexHome.RuntimeArtifactsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.RuntimeArtifacts

  test "the full ordered temporal closure and eleven-application guard preserve caller subset order" do
    applications = [
      :wotex_home,
      :wotex_routines,
      :wotex_continuum,
      :wotex,
      :ex_booking,
      :decimal,
      :jason,
      :ex_json_schema,
      :nimble_options,
      :tz
    ]

    assert RuntimeArtifacts.temporal_applications() == applications
    applications = applications ++ [:wotex_udp]
    assert {:ok, expected} = RuntimeArtifacts.manifest(applications)
    assert Enum.map(expected, & &1.application) == applications
    home = hd(expected)
    assert length(home.modules) == length(Application.spec(:wotex_home, :modules))
    assert length(home.modules) > 512
    reversed = Enum.reverse(expected)

    assert {:ok, :complete} =
             RuntimeArtifacts.with_guard(fn ->
               assert {:ok, ^expected} = RuntimeArtifacts.manifest(applications)
               assert {:ok, ^reversed} = RuntimeArtifacts.manifest(Enum.reverse(applications))

               for entry <- expected,
                   do: assert(RuntimeArtifacts.manifest([entry.application]) == {:ok, [entry]})

               assert :ok = RuntimeArtifacts.finish_guard()
               assert {:ok, ^expected} = RuntimeArtifacts.manifest(applications)
               :complete
             end)
  end

  test "one guarded invocation preserves domain identities and releases its inventory before final checks" do
    assert {:ok, [home, udp] = expected} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])

    assert {:ok, :checked} =
             RuntimeArtifacts.with_guard(fn ->
               assert {:ok, ^expected} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])
               assert {:ok, [^udp, ^home]} = RuntimeArtifacts.manifest([:wotex_udp, :wotex_home])
               assert {:ok, [^home]} = RuntimeArtifacts.manifest([:wotex_home])

               assert {:error, :runtime_artifact_unavailable} =
                        RuntimeArtifacts.with_guard(fn -> :nested end)

               assert :ok = RuntimeArtifacts.finish_guard()
               assert :ok = RuntimeArtifacts.finish_guard()
               assert {:ok, ^expected} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])
               :checked
             end)

    assert {:ok, ^expected} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])
    assert {:ok, :next} = RuntimeArtifacts.with_guard(fn -> :next end)
    assert {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.with_guard(nil)
  end

  test "guard inventories unwind through exceptions, throws and exits without seeding the next invocation" do
    assert_raise RuntimeError, "injected", fn ->
      RuntimeArtifacts.with_guard(fn -> raise "injected" end)
    end

    assert catch_throw(RuntimeArtifacts.with_guard(fn -> throw(:injected) end)) == :injected
    assert catch_exit(RuntimeArtifacts.with_guard(fn -> exit(:injected) end)) == :injected
    assert {:ok, :after_unwind} = RuntimeArtifacts.with_guard(fn -> :after_unwind end)
  end

  test "a warmed guard refuses changed complete bytes, missing files, loaded drift and metadata in an isolated VM" do
    isolated_guard("""
    {:ok, expected} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])
    module = WotexHome.Schedules.Window
    path = Path.join(private_home, Atom.to_string(module) <> ".beam")
    original = File.read!(path)
    {:ok, ^module, chunks} = :beam_lib.all_chunks(original)
    {:ok, changed} = :beam_lib.build_module(chunks ++ [{~c"TEST", "different complete bytes"}])
    {:ok, {^module, checksum}} = :beam_lib.md5(original)
    {:ok, {^module, ^checksum}} = :beam_lib.md5(changed)

    {:error, :runtime_artifact_unavailable, :unpublished} = RuntimeArtifacts.with_guard(fn ->
      File.write!(path, changed)
      {:ok, ^expected} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])
      :unpublished
    end)
    {:ok, different} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])
    true = different != expected
    File.write!(path, original)

    {:error, :runtime_artifact_unavailable, :unpublished} = RuntimeArtifacts.with_guard(fn ->
      File.rm!(path)
      :unpublished
    end)
    File.write!(path, original)

    forms = [{:attribute, 1, :module, module}, {:attribute, 1, :export, [{:value, 0}]},
      {:function, 1, :value, 0, [{:clause, 1, [], [], [{:integer, 1, 1}]}]}]
    {:ok, ^module, replacement, []} = :compile.forms(forms, [:binary, :return_errors, :return_warnings])
    {:error, :runtime_artifact_unavailable, :unpublished} = RuntimeArtifacts.with_guard(fn ->
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), replacement)
      :code.purge(module)
      :unpublished
    end)
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), original)
    :code.purge(module)

    {:ok, [home_app]} = :file.consult(String.to_charlist(Path.join(private_home, "wotex_home.app")))
    {:application, :wotex_home, properties} = home_app
    {:error, :runtime_artifact_unavailable, :unpublished} = RuntimeArtifacts.with_guard(fn ->
      :ok = Application.unload(:wotex_home)
      :ok = :application.load({:application, :wotex_home, Keyword.put(properties, :vsn, ~c"changed")})
      :unpublished
    end)
    :ok = Application.unload(:wotex_home)
    :ok = :application.load(home_app)
    {:ok, ^expected} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])

    {:ok, :independent_final_check} = RuntimeArtifacts.with_guard(fn ->
      :ok = RuntimeArtifacts.finish_guard()
      File.write!(path, changed)
      {:ok, different} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])
      true = different != expected
      File.write!(path, original)
      :independent_final_check
    end)
    {:ok, :next} = RuntimeArtifacts.with_guard(fn -> :next end)
    """)
  end

  test "every temporal member and UDP closes the guard on byte or metadata drift and is read after closure" do
    isolated_guard("""
    applications = RuntimeArtifacts.temporal_applications() ++ [:wotex_udp]
    {:ok, expected} = RuntimeArtifacts.manifest(applications)
    for entry <- expected do
      app = entry.application
      directory = Map.fetch!(private_applications, app)
      {module, _} = hd(entry.modules)
      path = Path.join(directory, Atom.to_string(module) <> ".beam")
      original = File.read!(path)
      {:ok, ^module, chunks} = :beam_lib.all_chunks(original)
      {:ok, changed} = :beam_lib.build_module(chunks ++ [{~c"TEST", "changed complete member bytes"}])
      {:ok, {^module, checksum}} = :beam_lib.md5(original)
      {:ok, {^module, ^checksum}} = :beam_lib.md5(changed)
      {:error, :runtime_artifact_unavailable, :unpublished} = RuntimeArtifacts.with_guard(fn ->
        File.write!(path, changed)
        {:ok, ^expected} = RuntimeArtifacts.manifest(applications)
        :unpublished
      end)
      File.write!(path, original)
      {:ok, :final_read} = RuntimeArtifacts.with_guard(fn ->
        :ok = RuntimeArtifacts.finish_guard()
        File.write!(path, changed)
        {:ok, different} = RuntimeArtifacts.manifest(applications)
        true = different != expected
        File.write!(path, original)
        :final_read
      end)
      File.rm!(path)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.with_guard(fn -> raise "opened incomplete cohort" end)
      File.write!(path, original)
      Code.ensure_loaded!(module)
      forms = [{:attribute, 1, :module, module}, {:attribute, 1, :export, [{:fixture, 0}]},
        {:function, 1, :fixture, 0, [{:clause, 1, [], [], [{:integer, 1, 1}]}]}]
      {:ok, ^module, replacement, []} = :compile.forms(forms, [:binary, :return_errors, :return_warnings])
      {:error, :runtime_artifact_unavailable, :unpublished} = RuntimeArtifacts.with_guard(fn ->
        {:module, ^module} = :code.load_binary(module, String.to_charlist(path), replacement)
        :unpublished
      end)
      true = :erlang.check_old_code(module)
      :code.purge(module)
      false = :erlang.check_old_code(module)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.with_guard(fn -> raise "opened mismatched loaded code" end)
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), original)
      :code.purge(module)
      {:ok, [{:application, ^app, properties}]} = :file.consult(String.to_charlist(Path.join(directory, Atom.to_string(app) <> ".app")))
      for modified <- [Keyword.put(properties, :vsn, ~c"changed"), Keyword.update!(properties, :modules, &tl/1)] do
        {:error, :runtime_artifact_unavailable, :unpublished} = RuntimeArtifacts.with_guard(fn ->
          :ok = Application.unload(app)
          :ok = :application.load({:application, app, modified})
          :unpublished
        end)
        :ok = Application.unload(app)
        :ok = :application.load({:application, app, properties})
      end
      {:ok, ^expected} = RuntimeArtifacts.manifest(applications)
    end
    """)
  end

  defp isolated_guard(body) do
    applications = RuntimeArtifacts.temporal_applications() ++ [:wotex_udp]
    paths = Enum.map(applications, &{&1, Application.app_dir(&1, "ebin")})

    script = """
    alias WotexHome.RuntimeArtifacts
    directory = Path.join(System.tmp_dir!(), "woh-guard-artifacts-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    try do
      private_applications = Map.new(#{inspect(paths)}, fn {app, original} ->
        private = Path.join(directory, Atom.to_string(app))
        File.mkdir!(private)
        for path <- Path.wildcard(Path.join(original, "*")), File.regular?(path), do: File.cp!(path, Path.join(private, Path.basename(path)))
        true = :code.del_path(String.to_charlist(original))
        true = :code.add_patha(String.to_charlist(private))
        {app, private}
      end)
      private_home = Map.fetch!(private_applications, :wotex_home)
      _ = private_home
      #{body}
      IO.puts("verified")
    after
      File.rm_rf!(directory)
    end
    """

    arguments = Enum.flat_map(paths, fn {_app, path} -> ["-pa", path] end) ++ ["-e", script]

    assert {"verified\n", 0} =
             System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)
  end

  test "fixed application manifests are complete, domain-separated and preserve the LIFX identity" do
    assert {:ok, [home, udp] = manifest} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])

    for entry <- [home, udp] do
      assert entry.version == Application.spec(entry.application, :vsn)

      assert Enum.map(entry.modules, &elem(&1, 0)) ==
               Enum.sort(Application.spec(entry.application, :modules))
    end

    assert {:ok, expected} =
             RuntimeArtifacts.digest(
               [:wotex_home, :wotex_udp],
               "wotex-home.lifx-power-runtime.v2"
             )

    assert expected == term_digest({"wotex-home.lifx-power-runtime.v2", manifest})
    assert {:ok, ^expected} = WotexHome.Lifx.ProfileBasis.runtime_digest()

    assert {:ok, alternate} =
             RuntimeArtifacts.digest([:wotex_home, :wotex_udp], "different-domain")

    refute alternate == expected

    for {module, digest} <- home.modules do
      {^module, bytes, _} = :code.get_object_code(module)
      assert digest == term_digest(bytes)
    end
  end

  test "invalid application scopes and digest domains never fall back to a smaller closure" do
    for apps <- [
          [],
          [:wotex_home, :wotex_home],
          ["wotex_home"],
          [:home_runtime_missing_application],
          [
            :wotex_home,
            :wotex_udp,
            :crypto,
            :elixir,
            :logger,
            :kernel,
            :stdlib,
            :compiler,
            :sasl,
            :exqlite,
            :db_connection,
            :decimal
          ],
          nil
        ] do
      assert {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest(apps)
    end

    for domain <- [nil, "", String.duplicate("x", 129)] do
      assert {:error, :runtime_artifact_unavailable} =
               RuntimeArtifacts.digest([:wotex_home], domain)
    end
  end

  test "invalid versions, module inventories and missing files fail in an isolated VM" do
    isolated("""
    alias WotexHome.RuntimeArtifacts
    for {version, modules} <- [
      {~c"1", []}, {~c"1", [RuntimeArtifacts, RuntimeArtifacts]},
      {~c"1", ["not-a-module"]}, {~c"1", [WotexHome.MissingRuntimeArtifact]},
      {~c"1", List.duplicate(RuntimeArtifacts, 1025)}, {~c"1", [RuntimeArtifacts | :bad_tail]},
      {[], [RuntimeArtifacts]}, {"1", [RuntimeArtifacts]},
      {List.duplicate(?x, 129), [RuntimeArtifacts]}, {[-1], [RuntimeArtifacts]}
    ] do
      :ok = :application.load({:application, :home_runtime_inventory_fixture,
        [vsn: version, modules: modules]})
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_inventory_fixture])
      :ok = Application.unload(:home_runtime_inventory_fixture)
    end
    IO.puts("verified")
    """)
  end

  test "loaded/file-code mismatch, old code and a deleted retained artifact fail closed" do
    isolated("""
    alias WotexHome.RuntimeArtifacts
    directory = Path.join(System.tmp_dir!(), "home-runtime-code-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(directory)
    module = :home_runtime_code_fixture
    path = Path.join(directory, "home_runtime_code_fixture.beam")
    compile = fn value ->
      forms = [{:attribute, 1, :module, module}, {:attribute, 1, :export, [{:value, 0}]},
        {:function, 1, :value, 0, [{:clause, 1, [], [], [{:integer, 1, value}]}]}]
      {:ok, ^module, bytes, []} = :compile.forms(forms, [:binary, :return_errors, :return_warnings])
      bytes
    end
    try do
      original = compile.(1)
      changed = compile.(2)
      File.write!(path, original)
      true = :code.add_patha(String.to_charlist(directory))
      :ok = :application.load({:application, :home_runtime_code_app, [vsn: ~c"1", modules: [module]]})
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      # Warm parsing never skips the next complete file read or loaded check.
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      1 = apply(module, :value, [])
      # Disk bytes changed but the VM still executes the original code.
      File.write!(path, changed)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      File.write!(path, original)
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      File.write!(path, changed)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), changed)
      2 = apply(module, :value, [])
      true = :erlang.check_old_code(module)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      :code.purge(module)
      false = :erlang.check_old_code(module)
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      # A warm file-code checksum cannot authorize changed loaded code.
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), original)
      :code.purge(module)
      false = :erlang.check_old_code(module)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), changed)
      :code.purge(module)
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      File.rm!(path)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      IO.puts("verified")
    after
      :code.purge(module)
      :code.delete(module)
      :code.del_path(String.to_charlist(directory))
      File.rm_rf!(directory)
    end
    """)
  end

  defp isolated(script) do
    ebin = RuntimeArtifacts |> :code.which() |> List.to_string() |> Path.dirname()

    assert {"verified\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
               stderr_to_stdout: true
             )
  end

  test "parallel inventories preserve complete-byte identity and refuse drift after warming" do
    isolated_many("""
    {:ok, [entry] = expected} = RuntimeArtifacts.manifest([app])
    ^modules = Enum.map(entry.modules, &elem(&1, 0))
    for {module, digest} <- entry.modules do
      {^module, bytes, _} = :code.get_object_code(module)
      ^digest = hash.(bytes)
    end
    {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    module = hd(modules)
    path = Map.fetch!(paths, module)
    original = File.read!(path)
    {:ok, ^module, chunks} = :beam_lib.all_chunks(original)
    {:ok, extra} = :beam_lib.build_module(chunks ++ [{~c"TEST", "extra retained bytes"}])
    {:ok, {^module, checksum}} = :beam_lib.md5(original)
    {:ok, {^module, ^checksum}} = :beam_lib.md5(extra)
    File.write!(path, extra)
    {:ok, changed} = RuntimeArtifacts.manifest([app])
    true = changed != expected
    {:ok, ^changed} = RuntimeArtifacts.manifest([app])
    File.write!(path, compile.(module, 2))
    {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
    File.write!(path, original)
    {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), compile.(module, 2))
    true = :erlang.check_old_code(module)
    {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
    :code.purge(module)
    {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), original)
    :code.purge(module)
    {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    File.rm!(path)
    {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
    File.write!(path, original)
    {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    """)
  end

  test "fresh filename lookup observes a new preceding file even with OTP directory caching" do
    isolated_many("""
    shadow = Path.join(directory, "shadow")
    File.mkdir!(shadow)
    Code.prepend_path(shadow, cache: true)
    try do
      {:ok, expected} = RuntimeArtifacts.manifest([app])
      module = hd(modules)
      original = File.read!(Map.fetch!(paths, module))
      path = Path.join(shadow, Atom.to_string(module) <> ".beam")
      File.write!(path, compile.(module, 2))
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
      File.write!(path, original)
      {:ok, ^expected} = RuntimeArtifacts.manifest([app])
      File.rm!(path)
      {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    after
      Code.delete_path(shadow)
    end
    """)
  end

  test "archive code paths retain OTP lookup rather than skipping an earlier source" do
    isolated_many("""
    {:ok, expected} = RuntimeArtifacts.manifest([app])
    archive = Path.join(directory, "home_runtime_fixture.ez")
    files = Enum.map(modules, fn module ->
      {String.to_charlist("home_runtime_fixture/ebin/" <> Atom.to_string(module) <> ".beam"),
       File.read!(Map.fetch!(paths, module))}
    end)
    {:ok, _} = :zip.create(String.to_charlist(archive), files)
    archive_path = archive <> "/home_runtime_fixture/ebin"
    true = :code.add_patha(String.to_charlist(archive_path))
    try do
      Enum.each(paths, fn {_module, path} -> File.rm!(path) end)
      {:ok, ^expected} = RuntimeArtifacts.manifest([app])
      {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    after
      :code.del_path(String.to_charlist(archive_path))
    end
    """)
  end

  test "parent references through a symlink preserve the actual OTP artifact source" do
    isolated_many("""
    physical = Path.join(directory, "physical")
    File.mkdir_p!(Path.join(physical, "nested"))
    File.mkdir!(Path.join(physical, "ebin"))
    File.mkdir!(Path.join(directory, "ebin"))
    link = Path.join(directory, "link")
    File.ln_s!(Path.join(physical, "nested"), link)
    for module <- modules do
      bytes = File.read!(Map.fetch!(paths, module))
      filename = Atom.to_string(module) <> ".beam"
      File.write!(Path.join([physical, "ebin", filename]), bytes)
      File.write!(Path.join([directory, "ebin", filename]), bytes)
    end
    module = hd(modules)
    path = Path.join([physical, "ebin", Atom.to_string(module) <> ".beam"])
    {:ok, ^module, chunks} = :beam_lib.all_chunks(File.read!(path))
    {:ok, changed} = :beam_lib.build_module(chunks ++ [{~c"TEST", "physical path bytes"}])
    File.write!(path, changed)
    selected = String.to_charlist(link <> "/../ebin")
    true = :code.add_patha(selected)
    try do
      {:ok, [entry]} = RuntimeArtifacts.manifest([app])
      for {module, digest} <- entry.modules do
        {^module, bytes, _} = :code.get_object_code(module)
        ^digest = hash.(bytes)
      end
      {:ok, [^entry]} = RuntimeArtifacts.manifest([app])
    after
      :code.del_path(selected)
    end
    """)
  end

  test "parallel reads visit each module once with four finished readers and a bounded parsed memo" do
    isolated_many("""
    key = {RuntimeArtifacts, :file_code_checksums}
    Process.put(key, Map.new(1..11264, &{&1, {"unused", <<0::128>>}}))
    1 = :erlang.trace_pattern({RuntimeArtifacts, :file_code_checksum, 3}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])
    {:ok, [_]} = RuntimeArtifacts.manifest([app])
    :erlang.trace(:all, false, [:call])
    :erlang.trace_pattern({RuntimeArtifacts, :file_code_checksum, 3}, false, [:local])
    barrier = :erlang.trace_delivered(:all)
    receive do {:trace_delivered, :all, ^barrier} -> :ok after 1000 -> raise "trace barrier" end
    collect = fn collect, entries ->
      receive do
        {:trace, pid, :call, {RuntimeArtifacts, :file_code_checksum, [module, _, _]}} ->
          collect.(collect, [{pid, module} | entries])
      after 0 -> entries end
    end
    entries = collect.(collect, [])
    ^modules = entries |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    readers = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    4 = length(readers)
    true = Enum.all?(readers, &(not Process.alive?(&1)))
    12 = map_size(Process.get(key))
    ^modules = Process.get(key) |> Map.keys() |> Enum.sort()
    """)
  end

  test "oversized or invalid parallel artifacts refuse without retaining a partial manifest" do
    isolated_many("""
    {:ok, expected} = RuntimeArtifacts.manifest([app])
    module = hd(modules)
    path = Map.fetch!(paths, module)
    original = File.read!(path)
    {:ok, file} = :file.open(path, [:write, :binary, :raw])
    :ok = :file.pwrite(file, 16_777_216, <<0>>)
    :ok = :file.close(file)
    {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
    File.write!(path, "invalid BEAM")
    {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
    File.write!(path, compile.(List.last(modules), 1))
    {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([app])
    File.write!(path, original)
    {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    """)
  end

  test "an oversized directory listing uses the unchanged sequential lookup" do
    isolated_many("""
    {:ok, expected} = RuntimeArtifacts.manifest([app])
    for number <- 1..16_385, do: File.write!(Path.join(directory, "unused-" <> Integer.to_string(number)), "")
    {:ok, ^expected} = RuntimeArtifacts.manifest([app])
    """)
  end

  test "reader exceptions and timeouts refuse and finish every temporary reader" do
    source = File.read!("lib/wotex_home/runtime_artifacts.ex")

    for {action, expected_wait} <- [
          {"raise \"reader failure\"", 0},
          {"Process.sleep(6000)", 5_000}
        ] do
      mutated =
        source
        |> String.replace(
          "defmodule WotexHome.RuntimeArtifacts do",
          "defmodule HomeRuntimeReaderProbe do"
        )
        |> String.replace(
          "  defp module_digests_files(files) do\n",
          "  defp module_digests_files(files) do\n    send(Process.whereis(:home_runtime_reader_observer), {:reader, self()})\n    #{action}\n"
        )

      isolated_many(
        """
        true = Process.register(self(), :home_runtime_reader_observer)
        Code.compile_string(#{inspect(mutated, limit: :infinity, printable_limit: :infinity)})
        started = System.monotonic_time(:millisecond)
        {:error, :runtime_artifact_unavailable} = HomeRuntimeReaderProbe.manifest([app])
        elapsed = System.monotonic_time(:millisecond) - started
        true = elapsed >= #{expected_wait}
        true = elapsed < #{expected_wait + 3_000}
        collect = fn collect, readers ->
          receive do {:reader, pid} -> collect.(collect, [pid | readers]) after 0 -> readers end
        end
        readers = collect.(collect, [])
        true = length(readers) in 1..4
        true = Enum.all?(readers, &(not Process.alive?(&1)))
        """,
        allow_output: true
      )
    end
  end

  test "a code-path change during parallel reads refuses the entire inventory" do
    source =
      File.read!("lib/wotex_home/runtime_artifacts.ex")
      |> String.replace(
        "defmodule WotexHome.RuntimeArtifacts do",
        "defmodule HomeRuntimePathProbe do"
      )
      |> String.replace(
        "  defp module_digests_files(files) do\n",
        "  defp module_digests_files(files) do\n    send(Process.whereis(:home_runtime_path_observer), {:reader, self()})\n    receive do :continue -> :ok after 1000 -> raise \"no observer\" end\n"
      )

    isolated_many("""
    shadow = Path.join(directory, "shadow")
    File.mkdir!(shadow)
    observer = spawn(fn ->
      true = Process.register(self(), :home_runtime_path_observer)
      Enum.each(1..4, fn _ ->
        receive do
          {:reader, pid} -> Code.prepend_path(shadow); send(pid, :continue)
        after 2000 -> raise "missing reader" end
      end)
    end)
    wait = fn wait ->
      if Process.whereis(:home_runtime_path_observer), do: :ok, else: (Process.sleep(1); wait.(wait))
    end
    wait.(wait)
    Code.compile_string(#{inspect(source, limit: :infinity, printable_limit: :infinity)})
    try do
      {:error, :runtime_artifact_unavailable} = HomeRuntimePathProbe.manifest([app])
      false = Process.alive?(observer)
    after
      Code.delete_path(shadow)
    end
    """)
  end

  defp isolated_many(body, options \\ []) do
    script = """
    alias WotexHome.RuntimeArtifacts
    directory = Path.join(System.tmp_dir!(), "home-runtime-many-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(directory)
    modules = Enum.map(1..12, &String.to_atom("home_runtime_many_fixture_" <> String.pad_leading(Integer.to_string(&1), 2, "0")))
    paths = Map.new(modules, &{&1, Path.join(directory, Atom.to_string(&1) <> ".beam")})
    app = :home_runtime_many_app
    compile = fn module, value ->
      forms = [{:attribute, 1, :module, module}, {:attribute, 1, :export, [{:value, 0}]},
        {:function, 1, :value, 0, [{:clause, 1, [], [], [{:integer, 1, value}]}]}]
      {:ok, ^module, bytes, []} = :compile.forms(forms, [:binary, :return_errors, :return_warnings])
      bytes
    end
    hash = fn bytes ->
      bytes |> :erlang.term_to_binary([:deterministic]) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    end
    try do
      Enum.each(modules, &File.write!(Map.fetch!(paths, &1), compile.(&1, 1)))
      true = :code.add_patha(String.to_charlist(directory))
      :ok = :application.load({:application, app, [vsn: ~c"1", modules: modules]})
      #{body}
      IO.puts("verified")
    after
      Enum.each(modules, fn module -> :code.purge(module); :code.delete(module) end)
      Application.unload(app)
      :code.del_path(String.to_charlist(directory))
      File.rm_rf!(directory)
    end
    """

    if options[:allow_output] do
      ebin = RuntimeArtifacts |> :code.which() |> List.to_string() |> Path.dirname()

      assert {output, 0} =
               System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
                 stderr_to_stdout: true
               )

      assert String.ends_with?(output, "verified\n")
    else
      isolated(script)
    end
  end

  defp term_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
