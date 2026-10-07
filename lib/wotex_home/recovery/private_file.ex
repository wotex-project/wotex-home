defmodule WotexHome.Recovery.PrivateFile do
  @moduledoc "Bounded immutable recovery custody; canonical private parent and pinned descriptors."
  import Bitwise
  @maximum 4_194_304

  def read(path, maximum) do
    read_mode(path, maximum, 0o400)
  end

  defp read_mode(path, maximum, mode) do
    with true <- is_integer(maximum) and maximum in 1..@maximum,
         {:ok, anchors, uid} <- anchors(path),
         :ok <- intact(anchors),
         {:ok, before} <- File.lstat(path),
         true <- private?(before, uid, maximum, mode),
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, opened} <- descriptor(file),
             true <- snapshot(before) == snapshot(opened),
             bytes when is_binary(bytes) and byte_size(bytes) == before.size <-
               IO.binread(file, maximum + 1),
             :eof <- IO.binread(file, 1),
             {:ok, closed} <- descriptor(file),
             {:ok, named} <- File.lstat(path),
             true <- snapshot(before) == snapshot(closed),
             true <- snapshot(before) == snapshot(named),
             :ok <- intact(anchors) do
          {:ok, bytes}
        else
          _ -> unavailable()
        end
      after
        File.close(file)
      end
    else
      _ -> unavailable()
    end
  end

  def write(path, bytes, maximum, sync \\ &:file.sync/1) do
    write_mode(path, bytes, maximum, 0o400, sync)
  end

  def write_credential(path, credential, sync \\ &:file.sync/1)

  def write_credential(path, credential, sync)
      when is_binary(credential) and byte_size(credential) == 32,
      do: write_mode(path, Base.url_encode64(credential, padding: false) <> "\n", 44, 0o600, sync)

  def write_credential(_, _, _), do: unavailable()

  def read_credential(path) do
    with {:ok, <<encoded::binary-size(43), "\n">>} <- read_mode(path, 44, 0o600),
         {:ok, credential} <- Base.url_decode64(encoded, padding: false),
         true <-
           byte_size(credential) == 32 and
             Base.url_encode64(credential, padding: false) == encoded do
      {:ok, credential}
    else
      _ -> unavailable()
    end
  end

  defp write_mode(path, bytes, maximum, mode, sync) do
    with true <-
           is_binary(bytes) and is_integer(maximum) and maximum in 1..@maximum and
             byte_size(bytes) in 1..maximum and is_function(sync, 1),
         {:ok, anchors, uid} <- anchors(path),
         {:ok, directory} <- File.open(Path.dirname(path), [:read, :raw, :directory]) do
      try do
        {_, parent} = List.last(anchors)

        with {:ok, opened} <- descriptor(directory),
             true <- identity(parent) == identity(opened),
             :ok <- intact(anchors) do
          publish(path, bytes, maximum, mode, uid, anchors, directory, sync)
        else
          _ -> unavailable()
        end
      after
        File.close(directory)
      end
    else
      _ -> unavailable()
    end
  end

  defp publish(path, bytes, maximum, mode, uid, anchors, directory, sync) do
    temporary =
      Path.join(
        Path.dirname(path),
        ".recovery-custody-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    with :ok <- intact(anchors),
         {:ok, file} <- File.open(temporary, [:write, :binary, :raw, :exclusive]) do
      try do
        case prepare(temporary, file, bytes, mode, uid, anchors, sync) do
          {:ok, created} ->
            result =
              with :ok <- intact(anchors),
                   :ok <- File.ln(temporary, path),
                   :ok <- remove_owned(temporary, created, anchors),
                   :ok <- sync.(directory),
                   {:ok, ^bytes} <- read_mode(path, maximum, mode) do
                :ok
              else
                {:error, :eexist} -> {:error, :private_custody_exists}
                _ -> unavailable()
              end

            if result != :ok and result != {:error, :private_custody_exists},
              do: remove_owned(path, created, anchors)

            result

          _ ->
            unavailable()
        end
      after
        # The exclusive open descriptor identifies only our temporary file.
        case descriptor(file) do
          {:ok, created} -> remove_owned(temporary, created, anchors)
          _ -> :ok
        end

        File.close(file)
      end
    else
      _ -> unavailable()
    end
  end

  defp prepare(path, file, bytes, mode, uid, anchors, sync) do
    with :ok <- File.chmod(path, mode),
         {:ok, before} <- File.lstat(path),
         {:ok, opened} <- descriptor(file),
         true <- identity(before) == identity(opened),
         :ok <- IO.binwrite(file, bytes),
         :ok <- sync.(file),
         {:ok, written} <- descriptor(file),
         {:ok, named} <- File.lstat(path),
         true <- identity(before) == identity(written),
         true <- snapshot(written) == snapshot(named),
         true <-
           private?(written, uid, byte_size(bytes), mode) and written.size == byte_size(bytes),
         :ok <- intact(anchors) do
      {:ok, written}
    else
      _ -> unavailable()
    end
  end

  defp remove_owned(path, stat, anchors) do
    with :ok <- intact(anchors),
         {:ok, named} <- File.lstat(path),
         true <- identity(named) == identity(stat) do
      File.rm(path)
    else
      _ -> unavailable()
    end
  end

  defp anchors(path) do
    with true <-
           is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path,
         true <- byte_size(Path.basename(path)) in 1..255,
         {:ok, anchors} <-
           path
           |> Path.dirname()
           |> Path.split()
           |> Enum.scan(&Path.join(&2, &1))
           |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
             case File.lstat(name) do
               {:ok, %{type: :directory} = stat} -> {:cont, {:ok, acc ++ [{name, stat}]}}
               _ -> {:halt, unavailable()}
             end
           end),
         {_, parent} = List.last(anchors),
         true <- band(parent.mode, 0o777) == 0o700 do
      {:ok, anchors, parent.uid}
    else
      _ -> unavailable()
    end
  end

  defp intact(anchors) do
    if Enum.all?(anchors, fn {path, before} ->
         case File.lstat(path) do
           {:ok, current} -> identity(before) == identity(current)
           _ -> false
         end
       end), do: :ok, else: unavailable()
  end

  defp descriptor(file) do
    with {:ok, info} <- :file.read_file_info(file, time: :universal),
         do: {:ok, File.Stat.from_record(info)}
  end

  defp private?(stat, uid, maximum, mode),
    do:
      stat.type == :regular and stat.links == 1 and stat.uid == uid and
        band(stat.mode, 0o777) == mode and stat.size in 1..maximum

  defp identity(stat),
    do: {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode}

  defp snapshot(stat), do: {identity(stat), stat.links, stat.size, stat.mtime, stat.ctime}
  defp unavailable, do: {:error, :private_custody_unavailable}
end
