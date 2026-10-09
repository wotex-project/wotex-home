defmodule Woh.Tool.LinuxNativeBundle do
  @moduledoc false

  alias Woh.Tool.{Command, Hash, Json, LinuxNativeDeps, ReleaseInventory}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @profile_path Path.expand("../../../../native/linux/native-libraries-arm64.json", __DIR__)
  @external_resource @profile_path
  @profile @profile_path |> File.read!() |> JSON.decode!()
  @directory "native/linux-libraries"
  @manifest @directory <> "/manifest.json"
  @max_library_bytes 16_777_216
  @max_input_bytes 1_048_576
  @reports ~w(release-inventory.json release-components.json release.spdx.json)

  def profile, do: @profile
  def manifest, do: @manifest

  def component_for(relative) do
    case Path.split(relative) do
      ["native", "linux-libraries", "lib", name] ->
        library = Enum.find(@profile["libraries"], &(&1["library"] == name))
        if library, do: library["component"], else: "linux-native-bundle"

      ["native", "linux-libraries", "licenses", "packages", package, "COPYRIGHT"] ->
        library = Enum.find(@profile["libraries"], &(&1["package"] == package))
        if library, do: library["component"], else: "linux-native-bundle"

      ["native", "linux-libraries", "licenses", "common", _] ->
        "debian-native-license-inputs"

      _ ->
        "linux-native-bundle"
    end
  end

  def package_version(component) do
    case Enum.find(@profile["libraries"], &(&1["component"] == component)) do
      nil -> "NOASSERTION"
      library -> library["version"]
    end
  end

  def native_component?(component) do
    component == "debian-native-license-inputs" or
      Enum.any?(@profile["libraries"], &(&1["component"] == component))
  end

  def license_inputs(source, component) do
    library = Enum.find(@profile["libraries"], &(&1["component"] == component))

    inputs =
      if library,
        do: [library["copyright"] | @profile["common_license_inputs"]],
        else: @profile["common_license_inputs"]

    Enum.map(inputs, fn input ->
      bytes = pinned_input!(source, input)
      %{"path" => input["path"], "sha256" => digest(bytes)}
    end)
  end

  # This mutates only unissued, owned Mix assembly. Source libraries, package
  # provenance and every legal input are validated before the first write.
  # A refused build never receives final component/SPDX/inventory reports.
  def assemble(release, source) do
    root = Path.expand(release)
    source = Path.expand(source)
    require_unissued!(root)
    require_platform!()
    require_tools!()
    inputs = source_inputs!(source)
    providers = providers!()

    originals =
      LinuxNativeDeps.native_files!(root, "arm64")
      |> Map.new(fn {name, _} -> {name, Hash.sha256(Path.join(root, name))} end)

    destination = Path.join(root, @directory)
    File.mkdir_p!(Path.dirname(destination))
    File.mkdir!(destination)
    File.mkdir!(Path.join(destination, "lib"))

    for {library, bytes} <- providers do
      write!(Path.join(destination, "lib/" <> library["library"]), bytes)
    end

    for {relative, bytes} <- inputs, do: write!(Path.join(root, relative), bytes)

    binaries = LinuxNativeDeps.native_files!(root, "arm64")

    patches =
      Enum.map(binaries, fn {name, _} ->
        path = Path.join(root, name)
        runpath = runpath!(name)
        command!("patchelf", ["--set-rpath", runpath, path])

        library =
          Enum.find(@profile["libraries"], fn item ->
            name == @directory <> "/lib/" <> item["library"]
          end)

        if library do
          ensure!(
            Hash.sha256(path) == library["packaged_sha256"],
            "patched Linux provider differs: #{library["library"]}"
          )
        end

        original = if library, do: library["source_sha256"], else: Map.fetch!(originals, name)

        %{
          "path" => name,
          "source_sha256" => original,
          "packaged_sha256" => Hash.sha256(path),
          "runpath" => runpath
        }
      end)

    {:ok, closure} = checked_payload!(root)

    report = %{
      "schema_version" => 1,
      "scope" => "pinned_debian_libraries_and_patched_runpaths",
      "profile" => @profile,
      "patches" => patches,
      "direct_loads" => closure["loads"],
      "license_review" => "unresolved",
      "artifact_authenticity" => "not_established"
    }

    write!(Path.join(root, @manifest), JSON.encode!(report) <> "\n")
    verify(root)
  rescue
    error in [Error, LinuxNativeDeps.Error] ->
      {:error, error.message}

    error in File.Error ->
      {:error, "cannot assemble Linux native bundle: #{Exception.message(error)}"}
  end

  def verify(release) do
    root = Path.expand(release)

    report =
      case Json.read(Path.join(root, @manifest), 131_072) do
        {:ok, report} -> report
        {:error, reason} -> fail!(reason)
      end

    ensure!(
      is_map(report) and
        Enum.sort(Map.keys(report)) ==
          ~w(artifact_authenticity direct_loads license_review patches profile schema_version scope),
      "invalid Linux native bundle manifest"
    )

    ensure!(
      report["schema_version"] == 1 and report["profile"] == @profile and
        report["scope"] == "pinned_debian_libraries_and_patched_runpaths" and
        report["license_review"] == "unresolved" and
        report["artifact_authenticity"] == "not_established",
      "Linux native bundle profile differs"
    )

    binaries = LinuxNativeDeps.native_files!(root, "arm64")
    patches = report["patches"]

    ensure!(
      is_list(patches) and length(patches) == length(binaries) and
        Enum.all?(patches, &is_map/1),
      "invalid Linux native patch list"
    )

    actual_paths = Enum.map(binaries, &elem(&1, 0))
    ensure!(Enum.map(patches, & &1["path"]) == actual_paths, "Linux native patch paths differ")

    for patch <- patches do
      ensure!(
        is_map(patch) and
          Enum.sort(Map.keys(patch)) ==
            ~w(packaged_sha256 path runpath source_sha256),
        "invalid Linux native patch record"
      )

      ensure!(
        valid_digest?(patch["source_sha256"]) and
          patch["packaged_sha256"] == Hash.sha256(Path.join(root, patch["path"])) and
          patch["runpath"] == runpath!(patch["path"]),
        "Linux native patched bytes differ"
      )
    end

    vendor = Path.join(root, @directory <> "/lib")

    ensure!(
      Enum.sort(File.ls!(vendor)) == Enum.sort(Enum.map(@profile["libraries"], & &1["library"])),
      "Linux native provider file set differs"
    )

    for library <- @profile["libraries"] do
      path = @directory <> "/lib/" <> library["library"]
      patch = Enum.find(patches, &(&1["path"] == path))

      ensure!(
        patch["source_sha256"] == library["source_sha256"] and
          patch["packaged_sha256"] == library["packaged_sha256"],
        "Linux native provider source or patched bytes differ"
      )

      verify_input!(root, package_copyright(library), library["copyright"])
    end

    for input <- @profile["common_license_inputs"],
        do: verify_input!(root, common_input(input), input)

    {:ok, closure} = checked_payload!(root)
    ensure!(closure["loads"] == report["direct_loads"], "Linux native direct loads differ")

    for patch <- patches do
      ensure!(
        closure["loads"][patch["path"]]["runpath"] == patch["runpath"],
        "Linux native RUNPATH differs from declared transformation"
      )
    end

    {:ok, length(binaries)}
  rescue
    error in [Error, LinuxNativeDeps.Error] ->
      {:error, error.message}

    error in File.Error ->
      {:error, "cannot verify Linux native bundle: #{Exception.message(error)}"}
  end

  def runpath!(relative) do
    ensure!(
      Path.type(relative) == :relative and
        not Enum.any?(Path.split(relative), &(&1 in [".", ".."])),
      "invalid native relative path"
    )

    if Path.dirname(relative) == @directory <> "/lib" do
      "$ORIGIN"
    else
      depth =
        if Path.dirname(relative) == ".", do: 0, else: length(Path.split(Path.dirname(relative)))

      "$ORIGIN/" <>
        Enum.join(List.duplicate("..", depth) ++ Path.split(@directory <> "/lib"), "/")
    end
  end

  defp require_unissued!(root) do
    for name <- @reports ++ [@directory] do
      ensure!(
        File.lstat(Path.join(root, name)) == {:error, :enoent},
        "refuse an issued release or existing native bundle"
      )
    end

    case ReleaseInventory.entries(root) do
      {:ok, _} -> :ok
      {:error, reason} -> fail!(reason)
    end
  end

  defp require_platform! do
    ensure!(
      :os.type() == {:unix, :linux} and
        String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64"),
      "Linux native bundling requires the arm64 build host"
    )

    # Debian's host metadata normally points at /usr/lib/os-release. Payload
    # and source legal inputs still require regular, non-symlinked files.
    os = bounded_read!("/etc/os-release", 16_384, true)
    lines = String.split(os, "\n")

    ensure!(
      "ID=debian" in lines and "VERSION_ID=\"13\"" in lines,
      "Linux native bundling requires Debian 13"
    )

    ensure!(
      String.trim(command!("dpkg-query", ["-W", "-f=${Version}", "libc6"])) ==
        @profile["glibc_package_version"],
      "build host glibc package differs"
    )
  end

  defp require_tools! do
    for {tool, key} <- [{"patchelf", "patchelf_version"}, {"readelf", "readelf_version"}] do
      version = command!(tool, ["--version"]) |> String.split("\n") |> hd() |> String.trim()
      ensure!(version == @profile[key], "Linux native build tool differs: #{tool}")
    end
  end

  defp providers! do
    Enum.map(@profile["libraries"], fn library ->
      format = "${Version}\n${Architecture}\n${source:Package}\n${source:Version}\n"

      actual =
        command!("dpkg-query", ["-W", "-f=" <> format, library["package"]])
        |> String.split("\n", trim: true)

      ensure!(
        actual == [
          library["version"],
          "arm64",
          library["source_package"],
          library["source_version"]
        ],
        "Linux native provider package differs: #{library["package"]}"
      )

      path = Path.join(@profile["provider_directory"], library["library"])
      bytes = bounded_read!(path, @max_library_bytes, true)

      ensure!(
        digest(bytes) == library["source_sha256"],
        "Linux native provider bytes differ: #{library["library"]}"
      )

      LinuxNativeDeps.header!(binary_part(bytes, 0, min(64, byte_size(bytes))), "arm64")
      {library, bytes}
    end)
  end

  defp source_inputs!(source) do
    packages =
      Enum.map(@profile["libraries"], fn library ->
        {package_copyright(library), pinned_input!(source, library["copyright"])}
      end)

    packages ++
      Enum.map(@profile["common_license_inputs"], fn input ->
        {common_input(input), pinned_input!(source, input)}
      end)
  end

  defp pinned_input!(source, input) do
    bytes = bounded_read!(Path.join(source, input["path"]), @max_input_bytes, false)

    ensure!(
      digest(bytes) == input["sha256"],
      "pinned Linux license input differs: #{input["name"]}"
    )

    bytes
  end

  defp verify_input!(root, relative, input) do
    bytes = bounded_read!(Path.join(root, relative), @max_input_bytes, false)

    ensure!(
      digest(bytes) == input["sha256"],
      "packaged Linux license input differs: #{input["name"]}"
    )
  end

  defp package_copyright(library),
    do: @directory <> "/licenses/packages/" <> library["package"] <> "/COPYRIGHT"

  defp common_input(input), do: @directory <> "/licenses/common/" <> input["name"]

  defp bounded_read!(path, limit, links?) do
    stat = if links?, do: File.stat(path), else: File.lstat(path)

    ensure!(
      match?({:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= limit, stat),
      "native input is unavailable, linked or overlong: #{Path.basename(path)}"
    )

    File.open!(path, [:read, :binary], fn file ->
      bytes = IO.binread(file, limit + 1)

      ensure!(
        is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= limit,
        "native input read exceeds bound"
      )

      bytes
    end)
  end

  defp write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o644)
  end

  defp checked_payload!(root) do
    case LinuxNativeDeps.check_payload(root, "arm64") do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> fail!(reason)
    end
  end

  defp command!(name, args) do
    case Command.run(name, args, 65_536, 15_000, [{"LC_ALL", "C"}]) do
      {:ok, output} -> output
      {:error, reason} -> fail!("Linux native build command failed: #{name}: #{reason}")
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp ensure!(true, _reason), do: :ok
  defp ensure!(_, reason), do: fail!(reason)
  defp fail!(reason), do: raise(Error, message: reason)
end
