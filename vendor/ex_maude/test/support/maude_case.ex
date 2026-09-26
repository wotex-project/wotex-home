defmodule ExMaude.MaudeCase do
  @moduledoc """
  Shared test case module for integration tests requiring Maude.

  This module provides a consistent setup for tests that need to interact
  with a real Maude process. It handles:

  - Detecting if Maude is available on the system
  - Starting an explicit ExMaude pool for integration tests
  - Providing test context with Maude availability information

  ## Usage

      defmodule MyIntegrationTest do
        use ExMaude.MaudeCase

        @moduletag :integration

        test "reduces a term", %{maude_available: true} do
          {:ok, result} = ExMaude.reduce("NAT", "1 + 2")
          assert result == "3"
        end
      end

  ## Test Tags

  Tests using this case template should be tagged with `@moduletag :integration`
  or individual `@tag :integration`. Integration tests are excluded by default;
  explicitly including them requires an available Maude interpreter.

  ## Context Variables

  The following variables are available in the test context:

    * `:maude_available` - Boolean indicating if Maude was found
    * `:maude_path` - Path to the Maude executable (when available)
    * `:maude_version` - Maude version string (when available)
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import ExMaude.MaudeCase
    end
  end

  setup_all do
    case find_maude() do
      nil ->
        {:ok, maude_available: false, maude_path: nil, maude_version: nil}

      path ->
        # Get Maude version
        version = get_maude_version(path)

        {:ok, maude_available: true, maude_path: path, maude_version: version}
    end
  end

  setup %{maude_path: path} do
    if path do
      start_supervised!(%{
        id: :ex_maude_test_pool_supervisor,
        start:
          {Supervisor, :start_link,
           [[ExMaude.Pool.child_spec(maude_path: path)], [strategy: :one_for_one]]},
        type: :supervisor
      })
    end

    :ok
  end

  # Find Maude binary - uses ExMaude.Binary for consistent detection
  defp find_maude do
    ExMaude.Binary.find()
  end

  @doc """
  Checks if Maude is available on the system.

  Uses `ExMaude.Binary.find/0` to check for bundled, configured, or system Maude.
  """
  @spec maude_available?() :: boolean()
  def maude_available? do
    ExMaude.Binary.find() != nil
  end

  @doc """
  Returns the path to the Maude executable, or `nil` if not found.

  Uses `ExMaude.Binary.find/0` for consistent detection.
  """
  @spec maude_path() :: String.t() | nil
  def maude_path do
    ExMaude.Binary.find()
  end

  @doc """
  Creates a temporary Maude module file for testing.

  Returns the path to the temporary file. The file is automatically
  deleted when the test process exits.

  ## Examples

      path = create_temp_module("fmod TEST is sort Foo . endfm")
      :ok = ExMaude.load_file(path)
  """
  @spec create_temp_module(String.t()) :: Path.t()
  def create_temp_module(source) do
    tmp_dir = System.tmp_dir!()
    filename = "ex_maude_test_#{:erlang.unique_integer([:positive])}.maude"
    path = Path.join(tmp_dir, filename)

    File.write!(path, source)

    # Register cleanup on test exit
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)

    path
  end

  defp get_maude_version(path) do
    case ExMaude.Subprocess.run(path, ["--version"], 5_000, 64 * 1024) do
      {:ok, output, 0} ->
        output
        |> String.split("\n")
        |> List.first()
        |> String.trim()

      _ ->
        "unknown"
    end
  rescue
    _ -> "unknown"
  end
end
