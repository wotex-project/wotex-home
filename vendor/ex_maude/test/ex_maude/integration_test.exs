defmodule ExMaude.IntegrationTest do
  @moduledoc false

  use ExMaude.MaudeCase

  @moduletag :integration

  describe "reduce/3" do
    test "reduces NAT expression to normal form", %{maude_available: true} do
      {:ok, result} = ExMaude.reduce("NAT", "1 + 2 + 3")
      assert result == "6"
    end

    test "reduces BOOL expression", %{maude_available: true} do
      {:ok, result} = ExMaude.reduce("BOOL", "true and false")
      assert result == "false"
    end

    test "reduces BOOL or expression", %{maude_available: true} do
      {:ok, result} = ExMaude.reduce("BOOL", "true or false")
      assert result == "true"
    end

    test "reduces nested NAT expression", %{maude_available: true} do
      {:ok, result} = ExMaude.reduce("NAT", "(10 + 5) * 2")
      assert result == "30"
    end

    test "reduces with successor notation", %{maude_available: true} do
      {:ok, result} = ExMaude.reduce("NAT", "s(s(s(0)))")
      assert result == "3"
    end

    test "returns error for invalid module", %{maude_available: true} do
      result = ExMaude.reduce("NONEXISTENT-MODULE", "1 + 2")
      assert {:error, _} = result
    end

    test "returns error for invalid term", %{maude_available: true} do
      result = ExMaude.reduce("NAT", "invalid garbage $$")
      assert {:error, _} = result
    end

    test "handles timeout option", %{maude_available: true} do
      {:ok, _} = ExMaude.reduce("NAT", "1 + 1", timeout: 10_000)
    end
  end

  describe "rewrite/3" do
    test "rewrites term using rules", %{maude_available: true} do
      # Load a simple module with rewrite rules
      source = """
      mod COUNTER is
        protecting NAT .
        sort Counter .
        op zero : -> Counter [ctor] .
        op inc : Counter -> Counter [ctor] .
        op count : Counter -> Nat .

        var C : Counter .
        eq count(zero) = 0 .
        eq count(inc(C)) = s(count(C)) .

        rl [tick] : C => inc(C) .
      endm
      """

      path = create_temp_module(source)
      :ok = ExMaude.load_file(path)

      {:ok, result} = ExMaude.rewrite("COUNTER", "zero", max_rewrites: 3)
      # After 3 rewrites, should have inc(inc(inc(zero)))
      assert String.contains?(result, "inc")
    end
  end

  describe "search/4" do
    test "finds reachable states", %{maude_available: true} do
      # Load a module with state space
      source = """
      mod LIGHT is
        sort Light .
        ops on off : -> Light [ctor] .

        rl [turn-on] : off => on .
        rl [turn-off] : on => off .
      endm
      """

      path = create_temp_module(source)
      :ok = ExMaude.load_file(path)

      {:ok, solutions} = ExMaude.search("LIGHT", "off", "on", max_depth: 5)
      assert solutions != []
      assert hd(solutions).state_num != nil
    end

    test "respects max_solutions option", %{maude_available: true} do
      source = """
      mod CHOICE is
        sort State .
        ops a b c : -> State [ctor] .

        rl [to-b] : a => b .
        rl [to-c] : a => c .
      endm
      """

      path = create_temp_module(source)
      :ok = ExMaude.load_file(path)

      {:ok, solutions} = ExMaude.search("CHOICE", "a", "S:State", max_solutions: 1)
      assert length(solutions) == 1
    end

    test "returns empty list when no solution found", %{maude_available: true} do
      source = """
      mod DEAD-END is
        sort State .
        ops start end : -> State [ctor] .
        *** No rules - can't reach end from start
      endm
      """

      path = create_temp_module(source)
      :ok = ExMaude.load_file(path)

      {:ok, solutions} = ExMaude.search("DEAD-END", "start", "end", max_depth: 10)
      assert solutions == []
    end
  end

  describe "load_file/1" do
    test "loads a valid Maude module", %{maude_available: true} do
      source = """
      fmod SIMPLE is
        sort Simple .
        op simple : -> Simple .
      endfm
      """

      path = create_temp_module(source)
      assert :ok = ExMaude.load_file(path)
    end

    test "returns error for non-existent file", %{maude_available: true} do
      result = ExMaude.load_file("/nonexistent/path/file.maude")
      assert {:error, %ExMaude.Error{type: :file_not_found}} = result
    end

    test "module is available after loading", %{maude_available: true} do
      source = """
      fmod LOADED-TEST is
        sort MySort .
        op myConst : -> MySort .
      endfm
      """

      path = create_temp_module(source)
      :ok = ExMaude.load_file(path)

      {:ok, output} = ExMaude.execute("show module LOADED-TEST .")
      assert String.contains?(output, "LOADED-TEST")
    end

    test "loaded modules survive pool worker replacement", %{maude_available: true} do
      path =
        create_temp_module("fmod RELOADED-TEST is sort Answer . op answer : -> Answer . endfm")

      assert :ok = ExMaude.load_file(path)

      worker = ExMaude.Pool.checkout()
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000

      assert Enum.reduce_while(1..50, false, fn _, _ ->
               if ExMaude.Pool.status().available > 0 do
                 {:halt, true}
               else
                 Process.sleep(20)
                 {:cont, false}
               end
             end)

      assert {:ok, "answer"} = ExMaude.reduce("RELOADED-TEST", "answer")
    end
  end

  describe "load_module/1" do
    test "loads module from string", %{maude_available: true} do
      source = """
      fmod STRING-LOADED is
        sort Foo .
        op foo : -> Foo .
      endfm
      """

      assert :ok = ExMaude.load_module(source)
    end
  end

  describe "execute/2" do
    test "executes raw Maude command", %{maude_available: true} do
      {:ok, output} = ExMaude.execute("show modules .")
      assert is_binary(output)
    end

    test "shows module information", %{maude_available: true} do
      {:ok, output} = ExMaude.execute("show module NAT .")
      assert String.contains?(output, "NAT")
    end
  end

  describe "version/0" do
    test "returns Maude version info", %{maude_available: true} do
      {:ok, version} = ExMaude.version()
      assert is_binary(version)
    end
  end

  describe "pool behavior" do
    test "handles concurrent operations", %{maude_available: true} do
      # Run multiple reductions in parallel
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            ExMaude.reduce("NAT", "#{i} + #{i}")
          end)
        end

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      expected = for i <- 1..10, do: {:ok, "#{i * 2}"}
      assert results == expected
    end

    test "pool status reflects usage", %{maude_available: true} do
      status = ExMaude.Pool.status()

      assert is_map(status)
      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert status.size > 0
    end
  end

  describe "IoT rules module" do
    test "loads bundled IoT rules", %{maude_available: true} do
      path = ExMaude.iot_rules_path()
      assert File.exists?(path)

      :ok = ExMaude.load_file(path)
    end

    test "can use conflict detection after loading", %{maude_available: true} do
      path = ExMaude.iot_rules_path()
      :ok = ExMaude.load_file(path)

      command = """
      reduce in CONFLICT-DETECTOR :
        detectConflicts(
          rule("r1", thing("light-1"), propEq("motion", boolVal(true)), setProp(thing("light-1"), "state", strVal("on")), 1),
          rule("r2", thing("light-1"), propEq("time", intVal("2300")), setProp(thing("light-1"), "state", strVal("off")), 1)
        ) .
      """

      {:ok, result} = ExMaude.execute(command)
      assert String.contains?(result, "conflict") or String.contains?(result, "Conflict")
    end
  end
end
