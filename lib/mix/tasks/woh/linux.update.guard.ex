defmodule Woh.Tool.LinuxUpdateGuard do
  @moduledoc false
  alias Woh.Tool.LinuxUpdateMaintenance.Error
  alias WotexHome.Host.UpdateFence

  @stat_keys ~w(type inode major_device minor_device uid gid links mode size mtime ctime)a

  def configuration(source),
    do: %{
      artifact_id: source.intent["target"]["artifact_id"],
      path: source.ownership.base <> "/update-guard.json"
    }

  def record(journal, intent, state),
    do: %{
      "schema_version" => 1,
      "scope" => "linux_release_update_guard",
      "owner_sha256" => journal["owner_sha256"],
      "artifact_id" => intent["target"]["artifact_id"],
      "authority_epoch" => intent["maintenance"]["authority_epoch"],
      "begin_revision" => intent["maintenance"]["begin_revision"],
      "state" => state
    }

  def exact!(configuration, expected) do
    case read!(configuration) do
      {^expected, bytes} -> bytes
      _ -> refuse!(:update_guard_changed)
    end
  end

  def read!(configuration) do
    case UpdateFence.read(configuration) do
      :absent ->
        :absent

      {:ok, guard} ->
        {:ok, first} = need!(File.lstat(configuration.path))

        {:ok, bytes} =
          need!(File.open(configuration.path, [:read, :binary], &IO.binread(&1, 4097)))

        {:ok, second} = need!(File.lstat(configuration.path))

        ensure!(
          Map.take(first, @stat_keys) == Map.take(second, @stat_keys) and
            UpdateFence.decode(bytes) == {:ok, guard} and
            UpdateFence.read(configuration) == {:ok, guard},
          :update_guard_changed
        )

        {guard, bytes}

      _ ->
        refuse!(:update_guard_unavailable)
    end
  end

  defp need!({:ok, _} = result), do: result
  defp need!(_), do: refuse!(:update_guard_unavailable)
  defp ensure!(true, _), do: :ok
  defp ensure!(_, reason), do: refuse!(reason)
  defp refuse!(reason), do: raise(Error, reason: reason)
end
