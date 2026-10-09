defmodule Woh.Tool.LinuxInstallFiles do
  @moduledoc false
  alias Woh.Tool.Command

  @source Path.expand("../../../../native/linux", __DIR__)
  @tools ~w(installer-files installer-files.pl bootstrap bootstrap.pl)

  def tools, do: @tools

  def assemble(release) do
    case Path.wildcard(Path.join(release, "lib/wotex_home-*/priv")) do
      [private] ->
        destination = Path.join(private, "linux-install")

        if File.lstat(destination) == {:error, :enoent} do
          File.mkdir!(destination)

          Enum.each(@tools, fn name ->
            source = Path.join(@source, name)
            File.cp!(source, Path.join(destination, name))

            File.chmod!(
              Path.join(destination, name),
              if(String.ends_with?(name, ".pl"), do: 0o644, else: 0o755)
            )
          end)

          :ok
        else
          {:error, "refuse existing Linux installer tools"}
        end

      _ ->
        {:error, "Linux installer tools require one Home payload"}
    end
  rescue
    error in File.Error ->
      {:error, "cannot package Linux installer tools: #{Exception.message(error)}"}
  end

  def write(path, mode, bytes, old \\ nil, tool \\ packaged_tool()) do
    operation = if old, do: "replace", else: "write-new"

    arguments = [
      operation,
      path,
      Integer.to_string(mode, 8),
      digest(bytes),
      Integer.to_string(byte_size(bytes))
    ]

    arguments = if old, do: arguments ++ [old], else: arguments
    run(tool, arguments, bytes)
  end

  def publish(source, destination, owner_bytes, tool \\ packaged_tool()),
    do: run(tool, ["publish", source, destination, digest(owner_bytes)])

  def sync(source, owner_bytes, tool \\ packaged_tool()),
    do: run(tool, ["sync", source, digest(owner_bytes)])

  def mkdir(path, mode, uid, gid, tool \\ packaged_tool()),
    do: run(tool, ["mkdir", path, Integer.to_string(mode, 8), to_string(uid), to_string(gid)])

  def remove(path, mode, expected, tool \\ packaged_tool()),
    do: run(tool, ["remove", path, Integer.to_string(mode, 8), expected])

  def bootstrap(source, manifest, pin, destination, tool \\ packaged_tool()) do
    run(tool, ["copy", source, manifest, pin, destination], nil, 125_000)
  end

  def packaged_tool, do: Application.app_dir(:wotex_home, "priv/linux-install/installer-files")
  def assert_lock(tool \\ packaged_tool()), do: run(tool, ["assert-lock"])

  def execute(path, args, tool \\ packaged_tool()),
    do: Command.run(tool, locked_arguments(["exec", path | args]), 65_536, 60_000)

  def maintenance(uid, socket, frame, tool \\ packaged_tool()) do
    Command.run(
      tool,
      locked_arguments(["maintenance", to_string(uid), socket, to_string(byte_size(frame))]),
      4096,
      20_000,
      [],
      frame
    )
  end

  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp run(tool, arguments, input \\ nil, timeout \\ 120_000) do
    arguments =
      if Path.basename(tool) == "installer-files",
        do: locked_arguments(arguments),
        else: arguments

    case Command.run(tool, arguments, 4096, timeout, [], input) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp locked_arguments(arguments) do
    case {System.get_env("WOTEX_HOME_INSTALL_LOCK_FD"), arguments} do
      {fd, [operation | rest]} when is_binary(fd) ->
        [
          operation,
          "--lock-owner",
          System.pid(),
          fd,
          System.fetch_env!("WOTEX_HOME_INSTALL_LOCK_PATH") | rest
        ]

      _ ->
        arguments
    end
  end
end
