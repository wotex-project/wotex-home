defmodule Woh.Tool.MacosAppInventory do
  @moduledoc false

  import Bitwise

  alias Woh.Tool.{Command, Hash, Json, ReleaseInventory}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @report "Contents/Resources/app-inventory.json"
  @release "Contents/Resources/WotexHomeRelease"
  @required [
    "Contents/Info.plist",
    "Contents/Resources/app.spdx.json",
    "Contents/MacOS/WotexHome",
    "Contents/MacOS/WotexHomeAgent",
    "Contents/Library/LaunchAgents/org.wotex.home.agent.plist",
    "#{@release}/release-inventory.json",
    "#{@release}/release-components.json",
    "#{@release}/release.spdx.json",
    "#{@release}/bin/wotex_home"
  ]
  @executables [
    "Contents/MacOS/WotexHome",
    "Contents/MacOS/WotexHomeAgent",
    "#{@release}/bin/wotex_home"
  ]
  @max_files 20_000
  @max_bytes 2_147_483_648
  @max_report_bytes 5_000_000

  def report_name, do: @report
  def release_path, do: @release

  def entries(app) do
    app = Path.expand(app)
    require_directory!(app)
    {_count, _bytes, entries} = scan!(app, app, {0, 0, []})
    {:ok, Enum.sort_by(entries, & &1["path"])}
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "cannot inspect app: #{Exception.message(error)}"}
  end

  def checked_contents(app, revision) do
    app = Path.expand(app)

    with {:ok, files} <- entries(app) do
      paths = MapSet.new(files, & &1["path"])
      ensure!(MapSet.subset?(MapSet.new(@required), paths), "app is missing required payload")
      by_path = Map.new(files, &{&1["path"], &1})

      for executable <- @executables do
        ensure!(
          (by_path[executable]["mode"] &&& 0o111) != 0,
          "app executable has no execute permission: #{executable}"
        )
      end

      info = Path.join(app, "Contents/Info.plist")

      ensure!(
        plist_value!(info, "WotexHomeSourceRevision") == revision and
          plist_value!(info, "CFBundleIdentifier") == "org.wotex.home",
        "app source revision differs from inventory"
      )

      agent = Path.join(app, "Contents/Library/LaunchAgents/org.wotex.home.agent.plist")

      ensure!(
        plist_value!(agent, "BundleProgram") == "Contents/MacOS/WotexHomeAgent",
        "agent plist points outside the bundled helper"
      )

      release = Path.join(app, @release)

      with {:ok, embedded} <-
             Json.read(Path.join(release, ReleaseInventory.manifest()), @max_report_bytes),
           true <- is_map(embedded) and embedded["source_revision"] == revision,
           {:ok, _} <- ReleaseInventory.verify(release) do
        {:ok, %{"schema_version" => 1, "source_revision" => revision, "files" => files}}
      else
        false -> {:error, "embedded release revision differs from app"}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    error in Error -> {:error, error.message}
  end

  def create(app, revision) do
    with {:ok, report} <- checked_contents(app, revision) do
      destination = Path.join(app, @report)
      temporary = destination <> ".tmp"

      try do
        File.write!(temporary, ReleaseInventory.canonical_json(report["files"], revision), [
          :exclusive
        ])

        File.rename!(temporary, destination)
        {:ok, length(report["files"])}
      rescue
        error in File.Error -> {:error, "cannot write app inventory: #{Exception.message(error)}"}
      after
        File.rm(temporary)
      end
    end
  end

  def verify(app) do
    destination = Path.join(app, @report)

    with {:ok, saved} <- Json.read(destination, @max_report_bytes),
         true <- valid_report?(saved),
         {:ok, expected} <- checked_contents(app, saved["source_revision"]),
         true <- saved == expected do
      {:ok, length(saved["files"])}
    else
      false -> {:error, "invalid app inventory or app differs from inventory"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan!(directory, root, state) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(state, fn name, {count, bytes, entries} = state ->
      path = Path.join(directory, name)
      relative = Path.relative_to(path, root)
      info = File.lstat!(path)

      case info.type do
        :directory ->
          scan!(path, root, state)

        :regular when relative == @report ->
          state

        :regular ->
          count = count + 1
          bytes = bytes + info.size
          ensure!(count <= @max_files and bytes <= @max_bytes, "app inventory limit exceeded")

          entry = %{
            "path" => relative,
            "size" => info.size,
            "mode" => info.mode &&& 0o777,
            "sha256" => Hash.sha256(path)
          }

          {count, bytes, [entry | entries]}

        :symlink ->
          fail!("symlink in app: #{relative}")

        _ ->
          fail!("nonregular app entry: #{relative}")
      end
    end)
  end

  defp plist_value!(plist, key) do
    case Command.run("plutil", ["-extract", key, "raw", "-o", "-", plist], 4_096, 10_000) do
      {:ok, value} -> String.trim(value)
      {:error, _} -> fail!("invalid plist value: #{key}")
    end
  end

  defp valid_report?(saved) do
    is_map(saved) and
      MapSet.new(Map.keys(saved)) == MapSet.new(~w(schema_version source_revision files)) and
      saved["schema_version"] == 1 and is_binary(saved["source_revision"]) and
      Regex.match?(~r/\A[0-9a-f]{40}\z/, saved["source_revision"])
  end

  defp require_directory!(path) do
    ensure!(
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)),
      "app must be a real directory"
    )
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: fail!(message)
  defp fail!(message), do: raise(Error, message)
end

defmodule Mix.Tasks.Woh.Macos.App.Inventory do
  @moduledoc """
  Creates or verifies the unsigned macOS app file inventory.

  Run `mix woh.macos.app.inventory create APP_BUNDLE` after the embedded release
  inventory and outer SPDX document are complete. The report binds every
  regular outer bundle file to the committed source revision and checks the
  helper, agent plist, embedded release and executable modes. `verify` detects
  missing, changed, extra or linked files. The report is an integrity input;
  signing and installed-host checks remain separate.
  """

  @shortdoc "Create or verify macOS app inventory"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(["create", app]) do
    with {:ok, revision} <- Woh.Tool.ReleaseInventory.source_revision(File.cwd!()),
         {:ok, count} <- Woh.Tool.MacosAppInventory.create(app, revision) do
      Mix.shell().info("inventoried #{count} macOS app files at #{revision}")
    else
      {:error, reason} -> Mix.raise("macOS app inventory error: #{reason}")
    end
  end

  def run(["verify", app]) do
    case Woh.Tool.MacosAppInventory.verify(app) do
      {:ok, count} -> Mix.shell().info("verified #{count} macOS app files")
      {:error, reason} -> Mix.raise("macOS app inventory error: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.macos.app.inventory create|verify APP_BUNDLE")
end
