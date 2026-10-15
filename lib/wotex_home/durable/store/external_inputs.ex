defmodule WotexHome.Durable.Store.ExternalInputs do
  @moduledoc """
  Defines and checks retained external-input operations, slot history and heads.

  `schema/0` returns the three tables' DDL as a string; it executes no SQL.
  `tables/0` returns a map from each table name to its ordered column names.
  This foundation does not apply a migration or install an input. The live Store
  schema remains 37; installation, migration and recovery integration are separate.

  `validate/1` borrows Store's SQLite connection and returns `:ok` or
  `{:error, :corrupt_external_inputs}` for a detected mismatch or query failure.
  It checks table definitions and indexes, retained capacity, immutable original
  documents, per-slot generation and installation history, matching journal
  events and withdrawal causes, and exact latest heads. Referenced principals
  and targets must exist. The required tables and surrounding Store relations
  must already be present; this function neither repairs nor creates them.

  `capacity/5` takes the connection followed by prospective additions to operation
  count, history count, slot count and retained input/outcome bytes. Each addition
  must be a nonnegative signed-64 integer. It returns `:ok` when existing totals
  plus additions fit the inclusive limits: 1024 operations, 4096 history rows,
  1024 slots and 16,777,216 bytes. Invalid additions or exceeded limits return
  `{:error, :external_input_capacity}`; SQL query errors propagate. This check
  reserves nothing and evicts nothing.

  Store retains connection ownership and must provide a consistent transaction
  or snapshot for these reads. No helper opens or closes the borrowed connection.
  Historical validation uses retained package correspondence without a current
  producer, reviewer keys, programme file, live source or private artifact.
  A retained `"installed"` head is historical database state, not proof of current
  source authority. Store still owns authentication, current admission and all
  writes; these helpers establish no current qualification or dispatch permission.
  """

  alias WotexHome.{Id, Rules.ExternalInput}
  alias WotexHome.NativeSetup.TargetCodec
  alias WotexHome.Rules.{ExternalInputOperation, ExternalInputPackage}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @maximum 9_223_372_036_854_775_807
  @operations ~w(principal_id authority_epoch operation_id input_document outcome_document receipt_document revision)
  @history ~w(target_id capability_key revision generation action cause_revision outcome_document)
  @current ~w(target_id capability_key history_revision install_revision generation state)
  @tables %{
    "routine_external_input_operations" => @operations,
    "routine_external_input_history" => @history,
    "routine_external_input_current" => @current
  }
  @ddl [
    {"routine_external_input_operations",
     """
     CREATE TABLE routine_external_input_operations (
       principal_id TEXT NOT NULL REFERENCES principals(principal_id),
       authority_epoch INTEGER NOT NULL CHECK (typeof(authority_epoch)='integer' AND authority_epoch>0),
       operation_id TEXT NOT NULL,
       input_document TEXT NOT NULL CHECK (typeof(input_document)='text' AND length(CAST(input_document AS BLOB)) BETWEEN 1 AND 524288),
       outcome_document TEXT NOT NULL CHECK (typeof(outcome_document)='text' AND length(CAST(outcome_document AS BLOB)) BETWEEN 1 AND 524288),
       receipt_document TEXT NOT NULL CHECK (typeof(receipt_document)='text' AND length(CAST(receipt_document AS BLOB)) BETWEEN 1 AND 4096),
       revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision) CHECK (typeof(revision)='integer' AND revision>0),
       PRIMARY KEY (principal_id,authority_epoch,operation_id)
     );
     """},
    {"routine_external_input_history",
     """
     CREATE TABLE routine_external_input_history (
       target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
       capability_key TEXT NOT NULL,
       revision INTEGER NOT NULL PRIMARY KEY REFERENCES authority_journal(revision) CHECK (typeof(revision)='integer' AND revision>0),
       generation INTEGER NOT NULL CHECK (typeof(generation)='integer' AND generation>0),
       action TEXT NOT NULL CHECK (action IN ('install','revoke','withdraw')),
       cause_revision INTEGER REFERENCES authority_journal(revision),
       outcome_document TEXT NOT NULL CHECK (typeof(outcome_document)='text' AND length(CAST(outcome_document AS BLOB)) BETWEEN 1 AND 524288),
       CHECK ((action IN ('install','revoke') AND cause_revision IS NULL) OR
         (action='withdraw' AND cause_revision IS NOT NULL AND typeof(cause_revision)='integer' AND cause_revision>0 AND cause_revision<revision)),
       UNIQUE (target_id,capability_key,generation),
       UNIQUE (target_id,capability_key,revision)
     );
     """},
    {"routine_external_input_current",
     """
     CREATE TABLE routine_external_input_current (
       target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
       capability_key TEXT NOT NULL,
       history_revision INTEGER NOT NULL CHECK (typeof(history_revision)='integer' AND history_revision>0),
       install_revision INTEGER NOT NULL CHECK (typeof(install_revision)='integer' AND install_revision>0 AND install_revision<=history_revision),
       generation INTEGER NOT NULL CHECK (typeof(generation)='integer' AND generation>0),
       state TEXT NOT NULL CHECK (state IN ('installed','revoked')),
       CHECK ((state='installed' AND history_revision=install_revision) OR
         (state='revoked' AND history_revision>install_revision)),
       PRIMARY KEY (target_id,capability_key),
       FOREIGN KEY (target_id,capability_key,history_revision)
         REFERENCES routine_external_input_history(target_id,capability_key,revision),
       FOREIGN KEY (target_id,capability_key,install_revision)
         REFERENCES routine_external_input_history(target_id,capability_key,revision)
     );
     """}
  ]
  @indexes %{
    "routine_external_input_operations" => [
      {"pk", @operations |> Enum.take(3)},
      {"u", ["revision"]}
    ],
    "routine_external_input_history" => [
      {"u", ~w(target_id capability_key generation)},
      {"u", ~w(target_id capability_key revision)}
    ],
    "routine_external_input_current" => [{"pk", ~w(target_id capability_key)}]
  }
  @events ~w(external_input_installed external_input_revoked external_input_withdrawn)
  @target_losses ~w(external_target_selected external_target_revoked external_target_dependency_revoked thing_narrowed thing_revoked thing_enrollment_rereviewed)
  @global_losses ~w(external_profile_approved external_profile_revoked controller_source_retired controller_destination_accepted)

  def schema, do: Enum.map_join(@ddl, "\n", &elem(&1, 1))
  def tables, do: @tables

  def validate(db) do
    with :ok <- schema_matches(db),
         {:ok, [[maximum, epoch]]} <- meta(db),
         true <- integer?(maximum, 0) and integer?(epoch, 1),
         :ok <- capacity(db, 0, 0, 0, 0),
         {:ok, rows} <- rows(db, "routine_external_input_operations", "revision", 1025),
         {:ok, operations} <- operations(db, rows, maximum, epoch),
         {:ok, history} <- rows(db, "routine_external_input_history", "revision", 4097),
         {:ok, latest, used} <- history(db, history, operations, maximum),
         true <- used == MapSet.new(Map.keys(operations)),
         :ok <- heads(db, latest, maximum),
         {:ok, events} <-
           query(
             db,
             "SELECT revision FROM authority_journal WHERE event_type IN ('external_input_installed','external_input_revoked','external_input_withdrawn') ORDER BY revision LIMIT 4097"
           ),
         true <- events == Enum.map(history, &[Enum.at(&1, 2)]),
         do: :ok,
         else: (_ -> corrupt())
  end

  def capacity(db, operations, history, slots, bytes) do
    with true <- Enum.all?([operations, history, slots, bytes], &integer?(&1, 0)),
         {:ok, [[o, h, s, b]]} <-
           query(db, """
           SELECT
             (SELECT COUNT(*) FROM routine_external_input_operations),
             (SELECT COUNT(*) FROM routine_external_input_history),
             (SELECT COUNT(*) FROM routine_external_input_current),
             (SELECT COALESCE(SUM(length(CAST(input_document AS BLOB))+length(CAST(outcome_document AS BLOB))),0) FROM routine_external_input_operations) +
             (SELECT COALESCE(SUM(length(CAST(outcome_document AS BLOB))),0) FROM routine_external_input_history)
           """),
         true <-
           o + operations <= 1024 and h + history <= 4096 and s + slots <= 1024 and
             b + bytes <= 16_777_216,
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> {:error, :external_input_capacity}
         )
  end

  defp schema_matches(db) do
    Enum.reduce_while(@ddl, :ok, fn {table, ddl}, :ok ->
      with {:ok, [["table", ^table, actual]]} <-
             query(
               db,
               "SELECT type,name,sql FROM sqlite_master WHERE tbl_name=? AND name NOT GLOB 'sqlite_*' ORDER BY type,name",
               [table]
             ),
           true <- normalized(actual) == normalized(ddl),
           {:ok, indexes} <- query(db, "PRAGMA index_list(#{table})"),
           {:ok, indexes} <- index_columns(db, indexes),
           true <- Enum.sort(indexes) == Enum.sort(@indexes[table]),
           do: {:cont, :ok},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp index_columns(db, indexes) do
    Enum.reduce_while(indexes, {:ok, []}, fn
      [_, name, 1, origin, 0], {:ok, acc} when origin in ["pk", "u"] ->
        with true <-
               Regex.match?(~r/\Asqlite_autoindex_routine_external_input_[a-z_]+_[0-9]+\z/, name),
             {:ok, info} <- query(db, "PRAGMA index_info(#{name})"),
             do: {:cont, {:ok, [{origin, Enum.map(info, &Enum.at(&1, 2))} | acc]}},
             else: (_ -> {:halt, corrupt()})

      _, _ ->
        {:halt, corrupt()}
    end)
  end

  defp operations(db, rows, maximum, epoch) do
    Enum.reduce_while(rows, {:ok, %{}}, fn [p, e, id, input, outcome, receipt, rev], {:ok, acc} ->
      with true <-
             Id.valid?(p) and integer?(e, 1) and e <= epoch and integer?(rev, 1) and
               rev <= maximum,
           {:ok, original} <- ExternalInputOperation.validate_original(input, outcome, receipt),
           i = original["input"],
           r = original["receipt"],
           true <- i["authority_epoch"] == e and i["operation_id"] == id and r["revision"] == rev,
           {:ok, [[^p]]} <-
             query(db, "SELECT principal_id FROM principals WHERE principal_id=?", [p]),
           do:
             {:cont,
              {:ok, Map.put(acc, rev, %{original: original, document: outcome, principal: p})}},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp history(db, rows, operations, maximum) do
    Enum.reduce_while(rows, {:ok, %{}, MapSet.new()}, fn [
                                                           target,
                                                           key,
                                                           rev,
                                                           gen,
                                                           action,
                                                           cause,
                                                           doc
                                                         ],
                                                         {:ok, latest, used} ->
      previous = latest[{target, key}]

      with true <-
             Id.valid?(target) and Id.valid?(key) and integer?(rev, 1) and rev <= maximum and
               integer?(gen, 1) and gen == if(previous, do: previous.generation + 1, else: 1),
           {:ok, outcome} <- ExternalInputOperation.decode_outcome(doc),
           true <-
             outcome["target_id"] == target and outcome["capability_key"] == key and
               outcome["action"] == action,
           {:ok, [[event, ^target]]} <-
             query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
               rev
             ]),
           true <- event == event(action),
           :ok <- losses(db, previous, action, cause, rev),
           {:ok, installation} <-
             transition(previous, operations[rev], action, cause, doc, rev, gen),
           {:ok, context} <- context(outcome),
           :ok <- authors(db, installation.principal, context),
           record = %{
             revision: rev,
             generation: gen,
             state: if(action == "install", do: "installed", else: "revoked"),
             install_revision: installation.revision,
             installer: installation.principal,
             outcome: outcome,
             context: context
           },
           do:
             {:cont,
              {:ok, Map.put(latest, {target, key}, record),
               if(action == "withdraw", do: used, else: MapSet.put(used, rev))}},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp transition(previous, nil, "withdraw", cause, doc, _rev, _gen) when is_integer(cause) do
    with %{state: "installed"} <- previous,
         {:ok, outcome} <- ExternalInputOperation.decode_outcome(doc),
         true <- outcome == Map.put(previous.outcome, "action", "withdraw"),
         do: {:ok, %{revision: previous.install_revision, principal: previous.installer}},
         else: (_ -> corrupt())
  end

  defp transition(previous, op, action, nil, doc, rev, gen)
       when is_map(op) and action in ["install", "revoke"] do
    i = op.original["input"]
    r = op.original["receipt"]
    install = if action == "install", do: rev, else: previous && previous.install_revision

    with true <- op.document == doc and i["action"] == action,
         true <-
           i["expected_install_revision"] == if(previous, do: previous.install_revision, else: 0) and
             i["expected_generation"] == if(previous, do: previous.generation, else: 0),
         true <- r["generation"] == gen and r["install_revision"] == install,
         true <-
           action == "install" or
             (previous != nil and previous.state == "installed" and
                op.original["outcome"] == Map.put(previous.outcome, "action", "revoke")),
         do:
           {:ok,
            %{
              revision: install,
              principal: if(action == "install", do: op.principal, else: previous.installer)
            }},
         else: (_ -> corrupt())
  end

  defp transition(_, _, _, _, _, _, _), do: corrupt()

  defp heads(db, latest, maximum) do
    with {:ok, rows} <-
           rows(db, "routine_external_input_current", "target_id,capability_key", 1025),
         true <- length(rows) == map_size(latest) do
      Enum.reduce_while(rows, :ok, fn [target, key, rev, install, gen, state], :ok ->
        with h when is_map(h) <- latest[{target, key}],
             true <-
               [rev, install, gen, state] ==
                 [h.revision, h.install_revision, h.generation, h.state],
             {:ok, [[^target]]} <-
               query(db, "SELECT thing_id FROM enrolled_things WHERE thing_id=?", [target]),
             :ok <- losses(db, h, "current", nil, maximum),
             do: {:cont, :ok},
             else: (_ -> {:halt, corrupt()})
      end)
    else
      _ -> corrupt()
    end
  end

  defp losses(_, nil, _, _, _), do: :ok
  defp losses(_, %{state: "revoked"}, _, _, _), do: :ok

  defp losses(db, previous, action, cause, upper) do
    c = previous.context
    people = Enum.uniq([previous.installer, c["selection_author"], c["trust_author"]])
    target = c["target_id"]

    with {:ok, rows} <-
           query(
             db,
             """
             SELECT a.revision,a.event_type,a.entity_id,n.principal_id,n.receipt_document
             FROM authority_journal a
             LEFT JOIN native_target_operations n ON
               a.event_type='native_target_revoked' AND a.revision=n.revision AND n.action='revoke' AND
               a.entity_id=n.principal_id||'/'||n.authority_epoch||'/'||n.operation_id
             WHERE a.revision>? AND a.revision<=? AND a.event_type IN
               ('external_target_selected','external_target_revoked','external_target_dependency_revoked',
                'thing_narrowed','thing_revoked','thing_enrollment_rereviewed',
                'external_profile_approved','external_profile_revoked','principal_revoked','target_grant_revoked',
                'native_target_revoked','controller_source_retired','controller_destination_accepted')
             ORDER BY a.revision
             """,
             [previous.revision, upper]
           ),
         {:ok, loss} <- first_loss(rows, people, target),
         true <-
           if(action == "withdraw", do: loss != nil and loss == cause, else: loss == nil),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp first_loss(rows, people, target) do
    Enum.reduce_while(rows, {:ok, nil}, fn [revision, event, entity, principal, receipt], _ ->
      result =
        if event == "native_target_revoked" do
          with {:ok, r} <- TargetCodec.decode("receipt", receipt),
               true <-
                 r["principal_id"] == principal and r["action"] == "revoke" and
                   r["change_revision"] == revision and
                   entity == "#{principal}/#{r["authority_epoch"]}/#{r["operation_id"]}",
               do: {:ok, principal in people and r["target_id"] == target},
               else: (_ -> corrupt())
        else
          {:ok,
           (event in @target_losses and entity == target) or event in @global_losses or
             (event == "principal_revoked" and entity in people) or
             (event == "target_grant_revoked" and
                entity in Enum.map(people, &(&1 <> "/" <> target)))}
        end

      case result do
        {:ok, true} -> {:halt, {:ok, revision}}
        {:ok, false} -> {:cont, {:ok, nil}}
        error -> {:halt, error}
      end
    end)
  end

  defp authors(db, installer, c) do
    people = Enum.uniq([installer, c["selection_author"], c["trust_author"]])

    with {:ok, rows} <-
           query(db, "SELECT principal_id FROM principals WHERE principal_id IN (?,?,?)", [
             installer,
             c["selection_author"],
             c["trust_author"]
           ]),
         true <- Enum.sort(List.flatten(rows)) == Enum.sort(people),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp context(outcome) do
    with {:ok, p} <- ExternalInputPackage.decode(outcome["package_document"]),
         {:ok, d} <- ExternalInput.decode(p["data"]["definition_document"]),
         do: {:ok, d["data"]["context"]}
  end

  defp rows(db, table, order, limit),
    do:
      query(
        db,
        "SELECT #{Enum.join(@tables[table], ",")} FROM #{table} ORDER BY #{order} LIMIT #{limit}"
      )

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp normalized(sql),
    do: sql |> String.replace(~r/\s+/, " ") |> String.trim() |> String.trim_trailing(";")

  defp event("install"), do: Enum.at(@events, 0)
  defp event("revoke"), do: Enum.at(@events, 1)
  defp event("withdraw"), do: Enum.at(@events, 2)
  defp event(_), do: nil
  defp integer?(n, min), do: is_integer(n) and n in min..@maximum
  defp corrupt, do: {:error, :corrupt_external_inputs}
end
