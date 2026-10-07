# Run with: elixir bin/build.exs [--dependency-env prod|test]
# Fresh Home compilation/assembly against explicitly selected prebuilt dependencies.
defmodule WotexHome.BuildRunner do
  @moduledoc false

  @packaged_store_check ~S"""
  System.delete_env("WOTEX_HOME_DATA_DIR")
  if Node.alive?(), do: raise("distributed Erlang must remain disabled")
  {:ok, _} = Application.ensure_all_started(:wotex_home)
  {:ok, _} = WotexHome.Lifx.ProfileBasis.runtime_digest()
  directory = Path.join(System.tmp_dir!(), "woh-packaged-store-" <>
    Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
  File.mkdir!(directory)
  File.chmod!(directory, 0o700)
  path = Path.join(directory, "home.sqlite")
  try do
    {:ok, store} = WotexHome.Durable.Store.start_link(path: path)
    {:ok, %{writable: true, store_revision: 0, authority_epoch: 1,
      dispatch_enabled: false}} = WotexHome.Durable.Store.health(store)
    %{profile: "home-explicit-request-cause-v1", max_effects: 1, max_depth: 1} =
      WotexHome.Durable.Store.CausalLedger.profile()
    {:ok, thing} = WotexHome.Semantics.Thing.new(%{
      "id" => "light:build", "role" => "Light", "profile_ref" => "fixture:power:1",
      "capabilities" => [%{
        "thing_id" => "light:build", "role" => "Light", "key" => "power",
        "value_kind" => "boolean", "unit" => "none", "operations" => ["read", "write"],
        "risk_class" => "ordinary", "profile_ref" => "fixture:power:1",
        "evidence_ref" => "fixture:build", "freshness_ms" => 5_000,
        "constraints" => %{}, "extensions" => %{}
      }]
    })
    {:ok, 1} = WotexHome.Durable.Store.enroll_thing(store, thing)
    {:ok, credential, 2} = WotexHome.Durable.Store.provision_principal(
      store, "operator:build", ["control:ordinary", "rule:review", "rule:manage", "host:maintain"], [thing.id])
    {:ok, mutation} = WotexHome.Mutation.new(%{
      "api_version" => 1, "authority_epoch" => 1, "operation_id" => "op:build",
      "expected_revision" => 0, "target_id" => thing.id, "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    })
    {:ok, %{disposition: :held, revision: 3} = receipt} =
      WotexHome.Durable.Store.submit_request(store, credential, mutation)
    {:ok, rule} = WotexHome.Rules.Rule.new(%{
      "version" => 1, "id" => "rule:build", "source_revision" => 3,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{"target_id" => thing.id, "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}},
      "authority_class" => "automation", "unknown_policy" => "block",
      "ownership_ms" => 1_000, "cooldown_ms" => 0, "causal_budget" => 1
    })
    {:ok, program} = WotexHome.Rules.Compiler.compile([rule])
    :ok = WotexHome.Rules.Compiler.current(program, [rule])
    {:ok, true} = WotexHome.Rules.Compiler.evaluate(hd(program.entries).predicate_code, %{})
    {:ok, %{profile: "explicit-boolean-light-v3", scope: :proposal_generation_only,
      compiler_profile: "home-rule-ir-v1"} = basis} =
      WotexHome.Rules.RestrictedBasis.qualify([rule], %{thing.id => thing})
    true = basis.source_digest == program.source_digest and basis.ir_digest == program.ir_digest
    :ok = WotexHome.Rules.RestrictedBasis.current(basis, [rule], %{thing.id => thing})
    false = WotexHome.Rules.RestrictedBasis.valid?(%{basis | scope: :admitted})
    :ok = GenServer.stop(store)
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)
    {:ok, [[20]]} = WotexHome.Durable.Store.SQL.query(db, "PRAGMA user_version")
    {:ok, [["explicit_request", 3, 0, nil]]} = WotexHome.Durable.Store.SQL.query(db,
      "SELECT origin, created_revision, reserved_effects, reservation_revision FROM request_causal_roots")
    :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
    :ok = Exqlite.Sqlite3.close(db)
    {:ok, restarted} = WotexHome.Durable.Store.start_link(path: path)
    {:ok, ^receipt} = WotexHome.Durable.Store.submit_request(restarted, credential, mutation)
    {:ok, %{writable: true, store_revision: 3, authority_epoch: 1,
      held_requests: 1, queued_requests: 0, dispatch_enabled: false}} =
      WotexHome.Durable.Store.health(restarted)
    {:ok, observation} = WotexHome.Semantics.Observation.new(%{
      "thing_id" => thing.id, "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true},
      "quality" => "reported", "trust" => "unauthenticated_local",
      "source_epoch" => "source:build", "source_sequence" => 1,
      "boot_epoch" => "adapter:build", "source_time_utc_ms" => nil,
      "received_time_utc_ms" => 1, "received_monotonic_ms" => 999_999_999
    }, thing.capabilities["power"])
    {:ok, 4} = WotexHome.Durable.Store.record(restarted, observation, thing.capabilities["power"])
    {:ok, %{profile: "home-reported-facts-v1", scope: :reported_fact_preview_only,
      store_revision: 4, facts: facts}} = WotexHome.Durable.Store.rule_facts_live(
        restarted, credential, [{thing.id, "power"}])
    true = facts[{thing.id, "power"}] == {:known, observation.value}
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(directory, "build.backup")
    {:ok, _} = WotexHome.Durable.Store.export_backup(restarted, archive, key)
    {:ok, %{store_revision: 4}} = WotexHome.Durable.Backup.verify(archive, key)
    :ok = GenServer.stop(restarted)
    {:ok, final_store} = WotexHome.Durable.Store.start_link(path: path)
    {:ok, %{facts: facts}} = WotexHome.Durable.Store.rule_facts_live(final_store, credential, [{thing.id, "power"}])
    true = facts[{thing.id, "power"}] == :unknown
    {:duplicate, 4} = WotexHome.Durable.Store.record(final_store, observation, thing.capabilities["power"])
    {:ok, %{facts: facts}} = WotexHome.Durable.Store.rule_facts_live(final_store, credential, [{thing.id, "power"}])
    true = facts[{thing.id, "power"}] == :unknown
    authority = WotexHome.Authority.new(store: final_store)
    {:ok, rule_source} = WotexHome.Rules.Codec.encode([%{rule | ownership_ms: 1}])
    rule_input = JSON.decode!(rule_source)["rules"]
    {:ok, %{state: :admitted, revision: 5} = admission} = WotexHome.Authority.admit_rule(
      authority, credential, 1, "admit:build", 4, rule_input)
    {:ok, %{state: :active, rule_generation: 1, store_revision: 7} = activation} =
      WotexHome.Authority.activate_rule(authority, credential, 1, "activate:build", 5, 5)
    {:ok, %{disposition: :held, revision: 8} = rule_receipt} = WotexHome.Authority.invoke_rule(
      authority, credential, 1, "invoke:build", 1, rule.id)
    rule_archive = Path.join(directory, "rules.backup")
    {:ok, _} = WotexHome.Durable.Store.export_backup(final_store, rule_archive, key)
    {:ok, %{store_revision: 8, dependencies: %{rule_admission_rows: 1,
      rule_activation_rows: 1, rule_history_reactivates_on_restore: false}}} =
      WotexHome.Durable.Backup.verify(rule_archive, key)
    :ok = GenServer.stop(final_store)
    {:ok, rule_store} = WotexHome.Durable.Store.start_link(path: path)
    rule_authority = WotexHome.Authority.new(store: rule_store)
    {:ok, ^admission} = WotexHome.Authority.admit_rule(
      rule_authority, credential, 1, "admit:build", 4, rule_input)
    {:ok, ^activation} = WotexHome.Authority.activate_rule(
      rule_authority, credential, 1, "activate:build", 5, 5)
    {:ok, ^rule_receipt} = WotexHome.Authority.invoke_rule(
      rule_authority, credential, 1, "invoke:build", 1, rule.id)
    {:ok, %{writable: true, rule_generation: 1, held_requests: 1,
      queued_requests: 0, dispatch_enabled: false}} = WotexHome.Durable.Store.health(rule_store)
    {:ok, %{state: :maintenance, affected_requests: 1, revision: 11} = maintenance} =
      WotexHome.Authority.begin_maintenance(rule_authority, credential, 1, "maintenance:build", 8)
    {:error, :maintenance_active} = WotexHome.Durable.Store.submit_request(
      rule_store, credential, %{mutation | operation_id: "blocked:build"})
    maintenance_archive = Path.join(directory, "maintenance.backup")
    {:ok, _} = WotexHome.Durable.Store.export_backup(rule_store, maintenance_archive, key)
    {:ok, %{dependencies: %{host_maintenance_active: true, host_maintenance_operation_rows: 1}}} =
      WotexHome.Durable.Backup.verify(maintenance_archive, key)
    :ok = GenServer.stop(rule_store)
    {:ok, maintenance_store} = WotexHome.Durable.Store.start_link(path: path)
    maintenance_authority = WotexHome.Authority.new(store: maintenance_store)
    {:ok, ^maintenance} = WotexHome.Authority.begin_maintenance(
      maintenance_authority, credential, 1, "maintenance:build", 8)
    {:ok, %{state: :maintenance, begin_revision: 11}} = WotexHome.Authority.maintenance_status(
      maintenance_authority, credential)
    {:ok, %{state: :normal, revision: 12}} = WotexHome.Authority.end_maintenance(
      maintenance_authority, credential, 1, "resume:build", 11, 11)
    :ok = GenServer.stop(maintenance_store)

    profile_directory = Path.join(directory, "portable-data")
    profile_directory = cond do
      String.starts_with?(profile_directory, "/var/") -> "/private" <> profile_directory
      :os.type() == {:unix, :darwin} and String.starts_with?(profile_directory, "/tmp/") -> "/private" <> profile_directory
      true -> profile_directory
    end
    File.mkdir!(profile_directory)
    File.chmod!(profile_directory, 0o700)
    profile_root = Path.join(profile_directory, "profiles")
    File.mkdir!(profile_root)
    File.chmod!(profile_root, 0o700)
    {:ok, profile_store} = WotexHome.Durable.Store.start_link(
      path: Path.join(profile_directory, "home.sqlite"),
      profile_custody: WotexHome.BuildProfiles.Custody)
    {:ok, custody} = WotexHome.Profiles.Custody.start_link(root: profile_root,
      store_owner: profile_store, name: WotexHome.BuildProfiles.Custody)
    profile_authority = WotexHome.Authority.new(store: profile_store, profile_custody: custody)
    {:ok, manager, 1} = WotexHome.Authority.provision_profile_manager(profile_authority)
    {:ok, maintainer, 2} = WotexHome.Authority.provision_maintenance(profile_authority)
    {:ok, _} = WotexHome.Authority.begin_maintenance(profile_authority, maintainer, 1, "maintenance:profiles", 2)
    example = File.read!(Application.app_dir(:wotex_home, "priv/profiles/lifx-power-example.json"))
    {:ok, digest} = WotexHome.Authority.stage_profile(profile_authority, manager, example)
    {:ok, expected} = WotexHome.Durable.Store.revision(profile_store)
    {:ok, approved} = WotexHome.Authority.profile_change(profile_authority, manager, %{
      "action" => "approve", "authority_epoch" => 1, "operation_id" => "profile:build",
      "expected_revision" => expected, "artifact_digest" => digest, "expected_trust_revision" => 0})
    profile_archive = Path.join(profile_directory, "profiles.backup")
    {:ok, %{portable_profile_objects: 1}} = WotexHome.Authority.export_profile_backup(
      profile_authority, profile_archive, key)
    {:ok, %{dependencies: %{portable_profile_bytes_included: true, portable_profile_object_count: 1}}} =
      WotexHome.Durable.Backup.verify(profile_archive, key)
    quarantine = Path.join(profile_directory, "quarantine")
    {:ok, %{quarantined: true, portable_profile_objects: 1}} =
      WotexHome.Durable.Backup.stage_profile_restore(profile_archive, key, quarantine)
    ^example = File.read!(Path.join(quarantine, "profiles/" <> digest <> ".json"))
    {:ok, ^approved} = WotexHome.Authority.profile_operation_status(profile_authority, manager, 1, "profile:build")
    {:ok, %{writable: true, dispatch_enabled: false, active_things: 0}} =
      WotexHome.Durable.Store.health(profile_store)
    :ok = GenServer.stop(custody)
    :ok = GenServer.stop(profile_store)

    IO.puts("PACKAGED_STORE_OK; schema20 profile import/approval/exact-byte quarantine, maintenance, clocks, causal roots, IR, rule lifecycle and encrypted history checked")
  after
    File.rm_rf!(directory)
  end
  """

  def run(args) do
    {options, remaining, invalid} =
      OptionParser.parse(args, strict: [dependency_env: :keep])

    dependency_env = Keyword.get(options, :dependency_env, "prod")

    unless invalid == [] and remaining == [] and length(options) <= 1 and
             dependency_env in ["prod", "test"],
           do: raise(ArgumentError, "usage: elixir bin/build.exs [--dependency-env prod|test]")

    # The internal dependency-compile load-path flag below is reviewed against
    # this repository's pinned Mix implementation, not a cross-version CLI API.
    unless System.version() == "1.19.6" and :erlang.system_info(:otp_release) == ~c"28",
      do: raise("Use the repository's pinned Elixir 1.19.6/OTP 28 toolchain.")

    root = Path.expand("..", __DIR__)
    File.cd!(root)
    require_clean_source!()
    Mix.start()
    Mix.env(:prod)

    build_parent = Path.join(root, "_build/socket-free-prod")
    File.mkdir_p!(build_parent)
    build = Path.join(build_parent, Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
    File.mkdir!(build)
    File.chmod!(build, 0o700)

    previous_lock = System.get_env("MIX_OS_CONCURRENCY_LOCK")
    previous_sources = System.get_env("WOTEX_HOME_GIT_DEPS")

    try do
      # No other build writes this freshly created exclusive directory. This is
      # a build-only Mix lock; the Home Store's host lock is unchanged.
      System.put_env("MIX_OS_CONCURRENCY_LOCK", "0")
      System.put_env("WOTEX_HOME_GIT_DEPS", "1")

      Mix.Project.in_project(:wotex_home, root, [build_path: build], fn project ->
        require_git_sources!(root, project.source_pins())
        dependencies = Mix.Dep.load_and_cache()
        preload_dependencies!(root, dependency_env, dependencies)

        # Dependency paths and metadata are actually loaded above. This is the
        # same nonrecursive entry used by Mix when compiling a dependency, not
        # a fake completed compile task or substitute PubSub process.
        Mix.Task.run("loadpaths", ["--from-mix-deps-compile"])
        Mix.Task.run("compile", ["--from-mix-deps-compile", "--warnings-as-errors"])
        Mix.Tasks.Woh.Spec.Check.run([])

        release = Path.join(build, "release")
        Mix.Task.run("release", ["--path", release])
        {:ok, payload} = Woh.Tool.ReleaseSmoke.check_payload(Path.join(release, "bin/wotex_home"))
        IO.puts(payload)
        check_packaged_store!(release)
        inventory!(release, root)
        IO.puts("Unsigned development release: #{release}")

        IO.puts(
          "Prebuilt #{dependency_env} dependencies reused; host/socket/hardware NOT qualified."
        )
      end)
    after
      restore_env("MIX_OS_CONCURRENCY_LOCK", previous_lock)
      restore_env("WOTEX_HOME_GIT_DEPS", previous_sources)
    end
  end

  defp preload_dependencies!(root, environment, dependencies) do
    destination = Path.join(Mix.Project.build_path(), "lib")
    File.mkdir_p!(destination)

    for dependency <- dependencies do
      source = Path.join([root, "_build", environment, "lib", Atom.to_string(dependency.app)])

      unless File.regular?(Path.join(source, "ebin/#{dependency.app}.app")),
        do:
          raise(
            "Missing prebuilt #{environment} dependency #{dependency.app}; build it normally first."
          )

      File.cp_r!(source, Path.join(destination, Atom.to_string(dependency.app)),
        dereference_symlinks: true
      )
    end

    Code.prepend_paths(Path.wildcard(Path.join(destination, "*/ebin")))
  end

  defp require_clean_source! do
    case System.cmd("git", ["status", "--porcelain", "--untracked-files=normal"],
           stderr_to_stdout: true
         ) do
      {"", 0} -> :ok
      _ -> raise("Build from a clean committed Home tree; no source revision may be fabricated.")
    end
  end

  defp require_git_sources!(root, pins) do
    # The caller may select a writable Home Git directory. That setting must
    # not redirect checks of the two independent dependency repositories.
    environment = [{"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}]

    for {application, pin} <- pins do
      directory = Path.join([root, "deps", Atom.to_string(application)])

      with {revision, 0} <-
             System.cmd("git", ["-C", directory, "rev-parse", "HEAD"],
               env: environment,
               stderr_to_stdout: true
             ),
           true <- String.trim(revision) == pin,
           {"", 0} <-
             System.cmd("git", ["-C", directory, "status", "--porcelain", "--untracked-files=no"],
               env: environment,
               stderr_to_stdout: true
             ) do
        :ok
      else
        _ -> raise("Fetch the clean exact Git pin for #{application} before building.")
      end
    end
  end

  defp check_packaged_store!(release) do
    case Woh.Tool.Command.run(
           Path.join(release, "bin/wotex_home"),
           ["eval", @packaged_store_check],
           1_048_576,
           15_000
         ) do
      {:ok, output} ->
        unless String.contains?(output, "PACKAGED_STORE_OK"),
          do: raise("Packaged Store startup/restart did not complete.")

        IO.puts(
          "Packaged Store/IR/basis/root/retry/restart/backup passed; no host socket was opened."
        )

      {:error, reason} ->
        raise("Packaged Store check failed: #{reason}")
    end
  end

  defp inventory!(release, root) do
    {:ok, revision} = Woh.Tool.ReleaseInventory.source_revision(root)
    {:ok, _} = Woh.Tool.ReleaseComponents.create(release, root, revision)
    {:ok, _} = Woh.Tool.ReleaseComponents.verify(release, root, revision)
    {:ok, spdx_count} = Woh.Tool.ReleaseSpdx.create(release, root)
    {:ok, ^spdx_count} = Woh.Tool.ReleaseSpdx.verify(release, root)
    {:ok, count} = Woh.Tool.ReleaseInventory.create(release, revision)
    {:ok, ^count} = Woh.Tool.ReleaseInventory.verify(release)

    IO.puts(
      "Verified #{count} inventoried release files and #{spdx_count} SPDX files at #{revision}."
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

WotexHome.BuildRunner.run(System.argv())
