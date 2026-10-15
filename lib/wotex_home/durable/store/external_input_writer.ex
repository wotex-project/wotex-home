defmodule WotexHome.Durable.Store.ExternalInputWriter do
  @moduledoc """
  Prepares and retains original-scoped external-input changes for Store.

  Native callers use `WotexHome.Authority.change_external_routine_input/3` and
  `WotexHome.Authority.external_routine_input_status/4`. This collaborator borrows
  Store's connection; it neither owns a transaction nor contacts producers or
  private owners.

  `prepare/3` takes the connection, credential and canonical change document.
  It authenticates current permissions and the submitted target grant before
  original lookup, then checks the retained target grant before returning any
  existing receipt or conflict. Success is `{:ok, :existing, receipt}` or
  `{:ok, :new, principal, input}`; refusal is `{:error, reason}`. Exact replay
  precedes fresh epoch, maintenance, slot, producer, signature and capacity work.
  Changed input under the same original returns `{:error, :external_input_conflict}`.

  `status/4` takes the connection, credential, authority epoch and operation ID.
  It looks up only that actor's original and checks its current target grant,
  returning `{:ok, receipt}`, `:not_found` or `{:error, reason}`. Replay, status
  and input revocation require no live input producer, source or reviewer keys.
  A new revoke still requires an installed slot and current mutable admission.

  `prepare_new/4` returns `{:ok, outcome_document}` or `{:error, reason}` after
  epoch, maintenance and slot checks, with installation revision checked before
  generation. Each new install needs a signed decision object never previously
  installed for that target/key; changing signature text alone cannot refresh it.
  Capacity includes the exact withdrawal footprint of other installed heads and,
  for an install, its own future withdrawal. No reservation row is retained.

  `retain_tx/5` repeats original classification and new-work admission, then
  prepares the original, history, receipt and head inside Store's transaction.
  It returns `{:commit, {:ok, receipt}}` or `{:rollback, reason}`, without
  committing itself. Store separately rebuilds actual current context and checks
  the exact package, programme and signatures before and after tentative install
  work, sharing one deadline; revoke repeats its producer-free mutable guards.
  Store owns final validation and commit/rollback. No retained receipt alone proves
  physical qualification, a physical result or permission to dispatch effects.
  """

  alias WotexHome.{Id, Rules.ExternalInput}
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, ExternalInputs, Journal, MaintenanceWriter}
  alias WotexHome.Rules.{ExternalInputOperation, ExternalInputPackage}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @maximum 9_223_372_036_854_775_807
  @permissions ~w(qualify:profile rule:review read)
  @policy ~w(unauthorized permission_denied invalid_external_input external_input_limit external_input_unavailable unsupported_external_input external_input_conflict external_input_basis_changed external_input_capacity external_input_not_installed stale_external_input_revision stale_external_input_generation stale_authority_epoch maintenance_active target_unavailable revision_exhausted qualification_unavailable invalid_external_input_decision runtime_artifact_unavailable source_retired)a

  @doc false
  def policy?(reason), do: reason in @policy

  @doc "Authenticates submitted and original scopes before classifying immutable replay or new work."
  def prepare(db, credential, document) do
    with {:ok, input} <- ExternalInputOperation.decode(document),
         {:ok, principal} <- actor(db, credential),
         :ok <- grant(db, principal, input["target_id"]),
         :ok <- ExternalInputs.validate_if_current(db),
         {:ok, rows} <- originals(db, principal, input["authority_epoch"], input["operation_id"]) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [[old, outcome, receipt]] ->
          with {:ok, original} <- ExternalInputOperation.validate_original(old, outcome, receipt),
               :ok <- grant(db, principal, original["input"]["target_id"]) do
            if old == document,
              do: {:ok, :existing, original["receipt"]},
              else: {:error, :external_input_conflict}
          end

        _ ->
          corrupt()
      end
    end
  end

  @doc "Reads this actor's retained original without checking producer, source, clock or capacity admission."
  def status(db, credential, epoch, operation) do
    with {:ok, principal} <- actor(db, credential),
         true <- integer?(epoch, 1) and Id.valid?(operation),
         :ok <- ExternalInputs.validate_if_current(db),
         {:ok, rows} <- originals(db, principal, epoch, operation) do
      case rows do
        [] ->
          :not_found

        [[input, outcome, receipt]] ->
          with {:ok, original} <-
                 ExternalInputOperation.validate_original(input, outcome, receipt),
               :ok <- grant(db, principal, original["input"]["target_id"]),
               do: {:ok, original["receipt"]}

        _ ->
          corrupt()
      end
    else
      false -> {:error, :invalid_external_input}
      error -> error
    end
  end

  @doc "Checks new-work counters, fresh-decision admission and the complete prospective reserve."
  def prepare_new(db, principal, input, document) do
    with {:ok, cursor} <- basis(db, principal, input),
         {:ok, outcome} <- outcome(input, cursor),
         :ok <- admission(db, input, cursor, document, outcome),
         do: {:ok, outcome}
  end

  @doc false
  def final_revoke(db, credential, input) do
    with {:ok, principal} <- actor(db, credential),
         :ok <- grant(db, principal, input["target_id"]),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key='authority_epoch'"),
         :ok <- same(epoch, input["authority_epoch"], :stale_authority_epoch),
         do: MaintenanceWriter.guard(db)
  end

  @doc "Retains one original and head inside Store's transaction; final live verification belongs to Store."
  def retain_tx(db, credential, document, outcome_document, boot) do
    with {:ok, :new, principal, input} <- prepare(db, credential, document),
         {:ok, cursor} <- basis(db, principal, input),
         {:ok, ^outcome_document} <- outcome(input, cursor),
         :ok <- admission(db, input, cursor, document, outcome_document),
         {:ok, revision} <- Journal.next_revision(db),
         receipt = %{
           "format" => "wotex-home.external-input-receipt@1",
           "authority_epoch" => input["authority_epoch"],
           "operation_id" => input["operation_id"],
           "target_id" => input["target_id"],
           "capability_key" => input["capability_key"],
           "revision" => revision,
           "generation" => cursor.generation + 1,
           "install_revision" =>
             if(input["action"] == "install", do: revision, else: cursor.install_revision),
           "action" => input["action"],
           "store_boot_epoch" => boot,
           "input_sha256" => ExternalInputOperation.input_sha256(document),
           "outcome_sha256" => ExternalInputOperation.outcome_sha256(outcome_document)
         },
         {:ok, receipt_document} <- ExternalInputOperation.encode_receipt(receipt),
         {:ok, _} <-
           ExternalInputOperation.validate_original(document, outcome_document, receipt_document),
         :ok <- Journal.authority_event(db, revision, event(input["action"]), input["target_id"]),
         {:ok, []} <-
           query(db, "INSERT INTO routine_external_input_operations VALUES (?,?,?,?,?,?,?)", [
             principal,
             input["authority_epoch"],
             input["operation_id"],
             document,
             outcome_document,
             receipt_document,
             revision
           ]),
         {:ok, []} <-
           query(db, "INSERT INTO routine_external_input_history VALUES (?,?,?,?,?,NULL,?)", [
             input["target_id"],
             input["capability_key"],
             revision,
             receipt["generation"],
             input["action"],
             outcome_document
           ]),
         {:ok, []} <-
           query(
             db,
             """
             INSERT INTO routine_external_input_current VALUES (?,?,?,?,?,?)
             ON CONFLICT(target_id,capability_key) DO UPDATE SET
             history_revision=excluded.history_revision,install_revision=excluded.install_revision,
             generation=excluded.generation,state=excluded.state
             """,
             [
               input["target_id"],
               input["capability_key"],
               revision,
               receipt["install_revision"],
               receipt["generation"],
               if(input["action"] == "install", do: "installed", else: "revoked")
             ]
           ),
         do: {:commit, {:ok, receipt}},
         else: (
           {:ok, :existing, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
           {:error, reason} when reason in @policy -> {:rollback, {:policy, reason}}
           {:error, reason} -> {:rollback, reason}
           _ -> {:rollback, :corrupt_external_inputs}
         )
  end

  defp basis(db, principal, input) do
    with :ok <- grant(db, principal, input["target_id"]),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key='authority_epoch'"),
         :ok <- same(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, cursor} <- cursor(db, input["target_id"], input["capability_key"]),
         :ok <-
           same(
             cursor.install_revision,
             input["expected_install_revision"],
             :stale_external_input_revision
           ),
         :ok <-
           same(cursor.generation, input["expected_generation"], :stale_external_input_generation),
         :ok <- desired(input["action"], cursor),
         true <- cursor.generation < @maximum - if(input["action"] == "install", do: 1, else: 0),
         {:ok, _} <- Journal.next_revision(db),
         :ok <- new_decision(db, input),
         do: {:ok, cursor},
         else: (
           false -> {:error, :revision_exhausted}
           error -> error
         )
  end

  defp actor(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         true <- Enum.all?(@permissions, &(&1 in permissions)),
         do: {:ok, principal},
         else: (
           false -> {:error, :permission_denied}
           {:error, :invalid_credential} -> {:error, :unauthorized}
           error -> error
         )
  end

  defp grant(db, principal, target) do
    with {:ok, grants} <- Access.allowed_targets(db, principal),
         true <- MapSet.member?(grants, target),
         do: :ok,
         else: (
           false -> {:error, :permission_denied}
           error -> error
         )
  end

  defp originals(db, principal, epoch, operation),
    do:
      query(
        db,
        "SELECT input_document,outcome_document,receipt_document FROM routine_external_input_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
        [principal, epoch, operation]
      )

  defp cursor(db, target, key) do
    case query(
           db,
           """
           SELECT c.history_revision,c.install_revision,c.generation,c.state,h.outcome_document
           FROM routine_external_input_current c LEFT JOIN routine_external_input_history h ON
             h.target_id=c.target_id AND h.capability_key=c.capability_key AND h.revision=c.history_revision
           WHERE c.target_id=? AND c.capability_key=?
           """,
           [target, key]
         ) do
      {:ok, []} ->
        {:ok, %{revision: 0, install_revision: 0, generation: 0, state: nil, outcome: nil}}

      {:ok, [[revision, install, generation, state, document]]} ->
        with {:ok, outcome} <- ExternalInputOperation.decode_outcome(document),
             do:
               {:ok,
                %{
                  revision: revision,
                  install_revision: install,
                  generation: generation,
                  state: state,
                  outcome: outcome
                }}

      {:error, _} = error ->
        error

      _ ->
        corrupt()
    end
  end

  defp desired("revoke", %{state: "installed"}), do: :ok
  defp desired("revoke", _), do: {:error, :external_input_not_installed}
  defp desired("install", _), do: :ok

  defp new_decision(_db, %{"action" => "revoke"}), do: :ok

  defp new_decision(db, input) do
    with {:ok, package} <- ExternalInputPackage.decode(input["package_document"]),
         decision = package["data"]["signed"]["decision"],
         {:ok, rows} <-
           query(
             db,
             "SELECT h.outcome_document FROM routine_external_input_history h WHERE h.target_id=? AND h.capability_key=? AND h.action='install' ORDER BY h.revision LIMIT 1025",
             [input["target_id"], input["capability_key"]]
           ),
         true <- length(rows) <= 1024 do
      Enum.reduce_while(rows, :ok, fn [document], :ok ->
        with {:ok, old} <- ExternalInputOperation.decode_outcome(document),
             {:ok, old_package} <- ExternalInputPackage.decode(old["package_document"]) do
          if old_package["data"]["signed"]["decision"] == decision,
            do: {:halt, {:error, :qualification_unavailable}},
            else: {:cont, :ok}
        else
          _ -> {:halt, corrupt()}
        end
      end)
    else
      false -> corrupt()
      error -> error
    end
  end

  defp outcome(%{"action" => "install"} = input, _) do
    with {:ok, package} <- ExternalInputPackage.decode(input["package_document"]),
         {:ok, definition} <- ExternalInput.decode(package["data"]["definition_document"]),
         do:
           ExternalInputOperation.encode_outcome(%{
             "format" => "wotex-home.external-input-result@1",
             "action" => "install",
             "target_id" => input["target_id"],
             "capability_key" => input["capability_key"],
             "definition_sha256" => definition["sha256"],
             "package_document" => input["package_document"]
           })
  end

  defp outcome(%{"action" => "revoke"}, cursor),
    do: ExternalInputOperation.encode_outcome(Map.put(cursor.outcome, "action", "revoke"))

  defp admission(db, input, cursor, document, outcome_document) do
    with {:ok, reserve} <-
           ExternalInputs.retirement_reserve(db, {input["target_id"], input["capability_key"]}),
         {:ok, outcome} <- ExternalInputOperation.decode_outcome(outcome_document),
         {:ok, withdrawal} <-
           ExternalInputOperation.encode_outcome(Map.put(outcome, "action", "withdraw")),
         installing = input["action"] == "install",
         do:
           ExternalInputs.capacity(
             db,
             1,
             1 + reserve.history_rows + if(installing, do: 1, else: 0),
             if(cursor.generation == 0, do: 1, else: 0),
             byte_size(document) + 2 * byte_size(outcome_document) + reserve.bytes +
               if(installing, do: byte_size(withdrawal), else: 0)
           )
  end

  defp event("install"), do: "external_input_installed"
  defp event("revoke"), do: "external_input_revoked"
  defp integer?(value, minimum), do: is_integer(value) and value in minimum..@maximum
  defp same(value, value, _reason), do: :ok
  defp same(_, _, reason), do: {:error, reason}
  defp corrupt, do: {:error, :corrupt_external_inputs}
end
