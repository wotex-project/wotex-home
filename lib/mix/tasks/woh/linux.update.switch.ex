defmodule Woh.Tool.LinuxUpdateSwitch do
  @moduledoc false
  alias Woh.Tool.{
    Command,
    LinuxInstallFiles,
    LinuxInstallHost,
    LinuxServicePackage,
    LinuxUpdateGuard,
    LinuxUpdateJournal,
    LinuxUpdateMaintenance,
    LinuxUpdateProcess,
    LinuxUpdateSelection
  }

  alias LinuxUpdateMaintenance.Error
  @unit "etc/systemd/system/wotex-home.service"

  # Internal, same-schema switch segment. It consumes a retained stopped intent
  # and never ends maintenance, changes enablement, or starts an old fallback.
  def run(nonce, credential, options \\ []) do
    try do
      ensure!(credential?(credential), :update_credential_refused)
      switch!(nonce, credential, options)
    rescue
      error in Error -> {:error, error.reason}
      _ -> {:error, :update_switch_unavailable}
    end
  end

  defp switch!(nonce, credential, options) do
    source = inspect!(nonce, options)
    configuration = LinuxUpdateGuard.configuration(source)
    pending = LinuxUpdateGuard.record(source.journal, source.intent, "pending")
    complete = %{pending | "state" => "complete"}
    {guard, bytes} = guard!(source, configuration, pending, complete)

    case source.intent["phase"] do
      "stopped" ->
        stopped!(source, guard, bytes, options)
        replace_unit!(source, guard, bytes, options)
        stopped!(source, guard, bytes, options)
        host_options = Keyword.take(options, [:change])

        need!(
          LinuxInstallHost.verify_units(Keyword.get(options, :root, "/"), host_options),
          :update_configuration_verification_unresolved
        )

        stopped!(source, guard, bytes, options)
        target_configuration!(source, options)
        need!(LinuxInstallHost.reload(host_options), :update_reload_unresolved)
        effective!(options)
        stopped!(source, guard, bytes, options)
        target_configuration!(source, options)
        advance!(source, "configuration_ready", guard, bytes, options)
        switch!(nonce, credential, options)

      "configuration_ready" ->
        effective!(options)
        query = Keyword.get(options, :query, &Command.run/4)

        {:ok, status} =
          need!(LinuxInstallHost.controller_status(query), :update_controller_unavailable)

        case status do
          %{state: :stopped, pid: 0} ->
            stopped!(source, guard, bytes, options)

            need!(
              LinuxInstallHost.start_controller(Keyword.take(options, [:query, :change])),
              :update_start_unresolved
            )

          %{state: :running} ->
            :ok
        end

        target!(source, credential, guard, bytes, options)
        advance!(source, "target_running", guard, bytes, options)
        switch!(nonce, credential, options)

      "target_running" ->
        target!(source, credential, guard, bytes, options)
        select!(source, credential, guard, bytes, options)
        advance!(source, "selected", guard, bytes, options)
        switch!(nonce, credential, options)

      "selected" ->
        target!(source, credential, guard, bytes, options)

        if guard == pending do
          write = Keyword.get(options, :guard_write, &LinuxInstallFiles.write/5)

          need!(
            write.(
              configuration.path,
              0o644,
              JSON.encode!(complete) <> "\n",
              LinuxInstallFiles.digest(bytes),
              tool(options)
            ),
            :update_guard_publication_unresolved
          )
        end

        completed_bytes = LinuxUpdateGuard.exact!(configuration, complete)
        # An operator may end maintenance after the completed guard is synced.
        # Resume resolves the original receipt under fresh current permission;
        # it never issues an end or creates another begin operation.
        target!(source, credential, complete, completed_bytes, options)
        advance!(source, "complete", complete, completed_bytes, options)
        switch!(nonce, credential, options)

      "complete" ->
        {:ok, target!(source, credential, complete, bytes, options)}
    end
  end

  defp replace_unit!(source, guard, guard_bytes, options) do
    root = Keyword.get(options, :root, "/")
    path = Path.join(root, @unit)
    target = unit(source.intent["target"])
    original = unit(source.intent["source"])
    check!(source, guard, guard_bytes, options)
    {:ok, observed} = need!(File.read(path), :update_configuration_refused)
    ensure!(observed in [original, target], :update_configuration_refused)

    unless observed == target do
      write = Keyword.get(options, :unit_write, &LinuxInstallFiles.write/5)

      need!(
        write.(path, 0o644, target, LinuxInstallFiles.digest(observed), tool(options)),
        :update_unit_publication_unresolved
      )
    end

    target_configuration!(source, options)
    check!(source, guard, guard_bytes, options)
  end

  defp target_configuration!(source, options) do
    ensure!(inspect!(source.intent["nonce"], options) == source, :update_source_changed)

    ensure!(
      File.read(Path.join(Keyword.get(options, :root, "/"), @unit)) ==
        {:ok, unit(source.intent["target"])},
      :update_configuration_refused
    )
  end

  defp unit(identity),
    do: LinuxServicePackage.files(identity["artifact_id"], 2) |> Map.new() |> Map.fetch!(@unit)

  defp select!(source, credential, guard, bytes, options) do
    {:ok, selection, previous} =
      need!(
        LinuxUpdateSelection.load(
          source.ownership.base,
          source.ownership.owner_bytes,
          source.journal,
          tool(options)
        ),
        :update_selection_unavailable
      )

    {:ok, candidate} =
      need!(
        LinuxUpdateSelection.select(selection, source.journal, source.intent["nonce"]),
        :update_selection_unavailable
      )

    target!(source, credential, guard, bytes, options)

    unless candidate == selection do
      persist = Keyword.get(options, :select_persist, &LinuxUpdateSelection.persist/6)

      {:ok, published} =
        need!(
          persist.(
            source.ownership.base,
            source.ownership.owner_bytes,
            source.journal,
            candidate,
            previous,
            tool(options)
          ),
          :update_selection_publication_unresolved
        )

      {:ok, ^candidate, ^published} =
        need!(
          LinuxUpdateSelection.load(
            source.ownership.base,
            source.ownership.owner_bytes,
            source.journal,
            tool(options)
          ),
          :update_selection_publication_unresolved
        )
    end

    target!(source, credential, guard, bytes, options)
  end

  defp target!(source, credential, guard, bytes, options) do
    check!(source, guard, bytes, options)
    effective!(options)

    {:ok, active} =
      need!(
        LinuxUpdateMaintenance.observe_target(source.intent["nonce"], credential, options),
        :update_target_unavailable
      )

    ensure!(
      Map.drop(active, [:status, :target_process, :guard]) == source and active.guard == guard,
      :update_source_changed
    )

    check!(source, guard, bytes, options)
    active
  end

  defp stopped!(source, guard, bytes, options) do
    probe = Keyword.get(options, :cgroup_probe, &LinuxUpdateProcess.stopped/1)
    probe_options = [query: Keyword.get(options, :query, &Command.run/4), tool: tool(options)]
    need!(probe.(probe_options), :update_cgroup_unavailable)
    check!(source, guard, bytes, options)
    need!(probe.(probe_options), :update_cgroup_unavailable)
  end

  defp effective!(options),
    do:
      need!(
        LinuxInstallHost.effective_units(Keyword.get(options, :query, &Command.run/4)),
        :update_effective_configuration_unavailable
      )

  defp check!(source, guard, bytes, options) do
    ensure!(inspect!(source.intent["nonce"], options) == source, :update_source_changed)

    ensure!(
      LinuxUpdateGuard.exact!(LinuxUpdateGuard.configuration(source), guard) == bytes,
      :update_guard_changed
    )
  end

  defp advance!(source, phase, guard, bytes, options) do
    check!(source, guard, bytes, options)

    {:ok, journal} =
      need!(
        LinuxUpdateJournal.advance(source.journal, source.intent["nonce"], phase),
        :update_phase_refused
      )

    persist = Keyword.get(options, :persist, &LinuxUpdateJournal.persist/5)

    {:ok, published} =
      need!(
        persist.(
          source.ownership.base,
          source.ownership.owner_bytes,
          journal,
          source.journal_bytes,
          tool(options)
        ),
        :update_progress_unresolved
      )

    {:ok, ^journal, ^published} =
      need!(
        LinuxUpdateJournal.load(
          source.ownership.base,
          source.ownership.owner_bytes,
          tool(options)
        ),
        :update_progress_unresolved
      )
  end

  defp guard!(source, configuration, pending, complete) do
    observed = LinuxUpdateGuard.read!(configuration)

    allowed =
      if source.intent["phase"] in ~w(selected complete), do: [pending, complete], else: [pending]

    allowed = if source.intent["phase"] == "complete", do: [complete], else: allowed

    case observed do
      {guard, _} -> ensure!(guard in allowed, :update_guard_changed)
      _ -> refuse!(:update_guard_changed)
    end

    observed
  end

  defp inspect!(nonce, options) do
    {:ok, source} =
      need!(LinuxUpdateMaintenance.inspect_switch(nonce, options), :update_source_unavailable)

    source
  end

  defp tool(options), do: Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())

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
