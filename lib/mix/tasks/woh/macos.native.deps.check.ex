defmodule Woh.Tool.MacosNativeDeps do
  @moduledoc false

  alias Woh.Tool.Command

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @macho_magic [
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xCF, 0xFA, 0xED, 0xFE>>,
    <<0xCA, 0xFE, 0xBA, 0xBE>>,
    <<0xBE, 0xBA, 0xFE, 0xCA>>
  ]
  @system_prefixes ["/usr/lib/", "/System/Library/"]
  @load_commands ~w(LC_LOAD_DYLIB LC_LOAD_WEAK_DYLIB LC_REEXPORT_DYLIB LC_LOAD_UPWARD_DYLIB LC_LAZY_LOAD_DYLIB LC_LOAD_DYLINKER)
  @max_files 10_000
  @max_macho 100
  @max_tool_output 1_048_576

  def check(app) do
    app = Path.expand(app)

    ensure!(
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(app)),
      "app bundle is unavailable"
    )

    plist = Path.join(app, "Contents/Info.plist")

    ensure!(
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(plist)),
      "app Info.plist is unavailable"
    )

    declared =
      command!("plutil", ["-extract", "LSMinimumSystemVersion", "raw", "-o", "-", plist])
      |> String.trim()

    minimum = version!(declared)

    binaries = scan!(app)
    relative = MapSet.new(binaries, &Path.relative_to(&1, app))

    ensure!(
      MapSet.subset?(
        MapSet.new(~w(Contents/MacOS/WotexHome Contents/MacOS/WotexHomeAgent)),
        relative
      ),
      "native app or agent executable is missing"
    )

    {architectures, system_loads, ids, highest} =
      Enum.reduce(Enum.sort(binaries), {%{}, MapSet.new(), 0, {0, 0, 0}}, fn path,
                                                                             {arches, loads, ids,
                                                                              highest} ->
        name = Path.relative_to(path, app)
        archs = command!("lipo", ["-archs", path]) |> String.split() |> MapSet.new()
        ensure!(archs == MapSet.new(["arm64"]), "unsupported native architecture: #{name}")

        output = command!("otool", ["-l", path])
        {dependencies, new_ids} = loads!(output)
        versions = deployment_versions!(output)

        ensure!(
          length(versions) == MapSet.size(archs) and Enum.all?(versions, &(&1 <= minimum)),
          "native binary requires newer macOS than app declares: #{name}"
        )

        loads =
          Enum.reduce(dependencies, loads, fn dependency, selected ->
            ensure!(
              system_path?(dependency),
              "unbundled native dependency in #{name}: #{dependency}"
            )

            MapSet.put(selected, dependency)
          end)

        {Map.put(arches, name, Enum.sort(archs)), loads, ids + new_ids,
         Enum.max([highest | versions])}
      end)

    {:ok,
     %{
       "scope" => "direct_macho_load_commands_only",
       "native_files" => length(binaries),
       "architectures" => architectures,
       "system_library_count" => MapSet.size(system_loads),
       "nonportable_self_install_ids" => ids,
       "declared_macos_minimum" => declared,
       "highest_binary_macos_minimum" => "#{elem(highest, 0)}.#{elem(highest, 1)}"
     }}
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "cannot inspect app bundle: #{Exception.message(error)}"}
  end

  def loads!(output) do
    lines = String.split(output, "\n")

    {command, found_name, dependencies, ids} =
      Enum.reduce(lines, {nil, false, [], 0}, fn line,
                                                 {command, found_name, dependencies, ids} = state ->
        cond do
          String.starts_with?(line, "Load command ") ->
            ensure!(
              command not in @load_commands or found_name,
              "Mach-O load command has no library name"
            )

            {nil, false, dependencies, ids}

          match = Regex.run(~r/^\s*cmd (LC_[A-Z_]+)$/, line) ->
            [_, current] = match

            ensure!(
              not (String.ends_with?(current, "DYLIB") and
                     current not in (@load_commands ++ ["LC_ID_DYLIB"])),
              "unsupported Mach-O dylib command: #{current}"
            )

            {current, found_name, dependencies, ids}

          match = Regex.run(~r/^\s*name (.+) \(offset \d+\)$/, line) ->
            [_, name] = match

            cond do
              command == "LC_ID_DYLIB" ->
                {command, true, dependencies, ids + if(system_path?(name), do: 0, else: 1)}

              command in @load_commands ->
                {command, true, [name | dependencies], ids}

              true ->
                state
            end

          true ->
            state
        end
      end)

    ensure!(
      command not in @load_commands or found_name,
      "Mach-O load command has no library name"
    )

    {Enum.reverse(dependencies), ids}
  end

  def deployment_versions!(output) do
    lines = String.split(output, "\n")

    found =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        case String.trim(line) do
          "cmd LC_BUILD_VERSION" ->
            fields = Enum.slice(lines, index + 1, 6) |> Enum.map(&String.trim/1)

            ensure!(
              Enum.any?(fields, &(&1 in ["platform 1", "platform MACOS"])),
              "native binary targets a non-macOS platform"
            )

            one_version!(fields, "minos ")

          "cmd LC_VERSION_MIN_MACOSX" ->
            fields = Enum.slice(lines, index + 1, 4) |> Enum.map(&String.trim/1)
            one_version!(fields, "version ")

          _ ->
            []
        end
      end)

    ensure!(found != [], "native binary has no macOS deployment command")
    found
  end

  defp one_version!(fields, prefix) do
    values =
      fields
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(&String.replace_prefix(&1, prefix, ""))

    case values do
      [value] -> [version!(value)]
      _ -> fail!("native binary has no exact macOS minimum")
    end
  end

  defp version!(value) do
    ensure!(
      Regex.match?(~r/^\d{1,2}\.\d{1,2}(?:\.\d{1,2})?$/, value),
      "invalid macOS deployment version"
    )

    value
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> then(&List.to_tuple(&1 ++ List.duplicate(0, 3 - length(&1))))
  end

  defp scan!(app) do
    {_, binaries} = scan_directory!(app, {0, []})
    binaries
  end

  defp scan_directory!(directory, state) do
    directory
    |> File.ls!()
    |> Enum.reduce(state, fn name, {files, binaries} = state ->
      path = Path.join(directory, name)

      case File.lstat!(path).type do
        :directory ->
          scan_directory!(path, state)

        :regular ->
          files = files + 1
          ensure!(files <= @max_files, "app bundle has too many files")
          {:ok, magic} = File.open(path, [:read, :binary], &IO.binread(&1, 4))
          binaries = if magic in @macho_magic, do: [path | binaries], else: binaries
          ensure!(length(binaries) <= @max_macho, "app bundle has too many Mach-O files")
          {files, binaries}

        :symlink ->
          fail!("app bundle contains a symlink")

        _ ->
          state
      end
    end)
  end

  defp system_path?(path), do: Enum.any?(@system_prefixes, &String.starts_with?(path, &1))

  defp command!(executable, args) do
    case Command.run(executable, args, @max_tool_output, 10_000) do
      {:ok, output} -> output
      {:error, reason} -> fail!("#{executable} failed: #{reason}")
    end
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: fail!(message)
  defp fail!(message), do: raise(Error, message)
end

defmodule Mix.Tasks.Woh.Macos.Native.Deps.Check do
  @moduledoc """
  Checks direct native library loads in an assembled macOS app.

  Run `mix woh.macos.native.deps.check APP_BUNDLE` after assembly. The task
  inspects every Mach-O file, requires arm64 and an app-compatible macOS
  deployment minimum, and rejects direct loads outside Apple's system library
  paths. It reports nonportable library self IDs separately. Transitive loads,
  `dlopen`, signing and availability on an installed Mac need other checks.
  """

  @shortdoc "Check assembled macOS native dependencies"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([app]) do
    case Woh.Tool.MacosNativeDeps.check(app) do
      {:ok, report} -> Mix.shell().info(JSON.encode!(report))
      {:error, reason} -> Mix.raise("macOS native dependency check failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.macos.native.deps.check APP_BUNDLE")
end
