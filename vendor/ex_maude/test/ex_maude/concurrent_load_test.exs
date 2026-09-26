defmodule ExMaude.ConcurrentLoadTest do
  @moduledoc """
  Regression cover for the concurrent-load stampede.

  Before `ensure_file_loaded/2`, every `detect_conflicts/2` call broadcast a
  file load to every pool worker — including workers checked out serving other
  reductions. Twelve concurrent callers produced eleven
  `load_error: Partial load: N module(s) failed to load` results and one
  success. The gate failed closed, which is correct behaviour for a wrong
  answer, but the library was manufacturing the failure itself.
  """
  use ExMaude.MaudeCase, async: false

  @moduletag :integration

  alias ExMaude.Maude

  setup do
    pool = :concurrent_load_test_pool
    start_supervised!(ExMaude.Pool.child_spec(name: pool, pool_size: 4))
    %{pool: pool}
  end

  @rules [
    %{
      id: "a",
      thing_id: "device-1",
      trigger: {:prop_lt, "battery", 20},
      actions: [{:set_prop, "device-1", "destination", "dock-7"}],
      priority: 1
    },
    %{
      id: "b",
      thing_id: "device-1",
      trigger: {:prop_gte, "hour", 9},
      actions: [{:set_prop, "device-1", "destination", "dock-19"}],
      priority: 1
    }
  ]

  describe "ensure_file_loaded/2" do
    test "reloads restored file contents on every worker", %{pool: pool} do
      path = create_temp_module("fmod RESTORED-CONTENTS is endfm")

      for value <- [1, 2, 1] do
        File.write!(
          path,
          "fmod RESTORED-CONTENTS is protecting NAT . op value : -> Nat . eq value = #{value} . endfm"
        )

        assert :ok = Maude.ensure_file_loaded(path, pool: pool)

        assert {:ok, values} =
                 ExMaude.Pool.broadcast(
                   &ExMaude.Server.execute(&1, "reduce in RESTORED-CONTENTS : value ."),
                   pool: pool
                 )

        assert values == List.duplicate({:ok, Integer.to_string(value)}, 4)
        assert length(ExMaude.Preloads.loaded_for_pool(pool)) == 1
      end
    end

    test "a failed reload invalidates an earlier successful identity", %{pool: pool} do
      source = "fmod FAILED-RELOAD is protecting NAT . endfm"
      path = create_temp_module(source)
      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
      File.write!(path, "fmod FAILED-RELOAD is protecting DOES-NOT-EXIST . endfm")
      assert {:error, %ExMaude.Error{type: :load_error}} = Maude.load_file(path, pool: pool)
      File.write!(path, source)
      assert ExMaude.Preloads.loaded_for_pool(pool) == []
      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
      assert {:ok, "3"} = ExMaude.reduce("FAILED-RELOAD", "1 + 2", pool: pool)
    end

    test "is idempotent", %{pool: pool} do
      path = ExMaude.iot_rules_path()

      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
    end

    test "reports a missing file rather than pretending to load it" do
      assert {:error, %ExMaude.Error{}} =
               Maude.ensure_file_loaded("/nonexistent/definitely-not-here.maude")
    end

    test "concurrent first-callers all succeed", %{pool: pool} do
      path = ExMaude.iot_rules_path()

      results =
        1..16
        |> Task.async_stream(fn _ -> Maude.ensure_file_loaded(path, pool: pool) end,
          max_concurrency: 16,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok)),
             "expected every concurrent load to succeed, got: #{inspect(Enum.frequencies(results))}"
    end
  end

  test "replacement workers preserve repeated string-module load order" do
    name = :repeated_source_pool
    start_supervised!(ExMaude.Pool.child_spec(name: name, pool_size: 1, pool_max_overflow: 0))

    for value <- [1, 2, 1] do
      assert :ok =
               ExMaude.load_module(
                 "fmod REPEATED-SOURCE is protecting NAT . op value : -> Nat . eq value = #{value} . endfm",
                 pool: name
               )
    end

    assert {:ok, "1"} = ExMaude.reduce("REPEATED-SOURCE", "value", pool: name)
    worker = ExMaude.Pool.checkout(pool: name)
    GenServer.stop(worker)
    assert {:ok, "1"} = ExMaude.reduce("REPEATED-SOURCE", "value", pool: name)
  end

  describe "detect_conflicts/2 under concurrency" do
    test "every concurrent caller gets the same real answer", %{pool: pool} do
      # Warm the pool once, the way an application does at boot (or via
      # `:preload_modules`). What is being tested is that the *steady state* no
      # longer re-broadcasts a load per call and trips over its own workers.
      :ok = Maude.ensure_file_loaded(ExMaude.iot_rules_path(), pool: pool)

      results =
        1..12
        |> Task.async_stream(fn _ -> ExMaude.IoT.detect_conflicts(@rules, pool: pool) end,
          max_concurrency: 8,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      failures = Enum.reject(results, &match?({:ok, _}, &1))

      assert failures == [],
             "concurrent detection must not manufacture load errors, got: #{inspect(failures)}"

      # And the answer must be right, not merely non-failing.
      Enum.each(results, fn {:ok, conflicts} ->
        assert [%{type: :state_conflict, rule1: "a", rule2: "b"}] =
                 Enum.map(conflicts, &Map.take(&1, [:type, :rule1, :rule2]))
      end)
    end
  end

  test "a new pool cannot inherit successful startup identities" do
    path =
      create_temp_module(
        "fmod POOL-IDENTITY is protecting NAT . op answer : -> Nat . eq answer = 42 . endfm"
      )

    name = :pool_identity_audit
    start_supervised!(ExMaude.Pool.child_spec(name: name, pool_size: 1, preload_modules: [path]))
    assert :ok = Maude.ensure_file_loaded(path, pool: name)
    stop_supervised!(name)

    assert {:error, %ExMaude.Error{type: :pool_error}} =
             Maude.ensure_file_loaded(path, pool: name)

    start_supervised!(ExMaude.Pool.child_spec(name: name, pool_size: 1, preload_modules: []))
    assert :ok = Maude.ensure_file_loaded(path, pool: name)
    assert {:ok, "42"} = ExMaude.reduce("POOL-IDENTITY", "answer", pool: name)
  end

  test "public file loading preserves relative imports", %{pool: pool} do
    dir = Path.join(System.tmp_dir!(), "relative-load-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    File.write!(Path.join(dir, "child.maude"), "fmod RELATIVE-CHILD is protecting NAT . endfm")
    parent = Path.join(dir, "parent.maude")

    File.write!(
      parent,
      "load child.maude\nfmod RELATIVE-PARENT is protecting RELATIVE-CHILD . endfm"
    )

    assert :ok = ExMaude.load_file(parent, pool: pool)
    assert {:ok, "3"} = ExMaude.reduce("RELATIVE-PARENT", "1 + 2", pool: pool)
  end

  test "string modules survive worker replacement and their files follow pool lifetime" do
    name = :owned_source_pool
    start_supervised!(ExMaude.Pool.child_spec(name: name, pool_size: 1, pool_max_overflow: 0))
    assert :ok = ExMaude.load_module("fmod OWNED-SOURCE is protecting NAT . endfm", pool: name)
    [path] = ExMaude.Preloads.runtime_for_pool(name)
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    worker = ExMaude.Pool.checkout(pool: name)
    GenServer.stop(worker)
    assert {:ok, "3"} = ExMaude.reduce("OWNED-SOURCE", "1 + 2", pool: name)
    stop_supervised!(name)
    start_supervised!(ExMaude.Pool.child_spec(name: name, pool_size: 1, pool_max_overflow: 0))
    assert :ok = ExMaude.load_module("fmod NEW-SOURCE is protecting NAT . endfm", pool: name)
    [new_path] = ExMaude.Preloads.runtime_for_pool(name)
    refute new_path == path

    Enum.reduce_while(1..100, nil, fn _, _ ->
      if File.exists?(path),
        do:
          (
            Process.sleep(10)
            {:cont, nil}
          ),
        else: {:halt, :ok}
    end)

    refute File.exists?(path)
    assert File.exists?(new_path)
    assert {:ok, "3"} = ExMaude.reduce("NEW-SOURCE", "1 + 2", pool: name)
  end
end
