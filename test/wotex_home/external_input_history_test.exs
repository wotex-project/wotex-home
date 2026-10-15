defmodule WotexHome.ExternalInputHistoryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.{ExternalInputs, Integrity, Journal, Schema, SQL}
  alias WotexHome.NativeSetup.TargetCodec
  alias WotexHome.Profiles.DocumentChunks
  alias WotexHome.Rules.{ExternalInput, ExternalInputPackage}
  alias WotexHome.Rules.ExternalInputOperation, as: Operation

  setup do
    {:ok, db} = Sqlite3.open(":memory:")
    on_exit(fn -> Sqlite3.close(db) end)
    :ok = Sqlite3.execute(db, "PRAGMA foreign_keys=ON")
    :ok = Schema.initialize(db, &Integrity.validate_schema_version/2)
    v = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    %{db: db, v: v}
  end

  test "fresh successor tables expose exact SQL keys without authority", c do
    assert :ok = ExternalInputs.validate(c.db)
    assert {:ok, [[38]]} = SQL.query(c.db, "PRAGMA user_version")
    assert :ok = Integrity.validate_snapshot(c.db)

    assert ExternalInputs.tables() == %{
             "routine_external_input_operations" =>
               ~w(principal_id authority_epoch operation_id input_document outcome_document receipt_document revision),
             "routine_external_input_history" =>
               ~w(target_id capability_key revision generation action cause_revision outcome_document),
             "routine_external_input_current" =>
               ~w(target_id capability_key history_revision install_revision generation state)
           }

    assert {:ok, foreign_keys} =
             SQL.query(c.db, "PRAGMA foreign_key_list(routine_external_input_current)")

    assert Enum.sort(Enum.map(foreign_keys, &Enum.slice(&1, 2, 3))) ==
             Enum.sort([
               ["enrolled_things", "target_id", "thing_id"],
               ["routine_external_input_history", "target_id", "target_id"],
               ["routine_external_input_history", "capability_key", "capability_key"],
               ["routine_external_input_history", "history_revision", "revision"],
               ["routine_external_input_history", "target_id", "target_id"],
               ["routine_external_input_history", "capability_key", "capability_key"],
               ["routine_external_input_history", "install_revision", "revision"]
             ])
  end

  test "frozen original advances through revoke, reinstall and cause-owned withdrawal", c do
    seed(c)
    assert :ok = ExternalInputs.validate(c.db)
    change(c, "revoke", 22, 21, 1)
    assert :ok = ExternalInputs.validate(c.db)
    change(c, "install", 23, 21, 2)
    assert :ok = ExternalInputs.validate(c.db)
    event(c.db, 24, "principal_revoked", "operator:entry")
    withdraw(c, 25, 23, 4, 24)
    assert :ok = ExternalInputs.validate(c.db)

    assert {:ok, [[25, 23, 4, "revoked"]]} =
             SQL.query(
               c.db,
               "SELECT history_revision,install_revision,generation,state FROM routine_external_input_current"
             )

    assert {:ok, [[c.v["receipt_document"]]]} ==
             SQL.query(
               c.db,
               "SELECT receipt_document FROM routine_external_input_operations WHERE revision=21"
             )

    assert {:ok, []} = SQL.query(c.db, "PRAGMA foreign_key_check")
  end

  test "operation, canonical package, epoch and original hashes are checked independently", c do
    seed(c)

    for {sql, parameters} <- [
          {"UPDATE routine_external_input_operations SET principal_id='missing'", []},
          {"UPDATE routine_external_input_operations SET operation_id='other'", []},
          {"UPDATE routine_external_input_operations SET authority_epoch=2", []},
          {"UPDATE routine_external_input_operations SET input_document=?",
           [c.v["change_document"] <> " "]},
          {"UPDATE routine_external_input_operations SET outcome_document=?",
           [c.v["outcome_document"] <> " "]},
          {"UPDATE routine_external_input_operations SET receipt_document=?",
           [receipt(c, %{"input_sha256" => String.duplicate("0", 64)})]},
          {"UPDATE routine_external_input_operations SET receipt_document=?",
           [receipt(c, %{"outcome_sha256" => String.duplicate("0", 64)})]},
          {"UPDATE meta SET value=20 WHERE key='revision'", []},
          {"DELETE FROM principals WHERE principal_id='operator:entry'", []}
        ] do
      corrupt_after(c.db, sql, parameters)
    end

    assert :ok = ExternalInputs.validate(c.db)
  end

  test "history and complete journal membership cannot be detached from an original", c do
    seed(c)

    for statement <- [
          "DELETE FROM routine_external_input_history",
          "DELETE FROM routine_external_input_operations",
          "UPDATE routine_external_input_history SET capability_key='foreign'",
          "UPDATE routine_external_input_history SET generation=2",
          "UPDATE authority_journal SET event_type='other' WHERE revision=21",
          "UPDATE authority_journal SET entity_id='other' WHERE revision=21",
          "INSERT INTO authority_journal VALUES (22,'external_input_installed','other')"
        ] do
      corrupt_after(c.db, statement)
    end
  end

  test "current requires the exact latest scoped installation and retained generation", c do
    seed(c)
    change(c, "install", 22, 21, 1)

    for statement <- [
          "DELETE FROM routine_external_input_current",
          "UPDATE routine_external_input_current SET history_revision=21,install_revision=21,generation=1",
          "UPDATE routine_external_input_current SET install_revision=21,state='revoked'",
          "UPDATE routine_external_input_current SET capability_key='foreign'",
          "UPDATE routine_external_input_current SET generation=3",
          "DELETE FROM enrolled_things",
          "INSERT INTO routine_external_input_current VALUES ('sensor:other','sample',22,22,2,'installed')"
        ] do
      corrupt_after(c.db, statement)
    end

    assert :ok = ExternalInputs.validate(c.db)
  end

  test "self-consistent but skipped original CAS and generations refuse", c do
    seed(c)
    change(c, "install", 22, 21, 1)
    assert :ok = Sqlite3.execute(c.db, "SAVEPOINT mutant")
    change(c, "install", 23, 22, 2)
    rewrite_original(c.db, 23, %{"expected_generation" => 1}, %{"generation" => 2})
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
    assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO mutant; RELEASE mutant")

    assert :ok = Sqlite3.execute(c.db, "SAVEPOINT mutant")
    change(c, "install", 23, 20, 2)
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
    assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO mutant; RELEASE mutant")
    assert :ok = ExternalInputs.validate(c.db)
  end

  test "later boot and authority epoch revoke preserves the old install original", c do
    seed(c)
    assert {:ok, []} = SQL.query(c.db, "UPDATE meta SET value=2 WHERE key='authority_epoch'")
    change(c, "revoke", 22, 21, 1, 2, "store:later")
    assert :ok = ExternalInputs.validate(c.db)

    corrupt_after(
      c.db,
      "UPDATE routine_external_input_operations SET authority_epoch=3 WHERE revision=22"
    )

    corrupt_after(
      c.db,
      "UPDATE routine_external_input_history SET cause_revision=21 WHERE revision=22"
    )
  end

  test "every durable loss withdraws at its first exact cause without creating an operation", c do
    seed(c)

    causes = [
      {"external_target_selected", "sensor:independent"},
      {"external_target_revoked", "sensor:independent"},
      {"external_target_dependency_revoked", "sensor:independent"},
      {"thing_narrowed", "sensor:independent"},
      {"thing_revoked", "sensor:independent"},
      {"thing_enrollment_rereviewed", "sensor:independent"},
      {"external_profile_approved", "unrelated-artifact-still-advances-global-policy"},
      {"external_profile_revoked", "unrelated-artifact-still-advances-global-policy"},
      {"principal_revoked", "operator:entry"},
      {"target_grant_revoked", "operator:entry/sensor:independent"},
      {"host_maintenance_started", "host:maintenance"},
      {"controller_source_retired", "controller:source"},
      {"controller_destination_accepted", "controller:destination"}
    ]

    for {event, entity} <- causes do
      assert :ok = Sqlite3.execute(c.db, "SAVEPOINT cause_case")
      event(c.db, 22, event, entity)
      assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
      event(c.db, 23, "principal_revoked", "operator:entry")
      withdraw(c, 24, 21, 2, 22)
      assert :ok = ExternalInputs.validate(c.db)

      corrupt_after(
        c.db,
        "UPDATE routine_external_input_history SET cause_revision=23 WHERE revision=24"
      )

      assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO cause_case; RELEASE cause_case")
    end
  end

  test "unrelated actors and targets create no withdrawal cause", c do
    seed(c)

    for {rev, event, entity} <- [
          {22, "thing_revoked", "sensor:other"},
          {23, "principal_revoked", "operator:other"},
          {24, "target_grant_revoked", "operator:other/sensor:independent"},
          {25, "target_grant_revoked", "operator:entry/sensor:other"}
        ],
        do: event(c.db, rev, event, entity)

    assert :ok = ExternalInputs.validate(c.db)
    assert :ok = Sqlite3.execute(c.db, "SAVEPOINT no_cause")
    withdraw(c, 26, 21, 2, 22)
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
    assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO no_cause; RELEASE no_cause")
  end

  test "new user changes and a later regrant cannot skip a prior durable loss", c do
    seed(c)
    event(c.db, 22, "target_grant_revoked", "operator:entry/sensor:independent")

    for action <- ["install", "revoke"] do
      assert :ok = Sqlite3.execute(c.db, "SAVEPOINT skipped_loss")
      change(c, action, 23, 21, 1)
      assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
      assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO skipped_loss; RELEASE skipped_loss")
    end

    event(c.db, 23, "target_grant_added", "operator:entry/sensor:independent")
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
    withdraw(c, 24, 21, 2, 22)
    assert :ok = ExternalInputs.validate(c.db)

    assert {:ok, []} =
             SQL.query(
               c.db,
               "SELECT revision FROM routine_external_input_operations WHERE revision>21"
             )
  end

  test "installer, selector and approver remain three separate durable dependencies", c do
    c =
      revise_context(c, %{
        "selection_author" => "operator:selector",
        "trust_author" => "operator:approver"
      })

    seed(c)

    for principal <- ["operator:selector", "operator:approver"] do
      assert {:ok, []} =
               SQL.query(c.db, "INSERT INTO principals VALUES (?,?,?,'active')", [
                 principal,
                 {:blob, :crypto.hash(:sha256, principal)},
                 "[]"
               ])
    end

    assert :ok = ExternalInputs.validate(c.db)

    for principal <- ["operator:entry", "operator:selector", "operator:approver"] do
      corrupt_after(c.db, "DELETE FROM principals WHERE principal_id=?", [principal])

      for {kind, entity} <- [
            {"principal_revoked", principal},
            {"target_grant_revoked", principal <> "/sensor:independent"}
          ] do
        assert :ok = Sqlite3.execute(c.db, "SAVEPOINT author")
        event(c.db, 22, kind, entity)
        assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
        withdraw(c, 23, 21, 2, 22)
        assert :ok = ExternalInputs.validate(c.db)
        assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO author; RELEASE author")
      end
    end
  end

  test "two capability slots retain independent generations and cannot borrow each other's heads",
       c do
    seed(c)
    second = revise_context(c, %{"capability_key" => "second"})

    input =
      Map.merge(second.v["change"], %{
        "operation_id" => "install:second",
        "capability_key" => "second"
      })

    {:ok, id} = Operation.encode(input)
    outcome = Map.put(second.v["outcome"], "capability_key", "second")
    {:ok, od} = Operation.encode_outcome(outcome)

    r =
      Map.merge(c.v["receipt"], %{
        "operation_id" => "install:second",
        "capability_key" => "second",
        "revision" => 22,
        "install_revision" => 22,
        "input_sha256" => Operation.input_sha256(id),
        "outcome_sha256" => Operation.outcome_sha256(od)
      })

    {:ok, rd} = Operation.encode_receipt(r)
    event(c.db, 22, "external_input_installed", "sensor:independent")

    insert(c.db, "routine_external_input_operations", [
      "operator:entry",
      1,
      "install:second",
      id,
      od,
      rd,
      22
    ])

    insert(c.db, "routine_external_input_history", [
      "sensor:independent",
      "second",
      22,
      1,
      "install",
      nil,
      od
    ])

    insert(c.db, "routine_external_input_current", [
      "sensor:independent",
      "second",
      22,
      22,
      1,
      "installed"
    ])

    assert :ok = ExternalInputs.validate(c.db)

    assert {:error, _} =
             SQL.query(
               c.db,
               "UPDATE routine_external_input_current SET install_revision=21,state='revoked' WHERE capability_key='second'"
             )

    corrupt_after(
      c.db,
      "UPDATE routine_external_input_current SET install_revision=21,state='revoked' WHERE capability_key='second'"
    )

    change(c, "revoke", 23, 21, 1)
    assert :ok = ExternalInputs.validate(c.db)

    assert {:ok, [[22, 1, "installed"]]} =
             SQL.query(
               c.db,
               "SELECT install_revision,generation,state FROM routine_external_input_current WHERE capability_key='second'"
             )
  end

  test "native grant loss resolves the exact retained receipt instead of an entity suffix", c do
    seed(c)
    principal = WotexHome.NativeSetup.Codec.principal(1, "operator")

    assert {:ok, []} =
             SQL.query(c.db, "INSERT INTO principals VALUES (?,?,?,'active')", [
               principal,
               {:blob, :crypto.hash(:sha256, "synthetic-native")},
               "[]"
             ])

    assert {:ok, []} =
             SQL.query(c.db, "UPDATE routine_external_input_operations SET principal_id=?", [
               principal
             ])

    native_loss(c, 22, "sensor:other")
    assert :ok = ExternalInputs.validate(c.db)
    native_loss(c, 23, "sensor:independent")
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
    withdraw(c, 24, 21, 2, 23)
    assert :ok = ExternalInputs.validate(c.db)

    corrupt_after(
      c.db,
      "UPDATE routine_external_input_history SET cause_revision=22 WHERE revision=24"
    )

    corrupt_after(
      c.db,
      "UPDATE native_target_operations SET receipt_document='[]' WHERE revision=23"
    )

    corrupt_after(
      c.db,
      "UPDATE authority_journal SET entity_id='operator:entry/sensor:independent' WHERE revision=23"
    )

    {:ok, [[document]]} =
      SQL.query(c.db, "SELECT receipt_document FROM native_target_operations WHERE revision=23")

    {:ok, original} = TargetCodec.decode("receipt", document)

    for delta <- [
          %{"operation_id" => "native:other"},
          %{"expected_revision" => 23, "change_revision" => 24, "final_revision" => 24}
        ] do
      {:ok, changed} = TargetCodec.encode("receipt", Map.merge(original, delta))

      corrupt_after(
        c.db,
        "UPDATE native_target_operations SET receipt_document=? WHERE revision=23",
        [changed]
      )
    end
  end

  test "DDL drift fails even before any row exists", c do
    for statement <- [
          "CREATE INDEX hidden_input_index ON routine_external_input_history(target_id)",
          "CREATE TRIGGER hidden_input AFTER INSERT ON routine_external_input_history BEGIN SELECT 1; END",
          "ALTER TABLE routine_external_input_operations ADD COLUMN hidden TEXT"
        ] do
      assert :ok = Sqlite3.execute(c.db, "SAVEPOINT ddl")
      assert :ok = Sqlite3.execute(c.db, statement)
      assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
      assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO ddl; RELEASE ddl")
    end

    assert :ok = Sqlite3.execute(c.db, "DROP TABLE routine_external_input_current")

    changed =
      String.replace(
        ExternalInputs.schema(),
        "FOREIGN KEY (target_id,capability_key,install_revision)",
        "FOREIGN KEY (target_id,capability_key,history_revision)"
      )

    [_, current] = String.split(changed, "CREATE TABLE routine_external_input_current", parts: 2)
    assert :ok = Sqlite3.execute(c.db, "CREATE TABLE routine_external_input_current" <> current)
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
  end

  test "SQL refuses wrong state, document type, causal relation and cross-slot head", c do
    seed(c)

    for statement <- [
          "UPDATE routine_external_input_history SET action='other'",
          "UPDATE routine_external_input_history SET cause_revision=21",
          "UPDATE routine_external_input_history SET action='withdraw',cause_revision=NULL",
          "UPDATE routine_external_input_history SET action='withdraw',cause_revision=21",
          "UPDATE routine_external_input_history SET generation=1.5",
          "UPDATE routine_external_input_operations SET input_document=x'31'",
          "UPDATE routine_external_input_operations SET receipt_document=printf('%4097s','x')",
          "UPDATE routine_external_input_current SET state='revoked'",
          "UPDATE routine_external_input_current SET install_revision=22",
          "UPDATE routine_external_input_current SET capability_key='foreign'"
        ] do
      assert {:error, _} = Sqlite3.execute(c.db, statement)
    end

    assert :ok = ExternalInputs.validate(c.db)
  end

  test "capacity includes actual repeated UTF-8 bytes and inclusive prospective maxima", c do
    seed(c)
    bytes = byte_size(c.v["change_document"]) + 2 * byte_size(c.v["outcome_document"])
    assert :ok = ExternalInputs.capacity(c.db, 1023, 4095, 1023, 16_777_216 - bytes)

    for delta <- [
          {1024, 0, 0, 0},
          {0, 4096, 0, 0},
          {0, 0, 1024, 0},
          {0, 0, 0, 16_777_217 - bytes},
          {-1, 0, 0, 0},
          {0, 0, 0, 1.0}
        ] do
      {o, h, s, b} = delta
      assert {:error, :external_input_capacity} = ExternalInputs.capacity(c.db, o, h, s, b)
    end

    assert :ok = Sqlite3.execute(c.db, "SAVEPOINT byte_count")

    assert {:ok, []} =
             SQL.query(
               c.db,
               "UPDATE routine_external_input_operations SET receipt_document=printf('%4096s','x')"
             )

    assert :ok = ExternalInputs.capacity(c.db, 0, 0, 0, 16_777_216 - bytes)

    assert {:ok, []} =
             SQL.query(
               c.db,
               "UPDATE routine_external_input_operations SET input_document=input_document||?",
               ["é"]
             )

    assert :ok = ExternalInputs.capacity(c.db, 0, 0, 0, 16_777_214 - bytes)

    assert {:error, :external_input_capacity} =
             ExternalInputs.capacity(c.db, 0, 0, 0, 16_777_215 - bytes)

    assert :ok = Sqlite3.execute(c.db, "ROLLBACK TO byte_count; RELEASE byte_count")
    assert :ok = ExternalInputs.validate(c.db)

    assert :ok = Sqlite3.execute(c.db, "DROP TABLE routine_external_input_current")
    assert {:error, reason} = ExternalInputs.capacity(c.db, 0, 0, 0, 0)
    refute reason == :external_input_capacity
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(c.db)
  end

  test "a failed SQL transition rolls back every original, head, event and revision", c do
    seed(c)
    original = snapshot(c.db)
    assert :ok = Sqlite3.execute(c.db, "BEGIN IMMEDIATE")
    change(c, "revoke", 22, 21, 1)
    assert :ok = ExternalInputs.validate(c.db)

    assert {:error, _} =
             SQL.query(c.db, "UPDATE routine_external_input_current SET generation=NULL")

    assert :ok = Sqlite3.execute(c.db, "ROLLBACK")
    assert snapshot(c.db) == original
    assert :ok = ExternalInputs.validate(c.db)
  end

  test "actual SQLite history remains readable without producers or the current programme", c do
    seed(c)
    change(c, "revoke", 22, 21, 1)

    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-input-history-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    database = Path.join(directory, "history.sqlite")

    try do
      assert {:ok, []} = SQL.query(c.db, "VACUUM INTO ?", [database])

      script = """
      alias WotexHome.Durable.Store.ExternalInputs
      alias WotexHome.Qualification.ExternalInputDecision
      directory = #{inspect(directory)}
      {:ok, db} = Exqlite.Sqlite3.open(#{inspect(database)})
      try do
        :ok = ExternalInputs.validate(db)
        original = ExternalInputDecision |> :code.which() |> List.to_string() |> Path.dirname()
        private_home = Path.join(directory, "wotex_home")
        private = Path.join(private_home, "ebin")
        File.mkdir_p!(private)
        File.cp!(Path.join(original, "wotex_home.app"), Path.join(private, "wotex_home.app"))
        true = :code.del_path(String.to_charlist(original))
        true = :code.add_patha(String.to_charlist(private))
        true = Application.app_dir(:wotex_home) == private_home
        for module <- [Wotex.JSON,Wotex.Runtime.Context,Wotex.Profiles.Proposal,Wotex.Routines.InputMapping] do
          path = module |> :code.which() |> List.to_string() |> Path.dirname() |> String.to_charlist()
          true = :code.del_path(path)
          false = Code.ensure_loaded?(module)
        end
        {:error, :qualification_unavailable} = ExternalInputDecision.programme()
        :ok = ExternalInputs.validate(db)
        IO.puts("verified SQLite originals without producers or current programme")
      after
        Exqlite.Sqlite3.close(db)
        File.rm_rf!(directory)
      end
      """

      args =
        Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
          ["-e", script]

      assert {"verified SQLite originals without producers or current programme\n", 0} =
               System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
    after
      File.rm_rf!(directory)
    end

    refute File.exists?(directory)
  end

  # Synthetic retained rows exercise this domain only, not admission or the
  # independent historical validators of enrollment/target selection.
  defp seed(c) do
    assert {:ok, []} =
             SQL.query(c.db, "INSERT INTO principals VALUES (?,?,?,'active')", [
               "operator:entry",
               {:blob, :crypto.hash(:sha256, "synthetic")},
               "[]"
             ])

    assert {:ok, []} =
             SQL.query(c.db, "INSERT INTO enrolled_things VALUES (?,?,?,0,'active')", [
               "sensor:independent",
               "synthetic",
               "{}"
             ])

    event(c.db, 20, "synthetic_predecessor", "entry")
    event(c.db, 21, "external_input_installed", "sensor:independent")

    insert(c.db, "routine_external_input_operations", [
      "operator:entry",
      1,
      "install:entry",
      c.v["change_document"],
      c.v["outcome_document"],
      c.v["receipt_document"],
      21
    ])

    insert(c.db, "routine_external_input_history", [
      "sensor:independent",
      "sample",
      21,
      1,
      "install",
      nil,
      c.v["outcome_document"]
    ])

    head(c.db, 21, 21, 1, "installed")
  end

  defp change(c, action, revision, install, gen, epoch \\ 1, boot \\ "store:entry") do
    input =
      Map.merge(c.v["change"], %{
        "operation_id" => "#{action}:#{revision}",
        "authority_epoch" => epoch,
        "expected_install_revision" => install,
        "expected_generation" => gen,
        "action" => action,
        "package_document" => if(action == "install", do: c.v["package_document"], else: nil)
      })

    {:ok, id} = Operation.encode(input)
    outcome = Map.put(c.v["outcome"], "action", action)
    {:ok, od} = Operation.encode_outcome(outcome)

    r =
      Map.merge(c.v["receipt"], %{
        "authority_epoch" => epoch,
        "operation_id" => input["operation_id"],
        "revision" => revision,
        "generation" => gen + 1,
        "install_revision" => if(action == "install", do: revision, else: install),
        "action" => action,
        "input_sha256" => Operation.input_sha256(id),
        "outcome_sha256" => Operation.outcome_sha256(od),
        "store_boot_epoch" => boot
      })

    {:ok, rd} = Operation.encode_receipt(r)
    assert {:ok, _} = Operation.validate_original(id, od, rd)

    event(
      c.db,
      revision,
      if(action == "install", do: "external_input_installed", else: "external_input_revoked"),
      "sensor:independent"
    )

    insert(c.db, "routine_external_input_operations", [
      "operator:entry",
      epoch,
      input["operation_id"],
      id,
      od,
      rd,
      revision
    ])

    insert(c.db, "routine_external_input_history", [
      "sensor:independent",
      "sample",
      revision,
      gen + 1,
      action,
      nil,
      od
    ])

    head(
      c.db,
      revision,
      r["install_revision"],
      gen + 1,
      if(action == "install", do: "installed", else: "revoked")
    )
  end

  defp withdraw(c, revision, install, gen, cause) do
    {:ok, od} = Operation.encode_outcome(Map.put(c.v["outcome"], "action", "withdraw"))
    event(c.db, revision, "external_input_withdrawn", "sensor:independent")

    insert(c.db, "routine_external_input_history", [
      "sensor:independent",
      "sample",
      revision,
      gen,
      "withdraw",
      cause,
      od
    ])

    head(c.db, revision, install, gen, "revoked")
  end

  defp native_loss(c, revision, target) do
    op = "native:#{revision}"
    principal = WotexHome.NativeSetup.Codec.principal(1, "operator")

    r = %{
      "deployment_id" => String.duplicate("d", 64),
      "owner_id" => String.duplicate("a", 64),
      "authority_epoch" => 1,
      "principal_id" => principal,
      "operation_id" => op,
      "action" => "revoke",
      "target_id" => target,
      "input_digest" => String.duplicate("b", 64),
      "expected_revision" => revision - 1,
      "change_revision" => revision,
      "final_revision" => revision,
      "affected_requests" => 0,
      "unknown_outcomes" => 0
    }

    {:ok, rd} = TargetCodec.encode("receipt", r)
    event(c.db, revision, "native_target_revoked", "#{principal}/1/#{op}")

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO native_target_operations VALUES (?,?,?,'revoke','[]',?,?)",
               [principal, 1, op, rd, revision]
             )
  end

  defp receipt(c, delta) do
    {:ok, doc} = Operation.encode_receipt(Map.merge(c.v["receipt"], delta))
    doc
  end

  defp rewrite_original(db, revision, input_delta, receipt_delta) do
    {:ok, [[id, od, rd]]} =
      SQL.query(
        db,
        "SELECT input_document,outcome_document,receipt_document FROM routine_external_input_operations WHERE revision=?",
        [revision]
      )

    {:ok, input} = Operation.decode(id)
    {:ok, receipt} = Operation.decode_receipt(rd)
    {:ok, id} = Operation.encode(Map.merge(input, input_delta))

    {:ok, rd} =
      Operation.encode_receipt(
        receipt
        |> Map.merge(receipt_delta)
        |> Map.put("input_sha256", Operation.input_sha256(id))
      )

    assert {:ok, _} = Operation.validate_original(id, od, rd)

    assert {:ok, []} =
             SQL.query(
               db,
               "UPDATE routine_external_input_operations SET input_document=?,receipt_document=? WHERE revision=?",
               [id, rd, revision]
             )
  end

  defp revise_context(c, delta) do
    wire = JSON.decode!(c.v["definition_document"])
    context = Map.merge(c.v["definition"]["context"], delta)
    context = put_in(context, ["declaration", "capability_key"], context["capability_key"])
    {:ok, inner} = Wotex.JSON.encode(context)
    {:ok, chunks} = DocumentChunks.encode(inner, 131_072)
    document = JSON.encode!(List.replace_at(wire, 1, chunks))
    {:ok, definition} = ExternalInput.decode(document)

    p =
      c.v["package"]
      |> Map.put("definition_document", document)
      |> put_in(["signed", "decision", "definition_sha256"], definition["sha256"])

    {:ok, package} = ExternalInputPackage.encode(p)
    input = c.v["change"] |> Map.put("package_document", package)

    outcome =
      c.v["outcome"]
      |> Map.put("package_document", package)
      |> Map.put("definition_sha256", definition["sha256"])

    {:ok, id} = Operation.encode(Map.put(input, "capability_key", context["capability_key"]))

    {:ok, od} =
      Operation.encode_outcome(Map.put(outcome, "capability_key", context["capability_key"]))

    r =
      c.v["receipt"]
      |> Map.put("capability_key", context["capability_key"])
      |> Map.put("input_sha256", Operation.input_sha256(id))
      |> Map.put("outcome_sha256", Operation.outcome_sha256(od))

    {:ok, rd} = Operation.encode_receipt(r)

    v =
      Map.merge(c.v, %{
        "change" => input,
        "outcome" => outcome,
        "receipt" => r,
        "definition_document" => document,
        "package_document" => package,
        "change_document" => id,
        "outcome_document" => od,
        "receipt_document" => rd
      })

    %{c | v: v}
  end

  defp head(db, rev, install, gen, state) do
    assert {:ok, []} =
             SQL.query(
               db,
               "INSERT INTO routine_external_input_current VALUES ('sensor:independent','sample',?,?,?,?) ON CONFLICT(target_id,capability_key) DO UPDATE SET history_revision=excluded.history_revision,install_revision=excluded.install_revision,generation=excluded.generation,state=excluded.state",
               [rev, install, gen, state]
             )
  end

  defp event(db, revision, event, entity),
    do: assert(:ok = Journal.authority_event(db, revision, event, entity))

  defp insert(db, table, values) do
    columns = Enum.join(ExternalInputs.tables()[table], ",")
    placeholders = Enum.map_join(values, ",", fn _ -> "?" end)

    assert {:ok, []} =
             SQL.query(db, "INSERT INTO #{table} (#{columns}) VALUES (#{placeholders})", values)
  end

  defp corrupt_after(db, statement, parameters \\ []) do
    assert :ok =
             Sqlite3.execute(
               db,
               "PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON; SAVEPOINT corruption"
             )

    assert {:ok, []} = SQL.query(db, statement, parameters)
    assert {:error, :corrupt_external_inputs} = ExternalInputs.validate(db)

    assert :ok =
             Sqlite3.execute(
               db,
               "ROLLBACK TO corruption; RELEASE corruption; PRAGMA ignore_check_constraints=OFF; PRAGMA foreign_keys=ON"
             )
  end

  defp snapshot(db) do
    for table <- ["meta", "authority_journal" | Enum.sort(Map.keys(ExternalInputs.tables()))],
        into: %{} do
      {:ok, rows} = SQL.query(db, "SELECT * FROM #{table} ORDER BY 1,2")
      {table, rows}
    end
  end
end
