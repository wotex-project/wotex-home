defmodule Woh.Tool.ReleaseSpdx do
  @moduledoc false

  import Bitwise

  alias Woh.Tool.{Json, ReleaseComponents}

  @report "release.spdx.json"
  @max_report_bytes 10_000_000

  def report_name, do: @report

  def package_id(name) do
    clean = Regex.replace(~r/[^A-Za-z0-9.-]/, name, "-")
    suffix = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    "SPDXRef-Package-#{clean}-#{suffix}"
  end

  def document(root, components, created) do
    with true <- valid_created?(created),
         {:ok, groups} <- ReleaseComponents.packaged_components(root),
         true <-
           MapSet.new(Map.keys(groups)) ==
             MapSet.new(Enum.map(components["components"], & &1["name"])) do
      {packages, files, relationships, count} =
        Enum.reduce(components["components"], {[], [], [], 0}, fn component,
                                                                  {packages, files, relationships,
                                                                   count} ->
          name = component["name"]
          group = Map.fetch!(groups, name)
          package_spdx_id = package_id(name)
          version = package_version(name)

          {package_files, new_files, new_relationships, count} =
            group.files
            |> Enum.sort()
            |> Enum.reduce({[], [], [], count}, fn {path, checksum},
                                                   {ids, items, links, number} ->
              number = number + 1
              file_id = "SPDXRef-File-#{number}"

              file = %{
                "SPDXID" => file_id,
                "fileName" => "./#{path}",
                "checksums" => [%{"algorithm" => "SHA256", "checksumValue" => checksum}],
                "licenseConcluded" => "NOASSERTION",
                "licenseInfoInFiles" => ["NOASSERTION"],
                "copyrightText" => "NOASSERTION"
              }

              relation = %{
                "spdxElementId" => package_spdx_id,
                "relationshipType" => "CONTAINS",
                "relatedSpdxElement" => file_id
              }

              {[file_id | ids], [file | items], [relation | links], number}
            end)

          package = %{
            "SPDXID" => package_spdx_id,
            "name" => name,
            "versionInfo" => version,
            "downloadLocation" => "NOASSERTION",
            "filesAnalyzed" => true,
            "hasFiles" => Enum.reverse(package_files),
            "licenseConcluded" => "NOASSERTION",
            "licenseDeclared" => "NOASSERTION",
            "licenseInfoFromFiles" => ["NOASSERTION"],
            "copyrightText" => "NOASSERTION",
            "comment" =>
              "License review unresolved; local input status: #{component["license_input_status"]}"
          }

          describes = %{
            "spdxElementId" => "SPDXRef-DOCUMENT",
            "relationshipType" => "DESCRIBES",
            "relatedSpdxElement" => package_spdx_id
          }

          {
            [package | packages],
            new_files ++ files,
            [describes | new_relationships ++ relationships],
            count
          }
        end)

      packages = Enum.reverse(packages)
      files = Enum.reverse(files)
      relationships = Enum.reverse(relationships)

      if count == components["file_count"] do
        {:ok,
         %{
           "spdxVersion" => "SPDX-2.3",
           "dataLicense" => "CC0-1.0",
           "SPDXID" => "SPDXRef-DOCUMENT",
           "name" => "WoTEx Home release #{String.slice(components["source_revision"], 0, 12)}",
           "documentNamespace" => namespace(components["source_revision"], files),
           "creationInfo" => %{
             "created" => created,
             "creators" => ["Tool: wotex-home-release-spdx-1"]
           },
           "comment" =>
             "Packaged regular payload files are enumerated. Generated reports are excluded " <>
               "and covered by release-inventory.json. All license conclusions are NOASSERTION.",
           "documentDescribes" => Enum.map(packages, & &1["SPDXID"]),
           "packages" => packages,
           "files" => files,
           "relationships" => relationships
         }}
      else
        {:error, "component report file count differs from release"}
      end
    else
      false -> {:error, "invalid SPDX creation timestamp or component coverage"}
      {:error, reason} -> {:error, reason}
    end
  end

  def create(root, source) do
    with {:ok, components} <- checked_components(root, source, true),
         {:ok, document} <-
           document(
             root,
             components,
             DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           ) do
      destination = Path.join(root, @report)
      temporary = destination <> ".tmp"

      try do
        File.write!(temporary, JSON.encode!(document) <> "\n", [:exclusive])
        File.rename!(temporary, destination)
        {:ok, length(document["files"])}
      rescue
        error in File.Error -> {:error, "cannot write SPDX document: #{Exception.message(error)}"}
      after
        File.rm(temporary)
      end
    end
  end

  def verify(root, source) do
    with {:ok, components} <- checked_components(root, source, false),
         {:ok, saved} <- Json.read(Path.join(root, @report), @max_report_bytes),
         {:ok, created} <- creation_time(saved),
         {:ok, expected} <- document(root, components, created),
         true <- saved == expected do
      {:ok, length(saved["files"])}
    else
      false -> {:error, "release payload differs from SPDX document"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checked_components(root, source, clean?) do
    with {:ok, revision} <- ReleaseComponents.source_revision(source, clean?),
         {:ok, components} <- ReleaseComponents.verify(root, source, revision) do
      {:ok, components}
    else
      {:error, reason} ->
        {:error, "component report must be created and verified first: #{reason}"}
    end
  end

  defp creation_time(%{"creationInfo" => %{"created" => created}}) when is_binary(created),
    do: {:ok, created}

  defp creation_time(_), do: {:error, "invalid SPDX document creation info"}

  defp package_version(name) do
    case Regex.run(~r/\A(.+)-([0-9][A-Za-z0-9.+-]*)\z/, name) do
      [_, _, version] -> version
      _ -> "NOASSERTION"
    end
  end

  defp valid_created?(created),
    do: is_binary(created) and Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, created)

  defp namespace(revision, files) do
    pairs =
      Enum.map_join(files, ",", fn file ->
        checksum = hd(file["checksums"])["checksumValue"]

        "[#{JSON.encode!(file["fileName"])}," <>
          "[{\"algorithm\":\"SHA256\",\"checksumValue\":#{JSON.encode!(checksum)}}]]"
      end)

    digest = :crypto.hash(:sha256, revision <> "[" <> pairs <> "]")

    <<prefix::binary-size(6), version, middle, variant, rest::binary-size(7), _::binary>> =
      digest

    bytes =
      <<prefix::binary, (version &&& 0x0F) ||| 0x50, middle, (variant &&& 0x3F) ||| 0x80,
        rest::binary>>

    hex = Base.encode16(bytes, case: :lower)

    "urn:uuid:#{binary_part(hex, 0, 8)}-#{binary_part(hex, 8, 4)}-" <>
      "#{binary_part(hex, 12, 4)}-#{binary_part(hex, 16, 4)}-#{binary_part(hex, 20, 12)}"
  end
end

defmodule Mix.Tasks.Woh.Release.Spdx do
  @moduledoc """
  Creates or verifies a file-level SPDX 2.3 document for an OTP release.

  Run `mix woh.release.spdx create RELEASE_ROOT` after creating the component
  report, then create the final release inventory. `verify` checks the current
  payload against the saved document. Every license conclusion remains
  `NOASSERTION`; the document records file and package relationships without
  claiming license clearance or source correspondence.
  """

  @shortdoc "Create or verify release SPDX document"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([action, root]) when action in ~w(create verify) do
    case apply(Woh.Tool.ReleaseSpdx, String.to_existing_atom(action), [root, File.cwd!()]) do
      {:ok, count} ->
        verb = if action == "create", do: "created", else: "verified"
        Mix.shell().info("#{verb} SPDX 2.3 document for #{count} payload files")

      {:error, reason} ->
        Mix.raise("release SPDX error: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.release.spdx create|verify RELEASE_ROOT")
end
