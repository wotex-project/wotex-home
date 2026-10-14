defmodule WotexHome.Schedules.Timezone do
  @moduledoc """
  Reads bounded timezone data from an explicitly selected host zoneinfo root.

  `read/2` checks the selected owner, root/directories, file descriptor and
  unchanged byte custody before returning an immutable TZif value. `source/2`
  requires the source's exact timezone digest; `resolve/3` reports zero, one or
  two UTC instants for an explicit local label without choosing a fold silently.

  Timezone names select inert fixed-root data, not caller endpoints or code.
  The result supports calendar calculation and supplies no clock confidence,
  registration or schedule activation.
  """

  import Bitwise
  alias WotexHome.Schedules.{Codec, TemporalBasis, Tzif}
  @default_root "/usr/share/zoneinfo"

  def read(name, options \\ []) do
    root = Keyword.get(options, :root, @default_root)
    owner = Keyword.get(options, :owner_uid, 0)

    with true <- Codec.zone?(name) and is_binary(root) and Path.type(root) == :absolute,
         true <- Codec.integer?(owner, 0, 4_294_967_295),
         {:ok, root_before} <- File.stat(root, time: :posix),
         true <- safe?(root_before, owner, :directory),
         {:ok, directories} <- directories(root, name, owner),
         path = Path.join(root, name),
         {:ok, before} <- File.stat(path, time: :posix),
         true <- safe?(before, owner, :regular) and before.size in 1..65_536,
         {:ok, bytes} <- read_original(path, before, owner),
         {:ok, root_after} <- File.stat(root, time: :posix),
         true <- seal(root_before) == seal(root_after),
         {:ok, ^directories} <- directories(root, name, owner),
         {:ok, zone} <- Tzif.decode(name, bytes),
         do: {:ok, zone},
         else: (_ -> {:error, :timezone_unavailable})
  rescue
    _ -> {:error, :timezone_unavailable}
  end

  def source(source, options \\ []) do
    with {:ok, _} <- Codec.encode(source) do
      case TemporalBasis.timezone_digest(source) do
        nil ->
          {:ok, nil}

        digest ->
          [_, name | _] = source["trigger"]

          with {:ok, %Tzif{digest: ^digest} = zone} <- read(name, options),
               do: {:ok, zone},
               else: (_ -> {:error, :timezone_basis_changed})
      end
    end
  end

  def resolve(name, label, options \\ []) do
    with true <- is_binary(label) and byte_size(label) == 19,
         {:ok, local} <- NaiveDateTime.from_iso8601(label),
         true <- local.year in 1970..9999 and NaiveDateTime.to_iso8601(local) == label,
         {:ok, zone} <- read(name, options),
         {:ok, instants} <- Tzif.resolve(zone, local),
         true <- length(instants) <= 2 do
      {:ok,
       %{
         name: zone.name,
         digest: zone.digest,
         local_datetime: label,
         instant_count: length(instants),
         first_utc_ms: Enum.at(instants, 0),
         second_utc_ms: Enum.at(instants, 1),
         basis_scope: "calendar_calculation_only"
       }}
    else
      false -> {:error, :invalid_schedule_local_time}
      error -> error
    end
  end

  defp read_original(path, before, owner) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with :ok <- descriptor(file, before, owner),
             {:ok, bytes} when byte_size(bytes) == before.size <- :file.read(file, 65_537),
             :eof <- :file.read(file, 1),
             :ok <- descriptor(file, before, owner),
             {:ok, after_read} <- File.stat(path, time: :posix),
             true <- seal(before) == seal(after_read),
             do: {:ok, bytes},
             else: (_ -> {:error, :timezone_unavailable})
      after
        File.close(file)
      end
    end
  end

  defp directories(root, name, owner) do
    name
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while({:ok, {root, []}}, fn part, {:ok, {parent, seals}} ->
      path = Path.join(parent, part)

      case File.stat(path, time: :posix) do
        {:ok, stat} ->
          if safe?(stat, owner, :directory),
            do: {:cont, {:ok, {path, [{path, seal(stat)} | seals]}}},
            else: {:halt, {:error, :timezone_unavailable}}

        _ ->
          {:halt, {:error, :timezone_unavailable}}
      end
    end)
    |> case do
      {:ok, {_, seals}} -> {:ok, seals}
      error -> error
    end
  end

  defp descriptor(file, before, owner) do
    with {:ok, info} <- :file.read_file_info(file, time: :posix),
         current = File.Stat.from_record(info),
         true <- safe?(current, owner, :regular) and seal(current) == seal(before),
         do: :ok,
         else: (_ -> {:error, :timezone_unavailable})
  end

  defp safe?(stat, owner, type),
    do: stat.type == type and stat.uid == owner and (stat.mode &&& 0o022) == 0

  defp seal(stat),
    do:
      {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode,
       stat.size, stat.mtime, stat.ctime}
end
