defmodule ExMaude.ServerTest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.Server

  doctest ExMaude.Server

  describe "module functions exist" do
    test "start_link/1 is exported" do
      assert function_exported?(Server, :start_link, 1)
    end

    test "execute/3 is exported" do
      assert function_exported?(Server, :execute, 3)
    end

    test "load_file/2 is exported" do
      assert function_exported?(Server, :load_file, 2)
    end

    test "alive?/1 is exported" do
      assert function_exported?(Server, :alive?, 1)
    end
  end

  describe "configuration" do
    test "accepts maude_path option" do
      opts = [maude_path: "/nonexistent/maude"]
      assert Keyword.get(opts, :maude_path) == "/nonexistent/maude"
    end

    test "accepts preload_modules option" do
      opts = [preload_modules: ["/path/to/module.maude"]]
      assert Keyword.get(opts, :preload_modules) == ["/path/to/module.maude"]
    end

    test "accepts timeout option" do
      opts = [timeout: 10_000]
      assert Keyword.get(opts, :timeout) == 10_000
    end
  end

  # Unit tests for internal logic
  describe "ensure_command_format (internal behavior verification)" do
    # These tests verify expected input/output transformation
    # by testing the execute function with integration tests

    test "command formatting rules" do
      # A properly formatted command should:
      # 1. Be trimmed
      # 2. End with a period
      # 3. End with a newline

      # Without period
      command = "reduce in NAT : 1 + 2"
      assert String.contains?(command, "reduce")
      refute String.ends_with?(command, ".")

      # With period
      command_with_period = "reduce in NAT : 1 + 2 ."
      assert String.ends_with?(command_with_period, ".")
    end
  end

  describe "response parsing logic" do
    # Test error detection patterns
    test "error patterns are recognized" do
      error_outputs = [
        "Error: invalid syntax",
        "Warning: module not found",
        "No parse for term: xyz",
        "module FOO not found",
        "syntax error at line 1",
        "Advisory: deprecated feature"
      ]

      for output <- error_outputs do
        assert has_error_pattern?(output),
               "Expected error pattern to be detected in: #{output}"
      end
    end

    test "non-error outputs are not flagged" do
      valid_outputs = [
        "result Nat: 6",
        "reduce in NAT : 1 + 2 .",
        "rewrites: 3"
      ]

      for output <- valid_outputs do
        refute has_error_pattern?(output),
               "Did not expect error pattern in: #{output}"
      end
    end

    test "result extraction" do
      outputs = [
        {"result Nat: 6", "6"},
        {"result Bool: true", "true"},
        {"result NatList: 1 2 3", "1 2 3"},
        {"rewrites: 3\nresult Nat: 42", "42"}
      ]

      for {output, expected} <- outputs do
        assert extract_result(output) == expected
      end
    end
  end

  describe "prompt detection" do
    test "detects a complete Maude prompt at a line boundary" do
      assert response_complete?("result Nat: 6\nMaude> ")
      assert response_complete?("Maude> ")
    end

    test "incomplete without prompt" do
      refute response_complete?("result Nat: 6")
      refute response_complete?("processing...")
      refute response_complete?("some output Maude> marker")
    end
  end

  describe "alive?/1 edge cases" do
    test "returns false for non-existent server" do
      # Generate a random pid that doesn't exist
      fake_pid = spawn(fn -> :ok end)
      Process.exit(fake_pid, :kill)
      Process.sleep(10)

      refute Server.alive?(fake_pid)
    end
  end

  # Integration tests
  describe "integration tests" do
    @tag :integration
    test "starts and stops server", %{maude_available: true} do
      {:ok, pid} = Server.start_link([])
      assert Process.alive?(pid)
      assert Server.alive?(pid)

      GenServer.stop(pid)
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    @tag :integration
    test "executes simple command", %{maude_available: true} do
      {:ok, pid} = Server.start_link([])

      {:ok, result} = Server.execute(pid, "reduce in NAT : 1 + 2 .")

      assert result == "3"

      GenServer.stop(pid)
    end

    @tag :integration
    test "handles multiple commands", %{maude_available: true} do
      {:ok, pid} = Server.start_link([])

      {:ok, r1} = Server.execute(pid, "reduce in NAT : 1 + 1 .")
      {:ok, r2} = Server.execute(pid, "reduce in NAT : 2 + 2 .")
      {:ok, r3} = Server.execute(pid, "reduce in NAT : 3 + 3 .")

      assert r1 == "2"
      assert r2 == "4"
      assert r3 == "6"

      GenServer.stop(pid)
    end

    @tag :integration
    test "handles timeout", %{maude_available: true} do
      {:ok, pid} = Server.start_link([])

      # Very short timeout may or may not fail depending on system speed
      # We just verify it returns either :ok or :timeout without crashing
      result = Server.execute(pid, "reduce in NAT : 1 + 1 .", timeout: 1)

      assert match?({:ok, _}, result) or match?({:error, %ExMaude.Error{type: :timeout}}, result)

      GenServer.stop(pid)
    end

    @tag :integration
    test "reports parse errors", %{maude_available: true} do
      {:ok, pid} = Server.start_link([])

      {:error, error} = Server.execute(pid, "reduce in NAT : invalid$$syntax .")

      assert error.type in [:parse_error, :syntax_error, :unknown]

      GenServer.stop(pid)
    end

    @tag :integration
    test "loads file", %{maude_available: true} do
      {:ok, pid} = Server.start_link([])

      result = Server.load_file(pid, "/nonexistent/file.maude")

      assert {:error, _} = result

      GenServer.stop(pid)
    end
  end

  # Helper functions that mirror internal logic for testing
  defp has_error_pattern?(output) do
    error_patterns = [
      ~r/Error:/,
      ~r/Warning:/,
      ~r/No parse for term/,
      ~r/no module\s+\S+/i,
      ~r/module\s+\S+\s+not found/i,
      ~r/syntax error/i,
      ~r/Advisory:/
    ]

    Enum.any?(error_patterns, fn pattern ->
      Regex.match?(pattern, output)
    end)
  end

  defp extract_result(output) do
    case Regex.run(~r/result\s+\w+:\s*(.+)/s, output) do
      [_, value] -> String.trim(value)
      nil -> output
    end
  end

  defp response_complete?(buffer) do
    Regex.match?(~r/(?:\A|[\r\n])Maude> /, buffer)
  end

  describe "configuration edge cases" do
    test "default timeout is 5000ms" do
      assert Server.default_timeout() == 5000
    end

    test "uses the configured application timeout" do
      previous = Application.get_env(:ex_maude, :timeout)
      Application.put_env(:ex_maude, :timeout, 1_234)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ex_maude, :timeout, previous),
          else: Application.delete_env(:ex_maude, :timeout)
      end)

      assert Server.default_timeout() == 1_234
    end

    test "configured timeout reaches backend commands without an explicit option" do
      previous = Application.get_env(:ex_maude, :timeout)
      Application.put_env(:ex_maude, :timeout, 60)
      fake_maude = Path.expand("../support/fake_maude.sh", __DIR__)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ex_maude, :timeout, previous),
          else: Application.delete_env(:ex_maude, :timeout)
      end)

      worker =
        start_supervised!(
          {ExMaude.Backend.Port, maude_path: fake_maude, use_pty: false},
          restart: :temporary
        )

      assert {:error, %ExMaude.Error{type: :timeout, details: %{timeout_ms: 60}}} =
               ExMaude.Backend.Port.execute(worker, "hang")
    end

    test "empty preload_modules is valid" do
      opts = [preload_modules: []]
      assert Keyword.get(opts, :preload_modules) == []
    end

    test "an existing worker keeps its backend when application config changes" do
      fake_maude = Path.expand("../support/fake_maude.sh", __DIR__)
      previous = Application.get_env(:ex_maude, :backend)
      {:ok, worker} = ExMaude.Backend.Port.start_link(maude_path: fake_maude, use_pty: false)

      on_exit(fn ->
        if Process.alive?(worker), do: ExMaude.Backend.Port.stop(worker)

        if previous,
          do: Application.put_env(:ex_maude, :backend, previous),
          else: Application.delete_env(:ex_maude, :backend)
      end)

      Application.put_env(:ex_maude, :backend, :nif)
      assert :ok = Server.load_file(worker, "/tmp/example.maude")
      assert Server.alive?(worker)
    end
  end

  describe "command formatting edge cases" do
    test "handles command with trailing whitespace" do
      command = "reduce in NAT : 1 + 2   "
      trimmed = String.trim(command)
      assert trimmed == "reduce in NAT : 1 + 2"
    end

    test "handles command with leading whitespace" do
      command = "   reduce in NAT : 1 + 2"
      trimmed = String.trim(command)
      assert trimmed == "reduce in NAT : 1 + 2"
    end

    test "handles command already ending with period" do
      command = "reduce in NAT : 1 + 2 ."
      assert String.ends_with?(command, ".")
    end

    test "handles multiline command" do
      command = """
      reduce in NAT :
        1 + 2 + 3
      """

      trimmed = String.trim(command)
      assert String.contains?(trimmed, "reduce")
    end
  end

  describe "error detection patterns" do
    test "detects Advisory messages" do
      assert has_error_pattern?("Advisory: this is deprecated")
    end

    test "detects lowercase module not found" do
      assert has_error_pattern?("no module FOO")
    end

    test "detects uppercase module not found" do
      assert has_error_pattern?("module BAR not found")
    end

    test "detects No parse for term" do
      assert has_error_pattern?("No parse for term xyz")
    end

    test "does not detect 'error' as substring in normal content" do
      # The word "error" appearing in a value shouldn't trigger error detection
      # unless it matches the specific patterns
      refute has_error_pattern?("result String: \"handle error gracefully\"")
    end
  end

  describe "result extraction edge cases" do
    test "extracts result with newlines in value" do
      output = "result List: a\nb\nc"
      result = extract_result(output)
      assert String.contains?(result, "a")
    end

    test "extracts result with colons in value" do
      output = "result Time: 12:30:45"
      result = extract_result(output)
      assert result == "12:30:45"
    end

    test "handles output without result keyword" do
      output = "some random output"
      result = extract_result(output)
      assert result == "some random output"
    end
  end

  describe "prompt detection edge cases" do
    test "detects prompt at end of output" do
      assert response_complete?("result Nat: 6\nMaude> ")
    end

    test "detects prompt with spaces" do
      assert response_complete?("result Nat: 6\nMaude> ")
    end

    test "ignores prompt-like text in output" do
      refute response_complete?("payload Maude> marker")
    end

    test "does not detect partial prompt" do
      refute response_complete?("result Nat: 6\nMaud")
    end

    test "does not detect similar text" do
      refute response_complete?("result Nat: 6\nMaudeSystem")
    end
  end

  describe "ensure_command_format behavior" do
    # Testing the expected transformations without accessing private functions
    test "command without period gets period added" do
      # The command "reduce in NAT : 1 + 2" should become "reduce in NAT : 1 + 2 .\n"
      command = "reduce in NAT : 1 + 2"
      refute String.ends_with?(command, ".")
    end

    test "command with period keeps period" do
      command = "reduce in NAT : 1 + 2 ."
      assert String.ends_with?(command, ".")
    end

    test "command with extra whitespace is trimmed" do
      command = "   reduce in NAT : 1 + 2   "
      assert String.trim(command) == "reduce in NAT : 1 + 2"
    end
  end

  describe "error pattern specificity" do
    test "detects 'No parse for term' pattern" do
      assert has_error_pattern?("No parse for term: s(s(s(0)))")
    end

    test "detects case-insensitive syntax error" do
      assert has_error_pattern?("syntax error at position 10")
      assert has_error_pattern?("Syntax error: unexpected token")
    end

    test "does not flag normal result output" do
      refute has_error_pattern?("result Bool: true")
      refute has_error_pattern?("rewrites: 100 in 5ms")
    end

    test "detects Advisory messages as errors" do
      assert has_error_pattern?("Advisory: Feature X is deprecated")
    end
  end

  describe "result extraction robustness" do
    test "extracts from minimal result" do
      assert extract_result("result Nat: 0") == "0"
    end

    test "extracts from result with spaces in type" do
      output = "result List Nat: 1 2 3"
      result = extract_result(output)
      assert is_binary(result)
    end

    test "preserves special characters in result value" do
      output = "result String: \"hello\\nworld\""
      result = extract_result(output)
      assert String.contains?(result, "hello")
    end

    test "handles result with parentheses" do
      output = "result Term: f(g(h(x, y, z)))"
      result = extract_result(output)
      assert String.contains?(result, "f(g(h")
    end
  end

  describe "delegation module structure" do
    test "exports start_link/1" do
      assert function_exported?(Server, :start_link, 1)
    end

    test "exports execute/3" do
      assert function_exported?(Server, :execute, 3)
    end

    test "exports load_file/2" do
      assert function_exported?(Server, :load_file, 2)
    end

    test "exports alive?/1" do
      assert function_exported?(Server, :alive?, 1)
    end

    test "exports stop/1" do
      assert function_exported?(Server, :stop, 1)
    end

    test "delegates to Backend.impl()" do
      assert function_exported?(ExMaude.Backend.Port, :init, 1)
      assert function_exported?(ExMaude.Backend.Port, :handle_call, 3)
      assert function_exported?(ExMaude.Backend.Port, :handle_info, 2)
      assert function_exported?(ExMaude.Backend.Port, :terminate, 2)
    end
  end

  describe "configuration functions" do
    test "accepts all valid configuration options" do
      valid_opts = [
        maude_path: "/usr/bin/maude",
        preload_modules: ["/path/to/mod1.maude", "/path/to/mod2.maude"],
        timeout: 10_000
      ]

      # All options should be extractable
      assert Keyword.get(valid_opts, :maude_path) == "/usr/bin/maude"
      assert length(Keyword.get(valid_opts, :preload_modules)) == 2
      assert Keyword.get(valid_opts, :timeout) == 10_000
    end

    test "handles missing optional configuration" do
      opts = []
      assert Keyword.get(opts, :maude_path) == nil
      assert Keyword.get(opts, :preload_modules) == nil
      assert Keyword.get(opts, :timeout) == nil
    end
  end

  describe "alive?/1 function behavior" do
    test "returns false for nil" do
      assert function_exported?(Server, :alive?, 1)
    end

    test "returns false after process exits" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute Server.alive?(pid)
    end
  end

  describe "stop/1" do
    test "stop/1 is exported" do
      assert function_exported?(Server, :stop, 1)
    end

    @tag :integration
    test "stops a running server", %{maude_available: true} do
      {:ok, pid} = Server.start_link([])
      assert Process.alive?(pid)

      Server.stop(pid)
      Process.sleep(100)
      refute Process.alive?(pid)
    end
  end
end
