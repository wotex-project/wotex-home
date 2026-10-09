defmodule Woh.Tool.LinuxUpdateMaintenance do
  @moduledoc false
  import Bitwise

  alias Woh.Tool.{
    LinuxInstaller,
    LinuxInstallFiles,
    LinuxInstallMaintenance,
    LinuxServicePackage,
    LinuxUpdateJournal,
    LinuxUpdateProcess,
    LinuxUpdateSelection
  }

  defmodule Error do
    @moduledoc false
    defexception [:reason]
    def message(%{reason: reason}), do: Atom.to_string(reason)
  end

  @stat_keys ~w(type inode major_device minor_device uid gid links mode size mtime ctime)a

  # Internal coordinator segment, with no public CLI or service effects. The
  # default path uses owned installation, actual kernel observations and the
  # service-UID bridge. Overrides exist only for private mechanism fixtures.
  def activate(nonce, credential, options \\ []) do
    try do
      ensure!(credential?(credential), :update_credential_refused)
      context = context!(nonce, options, ~w(staged begin_recorded maintenance_active))
      activate!(context, credential)
    rescue
      error in Error -> {:error, error.reason}
      _ -> {:error, :update_maintenance_unavailable}
    end
  end

  # No begin or other Store mutation is possible through these observation
  # entries. Later stop phases retain source configuration until its byte CAS.
  def inspect_source(nonce, options \\ []) do
    try do
      context = context!(nonce, options, ~w(maintenance_active fenced stopped))
      {:ok, result(context)}
    rescue
      error in Error -> {:error, error.reason}
      _ -> {:error, :update_maintenance_unavailable}
    end
  end

  def observe_active(nonce, credential, options \\ []) do
    try do
      ensure!(credential?(credential), :update_credential_refused)
      context = context!(nonce, options, ~w(maintenance_active fenced))
      active!(context, credential)
    rescue
      error in Error -> {:error, error.reason}
      _ -> {:error, :update_maintenance_unavailable}
    end
  end

  defp context!(nonce, options, phases) do
    inspect = Keyword.get(options, :inspect, &LinuxInstaller.inspect_update/1)
    {:ok, owned} = need!(inspect.(options), :update_ownership_unavailable)
    root = Keyword.get(options, :root, "/")
    base = Path.join(root, "opt/wotex-home")
    ensure!(owned.base == base, :update_ownership_unavailable)
    tool = Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool())

    {:ok, journal, bytes} =
      need!(LinuxUpdateJournal.load(base, owned.owner_bytes, tool), :update_journal_unavailable)

    intent = List.last(journal["updates"])

    ensure!(
      is_map(intent) and intent["nonce"] == nonce and
        intent["phase"] in phases and
        journal["initial_release"] == owned.initial_release,
      :update_phase_refused
    )

    {:ok, process} =
      need!(LinuxUpdateProcess.restore(intent["source_process"]), :update_process_unavailable)

    context = %{
      root: root,
      base: base,
      tool: tool,
      owned: owned,
      journal: journal,
      bytes: bytes,
      intent: intent,
      process: process,
      options: options,
      inspect: inspect,
      observe: Keyword.get(options, :observe, &LinuxUpdateProcess.running/4),
      request: Keyword.get(options, :request, &LinuxInstallMaintenance.request_peer/6),
      persist: Keyword.get(options, :persist, &LinuxUpdateJournal.persist/5)
    }

    recheck!(context)
    context
  end

  defp activate!(%{intent: %{"phase" => "staged"}} = context, credential) do
    status = status!(context, credential)

    {:ok, journal} =
      need!(
        LinuxUpdateJournal.record_begin(context.journal, context.intent["nonce"], status),
        :update_original_basis_refused
      )

    context |> persist!(journal) |> activate!(credential)
  end

  defp activate!(%{intent: %{"phase" => "begin_recorded"}} = context, credential) do
    status = status!(context, credential)
    original_status!(context.intent["maintenance"], status)
    {:ok, commands} = LinuxUpdateJournal.begin_commands(context.journal, context.intent["nonce"])

    receipt =
      case exchange!(context, commands.lookup, credential) do
        {:ok, receipt} ->
          receipt

        :not_found ->
          ensure!(
            status["state"] == "normal" and
              status["store_revision"] == context.intent["maintenance"]["expected_revision"],
            :update_original_basis_refused
          )

          {:ok, receipt} =
            need!(exchange!(context, commands.retry, credential), :update_begin_unresolved)

          receipt
      end

    {:ok, journal} =
      need!(
        LinuxUpdateJournal.accept_begin(context.journal, context.intent["nonce"], receipt),
        :update_receipt_refused
      )

    context |> persist!(journal) |> activate!(credential)
  end

  defp activate!(%{intent: %{"phase" => "maintenance_active"}} = context, credential) do
    active!(context, credential)
  end

  defp active!(context, credential) do
    original = context.intent["maintenance"]
    {:ok, commands} = LinuxUpdateJournal.begin_commands(context.journal, context.intent["nonce"])

    {:ok, receipt} =
      need!(exchange!(context, commands.lookup, credential), :update_begin_unresolved)

    ensure!(
      receipt["principal_id"] == original["principal_id"] and
        receipt["begin_revision"] == original["begin_revision"] and
        receipt["begin_revision"] > original["expected_revision"],
      :update_receipt_refused
    )

    status = status!(context, credential)
    original_status!(original, status)

    ensure!(
      status["state"] == "maintenance" and
        status["begin_revision"] == original["begin_revision"],
      :update_live_barrier_refused
    )

    {:ok, Map.put(result(context), :status, status)}
  end

  defp result(context),
    do: %{
      ownership: context.owned,
      journal: context.journal,
      journal_bytes: context.bytes,
      intent: context.intent,
      process: context.process
    }

  defp persist!(context, journal) do
    recheck!(context)

    {:ok, bytes} =
      need!(
        context.persist.(
          context.base,
          context.owned.owner_bytes,
          journal,
          context.bytes,
          context.tool
        ),
        :update_progress_unresolved
      )

    # Even a successful callback must agree with the actual retained bytes.
    {:ok, ^journal, ^bytes} =
      need!(
        LinuxUpdateJournal.load(context.base, context.owned.owner_bytes, context.tool),
        :update_progress_unresolved
      )

    updated = %{context | journal: journal, bytes: bytes, intent: List.last(journal["updates"])}
    recheck!(updated)
    updated
  end

  defp status!(context, credential) do
    {:ok, status} =
      need!(
        exchange!(context, ["maintenance-update-status"], credential),
        :update_status_unavailable
      )

    ensure!(
      status["store_schema_version"] == 27 and status["writable"] and
        status["update_fence_enabled"],
      :update_compatibility_refused
    )

    status
  end

  defp original_status!(original, status) do
    ensure!(
      status["principal_id"] == original["principal_id"] and
        status["authority_epoch"] == original["authority_epoch"],
      :update_original_basis_refused
    )
  end

  defp exchange!(context, command, credential) do
    recheck!(context)
    observe!(context)
    socket = Path.join(context.root, "var/lib/wotex-home/ipc/home.sock")

    result =
      context.request.(
        context.process.account_id,
        socket,
        command,
        credential,
        context.tool,
        context.process
      )

    # Revalidate typed wire results even when a private fixture supplies them.
    {:ok, request} =
      need!(WotexHome.CLI.build_request(command, credential), :update_credential_refused)

    decoded =
      case result do
        {:ok, value, peer} ->
          need!(LinuxUpdateProcess.join_peer(context.process, peer), :update_peer_refused)

          field =
            if command == ["maintenance-update-status"],
              do: "maintenance_update_status",
              else: "maintenance_receipt"

          need!(
            LinuxInstallMaintenance.decode_response(
              %{"api_version" => 1, "outcome" => "ok", field => value},
              request
            ),
            :update_response_refused
          )

        {:not_found, peer} ->
          need!(LinuxUpdateProcess.join_peer(context.process, peer), :update_peer_refused)

          ensure!(
            request["operation"] == "maintenance_operation_status",
            :update_response_refused
          )

          :not_found

        _ ->
          refuse!(:update_exchange_unresolved)
      end

    observe!(context)
    recheck!(context)
    decoded
  end

  defp observe!(context) do
    {:ok, process} =
      need!(
        context.observe.(
          release(context, context.intent["source"]),
          context.intent["source"],
          context.process.account_id,
          tool: context.tool,
          expected: context.process
        ),
        :update_process_unavailable
      )

    ensure!(process == context.process, :update_process_unavailable)
  end

  defp recheck!(context) do
    {:ok, owned} = need!(context.inspect.(context.options), :update_ownership_unavailable)
    ensure!(owned == context.owned, :update_ownership_unavailable)

    {:ok, journal, bytes} =
      need!(
        LinuxUpdateJournal.load(context.base, context.owned.owner_bytes, context.tool),
        :update_journal_unavailable
      )

    ensure!(journal == context.journal and bytes == context.bytes, :update_progress_unresolved)

    {:ok, selection, _} =
      need!(
        LinuxUpdateSelection.load(context.base, context.owned.owner_bytes, journal, context.tool),
        :update_selection_unavailable
      )

    ensure!(selection["release"] == context.intent["source"], :update_selection_unavailable)

    for identity <- [context.intent["source"], context.intent["target"]] do
      need!(
        LinuxUpdateProcess.image(release(context, identity), identity),
        :update_payload_refused
      )
    end

    {:ok, configuration} =
      need!(
        LinuxServicePackage.configuration_files(
          context.intent["source"]["artifact_id"],
          selection["configuration"]
        ),
        :update_configuration_refused
      )

    for {relative, bytes} <- configuration,
        do: configuration!(Path.join(context.root, relative), bytes)

    :ok
  end

  defp configuration!(path, expected) do
    path
    |> Path.dirname()
    |> Path.split()
    |> Enum.reduce("/", fn component, parent ->
      next = Path.join(parent, component)
      {:ok, info} = need!(File.lstat(next), :update_configuration_refused)

      ensure!(
        info.type == :directory and info.uid == 0 and info.gid == 0 and
          ((info.mode &&& 0o022) == 0 or
             (next != Path.dirname(path) and (info.mode &&& 0o1000) != 0)),
        :update_configuration_refused
      )

      next
    end)

    {:ok, first} = need!(File.lstat(path), :update_configuration_refused)

    ensure!(
      first.type == :regular and first.uid == 0 and first.gid == 0 and first.links == 1 and
        (first.mode &&& 0o7777) == 0o644 and first.size == byte_size(expected),
      :update_configuration_refused
    )

    {:ok, bytes} = need!(File.read(path), :update_configuration_refused)
    {:ok, second} = need!(File.lstat(path), :update_configuration_refused)

    ensure!(
      bytes == expected and Map.take(first, @stat_keys) == Map.take(second, @stat_keys),
      :update_configuration_refused
    )
  end

  defp release(context, identity),
    do: Path.join([context.base, "releases", identity["artifact_id"]])

  defp credential?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == value
      _ -> false
    end
  end

  defp credential?(_), do: false

  defp need!(:ok, _), do: :ok
  defp need!({:ok, _} = result, _), do: result
  defp need!({:ok, _, _} = result, _), do: result
  defp need!(_, reason), do: refuse!(reason)
  defp ensure!(true, _), do: :ok
  defp ensure!(_, reason), do: refuse!(reason)
  defp refuse!(reason), do: raise(Error, reason: reason)
end
