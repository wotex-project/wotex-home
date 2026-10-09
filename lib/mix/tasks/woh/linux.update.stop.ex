defmodule Woh.Tool.LinuxUpdateStop do
  @moduledoc false
  alias Woh.Tool.{
    Command,
    LinuxInstallFiles,
    LinuxInstallHost,
    LinuxUpdateJournal,
    LinuxUpdateMaintenance,
    LinuxUpdateProcess
  }

  alias WotexHome.Host.UpdateFence
  alias LinuxUpdateMaintenance.Error

  @stat_keys ~w(type inode major_device minor_device uid gid links mode size mtime ctime)a

  # Fixed owned-unit stop only. No enablement, unit replacement, restart,
  # selection, maintenance end or fallback. Overrides are private fixtures.
  def run(nonce, credential, options \\ []) do
    try do
      ensure!(credential?(credential), :update_credential_refused)
      stop!(nonce, credential, options)
    rescue
      error in Error -> {:error, error.reason}
      _ -> {:error, :update_stop_unavailable}
    end
  end

  defp stop!(nonce, credential, options) do
    {:ok, source} =
      need!(LinuxUpdateMaintenance.inspect_source(nonce, options), :update_source_unavailable)

    configuration = %{
      artifact_id: source.intent["target"]["artifact_id"],
      path: source.ownership.base <> "/update-guard.json"
    }

    pending = guard(source.journal, source.intent, "pending")
    tool = Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())
    query = Keyword.get(options, :query, &Command.run/4)

    case source.intent["phase"] do
      "maintenance_active" ->
        original = predecessor_guard!(source, configuration, pending)
        running!(source, query)
        active!(source, credential, options)

        unless match?({^pending, _}, original) do
          bytes = JSON.encode!(pending) <> "\n"

          old =
            case original do
              :absent -> nil
              {_, bytes} -> LinuxInstallFiles.digest(bytes)
            end

          write = Keyword.get(options, :guard_write, &LinuxInstallFiles.write/5)

          need!(
            write.(configuration.path, 0o644, bytes, old, tool),
            :update_guard_publication_unresolved
          )
        end

        retained = exact_guard!(configuration, pending)
        active!(source, credential, options)
        ensure!(exact_guard!(configuration, pending) == retained, :update_guard_changed)
        advance!(source, "fenced", options)
        stop!(nonce, credential, options)

      "fenced" ->
        retained = exact_guard!(configuration, pending)

        {:ok, status} =
          need!(LinuxInstallHost.controller_status(query), :update_controller_unavailable)

        case status do
          %{state: :running, pid: pid} when pid == source.process.pid ->
            active!(source, credential, options)
            ensure!(exact_guard!(configuration, pending) == retained, :update_guard_changed)

            need!(
              LinuxInstallHost.stop_controller(pid, Keyword.take(options, [:query, :change])),
              :update_stop_unresolved
            )

          %{state: :stopped, pid: 0} ->
            :ok

          _ ->
            refuse!(:update_controller_changed)
        end

        stopped!(source, configuration, pending, retained, options)
        advance!(source, "stopped", options)
        stop!(nonce, credential, options)

      "stopped" ->
        retained = exact_guard!(configuration, pending)
        stopped!(source, configuration, pending, retained, options)
        {:ok, Map.put(source, :guard, pending)}
    end
  end

  defp active!(source, credential, options) do
    {:ok, active} =
      need!(
        LinuxUpdateMaintenance.observe_active(source.intent["nonce"], credential, options),
        :update_live_barrier_unavailable
      )

    ensure!(Map.delete(active, :status) == source, :update_source_changed)
  end

  defp running!(source, query) do
    {:ok, status} =
      need!(LinuxInstallHost.controller_status(query), :update_controller_unavailable)

    ensure!(status == %{state: :running, pid: source.process.pid}, :update_controller_changed)
  end

  defp stopped!(source, configuration, pending, retained, options) do
    probe = Keyword.get(options, :cgroup_probe, &LinuxUpdateProcess.stopped/1)

    probe_options = [
      query: Keyword.get(options, :query, &Command.run/4),
      tool: Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())
    ]

    need!(probe.(probe_options), :update_cgroup_unavailable)

    {:ok, current} =
      need!(
        LinuxUpdateMaintenance.inspect_source(source.intent["nonce"], options),
        :update_source_unavailable
      )

    ensure!(current == source, :update_source_changed)
    ensure!(exact_guard!(configuration, pending) == retained, :update_guard_changed)
    need!(probe.(probe_options), :update_cgroup_unavailable)
  end

  defp advance!(source, phase, options) do
    {:ok, current} =
      need!(
        LinuxUpdateMaintenance.inspect_source(source.intent["nonce"], options),
        :update_source_unavailable
      )

    ensure!(current == source, :update_source_changed)

    {:ok, journal} =
      need!(
        LinuxUpdateJournal.advance(source.journal, source.intent["nonce"], phase),
        :update_phase_refused
      )

    persist = Keyword.get(options, :persist, &LinuxUpdateJournal.persist/5)

    {:ok, bytes} =
      need!(
        persist.(
          source.ownership.base,
          source.ownership.owner_bytes,
          journal,
          source.journal_bytes,
          Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())
        ),
        :update_progress_unresolved
      )

    {:ok, ^journal, ^bytes} =
      need!(
        LinuxUpdateJournal.load(
          source.ownership.base,
          source.ownership.owner_bytes,
          Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())
        ),
        :update_progress_unresolved
      )
  end

  defp predecessor_guard!(source, configuration, pending) do
    observed = read_guard!(configuration)
    previous = source.journal["updates"] |> Enum.drop(-1) |> List.last()
    expected = if previous, do: guard(source.journal, previous, "complete"), else: :absent

    ensure!(
      (observed == :absent and expected == :absent) or
        match?({^pending, _}, observed) or
        match?({^expected, _}, observed),
      :update_guard_foreign
    )

    observed
  end

  defp exact_guard!(configuration, expected) do
    case read_guard!(configuration) do
      {^expected, bytes} -> bytes
      _ -> refuse!(:update_guard_changed)
    end
  end

  defp read_guard!(configuration) do
    case UpdateFence.read(configuration) do
      :absent ->
        :absent

      {:ok, guard} ->
        {:ok, first} = need!(File.lstat(configuration.path), :update_guard_unavailable)

        {:ok, bytes} =
          need!(
            File.open(configuration.path, [:read, :binary], &IO.binread(&1, 4097)),
            :update_guard_unavailable
          )

        {:ok, second} = need!(File.lstat(configuration.path), :update_guard_unavailable)

        ensure!(
          Map.take(first, @stat_keys) == Map.take(second, @stat_keys),
          :update_guard_changed
        )

        ensure!(
          UpdateFence.decode(bytes) == {:ok, guard} and
            UpdateFence.read(configuration) == {:ok, guard},
          :update_guard_changed
        )

        {guard, bytes}

      _ ->
        refuse!(:update_guard_unavailable)
    end
  end

  defp guard(journal, intent, state),
    do: %{
      "schema_version" => 1,
      "scope" => "linux_release_update_guard",
      "owner_sha256" => journal["owner_sha256"],
      "artifact_id" => intent["target"]["artifact_id"],
      "authority_epoch" => intent["maintenance"]["authority_epoch"],
      "begin_revision" => intent["maintenance"]["begin_revision"],
      "state" => state
    }

  defp credential?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == value
      _ -> false
    end
  end

  defp credential?(_), do: false
  defp need!(:ok, _), do: :ok
  defp need!({:ok, _} = value, _), do: value
  defp need!({:ok, _, _} = value, _), do: value
  defp need!(_, reason), do: refuse!(reason)
  defp ensure!(true, _), do: :ok
  defp ensure!(_, reason), do: refuse!(reason)
  defp refuse!(reason), do: raise(Error, reason: reason)
end
