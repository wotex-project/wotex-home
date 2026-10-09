defmodule Woh.Tool.ReleaseNativeBackends do
  @moduledoc false

  def profile(
        os \\ :os.type(),
        architecture \\ to_string(:erlang.system_info(:system_architecture))
      ) do
    case {os, architecture} do
      {{:unix, :darwin}, "aarch64" <> _} -> {:ok, :darwin_arm64}
      {{:unix, :linux}, "aarch64" <> _} -> {:ok, :linux_arm64}
      _ -> {:error, "unsupported Home release platform"}
    end
  end

  def prune(release, profile) when profile in [:darwin_arm64, :linux_arm64] do
    root = Path.expand(release)

    with :ok <- directory(root),
         :ok <- directory(Path.join(root, "lib")),
         [priv] <- Path.wildcard(Path.join(root, "lib/ex_maude-*/priv")),
         :ok <- directory(Path.dirname(priv)),
         :ok <- directory(priv),
         :ok <- directory(Path.join(priv, "maude")),
         :ok <- optional_directory(Path.join(priv, "maude/bin")) do
      case profile do
        :darwin_arm64 ->
          for name <- ~w(maude-darwin-x64 maude-linux-x64) do
            remove_file!(Path.join(priv, "maude/bin/" <> name))
          end

        :linux_arm64 ->
          # This locked dependency has no arm64 Linux Port backend. Remove
          # the unused platform executables and their library tree together;
          # a retained foreign binary cannot serve as a verifier substitute.
          path = Path.join(priv, "maude/bin")

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} -> File.rm_rf!(path)
            {:error, :enoent} -> :ok
            _ -> raise File.Error, reason: :einval, action: "prune native directory", path: path
          end
      end

      remove_file!(Path.join(priv, "maude_bridge"))
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "release has no exact private ExMaude tree"}
    end
  rescue
    error in File.Error -> {:error, "cannot prune native backends: #{Exception.message(error)}"}
  end

  def prune(_release, _profile), do: {:error, "unsupported Home release platform"}

  defp directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _ -> {:error, "release native directory is unavailable or linked"}
    end
  end

  defp optional_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, "release native directory is unavailable or linked"}
    end
  end

  defp remove_file!(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "prune native file", path: path
    end
  end
end
