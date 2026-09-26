defmodule ExMaude.Error do
  @moduledoc """
  Structured error types for ExMaude operations.

  This module provides rich error representations that make it easier
  to handle and display Maude errors in Elixir applications.

  ## Error Types

    * `:parse_error` - Failed to parse a term
    * `:module_not_found` - Referenced module doesn't exist
    * `:syntax_error` - Invalid Maude syntax
    * `:timeout` - Operation timed out
    * `:response_too_large` - Backend output exceeded the configured ceiling
    * `:busy` - Worker already has a command in flight
    * `:maude_crash` - Maude process crashed
    * `:file_not_found` - File doesn't exist
    * `:load_error` - Failed to load a module
    * `:pool_error` - Pool checkout/operation failed
    * `:invalid_path` - Path validation failed
    * `:ambiguous_term` - Term has multiple parses
    * `:sort_error` - Sort/type mismatch
    * `:not_connected` - Backend not connected (C-Node)
    * `:cnode_error` - C-Node communication error
    * `:nif_not_loaded` - NIF binary failed to load (precompiled binary
      missing for the host platform; set `EX_MAUDE_BUILD=1` to build from
      source, or check that your platform is in the supported targets list)
    * `:nif_error` - Runtime error from the NIF backend
    * `:validation` - Input validation failed
    * `:unknown` - Unrecognized error

  ## Usage

      case ExMaude.reduce("NAT", "invalid syntax $$") do
        {:ok, result} -> handle_result(result)
        {:error, %ExMaude.Error{type: :parse_error, message: msg}} ->
          Logger.warning("Parse error: \#{msg}")
      end

  ## Creating Errors

      # From Maude output
      error = ExMaude.Error.from_output("Warning: module NAT not found")

      # Directly
      error = ExMaude.Error.new(:timeout, "Operation exceeded 5000ms")
  """

  defexception [:type, :message, :details, :raw_output]

  @type error_type ::
          :parse_error
          | :module_not_found
          | :syntax_error
          | :timeout
          | :response_too_large
          | :busy
          | :maude_crash
          | :file_not_found
          | :load_error
          | :pool_error
          | :invalid_path
          | :ambiguous_term
          | :sort_error
          | :not_connected
          | :cnode_error
          | :nif_not_loaded
          | :nif_error
          | :validation
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          details: map() | nil,
          raw_output: String.t() | nil
        }

  @impl Exception
  def message(%__MODULE__{type: type, message: msg}) do
    "[#{type}] #{msg}"
  end

  @doc """
  Creates a new error with the given type and message.

  ## Examples

      iex> error = ExMaude.Error.new(:timeout, "Operation timed out")
      ...> {error.type, error.message}
      {:timeout, "Operation timed out"}
  """
  @spec new(error_type(), String.t(), keyword()) :: t()
  def new(type, message, opts \\ []) do
    %__MODULE__{
      type: type,
      message: message,
      details: Keyword.get(opts, :details),
      raw_output: Keyword.get(opts, :raw_output)
    }
  end

  @doc """
  Creates a new error with the given type and message.

  Alias for `new/2` for convenience.

  ## Examples

      iex> error = ExMaude.Error.exception(:not_connected, "C-Node not connected")
      ...> {error.type, error.message}
      {:not_connected, "C-Node not connected"}
  """
  @spec exception(error_type(), String.t()) :: t()
  def exception(type, message) do
    new(type, message)
  end

  @doc """
  Creates an error from Maude output by detecting the error type.

  Parses the output to identify the type of error and extract
  a meaningful message.

  ## Examples

      iex> error = ExMaude.Error.from_output("Warning: module FOO not found")
      ...> {error.type, error.message}
      {:module_not_found, "Module not found: FOO"}
  """
  @spec from_output(String.t()) :: t()
  def from_output(output) when is_binary(output) do
    cond do
      parse_error?(output) ->
        %__MODULE__{type: :parse_error, message: extract_parse_error(output), raw_output: output}

      module_not_found?(output) ->
        %__MODULE__{
          type: :module_not_found,
          message: extract_module_not_found(output),
          raw_output: output
        }

      syntax_error?(output) ->
        %__MODULE__{
          type: :syntax_error,
          message: extract_syntax_error(output),
          raw_output: output
        }

      ambiguous_error?(output) ->
        %__MODULE__{
          type: :ambiguous_term,
          message: extract_ambiguous_error(output),
          raw_output: output
        }

      sort_error?(output) ->
        %__MODULE__{type: :sort_error, message: extract_sort_error(output), raw_output: output}

      generic_error?(output) ->
        %__MODULE__{type: :unknown, message: extract_warning_or_error(output), raw_output: output}

      true ->
        %__MODULE__{type: :unknown, message: String.slice(output, 0, 200), raw_output: output}
    end
  end

  defp parse_error?(output), do: String.contains?(output, "No parse for term")

  defp module_not_found?(output) do
    normalized = String.downcase(output)

    String.contains?(normalized, "module") and
      (String.contains?(normalized, "not found") or String.contains?(normalized, "no module"))
  end

  defp syntax_error?(output),
    do: String.contains?(output, "syntax error") or String.contains?(output, "Syntax error")

  defp ambiguous_error?(output), do: String.contains?(output, "ambiguous")

  defp sort_error?(output),
    do: String.contains?(output, "sort") and String.contains?(output, "error")

  defp generic_error?(output),
    do: String.contains?(output, "Warning:") or String.contains?(output, "Error:")

  @doc """
  Creates a timeout error.

  ## Examples

      iex> error = ExMaude.Error.timeout(5000)
      ...> {error.type, error.message}
      {:timeout, "Operation timed out after 5000ms"}
  """
  @spec timeout(non_neg_integer()) :: t()
  def timeout(timeout_ms) do
    %__MODULE__{
      type: :timeout,
      message: "Operation timed out after #{timeout_ms}ms",
      details: %{timeout_ms: timeout_ms}
    }
  end

  @doc """
  Creates an error for a response that exceeded the configured byte ceiling.

  ## Examples

      iex> error = ExMaude.Error.response_too_large(1024)
      ...> {error.type, error.details}
      {:response_too_large, %{max_response_bytes: 1024}}
  """
  @spec response_too_large(pos_integer()) :: t()
  def response_too_large(max_response_bytes) do
    %__MODULE__{
      type: :response_too_large,
      message: "Maude response exceeded #{max_response_bytes} bytes",
      details: %{max_response_bytes: max_response_bytes}
    }
  end

  @doc """
  Creates a Maude crash error.

  ## Examples

      iex> error = ExMaude.Error.crash(137)
      ...> {error.type, error.message}
      {:maude_crash, "Maude process crashed with exit code 137"}
  """
  @spec crash(integer()) :: t()
  def crash(exit_code) do
    %__MODULE__{
      type: :maude_crash,
      message: "Maude process crashed with exit code #{exit_code}",
      details: %{exit_code: exit_code}
    }
  end

  @doc """
  Creates a file not found error.

  ## Examples

      iex> error = ExMaude.Error.file_not_found("/path/to/missing.maude")
      ...> {error.type, error.message}
      {:file_not_found, "File not found: /path/to/missing.maude"}
  """
  @spec file_not_found(Path.t()) :: t()
  def file_not_found(path) do
    %__MODULE__{
      type: :file_not_found,
      message: "File not found: #{path}",
      details: %{path: path}
    }
  end

  @doc """
  Creates a partial load error when some modules fail to load.

  ## Examples

      iex> error = ExMaude.Error.partial_load([{:error, "syntax error"}])
      ...> {error.type, error.message}
      {:load_error, "Partial load: 1 module(s) failed to load"}
  """
  @spec partial_load([term()]) :: t()
  def partial_load(failures) when is_list(failures) do
    count = length(failures)

    %__MODULE__{
      type: :load_error,
      message: "Partial load: #{count} module(s) failed to load",
      details: %{failures: failures, count: count}
    }
  end

  @doc """
  Creates a pool error when pool operations fail.

  ## Examples

      iex> error = ExMaude.Error.pool_error(:timeout)
      ...> {error.type, error.message}
      {:pool_error, "Pool checkout timed out"}
  """
  @spec pool_error(term()) :: t()
  def pool_error(reason) do
    message =
      case reason do
        :timeout -> "Pool checkout timed out"
        :full -> "Pool is full, no workers available"
        {:exit, exit_reason} -> "Pool worker exited: #{inspect(exit_reason)}"
        other -> "Pool error: #{inspect(other)}"
      end

    %__MODULE__{
      type: :pool_error,
      message: message,
      details: %{reason: reason}
    }
  end

  @doc """
  Creates an invalid path error for security violations.

  ## Examples

      iex> error = ExMaude.Error.invalid_path("Path escapes temp directory")
      ...> {error.type, error.message}
      {:invalid_path, "Path escapes temp directory"}
  """
  @spec invalid_path(String.t()) :: t()
  def invalid_path(reason) do
    %__MODULE__{
      type: :invalid_path,
      message: reason,
      details: nil
    }
  end

  @doc """
  Checks if the error is recoverable.

  Some errors like timeouts might be recoverable by retrying,
  while others like syntax errors are not.
  """
  @spec recoverable?(t()) :: boolean()
  def recoverable?(%__MODULE__{type: type}) do
    type in [:timeout, :maude_crash]
  end

  @doc """
  Converts the error to a simple tuple format for pattern matching.

  ## Examples

      iex> error = ExMaude.Error.new(:timeout, "timed out")
      ...> ExMaude.Error.to_tuple(error)
      {:timeout, "timed out"}
  """
  @spec to_tuple(t()) :: {error_type(), String.t()}
  def to_tuple(%__MODULE__{type: type, message: message}) do
    {type, message}
  end

  defp extract_parse_error(output) do
    case Regex.run(~r/No parse for term[:\s]*(.+)/s, output) do
      [_, term] -> "No parse for term: #{String.slice(String.trim(term), 0, 100)}"
      nil -> "Failed to parse term"
    end
  end

  defp extract_module_not_found(output) do
    case Regex.run(~r/(?:module\s+(\S+)\s+not found|no module\s+(\S+))/i, output) do
      [_, module, ""] -> "Module not found: #{module}"
      [_, "", module] -> "Module not found: #{String.trim_trailing(module, ".")}"
      [_, module] -> "Module not found: #{module}"
      nil -> "Module not found"
    end
  end

  defp extract_syntax_error(output) do
    case Regex.run(~r/[Ss]yntax error[:\s]*(.+)/s, output) do
      [_, msg] -> String.slice(String.trim(msg), 0, 200)
      nil -> "Syntax error in input"
    end
  end

  defp extract_ambiguous_error(output) do
    case Regex.run(~r/ambiguous[:\s]*(.+)/is, output) do
      [_, msg] -> "Ambiguous: #{String.slice(String.trim(msg), 0, 200)}"
      nil -> "Ambiguous term"
    end
  end

  defp extract_sort_error(output) do
    case Regex.run(~r/sort[:\s]*(.+error.+)/is, output) do
      [_, msg] -> String.slice(String.trim(msg), 0, 200)
      nil -> "Sort error"
    end
  end

  defp extract_warning_or_error(output) do
    case Regex.run(~r/(Warning|Error):\s*(.+)/m, output) do
      [_, _, msg] -> String.slice(String.trim(msg), 0, 200)
      nil -> String.slice(output, 0, 200)
    end
  end

  defimpl Inspect do
    @spec inspect(ExMaude.Error.t(), Inspect.Opts.t()) :: String.t()
    def inspect(%ExMaude.Error{type: type, message: message}, _) do
      "#ExMaude.Error<#{type}: #{message}>"
    end
  end
end
