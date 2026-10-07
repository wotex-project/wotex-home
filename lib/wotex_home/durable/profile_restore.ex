defmodule WotexHome.Durable.ProfileRestore do
  @moduledoc "Publish verified database and inert bytes into new private quarantine only."
  import Bitwise

  def stage(destination, database, objects, sync \\ &:file.sync/1) do
    parent = if is_binary(destination), do: Path.dirname(destination), else: nil

    with true <-
           is_binary(destination) and Path.type(destination) == :absolute and
             Path.expand(destination) == destination,
         {:ok, anchors} <- anchors(parent),
         {_, parent_stat} = List.last(anchors),
         true <- band(parent_stat.mode, 0o777) == 0o700,
         {:ok, parent_handle} <- File.open(parent, [:read, :raw, :directory]) do
      try do
        with :ok <- intact(anchors),
             {:ok, info} <- :file.read_file_info(parent_handle, time: :universal),
             true <- identity(parent_stat) == identity(File.Stat.from_record(info)),
             :ok <- File.mkdir(destination) do
          create(destination, database, objects, anchors, parent_handle, sync)
        else
          {:error, :eexist} -> {:error, :restore_exists}
          _ -> {:error, :restore_unavailable}
        end
      after
        File.close(parent_handle)
      end
    else
      _ -> {:error, :invalid_restore_request}
    end
  end

  defp create(destination, database, objects, parent_anchors, parent_handle, sync) do
    with :ok <- File.chmod(destination, 0o700),
         {:ok, stat} <- File.lstat(destination) do
      anchors = parent_anchors ++ [{destination, stat}]
      result = publish(destination, database, objects, anchors, parent_handle, sync)
      # Never remove a replacement path or a directory whose parent changed.
      if result != :ok and intact(anchors) == :ok, do: File.rm_rf(destination)
      result
    else
      _ -> {:error, :restore_unavailable}
    end
  end

  defp publish(destination, database, objects, anchors, parent_handle, sync) do
    profiles = Path.join(destination, "profiles")

    with :ok <- intact(anchors),
         :ok <- File.mkdir(profiles),
         :ok <- File.chmod(profiles, 0o700),
         {:ok, stat} <- File.lstat(profiles),
         all_anchors = anchors ++ [{profiles, stat}],
         :ok <-
           Enum.reduce_while(objects, :ok, fn object, :ok ->
             case write_new(
                    Path.join(profiles, object.artifact_digest <> ".json"),
                    object.bytes,
                    0o400,
                    all_anchors,
                    sync
                  ) do
               :ok -> {:cont, :ok}
               _ -> {:halt, {:error, :restore_unavailable}}
             end
           end),
         :ok <- sync_directory(profiles, all_anchors, sync),
         staged_database = Path.join(destination, ".stage-home.sqlite"),
         :ok <- write_new(staged_database, database, 0o600, all_anchors, sync),
         :ok <- intact(all_anchors),
         :ok <- File.ln(staged_database, Path.join(destination, "home.sqlite")),
         :ok <- File.rm(staged_database),
         :ok <- sync_directory(destination, all_anchors, sync),
         :ok <- intact(all_anchors),
         :ok <- sync.(parent_handle) do
      :ok
    else
      _ -> {:error, :restore_unavailable}
    end
  end

  defp write_new(path, bytes, mode, anchors, sync) do
    with :ok <- intact(anchors),
         {:ok, file} <- File.open(path, [:write, :binary, :raw, :exclusive]) do
      try do
        with :ok <- File.chmod(path, mode),
             {:ok, before} <- File.lstat(path),
             :ok <- IO.binwrite(file, bytes),
             :ok <- sync.(file),
             {:ok, info} <- :file.read_file_info(file, time: :universal),
             {:ok, after_stat} <- File.lstat(path),
             true <- identity(before) == identity(after_stat),
             true <- identity(before) == identity(File.Stat.from_record(info)),
             true <-
               after_stat.type == :regular and after_stat.links == 1 and
                 after_stat.size == byte_size(bytes),
             :ok <- intact(anchors) do
          :ok
        else
          _ -> {:error, :restore_unavailable}
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, :restore_unavailable}
    end
  end

  defp sync_directory(path, anchors, sync) do
    with :ok <- intact(anchors), {:ok, handle} <- File.open(path, [:read, :raw, :directory]) do
      try do
        {_, stat} = Enum.find(anchors, fn {name, _} -> name == path end)

        with {:ok, info} <- :file.read_file_info(handle, time: :universal),
             true <- identity(stat) == identity(File.Stat.from_record(info)),
             :ok <- sync.(handle),
             :ok <- intact(anchors),
             do: :ok,
             else: (_ -> {:error, :restore_unavailable})
      after
        File.close(handle)
      end
    else
      _ -> {:error, :restore_unavailable}
    end
  end

  defp anchors(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case File.lstat(name) do
        {:ok, %{type: :directory} = stat} -> {:cont, {:ok, acc ++ [{name, stat}]}}
        _ -> {:halt, {:error, :invalid_restore_request}}
      end
    end)
  end

  defp intact(anchors) do
    if Enum.all?(anchors, fn {path, stat} ->
         case File.lstat(path) do
           {:ok, current} -> identity(stat) == identity(current)
           _ -> false
         end
       end), do: :ok, else: {:error, :restore_unavailable}
  end

  defp identity(stat),
    do: {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode}
end
