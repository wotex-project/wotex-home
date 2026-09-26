defmodule ExMaude.ErrorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.Error

  doctest ExMaude.Error

  describe "new/3" do
    test "creates error with type and message" do
      error = Error.new(:timeout, "Operation timed out")

      assert error.type == :timeout
      assert error.message == "Operation timed out"
      assert error.details == nil
      assert error.raw_output == nil
    end

    test "creates error with details" do
      error = Error.new(:timeout, "timed out", details: %{ms: 5000})

      assert error.details == %{ms: 5000}
    end

    test "creates error with raw_output" do
      error = Error.new(:unknown, "error", raw_output: "raw maude output")

      assert error.raw_output == "raw maude output"
    end
  end

  describe "from_output/1" do
    test "detects parse errors" do
      output = "No parse for term: invalid syntax"
      error = Error.from_output(output)

      assert error.type == :parse_error
      assert String.contains?(error.message, "parse")
    end

    test "detects module not found" do
      output = "Warning: module FOO not found"
      error = Error.from_output(output)

      assert error.type == :module_not_found
      assert String.contains?(error.message, "FOO")
    end

    test "detects Maude's no-module diagnostic" do
      error = Error.from_output("<standard input>, line 1: no module NAMED-ONLY.")

      assert error.type == :module_not_found
      assert error.message == "Module not found: NAMED-ONLY"
    end

    test "detects syntax errors" do
      output = "Syntax error at line 5"
      error = Error.from_output(output)

      assert error.type == :syntax_error
    end

    test "detects ambiguous term" do
      output = "ambiguous term: could be Nat or Int"
      error = Error.from_output(output)

      assert error.type == :ambiguous_term
    end

    test "detects sort errors" do
      output = "sort mismatch error in expression"
      error = Error.from_output(output)

      assert error.type == :sort_error
    end

    test "handles warnings and errors" do
      output = "Warning: something went wrong"
      error = Error.from_output(output)

      assert error.type == :unknown
      assert String.contains?(error.message, "something went wrong")
    end

    test "handles unknown output" do
      output = "some random output without known patterns"
      error = Error.from_output(output)

      assert error.type == :unknown
      assert error.raw_output == output
    end
  end

  describe "timeout/1" do
    test "creates timeout error with ms" do
      error = Error.timeout(5000)

      assert error.type == :timeout
      assert String.contains?(error.message, "5000")
      assert error.details == %{timeout_ms: 5000}
    end
  end

  describe "response_too_large/1" do
    test "records the enforced byte ceiling" do
      error = Error.response_too_large(1024)

      assert error.type == :response_too_large
      assert error.message =~ "1024"
      assert error.details == %{max_response_bytes: 1024}
      refute Error.recoverable?(error)
    end
  end

  describe "crash/1" do
    test "creates crash error with exit code" do
      error = Error.crash(137)

      assert error.type == :maude_crash
      assert String.contains?(error.message, "137")
      assert error.details == %{exit_code: 137}
    end
  end

  describe "file_not_found/1" do
    test "creates file not found error" do
      error = Error.file_not_found("/path/to/missing.maude")

      assert error.type == :file_not_found
      assert String.contains?(error.message, "/path/to/missing.maude")
      assert error.details == %{path: "/path/to/missing.maude"}
    end
  end

  describe "partial_load/1" do
    test "creates partial load error" do
      failures = [{:error, "file1"}, {:error, "file2"}]
      error = Error.partial_load(failures)

      assert error.type == :load_error
      assert String.contains?(error.message, "2")
      assert error.details.count == 2
      assert error.details.failures == failures
    end
  end

  describe "pool_error/1" do
    test "creates pool timeout error" do
      error = Error.pool_error(:timeout)

      assert error.type == :pool_error
      assert String.contains?(error.message, "timed out")
    end

    test "creates pool full error" do
      error = Error.pool_error(:full)

      assert error.type == :pool_error
      assert String.contains?(error.message, "full")
    end

    test "creates pool exit error" do
      error = Error.pool_error({:exit, :normal})

      assert error.type == :pool_error
      assert String.contains?(error.message, "exited")
    end

    test "creates generic pool error" do
      error = Error.pool_error(:some_reason)

      assert error.type == :pool_error
      assert error.details == %{reason: :some_reason}
    end
  end

  describe "invalid_path/1" do
    test "creates invalid path error" do
      error = Error.invalid_path("Path escapes temp directory")

      assert error.type == :invalid_path
      assert error.message == "Path escapes temp directory"
    end
  end

  describe "recoverable?/1" do
    test "timeout is recoverable" do
      error = Error.timeout(5000)
      assert Error.recoverable?(error) == true
    end

    test "crash is recoverable" do
      error = Error.crash(1)
      assert Error.recoverable?(error) == true
    end

    test "parse error is not recoverable" do
      error = Error.new(:parse_error, "bad syntax")
      assert Error.recoverable?(error) == false
    end

    test "file not found is not recoverable" do
      error = Error.file_not_found("/missing")
      assert Error.recoverable?(error) == false
    end
  end

  describe "to_tuple/1" do
    test "converts error to tuple" do
      error = Error.new(:timeout, "timed out")

      assert Error.to_tuple(error) == {:timeout, "timed out"}
    end
  end

  describe "message/1 (Exception callback)" do
    test "formats error message" do
      error = Error.new(:timeout, "Operation timed out")

      assert Exception.message(error) == "[timeout] Operation timed out"
    end
  end

  describe "inspect protocol" do
    test "formats error for inspection" do
      error = Error.new(:timeout, "timed out")
      inspected = inspect(error)

      assert String.contains?(inspected, "ExMaude.Error")
      assert String.contains?(inspected, "timeout")
      assert String.contains?(inspected, "timed out")
    end
  end

  describe "from_output/1 additional edge cases" do
    test "handles lowercase syntax error" do
      output = "syntax error at position 5"
      error = Error.from_output(output)

      assert error.type == :syntax_error
    end

    test "handles capitalized Syntax error" do
      output = "Syntax error: unexpected token"
      error = Error.from_output(output)

      assert error.type == :syntax_error
    end

    test "handles sort error variations" do
      output = "sort mismatch error: expected Nat, got Bool"
      error = Error.from_output(output)

      assert error.type == :sort_error
    end

    test "truncates long messages to 200 chars" do
      long_message = String.duplicate("x", 500)
      output = "Error: #{long_message}"
      error = Error.from_output(output)

      assert String.length(error.message) <= 200
    end

    test "preserves raw_output" do
      output = "Warning: test warning message"
      error = Error.from_output(output)

      assert error.raw_output == output
    end
  end

  describe "exception/2" do
    test "creates error with type and message" do
      error = Error.exception(:not_connected, "C-Node not connected")

      assert error.type == :not_connected
      assert error.message == "C-Node not connected"
      assert error.details == nil
      assert error.raw_output == nil
    end

    test "works for all new error types" do
      new_types = [:not_connected, :cnode_error, :nif_not_loaded, :nif_error, :validation]

      for type <- new_types do
        error = Error.exception(type, "test message for #{type}")
        assert error.type == type
        assert String.contains?(error.message, "#{type}")
      end
    end

    test "is equivalent to new/2" do
      error1 = Error.exception(:timeout, "timed out")
      error2 = Error.new(:timeout, "timed out")

      assert error1.type == error2.type
      assert error1.message == error2.message
    end
  end

  describe "error types" do
    test "all error types are atoms" do
      error_types = [
        :parse_error,
        :module_not_found,
        :syntax_error,
        :timeout,
        :response_too_large,
        :maude_crash,
        :file_not_found,
        :load_error,
        :pool_error,
        :invalid_path,
        :ambiguous_term,
        :sort_error,
        :not_connected,
        :cnode_error,
        :nif_not_loaded,
        :nif_error,
        :validation,
        :unknown
      ]

      for type <- error_types do
        assert is_atom(type)
        error = Error.new(type, "test message")
        assert error.type == type
      end
    end
  end

  describe "recoverable?/1 edge cases" do
    test "module_not_found is not recoverable" do
      error = Error.from_output("module FOO not found")
      assert Error.recoverable?(error) == false
    end

    test "syntax_error is not recoverable" do
      error = Error.new(:syntax_error, "invalid syntax")
      assert Error.recoverable?(error) == false
    end

    test "pool_error is not recoverable" do
      error = Error.pool_error(:full)
      assert Error.recoverable?(error) == false
    end

    test "invalid_path is not recoverable" do
      error = Error.invalid_path("bad path")
      assert Error.recoverable?(error) == false
    end
  end

  describe "Exception behaviour" do
    test "error is an exception" do
      error = Error.new(:test, "test message")
      assert is_exception(error)
    end

    test "can be raised" do
      assert_raise Error, fn ->
        raise Error.new(:test, "test error")
      end
    end

    test "message/1 returns formatted message" do
      error = Error.new(:parse_error, "bad syntax")
      assert Exception.message(error) == "[parse_error] bad syntax"
    end
  end

  describe "from_output/1 pattern matching" do
    test "detects module not found with varying case" do
      output1 = "Warning: module FOO not found"
      output2 = "Error: Module BAR not found"

      error1 = Error.from_output(output1)
      assert error1.type == :module_not_found

      error2 = Error.from_output(output2)
      assert error2.type in [:module_not_found, :unknown]
    end

    test "extracts module name from not found error" do
      output = "Warning: module MY-CUSTOM-MODULE not found"
      error = Error.from_output(output)

      assert error.type == :module_not_found
      assert String.contains?(error.message, "MY-CUSTOM-MODULE")
    end

    test "handles parse error with complex term" do
      output = "No parse for term: if_then_else(cond, a, b)"
      error = Error.from_output(output)

      assert error.type == :parse_error
      assert String.contains?(error.message, "parse")
    end

    test "handles ambiguous term message" do
      output = "ambiguous term: could be Nat or Int"
      error = Error.from_output(output)

      assert error.type == :ambiguous_term
    end

    test "handles sort error with details" do
      output = "sort mismatch error: expected Nat, got Bool at position 5"
      error = Error.from_output(output)

      assert error.type == :sort_error
    end
  end

  describe "error construction helpers" do
    test "timeout/1 with various values" do
      for ms <- [100, 1000, 5000, 30_000] do
        error = Error.timeout(ms)
        assert error.type == :timeout
        assert error.details.timeout_ms == ms
        assert String.contains?(error.message, "#{ms}")
      end
    end

    test "crash/1 with various exit codes" do
      for code <- [0, 1, 137, 255] do
        error = Error.crash(code)
        assert error.type == :maude_crash
        assert error.details.exit_code == code
      end
    end

    test "file_not_found/1 with various paths" do
      paths = [
        "/path/to/file.maude",
        "relative/path.maude",
        "/path with spaces/file.maude"
      ]

      for path <- paths do
        error = Error.file_not_found(path)
        assert error.type == :file_not_found
        assert error.details.path == path
      end
    end

    test "partial_load/1 with empty list" do
      error = Error.partial_load([])
      assert error.type == :load_error
      assert error.details.count == 0
    end

    test "partial_load/1 with multiple failures" do
      failures = [
        {:error, "file1.maude"},
        {:error, "file2.maude"},
        {:error, "file3.maude"}
      ]

      error = Error.partial_load(failures)
      assert error.type == :load_error
      assert error.details.count == 3
      assert error.details.failures == failures
    end
  end

  describe "pool_error/1 variants" do
    test "handles noproc error" do
      error = Error.pool_error(:noproc)
      assert error.type == :pool_error
      assert error.details.reason == :noproc
    end

    test "handles shutdown error" do
      error = Error.pool_error({:exit, :shutdown})
      assert error.type == :pool_error
      assert String.contains?(error.message, "exited")
    end

    test "handles killed error" do
      error = Error.pool_error({:exit, :killed})
      assert error.type == :pool_error
    end
  end

  describe "recoverable?/1 comprehensive" do
    test "only timeout and crash are recoverable" do
      recoverable_types = [:timeout, :maude_crash]

      non_recoverable_types = [
        :response_too_large,
        :parse_error,
        :module_not_found,
        :syntax_error,
        :file_not_found,
        :load_error,
        :pool_error,
        :invalid_path,
        :ambiguous_term,
        :sort_error,
        :not_connected,
        :cnode_error,
        :nif_not_loaded,
        :nif_error,
        :validation,
        :unknown
      ]

      for type <- recoverable_types do
        error = Error.new(type, "test")
        assert Error.recoverable?(error) == true, "#{type} should be recoverable"
      end

      for type <- non_recoverable_types do
        error = Error.new(type, "test")
        assert Error.recoverable?(error) == false, "#{type} should not be recoverable"
      end
    end
  end

  describe "to_tuple/1 conversion" do
    test "converts all error types correctly" do
      types = [:parse_error, :timeout, :unknown, :file_not_found]

      for type <- types do
        error = Error.new(type, "message for #{type}")
        {result_type, result_msg} = Error.to_tuple(error)

        assert result_type == type
        assert String.contains?(result_msg, "#{type}")
      end
    end
  end

  describe "Inspect protocol" do
    test "inspect shows type and message" do
      error = Error.new(:custom_type, "custom message")
      inspected = inspect(error)

      assert String.contains?(inspected, "custom_type")
      assert String.contains?(inspected, "custom message")
    end

    test "inspect handles special characters in message" do
      error = Error.new(:test, "message with \"quotes\" and 'apostrophes'")
      inspected = inspect(error)

      assert is_binary(inspected)
    end
  end

  describe "new/3 with all options" do
    test "creates error with details and raw_output" do
      error =
        Error.new(
          :custom,
          "test message",
          details: %{key: "value", count: 5},
          raw_output: "raw maude output here"
        )

      assert error.type == :custom
      assert error.message == "test message"
      assert error.details == %{key: "value", count: 5}
      assert error.raw_output == "raw maude output here"
    end

    test "handles nil options gracefully" do
      error = Error.new(:test, "msg", [])
      assert error.details == nil
      assert error.raw_output == nil
    end
  end

  describe "from_output/1 message truncation" do
    test "truncates very long error messages" do
      long_content = String.duplicate("x", 500)
      output = "Error: #{long_content}"
      error = Error.from_output(output)

      # Message should be truncated to 200 chars
      assert String.length(error.message) <= 200
    end

    test "preserves short messages intact" do
      output = "Error: short message"
      error = Error.from_output(output)

      assert error.message == "short message"
    end
  end

  describe "from_output/1 extraction fallbacks" do
    test "parse error without matching regex uses fallback" do
      # Contains "No parse for term" but not in expected format
      output = "No parse for term"
      error = Error.from_output(output)

      assert error.type == :parse_error
      assert error.message == "Failed to parse term"
    end

    test "module not found without matching regex uses fallback" do
      # Contains "module" and "not found" but regex expects "module X not found"
      output = "module not found"
      error = Error.from_output(output)

      assert error.type == :module_not_found
      assert error.message == "Module not found"
    end

    test "syntax error without matching regex uses fallback" do
      # Contains "syntax error" but not in expected format
      output = "syntax error"
      error = Error.from_output(output)

      assert error.type == :syntax_error
      assert error.message == "Syntax error in input"
    end

    test "ambiguous error without matching regex uses fallback" do
      # Contains "ambiguous" but not in expected format
      output = "ambiguous"
      error = Error.from_output(output)

      assert error.type == :ambiguous_term
      assert error.message == "Ambiguous term"
    end

    test "sort error without matching regex uses fallback" do
      # Contains "sort" and "error" but not in expected format
      output = "sort error"
      error = Error.from_output(output)

      assert error.type == :sort_error
      assert error.message == "Sort error"
    end

    test "warning without matching regex uses fallback" do
      # Contains "Warning:" but not in expected format
      output = "Warning:"
      error = Error.from_output(output)

      assert error.type == :unknown
    end
  end
end
