defmodule Woh.Tool.LinuxUpdateRecords do
  @moduledoc false
  import Bitwise
  alias Woh.Tool.LinuxInstallFiles

  @limit 65_536
  @names ~w(update-journal.json current-release.json)
  @stat_keys ~w(type inode major_device minor_device uid gid links mode size mtime ctime)a

  # Closed administrative names only; callers separately validate their typed
  # records and legal transitions. No Store handle or credential is accepted.
  def read(base, owner, name, tool \\ LinuxInstallFiles.packaged_tool()) do
    with true <- name in @names,
         :ok <- LinuxInstallFiles.assert_lock(tool),
         :ok <- custody(base, owner),
         {:ok, bytes} <- private_bytes(Path.join([base, ".installer", name])),
         :ok <- custody(base, owner) do
      {:ok, bytes}
    else
      _ -> error()
    end
  end

  def write(base, owner, name, bytes, previous \\ nil, tool \\ LinuxInstallFiles.packaged_tool()) do
    with true <- name in @names and bounded?(bytes) and (previous == nil or bounded?(previous)),
         :ok <- LinuxInstallFiles.assert_lock(tool),
         :ok <- custody(base, owner),
         :ok <-
           LinuxInstallFiles.write(
             Path.join([base, ".installer", name]),
             0o600,
             bytes,
             if(previous, do: LinuxInstallFiles.digest(previous)),
             tool
           ),
         :ok <- custody(base, owner),
         {:ok, ^bytes} <- private_bytes(Path.join([base, ".installer", name])) do
      {:ok, bytes}
    else
      _ -> error()
    end
  end

  defp custody(base, owner) do
    with true <- is_binary(base) and Path.type(base) == :absolute and Path.expand(base) == base,
         true <- bounded?(owner) and protected_parents?(base),
         {:ok, root} <- File.lstat(base),
         true <- directory?(root, 0o755),
         {:ok, admin} <- File.lstat(Path.join(base, ".installer")),
         true <- directory?(admin, 0o700),
         {:ok, ^owner} <- private_bytes(Path.join(base, ".installer/owner.json")) do
      :ok
    else
      _ -> error()
    end
  end

  defp private_bytes(path) do
    with {:ok, info} <- File.lstat(path),
         true <-
           info.type == :regular and info.uid == 0 and info.gid == 0 and info.links == 1 and
             (info.mode &&& 0o7777) == 0o600 and info.size in 1..@limit,
         {:ok, bytes} <- File.open(path, [:read, :binary], &IO.binread(&1, @limit + 1)),
         true <- is_binary(bytes) and byte_size(bytes) == info.size,
         {:ok, after_read} <- File.lstat(path),
         true <- Map.take(info, @stat_keys) == Map.take(after_read, @stat_keys) do
      {:ok, bytes}
    else
      _ -> error()
    end
  end

  defp protected_parents?(base) do
    base
    |> Path.split()
    |> Enum.reduce_while("/", fn component, parent ->
      path = Path.join(parent, component)

      case File.lstat(path) do
        {:ok, info} ->
          if info.type == :directory and info.uid == 0 and info.gid == 0 and
               ((info.mode &&& 0o022) == 0 or (info.mode &&& 0o1000) != 0),
             do: {:cont, path},
             else: {:halt, false}

        _ ->
          {:halt, false}
      end
    end) != false
  end

  defp directory?(info, mode),
    do:
      info.type == :directory and info.uid == 0 and info.gid == 0 and
        (info.mode &&& 0o7777) == mode

  defp bounded?(bytes), do: is_binary(bytes) and byte_size(bytes) in 1..@limit
  defp error, do: {:error, :invalid_update_record_custody}
end
