defmodule WotexHome.Firmware.DataMount do
  @moduledoc """
  Read-only check of the selected Pi 4 Home data mount at board runtime.

  The built image declares `/data -> root` and mounts the writable F2FS
  application partition at `/root`. This checks that relationship on a running
  board. It does not test persistence across a power cut.
  """

  @max_mountinfo_bytes 262_144

  @spec capture(Path.t(), Path.t()) :: {:ok, map()} | {:error, :data_mount_unavailable}
  def capture(root \\ "/", mountinfo \\ "/proc/self/mountinfo") do
    data = Path.join(root, "data")
    target = Path.join(root, "root")

    with {:ok, %{type: :symlink}} <- File.lstat(data),
         {:ok, "root"} <- File.read_link(data),
         {:ok, %{type: :directory}} <- File.lstat(target),
         {:ok, contents} <- bounded_read(mountinfo),
         {:ok, "f2fs"} <- filesystem(contents, target) do
      {:ok,
       %{
         scope: :read_only_data_mount_probe,
         data_path: data,
         writable_mount: target,
         filesystem: "f2fs"
       }}
    else
      _ -> {:error, :data_mount_unavailable}
    end
  end

  defp bounded_read(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      result = IO.binread(file, @max_mountinfo_bytes + 1)
      File.close(file)

      if is_binary(result) and byte_size(result) <= @max_mountinfo_bytes,
        do: {:ok, result},
        else: {:error, :data_mount_unavailable}
    end
  end

  defp filesystem(contents, target) do
    matches =
      contents
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, " - ", parts: 2) do
          [left, right] ->
            case {String.split(left, " "), String.split(right, " ")} do
              {[_, _, _, _, ^target, mount_options | _], [filesystem, _, super_options | _]} ->
                if "rw" in String.split(mount_options, ",") and
                     "rw" in String.split(super_options, ","),
                   do: [filesystem],
                   else: []

              _ ->
                []
            end

          _ ->
            []
        end
      end)

    case matches do
      [filesystem] -> {:ok, filesystem}
      _ -> {:error, :data_mount_unavailable}
    end
  end
end
