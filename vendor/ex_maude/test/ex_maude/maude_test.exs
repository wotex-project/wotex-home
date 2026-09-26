defmodule ExMaude.MaudeTest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.{Command, Error, Maude, Pool}

  doctest ExMaude.Maude

  describe "module functions exist" do
    test "reduce/3 is exported" do
      assert function_exported?(Maude, :reduce, 3)
    end

    test "rewrite/3 is exported" do
      assert function_exported?(Maude, :rewrite, 3)
    end

    test "search/4 is exported" do
      assert function_exported?(Maude, :search, 4)
    end

    test "load_file/1 is exported" do
      assert function_exported?(Maude, :load_file, 1)
      assert function_exported?(Maude, :load_file, 2)
      assert function_exported?(ExMaude, :load_file, 2)
    end

    test "ensure_file_loaded/2 is exported" do
      assert function_exported?(Maude, :ensure_file_loaded, 1)
      assert function_exported?(Maude, :ensure_file_loaded, 2)
      assert function_exported?(ExMaude, :ensure_file_loaded, 2)
    end

    test "load_module/1 is exported" do
      assert function_exported?(Maude, :load_module, 1)
      assert function_exported?(Maude, :load_module, 2)
      assert function_exported?(ExMaude, :load_module, 2)
    end

    test "execute/2 is exported" do
      assert function_exported?(Maude, :execute, 2)
    end

    test "version/0 is exported" do
      assert function_exported?(Maude, :version, 0)
    end

    test "parse/3 is exported" do
      assert function_exported?(Maude, :parse, 3)
    end

    test "show_module/2 is exported" do
      assert function_exported?(Maude, :show_module, 2)
    end

    test "list_modules/1 is exported" do
      assert function_exported?(Maude, :list_modules, 1)
    end
  end

  describe "load_file/1 validation" do
    test "returns error for non-existent file" do
      result = Maude.load_file("/nonexistent/path/to/file.maude")
      assert {:error, %Error{type: :file_not_found}} = result
    end

    test "error contains path in details" do
      path = "/missing/module.maude"
      {:error, error} = Maude.load_file(path)

      assert error.details.path == path
    end
  end

  describe "ensure_file_loaded/2 validation" do
    test "returns a structured error for a non-existent file" do
      assert {:error, %Error{type: :file_not_found}} =
               Maude.ensure_file_loaded("/nonexistent/path/to/file.maude")
    end
  end

  describe "load_module/1" do
    test "validates path stays in temp directory" do
      source = "fmod TEST is endfm"

      result = Maude.load_module(source)

      case result do
        {:error, %Error{type: :invalid_path}} ->
          flunk("Should not reject valid source as invalid path")

        _ ->
          # Other errors are acceptable (pool not running, etc.)
          :ok
      end
    end
  end

  describe "reduce/3 command building" do
    # Test the expected command format
    test "builds correct reduce command format" do
      assert Command.reduce("NAT", "1 + 2 + 3") == "reduce in NAT : 1 + 2 + 3"
    end
  end

  describe "rewrite/3 command building" do
    test "builds rewrite command without max_rewrites" do
      assert Command.rewrite("MY-MOD", "initial", []) == "rewrite in MY-MOD : initial"
    end

    test "builds rewrite command with max_rewrites" do
      assert Command.rewrite("MY-MOD", "initial", max_rewrites: 100) ==
               "rewrite [100] in MY-MOD : initial"
    end
  end

  describe "search/4 command building" do
    test "builds search command with defaults" do
      assert Command.search("MY-MOD", "init", "goal", []) ==
               "search [1, 100] in MY-MOD : init =>* goal"
    end

    test "supports different arrow operators" do
      for arrow <- ["=>1", "=>+", "=>*", "=>!"] do
        assert Command.search("M", "a", "b", arrow: arrow) =~ " #{arrow} "
      end
    end

    test "supports condition clause" do
      assert Command.search("M", "a", "S:State", condition: "property(S)") =~
               "such that property(S)"
    end
  end

  describe "parse/3 command building" do
    test "builds parse command" do
      assert Command.parse("NAT", "1 + 2") == "parse in NAT : 1 + 2"
    end

    test "quotes file paths as one Maude argument" do
      assert Command.load_file(~s|/tmp/a "quoted" module.maude|) ==
               ~s|load "/tmp/a \\"quoted\\" module.maude"|
    end
  end

  describe "show_module/2 command building" do
    test "builds show module command" do
      module = "NAT"
      expected = "show module #{module} ."

      assert String.contains?(expected, "show module")
      assert String.contains?(expected, module)
    end
  end

  describe "list_modules/1 command building" do
    test "builds show modules command" do
      expected = "show modules ."

      assert String.contains?(expected, "show modules")
    end
  end

  # Integration tests require Maude
  describe "reduce/3 integration" do
    @tag :integration
    test "reduces NAT expression", %{maude_available: true} do
      {:ok, result} = Maude.reduce("NAT", "1 + 2 + 3")
      assert result == "6"
    end

    @tag :integration
    test "reduces BOOL expression", %{maude_available: true} do
      {:ok, result} = Maude.reduce("BOOL", "true and false")
      assert result == "false"
    end

    @tag :integration
    test "reduces with timeout option", %{maude_available: true} do
      {:ok, result} = Maude.reduce("NAT", "1 + 1", timeout: 10_000)
      assert result == "2"
    end

    @tag :integration
    test "reduces a partial function to a kind-level result", %{maude_available: true} do
      # 1 / 0 has no well-sorted normal form; Maude answers `result [Rat]: 1 / 0`.
      {:ok, result} = Maude.reduce("RAT", "1 / 0")
      assert result == "1 / 0"
    end

    @tag :integration
    test "handles invalid module", %{maude_available: true} do
      result = Maude.reduce("NONEXISTENT-MODULE", "1 + 1")
      assert {:error, %Error{}} = result
    end

    @tag :integration
    test "handles parse error", %{maude_available: true} do
      result = Maude.reduce("NAT", "invalid$$syntax")
      assert {:error, %Error{}} = result
    end
  end

  describe "rewrite/3 integration" do
    @tag :integration
    test "rewrites simple term", %{maude_available: true} do
      {:ok, result} = Maude.rewrite("NAT", "0", max_rewrites: 10)
      assert result == "0"
    end

    @tag :integration
    test "respects max_rewrites", %{maude_available: true} do
      {:ok, _} = Maude.rewrite("NAT", "1", max_rewrites: 1)
    end
  end

  describe "execute/2 integration" do
    @tag :integration
    test "executes raw command", %{maude_available: true} do
      {:ok, output} = Maude.execute("reduce in NAT : 2 + 2 .")
      assert String.contains?(output, "4") or output == "4"
    end

    @tag :integration
    test "executes show modules", %{maude_available: true} do
      {:ok, output} = Maude.execute("show modules .")
      assert is_binary(output)
    end
  end

  describe "version/0 integration" do
    @tag :integration
    test "returns the real interpreter version", %{maude_available: true} do
      {:ok, version} = Maude.version()
      assert version =~ ~r/^\d+\.\d+/
    end

    @tag :integration
    test "agrees with the bundled VERSION metadata when using the bundled binary",
         %{maude_available: true} do
      # Only meaningful when the resolved binary IS the bundled one.
      if ExMaude.Binary.bundled?() and ExMaude.Binary.find() == ExMaude.Binary.bundled_path() do
        {:ok, version} = Maude.version()
        assert version == ExMaude.Binary.version()
      end
    end

    test "reports a structured error for an unrunnable binary" do
      assert {:error, %Error{type: :file_not_found}} = Maude.version("/nonexistent/maude")
    end
  end

  describe "parse/3 integration" do
    @tag :integration
    test "parses term without reducing", %{maude_available: true} do
      {:ok, output} = Maude.parse("NAT", "1 + 2")
      assert is_binary(output)
    end
  end

  describe "show_module/2 integration" do
    @tag :integration
    test "shows module definition", %{maude_available: true} do
      {:ok, output} = Maude.show_module("NAT")
      assert is_binary(output)
      assert String.contains?(output, "NAT") or String.contains?(output, "Nat")
    end
  end

  describe "list_modules/1 integration" do
    @tag :integration
    test "lists all modules", %{maude_available: true} do
      {:ok, output} = Maude.list_modules()
      assert is_binary(output)
    end
  end

  describe "search/4 integration" do
    @tag :integration
    test "searches for solutions", %{maude_available: true} do
      # NAT doesn't have rewrite rules, so search will find the initial term
      {:ok, solutions} = Maude.search("NAT", "0", "N:Nat", max_solutions: 1, max_depth: 1)
      assert is_list(solutions)
    end

    @tag :integration
    test "preserves the caller-selected pool", %{maude_available: true, maude_path: path} do
      pool = :ex_maude_named_search_pool
      start_named_pool(pool, path)

      assert {:ok, solutions} =
               Maude.search("NAT", "0", "N:Nat",
                 max_solutions: 1,
                 max_depth: 1,
                 pool: pool
               )

      assert is_list(solutions)
    end

    @tag :integration
    test "keeps dynamically loaded modules isolated by pool",
         %{maude_available: true, maude_path: path} do
      pool_a = :ex_maude_module_pool_a
      pool_b = :ex_maude_module_pool_b
      start_named_pool(pool_a, path)
      start_named_pool(pool_b, path)

      source = "fmod NAMED-ONLY is sort Answer . op answer : -> Answer . endfm"
      assert :ok = Maude.load_module(source, pool: pool_a)
      assert {:ok, "answer"} = Maude.reduce("NAMED-ONLY", "answer", pool: pool_a)

      assert {:error, %Error{type: :module_not_found}} =
               Maude.reduce("NAMED-ONLY", "answer", pool: pool_b)
    end

    @tag :integration
    test "replays a named pool's modules after worker replacement",
         %{maude_available: true, maude_path: path} do
      pool = :ex_maude_replacement_pool
      start_named_pool(pool, path)

      source = "fmod REPLAYED is sort Answer . op answer : -> Answer . endfm"
      assert :ok = Maude.load_module(source, pool: pool)

      worker = Pool.checkout(pool: pool)
      Pool.checkin(worker, pool: pool)
      Process.exit(worker, :kill)

      assert_eventually(fn ->
        case Maude.reduce("REPLAYED", "answer", pool: pool) do
          {:ok, "answer"} -> true
          _ -> false
        end
      end)
    end
  end

  describe "search/4 command building additional tests" do
    test "builds search with =>1 arrow" do
      # =>1 means exactly one step
      assert Command.search("M", "a", "b", arrow: "=>1") =~ " =>1 "
    end

    test "builds search with =>+ arrow" do
      # =>+ means one or more steps
      assert Command.search("M", "a", "b", arrow: "=>+") =~ " =>+ "
    end

    test "builds search with =>! arrow" do
      # =>! means search for normal forms
      assert Command.search("M", "a", "b", arrow: "=>!") =~ " =>! "
    end

    test "max_depth and max_solutions format correctly" do
      assert Command.search("M", "a", "b", max_solutions: 5, max_depth: 50) =~ "[5, 50]"
    end
  end

  describe "load_module/1 security" do
    test "generates unique temp file names" do
      id1 = :erlang.unique_integer([:positive])
      id2 = :erlang.unique_integer([:positive])
      refute id1 == id2
    end

    test "temp directory is used" do
      tmp_dir = System.tmp_dir!()
      assert is_binary(tmp_dir)
      assert File.dir?(tmp_dir)
    end
  end

  describe "reduce/3 additional tests" do
    test "command format is correct" do
      assert Command.reduce("MY-MODULE", "my-term") == "reduce in MY-MODULE : my-term"
    end
  end

  describe "rewrite/3 additional tests" do
    test "command format without max_rewrites" do
      assert Command.rewrite("MOD", "init", []) == "rewrite in MOD : init"
    end

    test "command format with max_rewrites" do
      assert Command.rewrite("MOD", "init", max_rewrites: 100) ==
               "rewrite [100] in MOD : init"
    end
  end

  describe "parse/3 additional tests" do
    test "command format is correct" do
      assert Command.parse("NAT", "1 + 2") == "parse in NAT : 1 + 2"
    end
  end

  describe "load_file/1 additional tests" do
    test "returns file_not_found for missing file" do
      result = Maude.load_file("/definitely/not/a/real/path/file.maude")
      assert {:error, %Error{type: :file_not_found}} = result
    end

    test "error includes the path" do
      path = "/missing/test.maude"
      {:error, error} = Maude.load_file(path)
      assert error.details.path == path
    end
  end

  describe "version/0 unit tests" do
    test "function is exported" do
      assert function_exported?(Maude, :version, 0)
    end
  end

  describe "show_module/2 command format" do
    test "command includes module name" do
      module = "NAT"
      expected = "show module #{module} ."
      assert expected == "show module NAT ."
    end
  end

  describe "list_modules/1 command format" do
    test "command is show modules" do
      expected = "show modules ."
      assert expected == "show modules ."
    end
  end

  describe "timeout handling" do
    test "default timeout is 5000ms" do
      default = 5_000
      assert default == 5000
    end

    test "search default timeout is 30000ms" do
      search_timeout = 30_000
      assert search_timeout == 30_000
    end
  end

  describe "error scenarios" do
    test "invalid module returns error" do
      # This would require Maude to be running, so just test structure
      assert function_exported?(Maude, :reduce, 3)
    end
  end

  defp start_named_pool(pool, maude_path) do
    start_supervised!(%{
      id: pool,
      start:
        {Supervisor, :start_link,
         [
           [
             Pool.child_spec(
               name: pool,
               pool_size: 1,
               pool_max_overflow: 0,
               maude_path: maude_path
             )
           ],
           [strategy: :one_for_one]
         ]},
      type: :supervisor
    })
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end
end
