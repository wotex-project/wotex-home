defmodule Woh.Tool.MacosAppSpdx do
  @moduledoc false

  import Bitwise

  alias Woh.Tool.{Command, Json, MacosAppInventory, ReleaseInventory, ReleaseSpdx}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @report "Contents/Resources/app.spdx.json"
  @embedded "Contents/Resources/WotexHomeRelease"
  @release_reports ~w(release-components.json release.spdx.json release-inventory.json)
  @native %{
    "Contents/MacOS/WotexHome" => "macos-ui",
    "Contents/Library/LoginItems/WotexHomeAgent.app/Contents/MacOS/WotexHomeAgent" =>
      "macos-agent",
    "Contents/Library/LoginItems/WotexHomeAgent.app/Contents/Info.plist" => "macos-agent",
    "Contents/Library/LaunchAgents/org.wotex.home.agent.plist" => "macos-agent",
    "Contents/Info.plist" => "app-wrapper"
  }
  @max_report_bytes 10_000_000

  def report_name, do: @report

  def document(app, created) do
    ensure!(valid_created?(created), "invalid SPDX creation timestamp")

    with {:ok, all_files} <- MacosAppInventory.entries(app) do
      inventory = Enum.reject(all_files, &(&1["path"] == @report))
      files_by_path = Map.new(inventory, &{&1["path"], &1})
      {revision, embedded_assignments} = embedded_packages!(app, files_by_path)
      info = Path.join(app, "Contents/Info.plist")

      ensure!(
        plist_value!(info, "WotexHomeSourceRevision") == revision,
        "app and release revisions differ"
      )

      assignments =
        Enum.reduce(Map.keys(files_by_path), embedded_assignments, fn path, assignments ->
          cond do
            Map.has_key?(assignments, path) ->
              assignments

            Map.has_key?(@native, path) ->
              Map.put(assignments, path, Map.fetch!(@native, path))

            String.starts_with?(path, @embedded <> "/") and
                String.replace_prefix(path, @embedded <> "/", "") in @release_reports ->
              Map.put(assignments, path, "embedded-release-reports")

            true ->
              fail!("unmapped app file: #{path}")
          end
        end)

      {files, links, members} =
        inventory
        |> Enum.with_index(1)
        |> Enum.reduce({[], [], %{}}, fn {entry, number}, {files, links, members} ->
          path = entry["path"]
          file_id = "SPDXRef-AppFile-#{number}"
          package = Map.fetch!(assignments, path)

          file = %{
            "SPDXID" => file_id,
            "fileName" => "./#{path}",
            "checksums" => [%{"algorithm" => "SHA256", "checksumValue" => entry["sha256"]}],
            "licenseConcluded" => "NOASSERTION",
            "licenseInfoInFiles" => ["NOASSERTION"],
            "copyrightText" => "NOASSERTION"
          }

          relation = %{
            "spdxElementId" => ReleaseSpdx.package_id(package),
            "relationshipType" => "CONTAINS",
            "relatedSpdxElement" => file_id
          }

          members = Map.update(members, package, [file_id], &[file_id | &1])
          {[file | files], [relation | links], members}
        end)

      files = Enum.reverse(files)
      links = Enum.reverse(links)

      {packages, describes} =
        members
        |> Enum.sort_by(fn {name, _} -> name end)
        |> Enum.map(fn {name, ids} ->
          package_id = ReleaseSpdx.package_id(name)

          package = %{
            "SPDXID" => package_id,
            "name" => name,
            "downloadLocation" => "NOASSERTION",
            "filesAnalyzed" => true,
            "hasFiles" => Enum.reverse(ids),
            "licenseConcluded" => "NOASSERTION",
            "licenseDeclared" => "NOASSERTION",
            "licenseInfoFromFiles" => ["NOASSERTION"],
            "copyrightText" => "NOASSERTION"
          }

          relation = %{
            "spdxElementId" => "SPDXRef-DOCUMENT",
            "relationshipType" => "DESCRIBES",
            "relatedSpdxElement" => package_id
          }

          {package, relation}
        end)
        |> Enum.unzip()

      {:ok,
       %{
         "spdxVersion" => "SPDX-2.3",
         "dataLicense" => "CC0-1.0",
         "SPDXID" => "SPDXRef-DOCUMENT",
         "name" => "WoTEx Home macOS app #{String.slice(revision, 0, 12)}",
         "documentNamespace" => namespace(revision, inventory),
         "creationInfo" => %{
           "created" => created,
           "creators" => ["Tool: wotex-home-macos-spdx-1"]
         },
         "comment" => "Unsigned app file inventory. All license conclusions are NOASSERTION.",
         "documentDescribes" => Enum.map(packages, & &1["SPDXID"]),
         "packages" => packages,
         "files" => files,
         "relationships" => links ++ describes
       }}
    end
  rescue
    error in Error ->
      {:error, error.message}

    error in [KeyError, BadMapError, ArgumentError] ->
      {:error, "invalid embedded release reports: #{Exception.message(error)}"}
  end

  def create(app) do
    with {:ok, document} <-
           document(
             app,
             DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           ) do
      destination = Path.join(app, @report)
      temporary = destination <> ".tmp"

      try do
        File.write!(temporary, JSON.encode!(document) <> "\n", [:exclusive])
        File.rename!(temporary, destination)
        {:ok, length(document["files"])}
      rescue
        error in File.Error ->
          {:error, "cannot write app SPDX document: #{Exception.message(error)}"}
      after
        File.rm(temporary)
      end
    end
  end

  def verify(app) do
    with {:ok, saved} <- Json.read(Path.join(app, @report), @max_report_bytes),
         {:ok, created} <- creation_time(saved),
         {:ok, expected} <- document(app, created),
         true <- saved == expected do
      {:ok, length(saved["files"])}
    else
      false -> {:error, "app differs from SPDX document"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp embedded_packages!(app, files_by_path) do
    release = Path.join(app, @embedded)
    {:ok, inventory} = read_embedded!(Path.join(release, "release-inventory.json"))
    {:ok, document} = read_embedded!(Path.join(release, "release.spdx.json"))
    revision = inventory["source_revision"]

    ensure!(
      is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{40}\z/, revision) and
        document["spdxVersion"] == "SPDX-2.3",
      "invalid embedded release identity"
    )

    ensure!(
      match?({:ok, _}, ReleaseInventory.verify(release)),
      "embedded release inventory differs"
    )

    spdx_files =
      Enum.reduce(document["files"], %{}, fn item, files ->
        spdx_id = item["SPDXID"]
        name = item["fileName"]
        checksums = item["checksums"]

        ensure!(
          is_binary(name) and String.starts_with?(name, "./") and is_list(checksums) and
            length(checksums) == 1 and hd(checksums)["algorithm"] == "SHA256",
          "invalid embedded SPDX file"
        )

        path = @embedded <> "/" <> String.replace_prefix(name, "./", "")

        ensure!(
          not Map.has_key?(files, spdx_id) and Map.has_key?(files_by_path, path) and
            hd(checksums)["checksumValue"] == files_by_path[path]["sha256"],
          "embedded SPDX differs from app payload"
        )

        Map.put(files, spdx_id, path)
      end)

    {assignments, _names} =
      Enum.reduce(document["packages"], {%{}, MapSet.new()}, fn package, {assignments, names} ->
        name = package["name"]

        ensure!(
          is_binary(name) and name != "" and not MapSet.member?(names, name) and
            package["licenseConcluded"] == "NOASSERTION",
          "invalid embedded SPDX package"
        )

        assignments =
          Enum.reduce(package["hasFiles"], assignments, fn id, assignments ->
            path = Map.get(spdx_files, id)

            ensure!(
              is_binary(path) and not Map.has_key?(assignments, path),
              "embedded SPDX package coverage is invalid"
            )

            Map.put(assignments, path, "embedded-#{name}")
          end)

        {assignments, MapSet.put(names, name)}
      end)

    payload_paths =
      files_by_path
      |> Map.keys()
      |> Enum.filter(fn path ->
        String.starts_with?(path, @embedded <> "/") and
          String.replace_prefix(path, @embedded <> "/", "") not in @release_reports
      end)
      |> MapSet.new()

    ensure!(
      MapSet.new(Map.keys(assignments)) == payload_paths,
      "embedded SPDX does not cover release payload"
    )

    {revision, assignments}
  end

  defp read_embedded!(path) do
    case Json.read(path, @max_report_bytes) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> fail!("invalid embedded release reports")
    end
  end

  defp plist_value!(plist, key) do
    case Command.run("plutil", ["-extract", key, "raw", "-o", "-", plist], 4_096, 10_000) do
      {:ok, value} -> String.trim(value)
      {:error, _} -> fail!("invalid app Info.plist")
    end
  end

  defp namespace(revision, inventory) do
    pairs =
      Enum.map_join(inventory, ",", fn item ->
        "[#{JSON.encode!(item["path"])},#{JSON.encode!(item["sha256"])}]"
      end)

    digest = :crypto.hash(:sha256, revision <> "[" <> pairs <> "]")
    <<prefix::binary-size(6), version, middle, variant, rest::binary-size(7), _::binary>> = digest

    bytes =
      <<prefix::binary, (version &&& 0x0F) ||| 0x50, middle, (variant &&& 0x3F) ||| 0x80,
        rest::binary>>

    hex = Base.encode16(bytes, case: :lower)

    "urn:uuid:#{binary_part(hex, 0, 8)}-#{binary_part(hex, 8, 4)}-" <>
      "#{binary_part(hex, 12, 4)}-#{binary_part(hex, 16, 4)}-#{binary_part(hex, 20, 12)}"
  end

  defp creation_time(%{"creationInfo" => %{"created" => created}}) when is_binary(created),
    do: {:ok, created}

  defp creation_time(_), do: {:error, "invalid app SPDX creation info"}

  defp valid_created?(created),
    do: is_binary(created) and Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, created)

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: fail!(message)
  defp fail!(message), do: raise(Error, message)
end

defmodule Mix.Tasks.Woh.Macos.App.Spdx do
  @moduledoc """
  Creates or verifies the file-level SPDX document for a macOS app bundle.

  Run `mix woh.macos.app.spdx create APP_BUNDLE` after copying an inventoried
  OTP release into the app and before creating the outer app inventory. The
  task checks the embedded release SPDX coverage and maps native UI, helper,
  agent and wrapper files. Every license conclusion remains `NOASSERTION`;
  signing, transitive native loads and license review need separate evidence.
  """

  @shortdoc "Create or verify macOS app SPDX document"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([action, app]) when action in ~w(create verify) do
    case apply(Woh.Tool.MacosAppSpdx, String.to_existing_atom(action), [app]) do
      {:ok, count} ->
        verb = if action == "create", do: "created", else: "verified"
        Mix.shell().info("#{verb} macOS SPDX document for #{count} app files")

      {:error, reason} ->
        Mix.raise("macOS SPDX error: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.macos.app.spdx create|verify APP_BUNDLE")
end
