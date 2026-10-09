defmodule Woh.Tool.LinuxUpdateProcess do
  @moduledoc false
  import Bitwise

  alias Woh.Tool.{
    Command,
    Json,
    LinuxInstallFiles,
    LinuxInstallHost,
    LinuxServicePackage,
    ReleaseBootstrap
  }

  @cgroup "/system.slice/wotex-home.service"
  @identity_keys ~w(source_revision artifact_id bootstrap_sha256 inventory_sha256)

  # This joins read-only registration/kernel/payload observations. It grants no
  # permission to stop, start, select or end maintenance. Fixture options are
  # internal; an eventual update CLI must never expose them.
  def running(release, identity, uid, options \\ []) do
    query = Keyword.get(options, :query, &Command.run/4)
    tool = Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())

    with true <- is_integer(uid) and uid in 100..999,
         {:ok, image} <- image(release, identity),
         {:ok, %{state: :running} = registration} <-
           LinuxInstallHost.controller_registration(query),
         {:ok, first} <- observe(registration.pid, image, uid, tool),
         true <- first.cgroup == registration.cgroup,
         {:ok, second} <- observe(registration.pid, image, uid, tool),
         true <- first == second,
         {:ok, ^registration} <- LinuxInstallHost.controller_registration(query) do
      result = Map.merge(first, Map.take(registration, [:invocation_id]))
      if Keyword.get(options, :expected, result) == result, do: {:ok, result}, else: error()
    else
      _ -> error()
    end
  end

  def stopped(options \\ []) do
    query = Keyword.get(options, :query, &Command.run/4)
    tool = Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())
    root = Keyword.get(options, :cgroup_root, "/sys/fs/cgroup")

    with true <- protected_directory?(root),
         {:ok, "cgroup2fs\n"} <- query.("/usr/bin/stat", ["-f", "-c", "%T", root], 128, 5000),
         {:ok, %{state: :stopped} = registration} <-
           LinuxInstallHost.controller_registration(query),
         {:ok, first} <- LinuxInstallFiles.empty_cgroup(root <> @cgroup, tool),
         :ok <- empty_frame(first),
         {:ok, ^first} <- LinuxInstallFiles.empty_cgroup(root <> @cgroup, tool),
         {:ok, ^registration} <- LinuxInstallHost.controller_registration(query) do
      :ok
    else
      _ -> error()
    end
  end

  def image(release, identity) do
    with true <- identity?(identity) and protected_directory?(release),
         {:ok, report} <- LinuxServicePackage.verify(release),
         true <-
           report["schema_version"] === 2 and
             report["source_revision"] == identity["source_revision"] and
             report["artifact_id"] == identity["artifact_id"],
         {:ok, bootstrap} <- ReleaseBootstrap.render(release),
         true <- LinuxInstallFiles.digest(bootstrap) == identity["bootstrap_sha256"],
         {:ok, inventory_bytes} <- File.read(Path.join(release, "release-inventory.json")),
         true <- LinuxInstallFiles.digest(inventory_bytes) == identity["inventory_sha256"],
         {:ok, inventory} <- Json.read(Path.join(release, "release-inventory.json"), 2_000_000),
         [entry] <-
           Enum.filter(
             inventory["files"],
             &Regex.match?(~r/\Aerts-[0-9]+(?:\.[0-9]+){1,4}\/bin\/beam\.smp\z/, &1["path"])
           ),
         true <- entry["mode"] == 0o755 and entry["size"] in 1..67_108_864,
         path = Path.join(release, entry["path"]),
         true <- protected_directory?(Path.dirname(path)),
         {:ok, info} <- File.lstat(path),
         true <- info.type == :regular and info.uid == 0 and info.gid == 0 and info.links == 1 do
      {:ok, %{path: path, sha256: entry["sha256"], size: entry["size"]}}
    else
      _ -> error()
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= 4096 do
    with ["WOTEX_HOME_PROCESS\t1", fields, ""] <- String.split(bytes, "\n"),
         [pid, uid, start, boot, cgroup, digest, device, inode] <- String.split(fields, "\t"),
         true <-
           decimal?(pid, 2, 2_147_483_647) and decimal?(uid, 100, 999) and
             decimal?(start, 1, 18_446_744_073_709_551_615) and
             decimal?(device, 0, 18_446_744_073_709_551_615) and
             decimal?(inode, 1, 18_446_744_073_709_551_615) and hex?(digest, 64),
         true <- Regex.match?(~r/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/, boot),
         true <- cgroup == @cgroup do
      {:ok,
       %{
         pid: String.to_integer(pid),
         account_id: String.to_integer(uid),
         start_ticks: String.to_integer(start),
         boot_id: boot,
         cgroup: cgroup,
         image_sha256: digest,
         image_device: String.to_integer(device),
         image_inode: String.to_integer(inode)
       }}
    else
      _ -> error()
    end
  end

  def decode(_), do: error()

  def join_peer(%{pid: pid}, pid) when is_integer(pid) and pid in 2..2_147_483_647, do: :ok
  def join_peer(_, _), do: error()

  defp observe(pid, image, uid, tool) do
    with {:ok, bytes} <-
           LinuxInstallFiles.observe_process(pid, image.path, image.sha256, image.size, uid, tool),
         {:ok, result} <- decode(bytes),
         true <-
           result.pid == pid and result.account_id == uid and result.image_sha256 == image.sha256 do
      {:ok, result}
    else
      _ -> error()
    end
  end

  defp empty_frame("WOTEX_HOME_CGROUP\t1\nabsent\n"), do: :ok

  defp empty_frame(bytes) do
    with ["WOTEX_HOME_CGROUP\t1", fields, ""] <- String.split(bytes, "\n"),
         ["empty", device, inode] <- String.split(fields, "\t"),
         true <-
           decimal?(device, 0, 18_446_744_073_709_551_615) and
             decimal?(inode, 1, 18_446_744_073_709_551_615),
         do: :ok,
         else: (_ -> error())
  end

  defp protected_directory?(path) when is_binary(path) do
    Path.type(path) == :absolute and Path.expand(path) == path and
      path
      |> Path.split()
      |> Enum.reduce_while("/", fn component, parent ->
        next = Path.join(parent, component)

        case File.lstat(next) do
          {:ok, info} ->
            if info.type == :directory and info.uid == 0 and info.gid == 0 and
                 ((info.mode &&& 0o022) == 0 or (next != path and (info.mode &&& 0o1000) != 0)),
               do: {:cont, next},
               else: {:halt, false}

          _ ->
            {:halt, false}
        end
      end) != false
  end

  defp protected_directory?(_), do: false

  defp identity?(value),
    do:
      is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(@identity_keys) and
        hex?(value["source_revision"], 40) and
        Enum.all?(~w(artifact_id bootstrap_sha256 inventory_sha256), &hex?(value[&1], 64))

  defp hex?(value, length),
    do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp decimal?(value, minimum, maximum),
    do:
      is_binary(value) and byte_size(value) <= 20 and
        Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) and
        String.to_integer(value) in minimum..maximum

  defp error, do: {:error, :invalid_update_process_observation}
end
