defmodule ExMaude.Binary do
  @moduledoc """
  Maude binary management and platform detection.

  This module handles locating and managing Maude executables, with support for:
  - Binaries in ExMaude's `priv/maude/bin/` (installed via `mix maude.install`;
    the git checkout also carries platform binaries there for development —
    the hex package does not, since Maude is GPL-licensed)
  - System PATH detection
  - Custom path configuration

  ## Fallback Chain

  Binary resolution follows this priority:

  1. `Application.get_env(:ex_maude, :maude_path)` - Explicit config
  2. `MAUDE_PATH` - Environment override
  3. `priv/maude/bin/maude-{platform}` or `priv/maude/bin/maude` - Local
     binary (development checkout or `mix maude.install`)
  4. `System.find_executable("maude")` - System PATH
  5. Raises error with install instructions

  Configured and local candidates must resolve to regular files with an execute
  permission bit. Symlinks to such files are accepted; directories are skipped.
  Discovery is a usability check, not protection from concurrent filesystem changes.

  ## Examples

      # Get the Maude binary path
      ExMaude.Binary.path()
      #=> "/path/to/ex_maude/priv/maude/bin/maude-darwin-arm64"

      # Check if a local binary is available
      ExMaude.Binary.bundled?()
      #=> true

      # Get current platform
      ExMaude.Binary.platform()
      #=> "darwin-arm64"

  """

  @version "3.5.1"

  @doc """
  Returns the path to the Maude binary.

  Follows the fallback chain: config → environment → local → system → error.

  ## Examples

      ExMaude.Binary.path()
      #=> "/path/to/maude"

  """
  @spec path() :: Path.t()
  def path do
    case find() do
      nil -> raise_not_found()
      found -> found
    end
  end

  @doc """
  Returns the path to the Maude binary, or nil if not found.

  Unlike `path/0`, this does not raise an error.
  """
  @spec find() :: Path.t() | nil
  def find do
    configured_path() || bundled_path() || system_path()
  end

  @doc """
  Returns the version associated with checkout-local development assets.

  Use `ExMaude.version/0` to query the interpreter that will actually run.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Checks whether this installation contains a package-local Maude binary for
  the current platform.
  """
  @spec bundled?() :: boolean()
  def bundled? do
    bundled_path() != nil
  end

  @doc """
  Returns the current platform identifier.

  ## Examples

      ExMaude.Binary.platform()
      #=> "darwin-arm64"

  """
  @spec platform() :: String.t()
  def platform do
    case {:os.type(), system_architecture()} do
      {{:unix, :darwin}, arch} when arch in ["aarch64", "arm64", "arm"] ->
        "darwin-arm64"

      {{:unix, :darwin}, _} ->
        "darwin-x64"

      {{:unix, :linux}, arch} when arch in ["x86_64", "amd64"] ->
        "linux-x64"

      {{:unix, :linux}, arch} when arch in ["aarch64", "arm64", "arm"] ->
        "linux-arm64"

      {os, arch} ->
        "#{elem(os, 1)}-#{arch}"
    end
  end

  @doc """
  Returns the priv directory path for ExMaude.
  """
  @spec priv_dir() :: Path.t()
  def priv_dir do
    case :code.priv_dir(:ex_maude) do
      # Reached only when the app is not loaded — fall back to cwd-relative
      # priv so development scripts still work.
      {:error, :bad_name} ->
        Path.join([File.cwd!(), "priv"])

      path ->
        to_string(path)
    end
  end

  @doc """
  Returns a package-local Maude binary for the current platform, or nil.

  Released Hex packages do not include these GPL-licensed binaries; this helper
  primarily supports source checkouts and separately installed assets.
  """
  @spec bundled_path() :: Path.t() | nil
  def bundled_path do
    platform_binary = "maude-#{platform()}"
    path = Path.join([priv_dir(), "maude", "bin", platform_binary])

    if File.exists?(path) and executable?(path) do
      path
    else
      generic = Path.join([priv_dir(), "maude", "bin", "maude"])

      if File.exists?(generic) and executable?(generic) do
        generic
      else
        nil
      end
    end
  end

  @doc """
  Returns platforms that ExMaude can identify and use with a configured,
  locally installed, or system-provided Maude executable.

  This is broader than `mix maude.install` availability. Official stable
  Maude release assets currently cover macOS arm64/x64 and Linux x64;
  Linux arm64 callers must provide a compatible executable.
  """
  @spec supported_platforms() :: [String.t()]
  def supported_platforms do
    ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64"]
  end

  @doc """
  Checks if the current platform is supported.
  """
  @spec supported_platform?() :: boolean()
  def supported_platform? do
    platform() in supported_platforms()
  end

  defp configured_path do
    application_path = Application.get_env(:ex_maude, :maude_path)
    environment_path = System.get_env("MAUDE_PATH")

    validate_configured_path(application_path) || validate_configured_path(environment_path)
  end

  defp validate_configured_path(path) when is_binary(path), do: validate_path(path)
  defp validate_configured_path(_), do: nil

  defp system_path do
    case System.find_executable("maude") do
      nil -> nil
      path -> path
    end
  end

  defp validate_path(path) do
    expanded = Path.expand(path)
    if File.exists?(expanded) and executable?(expanded), do: expanded
  end

  @doc false
  @spec executable?(Path.t()) :: boolean()
  def executable?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) > 0
      _ -> false
    end
  end

  defp system_architecture do
    :erlang.system_info(:system_architecture)
    |> to_string()
    |> then(&String.split(&1, "-"))
    |> List.first()
  end

  @spec raise_not_found() :: no_return()
  defp raise_not_found do
    raise """
    Maude executable not found.

    ExMaude looks for Maude in the following order:
    1. config :ex_maude, :maude_path
    2. MAUDE_PATH environment variable
    3. Bundled binary at priv/maude/bin/maude-#{platform()}
    4. System PATH

    To install Maude:
      mix maude.install

    Or download manually from:
      https://github.com/maude-lang/Maude/releases

    Current platform: #{platform()}
    Supported platforms: #{Enum.join(supported_platforms(), ", ")}
    """
  end
end
