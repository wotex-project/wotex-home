defmodule Woh.Tool.ReleaseComponents do
  @moduledoc false

  alias Woh.Tool.{Hash, Json, ReleaseInventory}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @report "release-components.json"
  @excluded ~w(release-components.json release-inventory.json release.spdx.json)
  @otp_components ~w(asn1-5.4.3 compiler-9.0.6.2 crypto-5.8.3.3 erts-16.4.0.6 inets-9.6.2.3 kernel-10.6.3.4 public_key-1.20.3.4 sasl-4.3.2 ssl-11.6.0.5 stdlib-7.3.0.2)
  @elixir_components ~w(elixir-1.19.6 iex-1.19.6 logger-1.19.6)
  @otp_license {"docs/provenance/license-inputs/otp-28.5.0.6-LICENSE.txt",
                "809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0"}
  @elixir_license {"docs/provenance/license-inputs/elixir-1.19.6-LICENSE",
                   "a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9"}
  @maude_license {"docs/provenance/license-inputs/maude-3.5.1-COPYING",
                  "32b1062f7da84967e7019d01ab805935caa7ab7321a7ced0e30ebe75e5df1670"}
  @maude_notice {"vendor/ex_maude/THIRD_PARTY_NOTICES.md",
                 "d7fcaf878bbae2f4539aa721a61d9d5f82b39c3109a6be440db3d1095c296f98"}
  @apache_license {"docs/provenance/license-inputs/apache-2.0-LICENSE.txt",
                   "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"}
  @package_notices %{
    "db_connection-2.10.2" => %{
      "README.md" => "457f9fa82cc8f0df65a7e294d5d9f04e487b265ecb5e592309601f72f637f707",
      "hex_metadata.config" => "e4b67e7e2e28998a24fded745ebbc9dfebc051a532f4b597fca581039535fced"
    },
    "rustler_precompiled-0.9.0" => %{
      "README.md" => "4eb98404fd972d657361ca4a3e3f7caf155ae0f90dcbbb64bc7a58640622e76e",
      "hex_metadata.config" => "2dd54885675a4ace0e1125e5d2d459c8261873d89917ba200194bbbfb12c14a2"
    }
  }

  def report_name, do: @report
  def excluded_reports, do: Enum.sort(@excluded)

  def component_for("bin/wotex_home_cli"), do: "home-cli"

  def component_for(relative) do
    case Path.split(relative) do
      ["lib", app, "priv", "maude", "bin" | _] when is_binary(app) ->
        if String.starts_with?(app, "ex_maude-"), do: "maude-bundled", else: app

      ["lib", app, "priv", "maude", legal]
      when legal in ["COPYING", "THIRD_PARTY_NOTICES.md"] ->
        if String.starts_with?(app, "ex_maude-"), do: "maude-bundled", else: app

      ["lib", app | _] ->
        app

      [first | _] ->
        if String.starts_with?(first, "erts-"), do: first, else: "release-wrapper"

      [] ->
        "release-wrapper"
    end
  end

  def packaged_components(root) do
    with {:ok, entries} <- ReleaseInventory.entries(root, @excluded) do
      groups =
        Enum.reduce(entries, %{}, fn entry, groups ->
          name = component_for(entry["path"])

          Map.update(
            groups,
            name,
            %{files: [{entry["path"], entry["sha256"]}], bytes: entry["size"]},
            fn group ->
              %{
                group
                | files: [{entry["path"], entry["sha256"]} | group.files],
                  bytes: group.bytes + entry["size"]
              }
            end
          )
        end)

      {:ok, groups}
    end
  end

  def license_inputs(source, component) do
    source = Path.expand(source)
    name = package_name(component)

    inputs =
      cond do
        Map.has_key?(@package_notices, component) ->
          package_notice_inputs!(source, component, name)

        component in @otp_components ->
          pinned_family_inputs!(source, [{"otp", @otp_license}])

        component in @elixir_components ->
          pinned_family_inputs!(source, [{"elixir", @elixir_license}])

        component == "release-wrapper" ->
          pinned_family_inputs!(source, [{"otp", @otp_license}, {"elixir", @elixir_license}])

        name == "maude-bundled" ->
          optional_pinned_inputs!(source, [
            {"Maude license input", @maude_license},
            {"Maude notice", @maude_notice}
          ])

        name == "ex_maude" ->
          ordinary_inputs(
            source,
            ~w(vendor/ex_maude/LICENSE vendor/ex_maude/THIRD_PARTY_NOTICES.md)
          )

        name == "wotex_home" or component == "home-cli" ->
          ordinary_inputs(source, ["LICENSE"])

        File.dir?(Path.join([source, "deps", name])) ->
          package_license_inputs(source, name)

        true ->
          []
      end

    {:ok, inputs}
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "cannot inspect license input: #{Exception.message(error)}"}
  end

  def report(root, source, revision) do
    with {:ok, groups} <- packaged_components(root) do
      components =
        groups
        |> Enum.sort_by(fn {name, _} -> name end)
        |> Enum.reduce_while([], fn {name, group}, components ->
          files = Enum.sort(group.files)

          fingerprint =
            files
            |> Enum.map(fn {path, hash} -> [path, hash] end)
            |> JSON.encode!()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          case license_inputs(source, name) do
            {:ok, inputs} ->
              component = %{
                "name" => name,
                "file_count" => length(files),
                "bytes" => group.bytes,
                "files_sha256" => fingerprint,
                "license_inputs" => inputs,
                "license_input_status" => input_status(name, inputs)
              }

              {:cont, [component | components]}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case components do
        {:error, reason} ->
          {:error, reason}

        components ->
          components = Enum.reverse(components)

          {:ok,
           %{
             "schema_version" => 2,
             "source_revision" => revision,
             "scope" => "packaged_regular_files_and_local_license_inputs",
             "license_review" => "unresolved",
             "excluded_reports" => excluded_reports(),
             "file_count" => Enum.reduce(components, 0, &(&1["file_count"] + &2)),
             "components" => components
           }}
      end
    end
  end

  def create(root, source, revision) do
    with {:ok, expected} <- report(root, source, revision) do
      destination = Path.join(root, @report)
      temporary = destination <> ".tmp"

      try do
        File.write!(temporary, JSON.encode!(expected) <> "\n", [:exclusive])
        File.rename!(temporary, destination)
        {:ok, expected}
      rescue
        error in File.Error ->
          {:error, "cannot write component report: #{Exception.message(error)}"}
      after
        File.rm(temporary)
      end
    end
  end

  def verify(root, source, revision) do
    with {:ok, expected} <- report(root, source, revision),
         {:ok, actual} <- Json.read(Path.join(root, @report), 2_000_000),
         true <- actual == expected do
      {:ok, expected}
    else
      false -> {:error, "release components or license inputs differ from report"}
      {:error, reason} -> {:error, reason}
    end
  end

  def source_revision(source, clean?) do
    with :ok <- maybe_clean(source, clean?),
         {revision, 0} <-
           System.cmd("git", ["rev-parse", "HEAD"], cd: source, stderr_to_stdout: true),
         revision = String.trim(revision),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, revision) do
      {:ok, revision}
    else
      false -> {:error, "invalid source revision"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "cannot read source revision"}
    end
  end

  defp maybe_clean(_source, false), do: :ok

  defp maybe_clean(source, true) do
    case System.cmd("git", ["status", "--porcelain", "--untracked-files=normal"],
           cd: source,
           stderr_to_stdout: true
         ) do
      {"", 0} -> :ok
      {_, 0} -> {:error, "source tree is dirty; commit before creating a component report"}
      _ -> {:error, "cannot inspect source tree"}
    end
  end

  defp package_name(component) do
    case Regex.run(~r/\A(.+)-([0-9][A-Za-z0-9.+-]*)\z/, component) do
      [_, name, _] -> name
      _ -> component
    end
  end

  defp package_notice_inputs!(source, component, name) do
    notices =
      @package_notices
      |> Map.fetch!(component)
      |> Enum.sort()
      |> Enum.reduce_while([], fn {filename, expected}, inputs ->
        relative = Path.join(["deps", name, filename])
        path = Path.join(source, relative)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            ensure!(
              Hash.sha256(path) == expected,
              "pinned #{component} notice input differs: #{filename}"
            )

            {:cont, [input(relative, expected) | inputs]}

          _ ->
            {:halt, :missing}
        end
      end)

    case notices do
      :missing ->
        []

      notices ->
        Enum.reverse(notices) ++
          optional_pinned_inputs!(source, [{"Apache license input", @apache_license}])
    end
  end

  defp pinned_family_inputs!(source, families) do
    families
    |> Enum.reduce_while([], fn {family, {relative, digest}}, inputs ->
      path = Path.join(source, relative)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          ensure!(
            Hash.sha256(path) == digest,
            "pinned #{family} license input differs: #{relative}"
          )

          {:cont, [input(relative, digest) | inputs]}

        _ ->
          {:halt, :missing}
      end
    end)
    |> case do
      :missing -> []
      inputs -> Enum.reverse(inputs)
    end
  end

  defp optional_pinned_inputs!(source, pins) do
    Enum.flat_map(pins, fn {label, {relative, digest}} ->
      path = Path.join(source, relative)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          ensure!(Hash.sha256(path) == digest, "pinned #{label} differs: #{relative}")
          [input(relative, digest)]

        _ ->
          []
      end
    end)
  end

  defp ordinary_inputs(source, relatives) do
    Enum.flat_map(relatives, fn relative ->
      path = Path.join(source, relative)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> [input(relative, Hash.sha256(path))]
        _ -> []
      end
    end)
  end

  defp package_license_inputs(source, name) do
    directory = Path.join([source, "deps", name])

    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.filter(&Regex.match?(~r/\A(?:LICENSE|LICENCE|COPYING|NOTICE)(?:[._-].*)?\z/i, &1))
    |> Enum.map(&Path.join(["deps", name, &1]))
    |> then(&ordinary_inputs(source, &1))
  end

  defp input(relative, digest), do: %{"path" => relative, "sha256" => digest}

  defp input_status("maude-bundled", inputs) do
    cond do
      Enum.any?(inputs, &(&1["path"] == elem(@maude_license, 0))) -> "present"
      inputs != [] -> "notice_only"
      true -> "missing"
    end
  end

  defp input_status(name, inputs) when is_map_key(@package_notices, name) do
    cond do
      Enum.any?(inputs, &(&1["path"] == elem(@apache_license, 0))) -> "present"
      inputs != [] -> "notice_only"
      true -> "missing"
    end
  end

  defp input_status(_name, []), do: "missing"
  defp input_status(_name, _inputs), do: "present"

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(Error, message)
end

defmodule Mix.Tasks.Woh.Release.Components do
  @moduledoc """
  Maps assembled release files to components and local license inputs.

  Run `mix woh.release.components create RELEASE_ROOT` from a clean committed
  tree before producing the SPDX document and final inventory. `verify` checks
  the current payload and local license inputs against the saved report. Missing
  inputs stay explicit; this report does not decide license compliance.
  """

  @shortdoc "Create or verify release component report"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([action, root]) when action in ~w(create verify) do
    source = File.cwd!()

    with {:ok, revision} <- Woh.Tool.ReleaseComponents.source_revision(source, action == "create"),
         {:ok, report} <-
           apply(Woh.Tool.ReleaseComponents, String.to_existing_atom(action), [
             root,
             source,
             revision
           ]) do
      verb = if action == "create", do: "mapped", else: "verified"

      Mix.shell().info(
        "#{verb} #{report["file_count"]} release files to #{length(report["components"])} components"
      )
    else
      {:error, reason} -> Mix.raise("release component error: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.release.components create|verify RELEASE_ROOT")
end
