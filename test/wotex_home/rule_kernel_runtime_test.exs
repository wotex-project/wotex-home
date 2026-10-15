Code.require_file(Path.expand("../support/rule_kernel_runtime_fixture.exs", __DIR__))

defmodule WotexHome.RuleKernelRuntimeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.RuntimeArtifacts

  for phase <- [:prepare, :commit, :final] do
    @phase phase
    @tag timeout: 120_000
    test "all ten runtime members refuse #{@phase} drift without changing retained originals" do
      isolated(
        """
        F.install_final_hook(paths[:wotex_home], #{inspect(Path.expand("lib/wotex_home/durable/store.ex"))})
        c = F.new(Path.join(directory, "runtime.sqlite"))
        {:ok, %{disposition: :held} = retained} = F.invoke(c, "retained:original")
        before = F.snapshot(c)
        operation = "new:runtime"
        {:ok, preparation} = F.prepare(c, operation)
        {:ok, projection} = F.proposal(preparation)
        for application <- RuntimeArtifacts.temporal_applications(), kind <- [:bytes, :version, :modules, :absent] do
          {change, restore} = F.mutation(paths, application, kind)
          try do
            case #{inspect(@phase)} do
              :prepare -> change.()
              :commit -> change.()
              :final ->
                observer = self()
                :ok = F.final_hook(c, fn db ->
                  :ok = F.tentative!(db, operation)
                  change.()
                  send(observer, {:late, application, kind})
                end)
            end
            result = case #{inspect(@phase)} do
              :prepare -> F.prepare(c, operation)
              _ -> F.commit(c, preparation, projection)
            end
            {:error, reason} = result
            true = reason in [:stale_rule_admission, :unsupported_admission_profile, :runtime_artifact_unavailable]
            if #{inspect(@phase)} == :final do
              receive do {:late, ^application, ^kind} -> :ok after 1_000 -> raise "missing final boundary" end
            end
            true = F.snapshot(c) == before
            {:ok, %{writable: true}} = Store.health(c.store)
            {:ok, ^retained} = F.invoke(c, "retained:original")
          after
            restore.()
          end
          {:ok, ^preparation} = F.prepare(c, operation)
          :ok = F.intact(c)
          IO.puts("#{@phase} " <> Atom.to_string(application) <> " " <> Atom.to_string(kind) <> " passed")
        end
        {:ok, %{disposition: :held, revision: 7}} = F.commit(c, preparation, projection)
        :ok = F.intact(c)
        :ok = GenServer.stop(c.store)
        """,
        40
      )
    end
  end

  @tag timeout: 120_000
  test "actual final-read SQL faults roll back tentative publication and disable writing" do
    isolated(
      """
      F.install_final_hook(paths[:wotex_home], #{inspect(Path.expand("lib/wotex_home/durable/store.ex"))})
      for table <- ~w(principals principal_targets invariant_policy_operations operator_override_leases request_rule_origins rule_admissions) do
        c = F.new(Path.join(directory, table <> ".sqlite"))
        {:ok, preparation} = F.prepare(c, "new:sql")
        {:ok, projection} = F.proposal(preparation)
        before = F.snapshot(c)
        observer = self()
        :ok = F.final_hook(c, fn db ->
          :ok = F.tentative!(db, "new:sql")
          :ok = Sqlite3.execute(db, "ALTER TABLE " <> table <> " RENAME TO final_read_fault")
          send(observer, {:late_sql, table})
        end)
        {:error, reason} = F.commit(c, preparation, projection)
        true = reason in [:store_unavailable, :corrupt_rule_admission, :corrupt_override, :corrupt_invariant]
        receive do {:late_sql, ^table} -> :ok after 1_000 -> raise "missing final SQL boundary" end
        true = F.snapshot(c) == before
        {:ok, %{writable: false}} = Store.health(c.store)
        :ok = F.intact(c)
        :ok = GenServer.stop(c.store)
        IO.puts("final SQL " <> table <> " " <> Atom.to_string(reason) <> " passed")
      end
      """,
      6
    )
  end

  @tag timeout: 120_000
  test "producer faults in actual invocation publish no original and preserve writer usability" do
    isolated(
      """
      module = Wotex.Routines.Kernel
      true = Code.ensure_loaded?(module)
      source = module.module_info(:compile)[:source] |> List.to_string() |> File.read!()
      path = Path.join(paths[:wotex_routines], Atom.to_string(module) <> ".beam")
      original_bytes = File.read!(path)
      operation = "refused:actual"
      original = {"wotex-home.rule-original.v1", "operator:runtime", 1, operation}
        |> :erlang.term_to_binary([:deterministic]) |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower) |> then(&("home:rule:" <> &1))
      marker = "      with :ok <- checked_run(run, program, profile, limits),\n"
      true = length(String.split(source, marker)) == 2
      mutations = [
        {:raise, ~S/if event["original"] == ORIGINAL, do: raise("actual producer failure")/},
        {:throw, ~S/if event["original"] == ORIGINAL, do: throw(:actual_producer_failure)/},
        {:zero, ~S/result = if event["original"] == ORIGINAL, do: %{result | "proposals" => []}, else: result/}
      ]
      try do
        for {kind, mutation} <- mutations do
          mutation = String.replace(mutation, "ORIGINAL", inspect(original))
          :ok = F.load_matching(module, String.replace(source, marker, "      " <> mutation <> "\n" <> marker), paths[:wotex_routines])
          c = F.new(Path.join(directory, Atom.to_string(kind) <> ".sqlite"))
          {:ok, %{disposition: :held} = retained} = F.invoke(c, "retained:original")
          before = F.snapshot(c)
          {:error, reason} = F.invoke(c, operation)
          true = reason in [:routine_kernel_refused, :invalid_kernel_projection]
          true = F.snapshot(c) == before
          {:ok, ^retained} = F.invoke(c, "retained:original")
          {:ok, %{writable: true}} = Store.health(c.store)
          :ok = F.intact(c)
          :ok = GenServer.stop(c.store)
          IO.puts("actual " <> Atom.to_string(kind) <> " " <> Atom.to_string(reason) <> " passed")
        end
      after
        File.write!(path, original_bytes)
        {:module, ^module} = :code.load_binary(module, String.to_charlist(path), original_bytes)
        :code.purge(module)
      end
      """,
      3
    )
  end

  @tag timeout: 120_000
  test "actual v3 admission and held original remain exact across current restart and producer loss" do
    isolated(
      """
      modules = [WotexHome.Rules.RestrictedBasis, WotexHome.Rules.AdmissionArtifact,
        WotexHome.Durable.Store.RuleWriter, WotexHome.Durable.Store, WotexHome.Authority]
      originals = Map.new(modules, fn module ->
        path = Path.join(paths[:wotex_home], Atom.to_string(module) <> ".beam")
        {module, {path, File.read!(path)}}
      end)
      for {module, source_path} <- legacy_sources do
        :ok = F.load_matching(module, File.read!(source_path), paths[:wotex_home])
      end
      c = F.new(Path.join(directory, "historical-v3.sqlite"))
      {:ok, %{disposition: :held} = retained} = F.invoke(c, "retained:v3")
      old = F.snapshot(c)
      [[_, _, _, _, _, document | _]] = old["rule_admissions"]
      true = JSON.decode!(document)["proposal_basis"]["profile"] == "explicit-boolean-light-v3"
      :ok = F.intact(c)
      :ok = GenServer.stop(c.store)
      for module <- modules do
        {path, bytes} = Map.fetch!(originals, module)
        File.write!(path, bytes)
        {:module, ^module} = :code.load_binary(module, String.to_charlist(path), bytes)
        :code.purge(module)
      end
      {:ok, store} = Store.start_link(path: c.path)
      current = %{c | store: store, authority: WotexHome.Authority.new(store: store)}
      {:ok, ^retained} = F.invoke(current, "retained:v3")
      {:error, :stale_rule_admission} = F.invoke(current, "new:current")
      true = F.snapshot(current) == old
      {:ok, %{writable: true}} = Store.health(store)
      :ok = GenServer.stop(store)
      true = Application.load(:wotex_routines) in [:ok, {:error, {:already_loaded, :wotex_routines}}]
      modules = Application.spec(:wotex_routines, :modules)
      true = :code.del_path(String.to_charlist(paths[:wotex_routines]))
      for module <- modules do :code.purge(module); :code.delete(module) end
      :ok = Application.unload(:wotex_routines)
      false = Code.ensure_loaded?(Wotex.Routines.Kernel)
      {:ok, restarted} = Store.start_link(path: c.path)
      current = %{current | store: restarted, authority: WotexHome.Authority.new(store: restarted)}
      {:ok, ^retained} = F.invoke(current, "retained:v3")
      {:ok, ^retained} = Store.invoke_rule(restarted, current.control, 1, "retained:v3", 1, "rule:runtime")
      {:error, reason} = F.invoke(current, "new:absent")
      true = reason in [:unsupported_admission_profile, :runtime_artifact_unavailable]
      true = F.snapshot(current) == old
      {:ok, %{writable: true}} = Store.health(restarted)
      :ok = F.intact(current)
      :ok = GenServer.stop(restarted)
      IO.puts("actual v3 held history passed")
      """,
      1,
      legacy: true
    )
  end

  defp isolated(body, expected, options \\ []) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-kernel-runtime-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    apps = RuntimeArtifacts.temporal_applications() ++ [:wotex_udp]
    originals = Map.new(apps, &{&1, Application.app_dir(&1, "ebin")})

    paths =
      Map.new(originals, fn {app, original} ->
        private = Path.join([directory, Atom.to_string(app), "ebin"])
        File.mkdir_p!(private)

        for path <- Path.wildcard(Path.join(original, "*")),
            File.regular?(path),
            do: File.cp!(path, Path.join(private, Path.basename(path)))

        {app, private}
      end)

    legacy_sources =
      if options[:legacy] do
        sources = [
          {WotexHome.Rules.RestrictedBasis, "lib/wotex_home/rules/restricted_basis.ex"},
          {WotexHome.Rules.AdmissionArtifact, "lib/wotex_home/rules/admission_artifact.ex"},
          {WotexHome.Durable.Store.RuleWriter, "lib/wotex_home/durable/store/rule_writer.ex"},
          {WotexHome.Durable.Store, "lib/wotex_home/durable/store.ex"},
          {WotexHome.Authority, "lib/wotex_home/authority.ex"}
        ]

        Enum.map(sources, fn {module, source} ->
          {bytes, 0} = System.cmd("git", ["show", "cf65675:" <> source], stderr_to_stdout: true)
          path = Path.join(directory, Atom.to_string(module) <> ".ex")
          File.write!(path, bytes)
          {module, path}
        end)
      else
        []
      end

    script = """
    alias WotexHome.RuntimeArtifacts
    alias WotexHome.Durable.Store
    alias Exqlite.Sqlite3
    Code.require_file(#{inspect(Path.expand("test/support/rule_kernel_runtime_fixture.exs"))})
    alias WotexHome.TestSupport.RuleKernelRuntimeFixture, as: F
    directory = #{inspect(directory)}
    paths = #{inspect(paths)}
    legacy_sources = #{inspect(legacy_sources)}
    _ = legacy_sources
    #{body}
    """

    original_paths = Map.values(originals)

    arguments =
      :code.get_path() |> Enum.map(&List.to_string/1) |> Enum.reject(&(&1 in original_paths))

    arguments = Enum.flat_map(arguments ++ Map.values(paths), &["-pa", &1]) ++ ["-e", script]

    {output, status} =
      System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)

    assert status == 0, output
    lines = String.split(output, "\n", trim: true)
    assert length(lines) == expected, output
    assert Enum.all?(lines, &String.ends_with?(&1, " passed")), output
  end
end
