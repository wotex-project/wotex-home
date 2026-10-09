defmodule Woh.Tool.LinuxNativeDeps do
  @moduledoc false

  alias Woh.Tool.{Command, ReleaseInventory}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @architectures %{
    "arm64" => {183, "/lib/ld-linux-aarch64.so.1"},
    "amd64" => {62, "/lib64/ld-linux-x86-64.so.2"}
  }
  # Only the platform C runtime is external. Other direct dependencies must
  # resolve through the referring ELF's own, release-relative RUNPATH.
  @glibc ~w(libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1)
  @foreign_magic [
    <<0xFE, 0xED, 0xFA, 0xCE>>,
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xCE, 0xFA, 0xED, 0xFE>>,
    <<0xCF, 0xFA, 0xED, 0xFE>>,
    <<0xCA, 0xFE, 0xBA, 0xBE>>,
    <<0xBE, 0xBA, 0xFE, 0xCA>>
  ]
  @max_native_files 256
  @max_output 1_048_576

  def check(release, architecture) do
    root = Path.expand(release)
    architecture!(architecture)

    with {:ok, _} <- ReleaseInventory.verify(root),
         {:ok, entries} <- ReleaseInventory.entries(root) do
      binaries = scan!(root, entries, architecture)

      ensure!(
        Enum.count(binaries, fn {name, _} ->
          Regex.match?(~r/\Aerts-[^\/]+\/bin\/beam\.smp\z/, name)
        end) == 1,
        "release has no exact native BEAM executable"
      )

      files = MapSet.new(binaries, fn {name, _} -> Path.join(root, name) end)

      loads =
        Map.new(binaries, fn {name, header} ->
          path = Path.join(root, name)
          output = command!(path)
          info = loads!(output, architecture)
          resolve!(info, path, root, files)

          if Path.basename(path) == "beam.smp" do
            ensure!(header.type in [2, 3] and info.interpreter != nil, "invalid BEAM loader")
          end

          {name,
           %{
             "needed" => info.needed,
             "runpath" => info.runpath,
             "interpreter" => info.interpreter,
             "glibc_versions" => info.glibc_versions
           }}
        end)

      # Inspection does not change the payload. Check its complete inventory
      # again rather than blessing a binary modified during a tool call.
      with {:ok, _} <- ReleaseInventory.verify(root) do
        {:ok,
         %{
           "scope" => "direct_elf_loads_only",
           "architecture" => architecture,
           "external_platform" => "debian_13_glibc",
           "native_files" => map_size(loads),
           "loads" => loads
         }}
      end
    end
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "cannot inspect Linux release: #{Exception.message(error)}"}
  end

  def header!(bytes, architecture) do
    {machine, _} = architecture!(architecture)

    case bytes do
      <<0x7F, "ELF", 2, 1, 1, abi, 0, 0::size(56), type::little-16, ^machine::little-16,
        1::little-32, _rest::binary-size(40)>>
      when abi in [0, 3] and type in [2, 3] ->
        %{type: type, machine: machine}

      _ ->
        fail!("unsupported, truncated or foreign ELF header")
    end
  end

  def loads!(output, architecture) do
    {_, interpreter} = architecture!(architecture)
    ensure!(String.valid?(output), "ELF tool output is not UTF-8")

    interpreters =
      Regex.scan(~r/\[Requesting program interpreter: ([^\]\r\n]+)\]/, output)
      |> Enum.map(fn [_, value] -> value end)

    ensure!(
      length(Regex.scan(~r/Requesting program interpreter:/, output)) == length(interpreters) and
        interpreters in [[], [interpreter]],
      "unsupported or duplicate ELF interpreter"
    )

    {needed, runpaths, sonames} =
      output
      |> String.split("\n")
      |> Enum.reduce({[], [], []}, fn line, {needed, runpaths, sonames} = acc ->
        cond do
          Regex.match?(~r/\((RPATH|FILTER|AUXILIARY|AUDIT|DEPAUDIT|CONFIG)\)/, line) ->
            fail!("unsupported ELF dynamic search or load tag")

          String.contains?(line, "(NEEDED)") ->
            value = value!(line, "NEEDED", "Shared library")
            library_name!(value)
            {[value | needed], runpaths, sonames}

          String.contains?(line, "(RUNPATH)") ->
            value = value!(line, "RUNPATH", "Library runpath")
            {needed, [value | runpaths], sonames}

          String.contains?(line, "(SONAME)") ->
            value = value!(line, "SONAME", "Library soname")
            library_name!(value)
            {needed, runpaths, [value | sonames]}

          true ->
            acc
        end
      end)

    ensure!(length(runpaths) <= 1 and length(sonames) <= 1, "duplicate ELF path or SONAME")
    ensure!(length(needed) <= 128, "ELF dependency bound exceeded")

    %{
      interpreter: List.first(interpreters),
      needed: Enum.sort(Enum.uniq(needed)),
      runpath: List.first(runpaths),
      soname: List.first(sonames),
      glibc_versions: glibc_versions!(output)
    }
  end

  def glibc_versions!(output) do
    versions =
      Regex.scan(~r/Name: (GLIBC_[^\s]+)\s+Flags:/, output)
      |> Enum.map(fn [_, version] -> version end)
      |> Enum.uniq()
      |> Enum.sort()

    ensure!(length(versions) <= 128, "ELF version requirement bound exceeded")

    for version <- versions do
      supported =
        case Regex.run(~r/\AGLIBC_(\d+)\.(\d+)(?:\.(\d+))?\z/, version) do
          [_, major, minor | patch] ->
            patch =
              case patch do
                [] -> 0
                [""] -> 0
                [value] -> String.to_integer(value)
              end

            {String.to_integer(major), String.to_integer(minor), patch} <= {2, 41, 0}

          _ ->
            version == "GLIBC_ABI_DT_RELR"
        end

      ensure!(supported, "ELF requires unsupported glibc version: #{version}")
    end

    versions
  end

  def resolve!(info, path, root, files) do
    paths = runpath!(info.runpath, path, root)

    for name <- info.needed do
      ensure!(
        name in @glibc or Enum.any?(paths, &MapSet.member?(files, Path.join(&1, name))),
        "unbundled native dependency in #{Path.relative_to(path, root)}: #{name}"
      )
    end

    :ok
  end

  def runpath!(nil, _path, _root), do: []

  def runpath!(runpath, path, root) do
    entries = String.split(runpath, ":")
    ensure!(length(entries) <= 16, "ELF search path bound exceeded")

    Enum.map(entries, fn entry ->
      suffix =
        cond do
          entry in ["$ORIGIN", "${ORIGIN}"] ->
            ""

          String.starts_with?(entry, "$ORIGIN/") ->
            String.replace_prefix(entry, "$ORIGIN/", "")

          String.starts_with?(entry, "${ORIGIN}/") ->
            String.replace_prefix(entry, "${ORIGIN}/", "")

          true ->
            fail!("ELF search path is not release-relative")
        end

      ensure!(
        Regex.match?(~r/\A[a-zA-Z0-9_.\/-]*\z/, suffix) and Path.type(suffix) != :absolute,
        "unsupported ELF search path"
      )

      resolved = Path.expand(suffix, Path.dirname(path))

      ensure!(
        resolved == root or String.starts_with?(resolved, root <> "/"),
        "ELF search path escapes release"
      )

      resolved
    end)
  end

  defp scan!(root, entries, architecture) do
    Enum.reduce(entries, [], fn entry, binaries ->
      path = Path.join(root, entry["path"])

      prefix =
        File.open!(path, [:read, :binary], fn file ->
          case IO.binread(file, 64) do
            :eof -> <<>>
            bytes when is_binary(bytes) -> bytes
            _ -> fail!("cannot read native file header")
          end
        end)

      cond do
        String.starts_with?(prefix, <<0x7F, "ELF">>) ->
          ensure!(length(binaries) < @max_native_files, "Linux native file bound exceeded")
          [{entry["path"], header!(prefix, architecture)} | binaries]

        Enum.any?(@foreign_magic, &String.starts_with?(prefix, &1)) or
            String.starts_with?(prefix, "MZ") ->
          fail!("foreign native binary in Linux release: #{entry["path"]}")

        true ->
          binaries
      end
    end)
    |> Enum.sort()
  end

  defp command!(path) do
    case Command.run(
           "readelf",
           ["--wide", "--program-headers", "--dynamic", "--version-info", path],
           @max_output,
           15_000,
           [
             {"LC_ALL", "C"}
           ]
         ) do
      {:ok, output} -> output
      {:error, reason} -> fail!("ELF inspection failed: #{reason}")
    end
  end

  defp value!(line, tag, label) do
    regex =
      Regex.compile!(
        "^\\s*0x[0-9a-fA-F]+\\s+\\(" <>
          tag <> "\\)\\s+" <> label <> ": \\[([^\\]\\r\\n]*)\\]\\s*$"
      )

    case Regex.run(regex, line) do
      [_, value] -> value
      _ -> fail!("malformed ELF #{tag} value")
    end
  end

  defp library_name!(name) do
    ensure!(
      byte_size(name) <= 255 and Regex.match?(~r/\A[a-zA-Z0-9_+.-]+\z/, name) and
        name not in [".", ".."],
      "ELF dependency is not a library basename"
    )
  end

  defp architecture!(architecture) do
    Map.get(@architectures, architecture) || fail!("unsupported Linux release architecture")
  end

  defp ensure!(true, _reason), do: :ok
  defp ensure!(_, reason), do: fail!(reason)
  defp fail!(reason), do: raise(Error, message: reason)
end

defmodule Mix.Tasks.Woh.Linux.Native.Deps.Check do
  @moduledoc """
  Checks an inventoried Linux release's ELF architecture and direct native loads.

  Run on a build host with GNU readelf. Only Debian 13 glibc is external;
  other libraries must resolve through each ELF's own release-relative RUNPATH.
  This does not establish artifact authenticity, dlopen closure, installed
  system-service behavior or physical qualification.
  """

  @shortdoc "Check a Linux release's direct ELF closure"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([release, architecture]) do
    case Woh.Tool.LinuxNativeDeps.check(release, architecture) do
      {:ok, report} -> Mix.shell().info(JSON.encode!(report))
      {:error, reason} -> Mix.raise("Linux native dependency check failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.linux.native.deps.check RELEASE arm64|amd64")
end
