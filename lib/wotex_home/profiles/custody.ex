defmodule WotexHome.Profiles.Custody do
  @moduledoc """
  Serialized private custody for inert portable profile bytes.

  The trusted host supplies an existing, absolute, symlink-free 0700 root.
  Every path component is pinned and checked around access. Publication uses
  an exclusively created, synchronized file and a non-replacing hard link;
  the directory is synchronized before success. Files are read-only and are
  verified by descriptor identity, exact digest and a fresh closed parse.

  Finite object/byte/lease quotas include crash orphans. Leases belong to a
  monitored caller. Collection accepts a retained reference snapshot only from
  the trusted configured Store owner and also preserves leases. No active
  pointer, trust approval or Store connection lives here. An actor controlling the host account is
  outside this custody boundary.
  """

  use GenServer
  import Bitwise
  alias WotexHome.Profiles.{Artifact, Codec}

  @max_objects 128
  @max_bytes 4_194_304
  @max_leases 32

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def stage(server, bytes), do: GenServer.call(server, {:stage, bytes})
  def read(server, digest), do: GenServer.call(server, {:read, digest})
  def lease(server, digest), do: GenServer.call(server, {:lease, digest})
  def release(server, token), do: GenServer.call(server, {:release, token})
  def inventory(server), do: GenServer.call(server, :inventory)
  def collect(server, retained), do: GenServer.call(server, {:collect, retained}, 15_000)

  @impl true
  def init(options) do
    root = options[:root]
    objects = Keyword.get(options, :max_objects, @max_objects)
    bytes = Keyword.get(options, :max_bytes, @max_bytes)
    leases = Keyword.get(options, :max_leases, @max_leases)
    store_owner = Keyword.get(options, :store_owner)

    with true <- is_binary(root) and Path.type(root) == :absolute and Path.expand(root) == root,
         true <- is_integer(objects) and objects in 1..@max_objects,
         true <- is_integer(bytes) and bytes in 1..@max_bytes,
         true <- is_integer(leases) and leases in 1..@max_leases,
         true <- is_nil(store_owner) or is_pid(store_owner) or is_atom(store_owner),
         {:ok, anchors} <- anchors(root),
         {_path, root_stat} = List.last(anchors),
         true <- band(root_stat.mode, 0o777) == 0o700,
         :yes <- :global.register_name({__MODULE__, root}, self()),
         {:ok, directory} <- File.open(root, [:read, :raw, :directory]) do
      state = %{
        root: root,
        anchors: anchors,
        directory: directory,
        uid: root_stat.uid,
        max_objects: objects,
        max_bytes: bytes,
        max_leases: leases,
        store_owner: store_owner,
        leases: %{}
      }

      case with(:ok <- recover_publication_links(state), do: usage(state)) do
        {:ok, _} ->
          {:ok, state}

        error ->
          File.close(directory)
          {:stop, elem(error, 1)}
      end
    else
      _ -> {:stop, :invalid_profile_custody}
    end
  end

  @impl true
  def handle_call({:stage, bytes}, _from, state) do
    result =
      with {:ok, artifact} <- Artifact.parse(bytes),
           :ok <- intact(state) do
        publish(state, artifact)
      end

    {:reply, result, state}
  end

  def handle_call({:read, digest}, _from, state),
    do: {:reply, read_artifact(state, digest), state}

  def handle_call(:inventory, _from, state) do
    result =
      with {:ok, usage} <- usage(state) do
        {:ok, Map.put(usage, :lease_count, map_size(state.leases))}
      end

    {:reply, result, state}
  end

  def handle_call({:collect, retained}, {caller, _}, state) do
    result =
      with true <- caller == store_owner(state.store_owner),
           true <-
             is_list(retained) and length(retained) <= 64 and Enum.uniq(retained) == retained and
               Enum.all?(retained, &Codec.digest?/1),
           {:ok, _} <- usage(state),
           protected =
             MapSet.new(retained ++ Enum.map(state.leases, fn {_, lease} -> lease.digest end)),
           {:ok, candidates} <- collection_candidates(state, protected) do
        collect_files(state, candidates)
      else
        false -> {:error, :invalid_profile_collection}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:lease, digest}, {owner, _}, state) do
    if map_size(state.leases) < state.max_leases do
      case read_artifact(state, digest) do
        {:ok, artifact} ->
          token = make_ref()
          monitor = Process.monitor(owner)
          lease = %{owner: owner, monitor: monitor, digest: digest}
          {:reply, {:ok, %{token: token, artifact: artifact}}, put_in(state.leases[token], lease)}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :profile_lease_capacity}, state}
    end
  end

  def handle_call({:release, token}, {owner, _}, state) do
    case state.leases[token] do
      %{owner: ^owner, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | leases: Map.delete(state.leases, token)}}

      _ ->
        {:reply, {:error, :invalid_profile_lease}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    leases = Map.reject(state.leases, fn {_token, lease} -> lease.monitor == monitor end)
    {:noreply, %{state | leases: leases}}
  end

  @impl true
  def terminate(_reason, state), do: File.close(state.directory)

  defp store_owner(nil), do: nil

  defp store_owner(reference) do
    GenServer.whereis(reference)
  rescue
    _ -> nil
  end

  # Preflight the complete bounded namespace before deleting any inert object.
  # Missing retained bytes are not replaced or removed from the reference set.
  defp collection_candidates(state, protected) do
    with :ok <- intact(state), {:ok, names} <- File.ls(state.root) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
        digest = String.trim_trailing(name, ".json")

        if MapSet.member?(protected, digest) do
          {:cont, {:ok, acc}}
        else
          case collection_candidate(state, name) do
            {:ok, candidate} -> {:cont, {:ok, [candidate | acc]}}
            error -> {:halt, error}
          end
        end
      end)
    end
  end

  defp collection_candidate(state, ".stage-" <> _ = name) do
    with true <- valid_name?(name),
         {:ok, %{links: 1} = stat} <- stage_file(state, Path.join(state.root, name)) do
      {:ok, {name, stat}}
    else
      _ -> {:error, :invalid_profile_custody}
    end
  end

  defp collection_candidate(state, name) do
    with true <- valid_name?(name),
         {:ok, stat} <- private_file(state, Path.join(state.root, name)),
         {:ok, bytes} <- read_verified(Path.join(state.root, name), stat),
         true <- Artifact.digest(bytes) == String.trim_trailing(name, ".json"),
         {:ok, _} <- Codec.decode(bytes) do
      {:ok, {name, stat}}
    else
      _ -> {:error, :invalid_profile_custody}
    end
  end

  defp collect_files(state, candidates) do
    Enum.reduce_while(candidates, {:ok, %{removed_objects: 0, removed_bytes: 0}}, fn {name, stat},
                                                                                     {:ok, acc} ->
      with :ok <- intact(state),
           {:ok, current} <- File.lstat(Path.join(state.root, name)),
           true <- same_file?(stat, current),
           :ok <- File.rm(Path.join(state.root, name)) do
        {:cont,
         {:ok,
          %{
            removed_objects: acc.removed_objects + 1,
            removed_bytes: acc.removed_bytes + stat.size
          }}}
      else
        _ -> {:halt, {:error, :profile_collection_failed}}
      end
    end)
    |> case do
      {:ok, removed} ->
        with :ok <- intact(state),
             :ok <- :file.sync(state.directory),
             {:ok, inventory} <- usage(state) do
          {:ok, Map.merge(removed, inventory)}
        else
          _ -> {:error, :profile_collection_failed}
        end

      error ->
        error
    end
  end

  defp publish(state, artifact) do
    destination = path(state, artifact.digest)

    case File.lstat(destination) do
      {:error, :enoent} ->
        with {:ok, usage} <- usage(state),
             true <- usage.object_count < state.max_objects,
             true <- usage.total_bytes + byte_size(artifact.bytes) <= state.max_bytes do
          publish_new(state, artifact, destination)
        else
          false -> {:error, :profile_custody_capacity}
          error -> error
        end

      {:ok, _} ->
        with {:ok, _} <- read_artifact(state, artifact.digest),
             :ok <- :file.sync(state.directory) do
          {:ok, artifact.digest}
        else
          _ -> {:error, :profile_publication_failed}
        end

      _ ->
        {:error, :profile_publication_failed}
    end
  end

  defp publish_new(state, artifact, destination) do
    stage =
      Path.join(
        state.root,
        ".stage-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    result =
      with :ok <- intact(state),
           :ok <- write_synced(stage, artifact.bytes),
           :ok <- intact(state),
           :ok <- File.ln(stage, destination),
           :ok <- File.rm(stage),
           :ok <- :file.sync(state.directory),
           {:ok, _} <- read_artifact(state, artifact.digest) do
        {:ok, artifact.digest}
      else
        _ -> {:error, :profile_publication_failed}
      end

    if intact(state) == :ok, do: File.rm(stage)
    result
  end

  defp write_synced(path, bytes) do
    case File.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(path, 0o400),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file),
               {:ok, info} <- :file.read_file_info(file, time: :universal),
               {:ok, stat} <- File.lstat(path),
               true <- same_file?(stat, File.Stat.from_record(info)) do
            :ok
          else
            _ -> {:error, :profile_publication_failed}
          end
        after
          File.close(file)
        end

      _ ->
        {:error, :profile_publication_failed}
    end
  end

  defp read_artifact(state, digest) do
    with true <- Codec.digest?(digest),
         :ok <- intact(state),
         {:ok, before} <- private_file(state, path(state, digest)),
         {:ok, bytes} <- read_verified(path(state, digest), before),
         :ok <- intact(state),
         true <- Artifact.digest(bytes) == digest,
         {:ok, artifact} <- Artifact.parse(bytes) do
      {:ok, artifact}
    else
      _ -> {:error, :profile_artifact_unavailable}
    end
  end

  defp read_verified(path, before) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          with {:ok, info} <- :file.read_file_info(file, time: :universal),
               true <- same_file?(before, File.Stat.from_record(info)),
               bytes when is_binary(bytes) and byte_size(bytes) == before.size <-
                 IO.binread(file, Codec.max_bytes() + 1),
               {:ok, after_info} <- :file.read_file_info(file, time: :universal),
               {:ok, after_path} <- File.lstat(path),
               true <- same_file?(before, File.Stat.from_record(after_info)),
               true <- same_file?(before, after_path) do
            {:ok, bytes}
          else
            _ -> {:error, :profile_artifact_unavailable}
          end
        after
          File.close(file)
        end

      _ ->
        {:error, :profile_artifact_unavailable}
    end
  end

  defp usage(state) do
    with :ok <- intact(state),
         {:ok, entries} <- File.ls(state.root),
         true <- length(entries) <= state.max_objects do
      Enum.reduce_while(entries, {:ok, %{object_count: 0, total_bytes: 0, digests: []}}, fn name,
                                                                                            {:ok,
                                                                                             acc} ->
        with true <- valid_name?(name),
             {:ok, stat} <- inventory_file(state, name),
             true <- acc.total_bytes + stat.size <= state.max_bytes do
          digests =
            if String.ends_with?(name, ".json"),
              do: [String.trim_trailing(name, ".json") | acc.digests],
              else: acc.digests

          {:cont,
           {:ok,
            %{
              object_count: acc.object_count + 1,
              total_bytes: acc.total_bytes + stat.size,
              digests: digests
            }}}
        else
          _ -> {:halt, {:error, :invalid_profile_custody}}
        end
      end)
      |> case do
        {:ok, usage} ->
          with :ok <- intact(state), do: {:ok, %{usage | digests: Enum.sort(usage.digests)}}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_profile_custody}
    end
  end

  defp private_file(state, path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.uid == state.uid and stat.links == 1,
         true <- band(stat.mode, 0o777) == 0o400 and stat.size in 1..Codec.max_bytes() do
      {:ok, stat}
    else
      _ -> {:error, :profile_artifact_unavailable}
    end
  end

  # A crash between link publication and temporary-name removal retains two
  # names for one complete file. Remove only the verified temporary alias;
  # incomplete single-link stages remain inert and consume the quota.
  defp recover_publication_links(state) do
    with :ok <- intact(state),
         {:ok, names} <- File.ls(state.root),
         true <- length(names) <= state.max_objects + 1 do
      names
      |> Enum.filter(&String.starts_with?(&1, ".stage-"))
      |> Enum.reduce_while(:ok, fn name, :ok ->
        stage = Path.join(state.root, name)

        with true <- valid_name?(name),
             {:ok, stat} <- stage_file(state, stage) do
          case stat.links do
            1 ->
              {:cont, :ok}

            2 ->
              with {:ok, bytes} <- read_verified(stage, stat),
                   destination = path(state, Artifact.digest(bytes)),
                   {:ok, final} <- File.lstat(destination),
                   true <- same_file?(stat, final) and band(final.mode, 0o777) == 0o400,
                   :ok <- intact(state),
                   :ok <- File.rm(stage),
                   :ok <- :file.sync(state.directory) do
                {:cont, :ok}
              else
                _ -> {:halt, {:error, :invalid_profile_custody}}
              end
          end
        else
          _ -> {:halt, {:error, :invalid_profile_custody}}
        end
      end)
    else
      _ -> {:error, :invalid_profile_custody}
    end
  end

  defp inventory_file(state, ".stage-" <> _ = name) do
    with {:ok, %{links: 1} = stat} <- stage_file(state, Path.join(state.root, name)),
         do: {:ok, stat}
  end

  defp inventory_file(state, name), do: private_file(state, Path.join(state.root, name))

  defp stage_file(state, path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.uid == state.uid and stat.links in [1, 2],
         true <- band(stat.mode, 0o111) == 0 and stat.size in 0..Codec.max_bytes() do
      {:ok, stat}
    else
      _ -> {:error, :invalid_profile_custody}
    end
  end

  defp valid_name?(".stage-" <> suffix), do: Regex.match?(~r/\A[0-9a-f]{32}\z/, suffix)

  defp valid_name?(name),
    do: String.ends_with?(name, ".json") and Codec.digest?(String.trim_trailing(name, ".json"))

  defp path(state, digest), do: Path.join(state.root, digest <> ".json")

  defp anchors(root) do
    root
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case File.lstat(path) do
        {:ok, %{type: :directory} = stat} -> {:cont, {:ok, [{path, stat} | acc]}}
        _ -> {:halt, {:error, :invalid_profile_custody}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp intact(state) do
    with true <-
           Enum.all?(state.anchors, fn {path, original} ->
             case File.lstat(path) do
               {:ok, current} -> identity(original) == identity(current)
               _ -> false
             end
           end),
         {_path, root_stat} = List.last(state.anchors),
         {:ok, info} <- :file.read_file_info(state.directory, time: :universal),
         true <- identity(root_stat) == identity(File.Stat.from_record(info)) do
      :ok
    else
      _ -> {:error, :invalid_profile_custody}
    end
  end

  defp identity(stat),
    do: {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode}

  defp same_file?(left, right),
    do:
      identity(left) == identity(right) and left.size == right.size and left.mtime == right.mtime and
        left.ctime == right.ctime
end
