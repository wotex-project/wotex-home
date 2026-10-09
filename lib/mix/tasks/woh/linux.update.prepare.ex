defmodule Woh.Tool.LinuxUpdatePrepare do
  @moduledoc false
  import Bitwise

  alias Woh.Tool.{
    LinuxInstaller,
    LinuxInstallFiles,
    LinuxInstallMaintenance,
    LinuxInstallStage,
    LinuxUpdateGuard,
    LinuxUpdateJournal,
    LinuxUpdateMaintenance,
    LinuxUpdateProcess,
    LinuxUpdateSelection,
    LinuxServicePackage,
    ReleaseBootstrap
  }

  alias LinuxUpdateMaintenance.Error

  # These internal overrides are private fixture seams, never CLI options.
  def plan(release, manifest, pin, credential, options \\ []) do
    safely(fn ->
      credential!(credential)
      context = context!(release, manifest, pin, options)
      last = List.last(context.journal["updates"])
      ensure!(last == nil or last["phase"] in ~w(complete planned), :update_phase_refused)

      if last && last["phase"] == "planned" do
        ensure!(last["target"] == context.target, :update_target_changed)
        ready!(context, credential, restore!(last))
        {:ok, result(context)}
      else
        ensure!(
          context.source["artifact_id"] != context.target["artifact_id"],
          :update_target_unchanged
        )

        ensure!(absent?(destination(context)), :update_target_occupied)
        process = ready!(context, credential)
        context = initialize!(context, credential, process)
        process = ready!(context, credential, process)

        nonce =
          Keyword.get(options, :nonce, fn ->
            Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
          end).()

        ensure!(is_binary(nonce) and nonce =~ ~r/\A[0-9a-f]{64}\z/, :update_nonce_refused)

        ensure!(
          absent?(stage_path(context, nonce)) and absent?(destination(context)),
          :update_target_occupied
        )

        {:ok, journal} =
          need!(
            LinuxUpdateJournal.prepare(
              context.journal,
              nonce,
              context.source,
              context.target,
              process
            ),
            :update_intent_refused
          )

        persist!(context, journal)
        {:ok, result(context!(release, manifest, pin, options))}
      end
    end)
  end

  def stage(nonce, release, manifest, pin, credential, options \\ []) do
    safely(fn ->
      credential!(credential)
      context = context!(release, manifest, pin, options)
      intent = List.last(context.journal["updates"])

      ensure!(
        is_map(intent) and intent["nonce"] == nonce and intent["target"] == context.target and
          intent["phase"] in ~w(planned staged),
        :update_phase_refused
      )

      process = restore!(intent)
      ready!(context, credential, process)

      if intent["phase"] == "staged" do
        need!(
          LinuxUpdateProcess.image(destination(context), context.target),
          :update_payload_refused
        )

        {:ok, result(context)}
      else
        stage!(context, intent, credential, process)
        ready!(context, credential, process)

        need!(
          LinuxUpdateProcess.image(destination(context), context.target),
          :update_payload_refused
        )

        {:ok, journal} =
          need!(
            LinuxUpdateJournal.advance(context.journal, nonce, "staged"),
            :update_phase_refused
          )

        persist!(context, journal)
        {:ok, result(context!(release, manifest, pin, options))}
      end
    end)
  end

  # Read-only view for the coordinator's closed phase dispatch. No missing or
  # malformed record is silently repaired here; only the initial empty records
  # may be represented before their exclusive publication.
  def inspect(release, manifest, pin, options \\ []) do
    safely(fn -> {:ok, context!(release, manifest, pin, options)} end)
  end

  defp context!(release, manifest, pin, options) do
    tool = Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())
    need!(LinuxInstallFiles.assert_lock(tool), :update_lock_unavailable)

    ensure!(
      is_binary(release) and Path.type(release) == :absolute and Path.expand(release) == release,
      :update_payload_refused
    )

    {:ok, manifest_bytes} =
      need!(
        File.open(manifest, [:read, :binary], &IO.binread(&1, 2_097_153)),
        :update_payload_refused
      )

    {:ok, _} =
      need!(LinuxInstallStage.decode_manifest(manifest_bytes, pin), :update_payload_refused)

    {:ok, ^manifest_bytes} = need!(ReleaseBootstrap.render(release), :update_payload_refused)
    {:ok, report} = need!(LinuxServicePackage.verify(release), :update_payload_refused)

    target = %{
      "source_revision" => report["source_revision"],
      "artifact_id" => report["artifact_id"],
      "bootstrap_sha256" => pin,
      "inventory_sha256" =>
        LinuxInstallFiles.digest(File.read!(release <> "/release-inventory.json"))
    }

    need!(LinuxUpdateProcess.image(release, target), :update_payload_refused)
    inspect = Keyword.get(options, :inspect, &LinuxInstaller.inspect_update/1)
    {:ok, owned} = need!(inspect.(options), :update_ownership_unavailable)
    root = Keyword.get(options, :root, "/")
    ensure!(owned.base == Path.join(root, "opt/wotex-home"), :update_ownership_unavailable)

    {:ok, initial} =
      need!(
        LinuxUpdateJournal.new(owned.owner_bytes, owned.initial_release),
        :update_ownership_unavailable
      )

    journal_path = owned.base <> "/.installer/update-journal.json"
    selection_path = owned.base <> "/.installer/current-release.json"

    {journal, journal_bytes} =
      if absent?(journal_path) do
        ensure!(absent?(selection_path), :update_selection_unavailable)
        {initial, nil}
      else
        {:ok, journal, bytes} =
          need!(
            LinuxUpdateJournal.load(owned.base, owned.owner_bytes, tool),
            :update_journal_unavailable
          )

        {journal, bytes}
      end

    ensure!(journal["initial_release"] == owned.initial_release, :update_journal_unavailable)

    {selection, selection_bytes} =
      if absent?(selection_path) do
        ensure!(journal["updates"] == [], :update_selection_unavailable)

        {:ok, selection} =
          need!(
            LinuxUpdateSelection.new(owned.owner_bytes, journal),
            :update_selection_unavailable
          )

        {selection, nil}
      else
        {:ok, selection, bytes} =
          need!(
            LinuxUpdateSelection.load(owned.base, owned.owner_bytes, journal, tool),
            :update_selection_unavailable
          )

        {selection, bytes}
      end

    source = selection["release"]

    need!(
      LinuxUpdateProcess.image(owned.base <> "/releases/" <> source["artifact_id"], source),
      :update_payload_refused
    )

    %{
      root: root,
      tool: tool,
      options: options,
      ownership: owned,
      journal: journal,
      journal_bytes: journal_bytes,
      selection: selection,
      selection_bytes: selection_bytes,
      source: source,
      target: target,
      release: release,
      manifest: manifest,
      manifest_bytes: manifest_bytes,
      pin: pin
    }
  end

  defp ready!(context, credential, expected \\ nil) do
    check!(context)
    guard = predecessor_guard!(context)

    need!(
      LinuxUpdateMaintenance.inspect_configuration(context.root, context.source),
      :update_configuration_refused
    )

    observe = Keyword.get(context.options, :observe, &LinuxUpdateProcess.running/4)
    observe_options = Keyword.put(Keyword.take(context.options, [:query]), :tool, context.tool)

    observe_options =
      if expected, do: Keyword.put(observe_options, :expected, expected), else: observe_options

    uid = JSON.decode!(context.ownership.owner_bytes)["account_id"]
    source = context.ownership.base <> "/releases/" <> context.source["artifact_id"]

    {:ok, process} =
      need!(observe.(source, context.source, uid, observe_options), :update_process_unavailable)

    {:ok, retained} = need!(LinuxUpdateProcess.retain(process), :update_process_unavailable)
    {:ok, ^process} = need!(LinuxUpdateProcess.restore(retained), :update_process_unavailable)

    ensure!(
      process.account_id == uid and (expected == nil or expected == process),
      :update_process_unavailable
    )

    request = Keyword.get(context.options, :request, &LinuxInstallMaintenance.request_peer/6)

    {:ok, status, peer} =
      need!(
        request.(
          uid,
          Path.join(context.root, "var/lib/wotex-home/ipc/home.sock"),
          ["maintenance-update-status"],
          credential,
          context.tool,
          process
        ),
        :update_exchange_unresolved
      )

    need!(LinuxUpdateProcess.join_peer(process, peer), :update_peer_refused)

    {:ok, ^status} =
      need!(
        LinuxInstallMaintenance.decode_response(
          %{"api_version" => 1, "outcome" => "ok", "maintenance_update_status" => status},
          %{"operation" => "maintenance_update_status"}
        ),
        :update_response_refused
      )

    ensure!(
      status["state"] == "normal" and status["store_schema_version"] == 28 and
        status["writable"] and status["update_fence_enabled"],
      :update_compatibility_refused
    )

    {:ok, ^process} =
      need!(
        observe.(source, context.source, uid, Keyword.put(observe_options, :expected, process)),
        :update_process_unavailable
      )

    check!(context)
    ensure!(predecessor_guard!(context) == guard, :update_guard_changed)

    need!(
      LinuxUpdateMaintenance.inspect_configuration(context.root, context.source),
      :update_configuration_refused
    )

    process
  end

  defp predecessor_guard!(context) do
    updates = context.journal["updates"]
    last = List.last(updates)

    previous =
      if last && last["phase"] != "complete",
        do: updates |> Enum.drop(-1) |> List.last(),
        else: last

    expected =
      if previous,
        do: LinuxUpdateGuard.record(context.journal, previous, "complete"),
        else: :absent

    observed =
      LinuxUpdateGuard.read!(%{
        artifact_id: context.source["artifact_id"],
        path: context.ownership.base <> "/update-guard.json"
      })

    ensure!(
      (observed == :absent and expected == :absent) or match?({^expected, _}, observed),
      :update_guard_foreign
    )

    observed
  end

  defp initialize!(context, credential, process) do
    if context.journal_bytes == nil, do: persist!(context, context.journal)
    updated = reload!(context)
    ready!(updated, credential, process)

    if updated.selection_bytes == nil do
      select = Keyword.get(updated.options, :select_persist, &LinuxUpdateSelection.persist/6)

      {:ok, published} =
        need!(
          select.(
            updated.ownership.base,
            updated.ownership.owner_bytes,
            updated.journal,
            updated.selection,
            nil,
            updated.tool
          ),
          :update_selection_publication_unresolved
        )

      {:ok, selection, ^published} =
        need!(
          LinuxUpdateSelection.load(
            updated.ownership.base,
            updated.ownership.owner_bytes,
            updated.journal,
            updated.tool
          ),
          :update_selection_publication_unresolved
        )

      ensure!(selection == updated.selection, :update_selection_publication_unresolved)
    end

    updated = reload!(updated)

    {:ok, journal} =
      need!(LinuxUpdateJournal.upgrade(updated.journal), :update_journal_unavailable)

    if journal != updated.journal do
      ready!(updated, credential, process)
      persist!(updated, journal)
    end

    reload!(updated)
  end

  defp stage!(context, intent, credential, process) do
    stage = stage_path(context, intent["nonce"])
    marker = marker(context, intent)
    destination = destination(context)
    owner_path = context.ownership.base <> "/.installer/owner.json"

    if absent?(destination) do
      create_stage!(context, stage, marker, credential, process)
      {:ok, snapshot} = snapshot(context, stage, marker)

      if not snapshot.complete and not absent?(stage <> "/release") do
        ready!(context, credential, process)

        need!(
          LinuxInstallFiles.remove_stage(
            stage,
            owner_path,
            context.ownership.owner_bytes,
            marker,
            snapshot.sha256,
            context.tool
          ),
          :update_stage_cleanup_unresolved
        )

        create_stage!(context, stage, marker, credential, process)
      end

      if absent?(stage <> "/release") do
        ready!(context, credential, process)
        copy = Keyword.get(context.options, :copy, &LinuxInstallFiles.bootstrap/5)

        need!(
          copy.(
            context.release,
            context.manifest,
            context.pin,
            stage <> "/release",
            context.tool
          ),
          :update_copy_unresolved
        )
      end

      {:ok, snapshot} = snapshot(context, stage, marker)
      ensure!(snapshot.complete, :update_stage_incomplete)

      need!(
        LinuxUpdateProcess.image(stage <> "/release", context.target),
        :update_payload_refused
      )

      ready!(context, credential, process)
      publish = Keyword.get(context.options, :publish, &LinuxInstallFiles.publish_release/8)

      need!(
        publish.(
          stage <> "/release",
          destination,
          owner_path,
          context.ownership.owner_bytes,
          marker,
          snapshot.sha256,
          context.target["inventory_sha256"],
          context.tool
        ),
        :update_publication_unresolved
      )
    else
      # A successful rename cannot leave another release in its original stage.
      # Preserve an occupied destination and duplicate/foreign stage on ambiguity.
      need!(LinuxUpdateProcess.image(destination, context.target), :update_target_occupied)

      unless absent?(stage) do
        {:ok, snapshot} = snapshot(context, stage, marker)
        ensure!(snapshot.files == 1 and snapshot.directories == 1, :update_stage_ambiguous)
      end
    end

    ready!(context, credential, process)
    need!(LinuxUpdateProcess.image(destination, context.target), :update_payload_refused)
    sync = Keyword.get(context.options, :sync, &LinuxInstallFiles.sync_release/5)

    need!(
      sync.(
        destination,
        owner_path,
        context.ownership.owner_bytes,
        context.target["inventory_sha256"],
        context.tool
      ),
      :update_sync_unresolved
    )

    unless absent?(stage) do
      {:ok, snapshot} = snapshot(context, stage, marker)
      ensure!(snapshot.files == 1 and snapshot.directories == 1, :update_stage_ambiguous)
      ready!(context, credential, process)
      cleanup = Keyword.get(context.options, :cleanup, &LinuxInstallFiles.remove_stage/6)

      need!(
        cleanup.(
          stage,
          owner_path,
          context.ownership.owner_bytes,
          marker,
          snapshot.sha256,
          context.tool
        ),
        :update_stage_cleanup_unresolved
      )
    end
  end

  defp create_stage!(context, stage, marker, credential, process) do
    ready!(context, credential, process)

    if absent?(stage),
      do:
        need!(
          LinuxInstallFiles.mkdir(stage, 0o700, 0, 0, context.tool),
          :update_stage_creation_unresolved
        )

    {:ok, info} = need!(File.lstat(stage), :update_stage_refused)

    ensure!(
      info.type == :directory and info.uid == 0 and info.gid == 0 and
        (info.mode &&& 0o7777) == 0o700,
      :update_stage_refused
    )

    if absent?(stage <> "/stage.json") do
      ensure!(File.ls(stage) == {:ok, []}, :update_stage_refused)

      need!(
        LinuxInstallFiles.write(stage <> "/stage.json", 0o600, marker, nil, context.tool),
        :update_stage_creation_unresolved
      )
    end

    {:ok, _} = snapshot(context, stage, marker)
  end

  defp snapshot(context, stage, marker),
    do:
      need!(
        LinuxInstallStage.snapshot(
          stage,
          marker,
          context.manifest_bytes,
          context.pin,
          context.release
        ),
        :update_stage_refused
      )

  defp marker(context, intent),
    do:
      JSON.encode!(%{
        "schema_version" => 1,
        "scope" => "linux_release_update_stage",
        "owner_sha256" => context.journal["owner_sha256"],
        "nonce" => intent["nonce"],
        "source" => intent["source"],
        "target" => intent["target"],
        "source_process" => intent["source_process"]
      }) <> "\n"

  defp check!(context), do: ensure!(reload!(context) == context, :update_progress_unresolved)

  defp reload!(context),
    do: context!(context.release, context.manifest, context.pin, context.options)

  defp persist!(context, journal) do
    check!(context)
    persist = Keyword.get(context.options, :persist, &LinuxUpdateJournal.persist/5)

    {:ok, bytes} =
      need!(
        persist.(
          context.ownership.base,
          context.ownership.owner_bytes,
          journal,
          context.journal_bytes,
          context.tool
        ),
        :update_progress_unresolved
      )

    {:ok, ^journal, ^bytes} =
      need!(
        LinuxUpdateJournal.load(
          context.ownership.base,
          context.ownership.owner_bytes,
          context.tool
        ),
        :update_progress_unresolved
      )
  end

  defp result(context) do
    intent = List.last(context.journal["updates"])

    %{
      ownership: context.ownership,
      journal: context.journal,
      journal_bytes: context.journal_bytes,
      intent: intent,
      process: restore!(intent)
    }
  end

  defp restore!(intent) do
    {:ok, process} =
      need!(LinuxUpdateProcess.restore(intent["source_process"]), :update_process_unavailable)

    process
  end

  defp destination(context),
    do: context.ownership.base <> "/releases/" <> context.target["artifact_id"]

  defp stage_path(context, nonce),
    do: context.ownership.base <> "/.installer/update-stage-" <> nonce

  defp absent?(path), do: File.lstat(path) == {:error, :enoent}

  defp credential!(value) do
    ensure!(
      is_binary(value) and byte_size(value) == 43 and
        case Base.url_decode64(value, padding: false) do
          {:ok, bytes} ->
            byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == value

          _ ->
            false
        end,
      :update_credential_refused
    )
  end

  defp safely(fun) do
    fun.()
  rescue
    error in Error -> {:error, error.reason}
    _ -> {:error, :update_preparation_unavailable}
  end

  defp need!(:ok, _), do: :ok
  defp need!({:ok, _} = value, _), do: value
  defp need!({:ok, _, _} = value, _), do: value
  defp need!(_, reason), do: raise(Error, reason: reason)
  defp ensure!(true, _), do: :ok
  defp ensure!(_, reason), do: raise(Error, reason: reason)
end
