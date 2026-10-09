defmodule Woh.Tool.LinuxInstallPreflight do
  @moduledoc false
  import Bitwise

  alias Woh.Tool.{Command, LinuxNativeBundle, LinuxServicePackage, ReleaseBootstrap}

  @configuration LinuxServicePackage.files(String.duplicate("0", 64)) |> Map.keys() |> Enum.sort()
  @namespaces ~w(/opt/wotex-home /var/lib/wotex-home /run/wotex-home /run/wotexhomejournal)
  @conflicts ~w(
    /etc/systemd/system/wotex-home.service.d
    /etc/systemd/system/systemd-journald@wotex-home.service.d
    /etc/systemd/journald@wotex-home.conf.d
    /etc/systemd/system/multi-user.target.wants/wotex-home.service
    /usr/local/lib/systemd/system/wotex-home.service
    /usr/lib/systemd/system/wotex-home.service
    /run/systemd/system/wotex-home.service
    /usr/local/lib/systemd/system/run-wotexhomejournal.mount
    /usr/lib/systemd/system/run-wotexhomejournal.mount
    /run/systemd/system/run-wotexhomejournal.mount
    /etc/systemd/system/systemd-journald@wotex-home.service
    /usr/local/lib/systemd/system/systemd-journald@wotex-home.service
    /usr/lib/systemd/system/systemd-journald@wotex-home.service
    /run/systemd/system/systemd-journald@wotex-home.service
    /run/systemd/journald@wotex-home.conf
    /run/systemd/journald@wotex-home.conf.d
    /usr/lib/systemd/journald@wotex-home.conf
    /usr/lib/systemd/journald@wotex-home.conf.d
  )
  @paths Enum.sort(Enum.uniq(@namespaces ++ @conflicts ++ Enum.map(@configuration, &("/" <> &1))))
  @local_filesystems ~w(ext4 xfs btrfs)
  @parents ~w(/opt /var/lib /run /etc/systemd /etc/systemd/system /usr/lib/systemd/system)

  # This is the initial-install read barrier only. It never adopts an existing
  # installation or grants a later write permission from a stale snapshot.
  def check(release, manifest, pin) do
    with {:ok, _} <- ReleaseBootstrap.verify(release, manifest, pin),
         {:ok, report} <- LinuxServicePackage.verify(release),
         {:ok, snapshot} <- snapshot(),
         {:ok, plan} <- plan(report, snapshot) do
      {:ok, Map.put(plan, "bootstrap_sha256", pin)}
    end
  end

  def plan(report, snapshot) when is_map(snapshot) do
    profile = LinuxServicePackage.profile()

    cond do
      not valid_report?(report, profile) ->
        {:error, "initial installation requires the exact verified service profile"}

      snapshot[:uid] != 0 ->
        {:error, "initial installation preflight requires root"}

      snapshot[:platform] != {:unix, :linux} or snapshot[:distribution] != {"debian", "13"} or
          snapshot[:architecture] != profile["architecture"] ->
        {:error, "initial installation requires Debian 13 arm64"}

      snapshot[:glibc_package] != LinuxNativeBundle.profile()["glibc_package_version"] ->
        {:error, "installed glibc differs from the pinned native cohort"}

      snapshot[:pid1] != "systemd" or snapshot[:cgroup] != "cgroup2fs" or
        not is_integer(snapshot[:systemd_version]) or
          snapshot[:systemd_version] < profile["systemd_minimum_version"] ->
        {:error, "initial installation requires systemd 257 or later with cgroup v2"}

      snapshot[:account] != :absent or snapshot[:group] != :absent ->
        {:error, "refuse existing wotex-home account or group"}

      snapshot[:units] != :absent ->
        {:error, "refuse existing Home unit registration or loaded instance"}

      true ->
        with :ok <- check_paths(snapshot[:paths]),
             :ok <- check_parents(snapshot[:parents]),
             :ok <- check_storage(snapshot[:storage]) do
          {:ok,
           %{
             "scope" => "development_initial_install_preflight",
             "source_revision" => report["source_revision"],
             "artifact_id" => report["artifact_id"],
             "profile_id" => profile["profile_id"],
             "configuration_paths" => Enum.map(@configuration, &("/" <> &1)),
             "namespace_paths" => @namespaces,
             "registration" => "not_performed",
             "installed_host_qualification" => "missing"
           }}
        end
    end
  end

  def plan(_report, _snapshot), do: {:error, "initial host observations are unavailable"}

  def paths, do: @paths

  # The root override is for independent private filesystem probes. This
  # observation function performs no host operations or mutations.
  def observe_paths(root \\ "/") do
    Map.new(@paths, fn path -> {path, walk(root, path)} end)
  end

  def observe_parents(root \\ "/"), do: Map.new(@parents, &{&1, walk(root, &1)})

  def snapshot do
    with true <- :os.type() == {:unix, :linux},
         {:ok, uid} <- output("/usr/bin/id", ["-u"]),
         {:ok, architecture} <- output("/usr/bin/dpkg", ["--print-architecture"]),
         {:ok, glibc} <- output("/usr/bin/dpkg-query", ["-W", "-f=${Version}", "libc6"]),
         {:ok, pid1} <- bounded_read("/proc/1/comm", 128),
         :ok <- require_systemd(pid1),
         {:ok, systemd} <- output("/usr/bin/systemctl", ["--version"]),
         {:ok, cgroup} <- output("/usr/bin/stat", ["-f", "-c", "%T", "/sys/fs/cgroup"]),
         {:ok, os} <- bounded_read("/etc/os-release", 16_384),
         {:ok, account} <- absent_name("passwd"),
         {:ok, group} <- absent_name("group"),
         {:ok, units} <- absent_units(),
         {:ok, mounts} <- bounded_read("/proc/self/mountinfo", 1_048_576) do
      version =
        case Regex.run(~r/\Asystemd ([0-9]+)(?: |\n)/, systemd) do
          [_, value] -> String.to_integer(value)
          _ -> nil
        end

      {:ok,
       %{
         platform: :os.type(),
         uid: integer(uid),
         architecture: String.trim(architecture),
         glibc_package: String.trim(glibc),
         systemd_version: version,
         pid1: String.trim(pid1),
         cgroup: String.trim(cgroup),
         distribution: {os_value(os, "ID"), os_value(os, "VERSION_ID")},
         account: account,
         group: group,
         units: units,
         paths: observe_paths(),
         parents: observe_parents(),
         storage: Map.new(["/opt", "/var/lib"], &{&1, observe_storage(mounts, &1)})
       }}
    else
      false -> {:error, "initial installation requires Linux"}
      {:error, _} = error -> error
    end
  end

  def check_cohort(snapshot) when is_map(snapshot) do
    profile = LinuxServicePackage.profile()

    cond do
      snapshot[:uid] != 0 ->
        {:error, "installation requires root"}

      snapshot[:platform] != {:unix, :linux} or snapshot[:distribution] != {"debian", "13"} or
          snapshot[:architecture] != profile["architecture"] ->
        {:error, "installation requires Debian 13 arm64"}

      snapshot[:glibc_package] != LinuxNativeBundle.profile()["glibc_package_version"] ->
        {:error, "installed glibc differs from the pinned native cohort"}

      snapshot[:pid1] != "systemd" or snapshot[:cgroup] != "cgroup2fs" or
        not is_integer(snapshot[:systemd_version]) or
          snapshot[:systemd_version] < profile["systemd_minimum_version"] ->
        {:error, "installation requires systemd 257 or later with cgroup v2"}

      true ->
        with :ok <- check_parents(snapshot[:parents]), do: check_storage(snapshot[:storage])
    end
  end

  def check_cohort(_), do: {:error, "host observations unavailable"}

  defp check_paths(paths) when is_map(paths) do
    Enum.reduce_while(@paths, :ok, fn path, :ok ->
      case Map.get(paths, path) do
        :absent -> {:cont, :ok}
        _ -> {:halt, {:error, "refuse occupied or unsafe Home path: #{path}"}}
      end
    end)
  end

  defp check_paths(_), do: {:error, "initial path observations are unavailable"}

  defp check_parents(parents) when is_map(parents) do
    Enum.reduce_while(@parents, :ok, fn path, :ok ->
      case parents[path] do
        :safe_directory ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, "required root-owned system directory unavailable or unsafe: #{path}"}}
      end
    end)
  end

  defp check_parents(_), do: {:error, "initial parent observations are unavailable"}

  defp check_storage(storage) when is_map(storage) do
    Enum.reduce_while(["/opt", "/var/lib"], :ok, fn path, :ok ->
      case storage[path] do
        %{filesystem: type, writable: true, executable: executable}
        when type in @local_filesystems and (executable == true or path == "/var/lib") ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, "refuse unsupported, read-only or noexec local storage: #{path}"}}
      end
    end)
  end

  defp check_storage(_), do: {:error, "initial storage observations are unavailable"}

  defp walk(root, path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce_while(Path.expand(root), fn component, directory ->
      next = Path.join(directory, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory, uid: 0, mode: mode}} when (mode &&& 0o022) == 0 ->
          {:cont, next}

        {:error, :enoent} ->
          {:halt, :absent}

        _ ->
          {:halt, :occupied_or_unsafe}
      end
    end)
    |> case do
      :absent -> :absent
      :occupied_or_unsafe -> :occupied_or_unsafe
      _ -> :safe_directory
    end
  end

  defp absent_name(database) do
    case output("/usr/bin/getent", [database, "wotex-home"]) do
      {:error, "tool exited with status 2"} -> {:ok, :absent}
      {:ok, _} -> {:ok, :present}
      {:error, _} -> {:error, "cannot resolve the Home #{database} namespace"}
    end
  end

  defp absent_units do
    names = [
      "wotex-home.service",
      "run-wotexhomejournal.mount",
      "systemd-journald@wotex-home.service"
    ]

    common = ["--system", "--no-pager", "--no-legend", "--plain", "--full"]

    with {:ok, files} <- output("/usr/bin/systemctl", common ++ ["list-unit-files" | names]),
         {:ok, loaded} <- output("/usr/bin/systemctl", common ++ ["list-units", "--all" | names]) do
      {:ok,
       if(String.trim(files) == "" and String.trim(loaded) == "", do: :absent, else: :present)}
    end
  end

  def observe_storage(mounts, path) do
    mounts
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " - ", parts: 2) do
        [left, right] ->
          fields = String.split(left)
          tail = String.split(right)

          if length(fields) >= 6 and length(tail) >= 3 do
            mount = decode_mount(Enum.at(fields, 4))

            if path == mount or String.starts_with?(path, String.trim_trailing(mount, "/") <> "/") do
              options =
                String.split(Enum.at(fields, 5), ",") ++ String.split(Enum.at(tail, 2), ",")

              [
                {mount,
                 %{
                   filesystem: hd(tail),
                   writable: "rw" in options and "ro" not in options,
                   executable: "noexec" not in options
                 }}
              ]
            else
              []
            end
          else
            []
          end

        _ ->
          []
      end
    end)
    |> Enum.max_by(fn {mount, _} -> byte_size(mount) end, fn -> {"", nil} end)
    |> elem(1)
  end

  defp decode_mount(path) do
    Enum.reduce(
      [{"\\040", " "}, {"\\011", "\t"}, {"\\012", "\n"}, {"\\134", "\\"}],
      path,
      fn {encoded, value}, result -> String.replace(result, encoded, value) end
    )
  end

  defp valid_report?(report, profile) do
    is_map(report) and report["profile"] == profile and
      is_binary(report["artifact_id"]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, report["artifact_id"]) and
      is_binary(report["source_revision"]) and
      Regex.match?(~r/\A[0-9a-f]{40}\z/, report["source_revision"])
  end

  defp os_value(os, key) do
    case Regex.scan(~r/^#{key}="?([A-Za-z0-9_.-]+)"?$/m, os) do
      [[_, value]] -> value
      _ -> nil
    end
  end

  defp integer(bytes) do
    case Integer.parse(String.trim(bytes)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp require_systemd(pid1) do
    if String.trim(pid1) == "systemd",
      do: :ok,
      else: {:error, "initial installation requires systemd as PID 1"}
  end

  defp bounded_read(path, bound) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= bound <- File.stat(path),
         {:ok, bytes} <- File.open(path, [:read, :binary], &IO.binread(&1, bound + 1)),
         true <- is_binary(bytes) and byte_size(bytes) <= bound do
      {:ok, bytes}
    else
      _ -> {:error, "host preflight input unavailable or overlong: #{path}"}
    end
  end

  defp output(path, arguments),
    do:
      Command.run(path, arguments, 65_536, 5_000, [
        {"LANG", "C"},
        {"LC_ALL", "C"},
        {"SYSTEMD_COLORS", "0"}
      ])
end
