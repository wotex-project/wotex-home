defmodule Mix.Tasks.Maude.Install do
  @moduledoc """
  Installs or updates the Maude interpreter binary.

  The hex package does not ship Maude itself (Maude is GPL-licensed and
  ~5 MB per platform) — run this task once after adding the dependency,
  or point `config :ex_maude, :maude_path` at an existing installation.

  The binary installs into ExMaude's `priv/maude/bin/` by default, where
  `ExMaude.Binary.find/0` discovers it without any configuration.

  Extraction validates the archive and requires a recognized regular Maude
  executable before copying any release files. Execute permissions are set in
  staging. Publication copies multiple files and is not atomic: an I/O failure
  during copying can leave a partial installation. There is no rollback, stale
  file removal, or concurrent-install lock. Install into a separate directory
  when preserving a running installation is required. Filesystem checks assume
  a trusted destination and do not defend against hostile concurrent writers.

  ## Usage

      mix maude.install [--version VERSION] [--path PATH] [--force] [--list] [--check]

  ## Options

    * `--version` - Maude version to install (default: latest)
    * `--path` - Installation path (default: ExMaude's `priv/maude/bin`);
      custom paths need `config :ex_maude, :maude_path` afterwards
    * `--force` - Force reinstall even if already installed
    * `--list` - List available versions and exit
    * `--check` - Check current Maude availability and exit

  ## Supported Platforms

    * macOS ARM64 (Apple Silicon)
    * macOS x86_64 (Intel)
    * Linux x86_64

  ## Examples

      # Check if Maude is available
      mix maude.install --check

      # Install latest version (only if needed)
      mix maude.install

      # List available versions
      mix maude.install --list

      # Install specific version
      mix maude.install --version 3.5.1

      # Install to custom path
      mix maude.install --path /usr/local/bin

      # Force reinstall
      mix maude.install --force

  ## Binary Resolution

  At runtime the binary resolution follows this priority:

    1. `config :ex_maude, :maude_path` - Explicit configuration
    2. `MAUDE_PATH` environment variable
    3. Binary in ExMaude's `priv/maude/bin/` (installed by this task; the
       git checkout also carries platform binaries there for development)
    4. System PATH (`maude` command)

  ## Troubleshooting

  If installation fails:

    * **Network errors** - Check your internet connection and proxy settings
    * **Permission denied** - Ensure you have write access to the installation path
    * **Platform not supported** - Check if your OS/architecture is in the supported list
    * **Integrity verification failed** - Download manually only after verifying
      the artifact against an authoritative checksum

  For macOS, you may need to allow the binary in System Preferences > Security & Privacy
  if you see a "cannot be opened because the developer cannot be verified" error.
  """

  use Mix.Task

  @shortdoc "Installs Maude system binary"

  @github_api "https://api.github.com/repos/maude-lang/Maude/releases"
  @download_timeout 120_000
  @api_timeout 30_000
  @max_download_size 100 * 1024 * 1024
  @max_extracted_size @max_download_size * 4
  @max_archive_entries 10_000

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          version: :string,
          path: :string,
          force: :boolean,
          list: :boolean,
          check: :boolean
        ]
      )

    if invalid != [] do
      invalid_opts = Enum.map_join(invalid, ", ", fn {opt, _} -> opt end)
      Mix.raise("Unknown options: #{invalid_opts}\n\nRun `mix help maude.install` for usage.")
    end

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:public_key)

    cond do
      Keyword.get(opts, :check, false) ->
        check_availability()

      Keyword.get(opts, :list, false) ->
        list_versions()

      true ->
        version = Keyword.get(opts, :version)
        install_path = Keyword.get(opts, :path, default_install_path())
        force = Keyword.get(opts, :force, false)

        maude_binary = Path.join(install_path, "maude")

        if File.exists?(maude_binary) and not force do
          Mix.shell().info("Maude already installed at #{maude_binary}")
          Mix.shell().info("Use --force to reinstall")
          :ok
        else
          install_maude(version, install_path)
        end
    end
  end

  defp check_availability do
    Mix.shell().info("Checking Maude availability...")
    Mix.shell().info("")

    platform = detect_platform()
    Mix.shell().info("Platform: #{platform}")

    bundled_path = ExMaude.Binary.bundled_path()

    if bundled_path do
      Mix.shell().info("✓ Local binary: #{bundled_path}")
    else
      Mix.shell().info("✗ Local binary: not found for #{platform}")
    end

    system_path = System.find_executable("maude")

    if system_path do
      Mix.shell().info("✓ System PATH: #{system_path}")
    else
      Mix.shell().info("✗ System PATH: maude not found")
    end

    configured = Application.get_env(:ex_maude, :maude_path)

    if configured do
      if File.exists?(configured) do
        Mix.shell().info("✓ Configured: #{configured}")
      else
        Mix.shell().info("✗ Configured: #{configured} (file not found)")
      end
    end

    # Final resolution
    Mix.shell().info("")

    case ExMaude.Binary.find() do
      nil ->
        Mix.shell().error("✗ No Maude binary available")
        Mix.shell().info("")
        Mix.shell().info("Install with: mix maude.install")

      path ->
        Mix.shell().info("✓ ExMaude will use: #{path}")
    end
  end

  defp list_versions do
    Mix.shell().info("Fetching available Maude versions...")

    case fetch_releases() do
      {:ok, releases} ->
        platform = detect_platform()
        print_available_versions(releases, platform)
        Mix.shell().info("\nInstall with: mix maude.install --version <VERSION>")
        Mix.shell().info("Example: mix maude.install --version 3.5.1")

      {:error, reason} ->
        Mix.raise("Failed to fetch releases: #{reason}")
    end
  end

  defp print_available_versions(releases, platform) do
    Mix.shell().info("\nAvailable Maude versions for #{platform}:\n")

    releases
    |> Enum.filter(&has_platform_asset?(&1, platform))
    |> Enum.each(&print_release_version/1)
  end

  defp print_release_version(release) do
    tag = release["tag_name"]
    name = release["name"]
    date = release["published_at"] |> String.slice(0, 10)
    latest = if release["prerelease"] == false, do: "", else: " (prerelease)"

    Mix.shell().info("  #{tag} - #{name} (#{date})#{latest}")
  end

  # Install into ExMaude's own priv directory: that's where
  # ExMaude.Binary.find/0 discovers the generic `maude` binary with zero
  # configuration, whether ExMaude is the project itself (priv/ is symlinked
  # into _build) or a dependency (deps/ex_maude/priv).
  defp default_install_path do
    Path.join([ExMaude.Binary.priv_dir(), "maude", "bin"])
  end

  # A custom --path lands outside Binary.find/0's discovery chain and needs
  # a :maude_path config hint after install.
  defp opts_for_path_hint(install_path) do
    if Path.expand(install_path) == Path.expand(default_install_path()) do
      []
    else
      [custom: true]
    end
  end

  defp install_maude(version, install_path) do
    platform = detect_platform()

    Mix.shell().info("Detecting platform: #{platform}")
    Mix.shell().info("Fetching release information from GitHub...")

    case find_release_asset(version, platform) do
      {:ok, %{url: url, sha256: sha256, version: resolved_version}} ->
        Mix.shell().info("Installing Maude #{resolved_version} for #{platform}...")

        File.mkdir_p!(install_path)

        tmp_dir = create_private_tmp_dir()
        zip_path = Path.join(tmp_dir, "maude.zip")

        try do
          download_file(url, zip_path)
          verify_checksum(zip_path, sha256)
          install_archive(zip_path, install_path, resolved_version, tmp_dir)
        after
          File.rm_rf(tmp_dir)
        end

        maude_binary = Path.join(install_path, "maude")

        Mix.shell().info("\n✓ Maude installed successfully at #{maude_binary}")

        if Keyword.has_key?(opts_for_path_hint(install_path), :custom) do
          Mix.shell().info("""

          Installed outside ExMaude's priv directory — point the library at it:

              config :ex_maude, maude_path: #{inspect(maude_binary)}
          """)
        end

        verify_installation(maude_binary)

      {:error, :no_releases} ->
        Mix.raise("""
        Failed to fetch releases from GitHub.

        Please check your internet connection and try again.
        You can also manually download Maude from:
        https://github.com/maude-lang/Maude/releases
        """)

      {:error, :version_not_found, available} ->
        Mix.raise("""
        Version "#{version}" not found.

        Available versions:
          #{Enum.join(available, "\n  ")}

        Run `mix maude.install --list` for more details.
        """)

      {:error, :platform_not_supported, available_platforms} ->
        Mix.raise("""
        No Maude binary available for platform: #{platform}

        Your system:
          OS: #{elem(:os.type(), 1)}
          Architecture: #{:erlang.system_info(:system_architecture)}

        Available platforms for this version:
          #{Enum.join(available_platforms, "\n  ")}

        You may need to build Maude from source for your platform.
        See: https://github.com/maude-lang/Maude
        """)

      {:error, :missing_digest, release, asset} ->
        Mix.raise("""
        Refusing to install #{asset} from #{release}: the GitHub release does not
        provide a valid SHA-256 digest.

        Automatic installation fails closed when artifact integrity cannot be
        verified. Install Maude manually from:
        https://github.com/maude-lang/Maude/releases
        """)
    end
  end

  defp find_release_asset(nil, platform) do
    case fetch_releases() do
      {:ok, releases} ->
        case latest_release_asset(releases, platform) do
          nil -> {:error, :platform_not_supported, get_all_platforms(releases)}
          result -> result
        end

      {:error, _} ->
        {:error, :no_releases}
    end
  end

  defp find_release_asset(version, platform) do
    # GitHub release tags use "Maude3.5.1" while users pass "3.5.1".
    version_tag = normalize_version_tag(version)

    case fetch_releases() do
      {:ok, releases} ->
        find_release_asset(releases, version_tag, platform)

      {:error, _} ->
        {:error, :no_releases}
    end
  end

  defp latest_release_asset(releases, platform) do
    releases
    |> Enum.filter(&(&1["prerelease"] == false))
    |> Enum.find_value(&latest_release_asset_details(&1, platform))
  end

  defp find_release_asset(releases, version_tag, platform) do
    case Enum.find(releases, &(&1["tag_name"] == version_tag)) do
      nil -> {:error, :version_not_found, stable_release_tags(releases)}
      release -> release_asset_details_for_platform(release, platform)
    end
  end

  defp release_asset_details_for_platform(release, platform) do
    case find_asset_for_platform(release, platform) do
      {:ok, asset} -> release_asset_details(release, asset)
      :error -> {:error, :platform_not_supported, get_release_platforms(release)}
    end
  end

  defp latest_release_asset_details(release, platform) do
    case find_asset_for_platform(release, platform) do
      {:ok, asset} -> release_asset_details(release, asset)
      :error -> nil
    end
  end

  defp stable_release_tags(releases) do
    releases
    |> Enum.filter(&(&1["prerelease"] == false))
    |> Enum.map(& &1["tag_name"])
  end

  defp normalize_version_tag(version) do
    cond do
      String.starts_with?(version, "Maude") -> version
      String.starts_with?(version, "maude") -> "Maude" <> String.slice(version, 5..-1//1)
      String.match?(version, ~r/^\d/) -> "Maude#{version}"
      true -> version
    end
  end

  defp find_asset_for_platform(release, platform) do
    patterns = Map.get(platform_patterns(), platform, [])
    assets = release["assets"] || []

    Enum.find_value(assets, :error, fn asset ->
      name = asset["name"]

      if Enum.any?(patterns, &Regex.match?(&1, name)) do
        {:ok, asset}
      else
        nil
      end
    end)
  end

  defp has_platform_asset?(release, platform) do
    case find_asset_for_platform(release, platform) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp get_release_platforms(release) do
    assets = release["assets"] || []

    platform_patterns()
    |> Enum.filter(fn {_, patterns} -> platform_asset?(assets, patterns) end)
    |> Enum.map(fn {platform, _} -> platform end)
  end

  defp platform_asset?(assets, patterns) do
    Enum.any?(assets, fn asset ->
      Enum.any?(patterns, &Regex.match?(&1, asset["name"]))
    end)
  end

  defp get_all_platforms(releases) do
    releases
    |> Enum.flat_map(&get_release_platforms/1)
    |> Enum.uniq()
  end

  defp release_asset_details(release, asset) do
    case parse_sha256(asset["digest"]) do
      nil ->
        {:error, :missing_digest, release["tag_name"], asset["name"]}

      sha256 ->
        {:ok,
         %{
           url: asset["browser_download_url"],
           sha256: sha256,
           version: release["tag_name"]
         }}
    end
  end

  defp parse_sha256("sha256:" <> hash) do
    if String.match?(hash, ~r/\A[0-9a-fA-F]{64}\z/), do: String.downcase(hash)
  end

  defp parse_sha256(_), do: nil

  defp fetch_releases do
    url = String.to_charlist(@github_api)

    headers =
      [
        {~c"User-Agent", ~c"ExMaude-Installer"},
        {~c"Accept", ~c"application/vnd.github.v3+json"}
      ] ++ github_auth_header()

    http_opts = [
      ssl: ssl_opts(),
      timeout: @api_timeout,
      # Never forward an optional GitHub API token across redirects.
      autoredirect: false
    ]

    case :httpc.request(:get, {url, headers}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, {{_, 403, _}, _, _}} ->
        {:error, "GitHub API rate limit exceeded. Try again later."}

      {:ok, {{_, status, reason}, _, _}} ->
        {:error, "HTTP #{status} #{reason}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp github_auth_header do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        [{~c"Authorization", String.to_charlist("Bearer " <> token)}]

      _ ->
        []
    end
  end

  defp detect_platform do
    ExMaude.Binary.platform()
  end

  defp create_private_tmp_dir do
    suffix =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    path = Path.join(System.tmp_dir!(), "ex_maude-install-#{suffix}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp download_file(url, destination) do
    Mix.shell().info("Downloading from: #{url}")

    with :ok <- validate_https_url(url),
         :ok <- validate_download_path(destination) do
      case System.find_executable("curl") do
        nil -> download_with_mint(url, destination)
        curl -> download_with_curl(curl, url, destination)
      end
    end
  end

  defp validate_download_path(path) do
    expanded = Path.expand(path)
    tmp_dir = Path.expand(System.tmp_dir!())

    cond do
      String.contains?(path, ["../", "..\\"]) ->
        Mix.raise("Invalid path: contains directory traversal")

      not String.starts_with?(expanded, tmp_dir) ->
        Mix.raise("Invalid path: must be within temp directory")

      true ->
        :ok
    end
  end

  defp download_with_curl(curl, url, destination) do
    args = [
      "-fSL",
      "--proto",
      "=https",
      "--proto-redir",
      "=https",
      "--progress-bar",
      "--connect-timeout",
      "30",
      "--max-time",
      Integer.to_string(div(@download_timeout, 1000)),
      "--max-filesize",
      Integer.to_string(@max_download_size),
      "-o",
      destination,
      url
    ]

    case System.cmd(curl, args, stderr_to_stdout: true) do
      {_, 0} ->
        validate_downloaded_file(destination)

      {output, code} ->
        Mix.raise("""
        Failed to download Maude (curl exit code: #{code})

        #{String.trim(output)}

        URL: #{url}
        """)
    end
  end

  defp validate_downloaded_file(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_download_size ->
        File.rm(path)

        Mix.raise("""
        Downloaded file exceeds maximum size limit.

        Size: #{div(size, 1024 * 1024)} MB
        Limit: #{div(@max_download_size, 1024 * 1024)} MB
        """)

      {:ok, %{size: size}} ->
        size_kb = div(size, 1024)
        Mix.shell().info("Downloaded #{size_kb} KB")
        :ok

      {:error, reason} ->
        Mix.raise("Failed to verify downloaded file: #{inspect(reason)}")
    end
  end

  defp download_with_mint(url, destination, redirects_left \\ 5, deadline \\ nil)

  defp download_with_mint(_, _, 0, _) do
    Mix.raise("Failed to download Maude: too many redirects")
  end

  defp download_with_mint(url, destination, redirects_left, deadline) do
    deadline = deadline || System.monotonic_time(:millisecond) + @download_timeout
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case ExMaude.Download.fetch(url, destination,
           timeout: remaining,
           max_bytes: @max_download_size
         ) do
      :ok ->
        validate_downloaded_file(destination)

      {:redirect, location} ->
        location =
          url
          |> URI.merge(location)
          |> URI.to_string()

        :ok = validate_https_url(location)
        download_with_mint(location, destination, redirects_left - 1, deadline)

      {:error, reason} ->
        Mix.raise("Failed to download Maude: #{inspect(reason)}")
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp validate_https_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _ -> Mix.raise("Refusing non-HTTPS download URL: #{inspect(url)}")
    end
  end

  defp verify_checksum(path, expected_sha) do
    Mix.shell().info("Verifying checksum...")

    actual_sha =
      path
      |> File.stream!(2048)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual_sha == expected_sha do
      Mix.shell().info("✓ Checksum verified")
      :ok
    else
      File.rm(path)

      Mix.raise("""
      Checksum verification failed!

      Expected: #{expected_sha}
      Got:      #{actual_sha}

      The downloaded file may be corrupted or tampered with.
      Please try again or report this issue.
      """)
    end
  end

  @doc false
  @spec install_archive(Path.t(), Path.t(), String.t(), Path.t()) :: :ok
  def install_archive(zip_path, install_path, version, tmp_dir) do
    Mix.shell().info("Extracting...")
    extraction_path = Path.join(tmp_dir, "extracted")
    File.mkdir!(extraction_path)

    with :ok <- validate_archive(zip_path) do
      extract_with_erlang(zip_path, extraction_path)
      validate_extracted_tree!(extraction_path)
      rename_maude_binary(extraction_path, version)
      File.chmod!(Path.join(extraction_path, "maude"), 0o755)
      copy_release_tree!(extraction_path, install_path)
    end
  end

  @doc false
  @spec validate_archive(Path.t()) :: :ok
  def validate_archive(zip_path) do
    case :zip.list_dir(String.to_charlist(zip_path)) do
      {:ok, entries} ->
        files =
          Enum.flat_map(entries, fn
            {:zip_file, name, info, _, _, _} -> [{to_string(name), info}]
            _ -> []
          end)

        if files == [], do: Mix.raise("Archive contains no files")

        if length(files) > @max_archive_entries,
          do: Mix.raise("Archive contains too many entries")

        extracted_size =
          Enum.reduce(files, 0, fn {_, info}, total ->
            total + archive_entry_size(info)
          end)

        if extracted_size > @max_extracted_size do
          Mix.raise("Archive exceeds the maximum extracted size")
        end

        Enum.each(files, &validate_archive_entry!/1)
        :ok

      {:error, reason} ->
        Mix.raise("Failed to inspect archive: #{inspect(reason)}")
    end
  end

  defp archive_entry_size(info) when is_tuple(info) and tuple_size(info) > 1 do
    case elem(info, 1) do
      size when is_integer(size) and size >= 0 -> size
      _ -> Mix.raise("Archive contains invalid file metadata")
    end
  end

  defp archive_entry_size(_), do: Mix.raise("Archive contains invalid file metadata")

  defp validate_archive_entry!({name, info}) do
    normalized = String.replace(name, "\\", "/")
    components = String.split(normalized, "/", trim: true)
    type = if is_tuple(info) and tuple_size(info) > 2, do: elem(info, 2)

    cond do
      normalized == "" ->
        Mix.raise("Archive contains an empty path")

      Path.type(normalized) == :absolute or String.match?(normalized, ~r/\A[A-Za-z]:/) ->
        Mix.raise("Archive contains an absolute path: #{inspect(name)}")

      ".." in components ->
        Mix.raise("Archive contains directory traversal: #{inspect(name)}")

      type not in [:regular, :directory] ->
        Mix.raise("Archive contains unsupported file type #{inspect(type)}: #{inspect(name)}")

      true ->
        :ok
    end
  end

  defp extract_with_erlang(zip_path, extraction_path) do
    case :zip.unzip(String.to_charlist(zip_path), cwd: String.to_charlist(extraction_path)) do
      {:ok, files} ->
        Mix.shell().info("Extracted #{length(files)} files")
        :ok

      {:error, :einval} ->
        Mix.raise("""
        Failed to extract: Invalid or corrupted ZIP file.

        Try running with --force to re-download.
        """)

      {:error, reason} ->
        Mix.raise("Failed to extract archive: #{inspect(reason)}")
    end
  end

  defp validate_extracted_tree!(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(fn path ->
      case File.lstat!(path) do
        %{type: type} when type in [:regular, :directory] -> :ok
        %{type: type} -> Mix.raise("Extracted archive contains unsupported #{type}: #{path}")
      end
    end)
  end

  defp copy_release_tree!(source, destination) do
    File.mkdir_p!(destination)
    reject_destination_symlinks!(source, destination)

    source
    |> File.ls!()
    |> Enum.each(fn entry ->
      source_path = Path.join(source, entry)
      destination_path = Path.join(destination, entry)

      case File.cp_r(source_path, destination_path) do
        {:ok, _} -> :ok
        {:error, reason, path} -> Mix.raise("Failed to install #{path}: #{inspect(reason)}")
      end
    end)
  end

  defp reject_destination_symlinks!(source, destination) do
    source
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(fn source_path ->
      relative = Path.relative_to(source_path, source)
      destination_path = Path.join(destination, relative)

      case File.lstat(destination_path) do
        {:ok, %{type: :symlink}} ->
          Mix.raise("Refusing to overwrite destination symlink: #{destination_path}")

        _ ->
          :ok
      end
    end)
  end

  defp rename_maude_binary(install_path, version) do
    target = Path.join(install_path, "maude")
    found = File.regular?(target) or rename_known_maude_binary(install_path, target, version)

    unless found do
      raise_missing_maude_binary(install_path)
    end
  end

  defp maude_binary_names(version) do
    [
      # 3.5+ naming
      "maude.darwin64",
      "maude.linux64",
      "maude.arm64",
      # Older naming
      "maude-Yices2",
      "Maude",
      # Version-specific
      "maude-#{version}",
      "Maude-#{version}"
    ]
  end

  defp rename_known_maude_binary(install_path, target, version) do
    Enum.find_value(maude_binary_names(version), false, fn name ->
      rename_maude_candidate(install_path, target, name)
    end)
  end

  defp rename_maude_candidate(install_path, target, name) do
    source = Path.join(install_path, name)

    if File.regular?(source) do
      File.rm(target)
      File.rename!(source, target)
      true
    else
      false
    end
  end

  @spec raise_missing_maude_binary(Path.t()) :: no_return()
  defp raise_missing_maude_binary(install_path) do
    files =
      install_path
      |> File.ls!()
      |> Enum.reject(&File.dir?(Path.join(install_path, &1)))

    Mix.raise("""
    Could not find a recognized Maude binary in the archive.
    Extracted files: #{inspect(files)}
    """)
  end

  defp verify_installation(maude_binary) do
    Mix.shell().info("Verifying installation...")

    verify_commands = [["--version"], ["--help"]]

    result =
      Enum.find_value(verify_commands, fn args ->
        verify_command(maude_binary, args)
      end)

    case result do
      {:ok, output} ->
        version_line =
          output
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, "Maude"))
          |> case do
            nil -> "Maude"
            line -> String.trim(line)
          end

        Mix.shell().info("✓ Verified: #{version_line}")

        Mix.shell().info("""

        Add to your config/config.exs:

            config :ex_maude,
              maude_path: "#{maude_binary}"

        Or set MAUDE_PATH environment variable.
        """)

      nil ->
        Mix.shell().error("""
        Warning: Maude verification failed.

        The binary may still work. Common issues:

        macOS: You may need to allow the binary in System Preferences > Security & Privacy
               Run: xattr -d com.apple.quarantine #{maude_binary}

        Linux: You may need to install additional libraries:
          Ubuntu/Debian: sudo apt-get install libgmp10 libncurses5
          Fedora/RHEL:   sudo dnf install gmp ncurses-compat-libs
        """)
    end
  end

  defp verify_command(maude_binary, args) do
    case ExMaude.Subprocess.run(maude_binary, args, 5_000, 64 * 1024) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, output, _} -> maude_banner(output)
      {:error, _} -> nil
    end
  end

  defp maude_banner(output) do
    if String.contains?(output, "Maude"), do: {:ok, output}
  end

  # Platform patterns for matching asset names across different release naming conventions.
  # Defined as a function to avoid compile-time serialization issues with Regex structs.
  defp platform_patterns do
    %{
      "darwin-arm64" => [
        ~r/macos-arm64\.zip$/i,
        ~r/macos-arm\.zip$/i,
        ~r/darwin-arm64\.zip$/i,
        ~r/darwin64-arm\.zip$/i
      ],
      "darwin-x64" => [
        ~r/macos-x86_64\.zip$/i,
        ~r/macos\.zip$/i,
        ~r/darwin-x86_64\.zip$/i,
        ~r/darwin64\.zip$/i
      ],
      "linux-x64" => [
        ~r/linux-x86_64\.zip$/i,
        ~r/linux\.zip$/i,
        ~r/linux64\.zip$/i
      ]
    }
  end
end
