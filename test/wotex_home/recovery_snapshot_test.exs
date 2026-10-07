defmodule WotexHome.RecoverySnapshotTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, RecoverySnapshot, SQL}
  alias WotexHome.Profiles.{Archive, Artifact, Custody}

  setup do
    Process.flag(:trap_exit, true)
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-transfer-snapshot-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    profile_root = Path.join(root, "profiles")
    File.mkdir!(profile_root)
    File.chmod!(profile_root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    store =
      start_supervised!(
        {Store,
         path: Path.join(root, "home.sqlite"),
         name: __MODULE__.Store,
         profile_custody: __MODULE__.Custody}
      )

    custody =
      start_supervised!(
        {Custody, root: profile_root, name: __MODULE__.Custody, store_owner: store}
      )

    authority = Authority.new(store: store, profile_custody: custody)
    {:ok, transfer, 1} = Authority.provision_transfer(authority)
    {:ok, maintenance, 2} = Authority.provision_maintenance(authority)
    {:ok, diagnostic, 3} = Authority.provision_diagnostic(authority)
    key = :crypto.strong_rand_bytes(32)
    active = Path.join(root, "active.woh")
    {:ok, _} = Authority.export_profile_backup(authority, active, key)

    {:ok, barrier} =
      Authority.begin_maintenance(authority, maintenance, 1, "maintenance:source", 3)

    {:ok, receipt} =
      Authority.retire_controller(authority, transfer, %{
        "authority_epoch" => 1,
        "operation_id" => "retire:source",
        "expected_revision" => barrier.revision,
        "destination_owner_id" => String.duplicate("a", 64)
      })

    archive = Path.join(root, "retired.woh")
    {:ok, _} = Authority.export_retired_profile_backup(authority, archive, key)
    {database, _objects} = source_database(archive, key)
    {:ok, basis} = Backup.retired_transfer_basis(archive, key)
    staged = Path.join(root, "destination")
    {:ok, _} = Backup.stage_profile_restore(archive, key, staged)

    %{
      root: root,
      source: database,
      staged: Path.join(staged, "home.sqlite"),
      archive: archive,
      active: active,
      key: key,
      basis: basis,
      receipt: receipt,
      authority: authority,
      diagnostic: diagnostic
    }
  end

  test "exact authenticated source bytes and full quarantine correspond without restoring authority",
       c do
    assert c.basis.snapshot_digest == Artifact.digest(c.source)
    assert c.basis.archive_digest == Artifact.digest(File.read!(c.archive))
    assert c.basis.retirement_receipt == c.receipt
    assert c.basis.source_maintenance_revision == c.receipt["maintenance_revision"]
    assert c.basis.source_rule_generation == 1
    assert c.basis.portable_profile_objects == 0
    refute Artifact.digest(File.read!(c.staged)) == c.basis.snapshot_digest

    with_copy(c.source, fn db ->
      assert {:ok, c.basis.logical_snapshot_digest} == RecoverySnapshot.commitment(db, :source)
      assert {:error, :invalid_transfer_snapshot} = RecoverySnapshot.commitment(db, :quarantine)
    end)

    with_copy(File.read!(c.staged), fn db ->
      assert :ok = RecoverySnapshot.match_quarantine(db, c.basis.logical_snapshot_digest)
      assert {:error, :invalid_transfer_snapshot} = RecoverySnapshot.commitment(db, :source)
      assert {:ok, [[1]]} = SQL.query(db, "SELECT value FROM meta WHERE key='restore_quarantine'")
      assert {:ok, [["retired"]]} = SQL.query(db, "SELECT state FROM controller_identity")

      assert {:error, {:store_open_failed, :restore_requires_transfer}} =
               Store.start_link(path: c.staged)
    end)
  end

  test "unused credential, permission and status changes refuse exact correspondence", c do
    for {sql, parameters} <- [
          {"UPDATE principals SET credential_hash=? WHERE principal_id='diagnostics:local'",
           [{:blob, :crypto.strong_rand_bytes(32)}]},
          {"UPDATE principals SET permissions='[\"host:maintain\"]' WHERE principal_id='diagnostics:local'",
           []},
          {"UPDATE principals SET status='revoked' WHERE principal_id='diagnostics:local'", []}
        ] do
      with_copy(File.read!(c.staged), fn db ->
        assert {:ok, []} = SQL.query(db, sql, parameters)
        assert {:ok, [[1]]} = SQL.query(db, "SELECT changes()")
        assert :ok = Integrity.validate_snapshot(db)
        assert {:ok, changed} = RecoverySnapshot.commitment(db, :quarantine)
        refute changed == c.basis.logical_snapshot_digest

        assert {:error, :transfer_snapshot_mismatch} =
                 RecoverySnapshot.match_quarantine(db, c.basis.logical_snapshot_digest)
      end)
    end
  end

  test "additional retained rows and altered schema bind beyond ownership heads", c do
    for statement <- [
          "INSERT INTO meta VALUES ('unreviewed_dependency',7)",
          "CREATE TRIGGER hidden_source AFTER UPDATE ON meta BEGIN SELECT 1; END",
          "CREATE VIEW retained_snapshot AS SELECT * FROM meta",
          "DROP INDEX power_handoff_time"
        ] do
      with_copy(File.read!(c.staged), fn db ->
        assert :ok = Sqlite3.execute(db, statement)
        assert :ok = Integrity.validate_snapshot(db)

        assert {:error, :transfer_snapshot_mismatch} =
                 RecoverySnapshot.match_quarantine(db, c.basis.logical_snapshot_digest)
      end)
    end
  end

  test "only the exact integer quarantine marker may differ", c do
    for statement <- [
          "DELETE FROM meta WHERE key='restore_quarantine'",
          "UPDATE meta SET value=0 WHERE key='restore_quarantine'",
          "UPDATE meta SET value=2 WHERE key='restore_quarantine'",
          "UPDATE meta SET value=x'31' WHERE key='restore_quarantine'"
        ] do
      with_copy(File.read!(c.staged), fn db ->
        assert :ok = Sqlite3.execute(db, statement)

        assert {:error, :transfer_snapshot_mismatch} =
                 RecoverySnapshot.match_quarantine(db, c.basis.logical_snapshot_digest)
      end)
    end

    with_copy(File.read!(c.staged), fn db ->
      assert {:error, :transfer_snapshot_mismatch} = RecoverySnapshot.match_quarantine(db, nil)

      assert {:error, :transfer_snapshot_mismatch} =
               RecoverySnapshot.match_quarantine(db, String.duplicate("A", 64))
    end)
  end

  test "physical serialization and row insertion order do not change a logical commitment", c do
    with_copy(c.source, fn db ->
      assert {:ok, before} = RecoverySnapshot.commitment(db, :source)
      assert :ok = Sqlite3.execute(db, "VACUUM")
      assert {:ok, ^before} = RecoverySnapshot.commitment(db, :source)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "INSERT INTO meta VALUES ('extra_b',2); INSERT INTO meta VALUES ('extra_a',1)"
               )

      assert {:ok, with_extra} = RecoverySnapshot.commitment(db, :source)

      assert :ok =
               Sqlite3.execute(
                 db,
                 "DELETE FROM meta WHERE key IN ('extra_a','extra_b'); INSERT INTO meta VALUES ('extra_a',1); INSERT INTO meta VALUES ('extra_b',2)"
               )

      assert {:ok, ^with_extra} = RecoverySnapshot.commitment(db, :source)
      refute before == with_extra
    end)
  end

  test "row and transcript budgets refuse the whole snapshot instead of a partial digest", c do
    with_copy(c.source, fn db ->
      assert {:ok, tables} =
               SQL.query(
                 db,
                 "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*'"
               )

      count =
        Enum.reduce(tables, 0, fn [table], count ->
          {:ok, [[rows]]} = SQL.query(db, "SELECT COUNT(*) FROM \"#{table}\"")
          count + rows
        end)

      assert {:ok, c.basis.logical_snapshot_digest} ==
               RecoverySnapshot.commitment(db, :source, max_rows: count)

      assert {:error, :invalid_transfer_snapshot} =
               RecoverySnapshot.commitment(db, :source, max_rows: count - 1)

      for options <- [
            [max_bytes: 1],
            [max_rows: 0],
            [max_rows: 131_073],
            [max_bytes: 134_217_729],
            [max_rows: 1, max_rows: 2],
            [unexpected: 1],
            [nil],
            nil
          ] do
        assert {:error, :invalid_transfer_snapshot} =
                 RecoverySnapshot.commitment(db, :source, options)
      end
    end)
  end

  test "normal and database-only archives cannot supply a retired inclusive transfer basis", c do
    assert {:error, :retired_archive_required} = Backup.retired_transfer_basis(c.active, c.key)

    assert {:error, :invalid_backup} =
             Backup.retired_transfer_basis(c.archive, :crypto.strong_rand_bytes(32))

    database_only = Path.join(c.root, "database-only.woh")
    assert {:ok, _} = Store.export_backup(Authority.owner(c.authority), database_only, c.key)
    assert {:ok, _} = Backup.verify(database_only, c.key)

    assert {:error, :retired_archive_required} =
             Backup.retired_transfer_basis(database_only, c.key)

    second = Path.join(c.root, "second.woh")
    assert {:ok, _} = Authority.export_retired_profile_backup(c.authority, second, c.key)
    assert {:ok, other} = Backup.retired_transfer_basis(second, c.key)
    refute other.archive_digest == c.basis.archive_digest
    assert other.logical_snapshot_digest == c.basis.logical_snapshot_digest
    assert other.retirement_receipt == c.receipt
  end

  defp with_copy(bytes, function) do
    {:ok, db} = Sqlite3.open(":memory:")

    try do
      :ok = Sqlite3.deserialize(db, "main", bytes)
      function.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp source_database(path, key) do
    <<"WOHBK2\0", revision::64, epoch::64, nonce::binary-size(12), size::32, rest::binary>> =
      File.read!(path)

    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = rest
    header = <<"WOHBK2\0", revision::64, epoch::64, nonce::binary-size(12), size::32>>
    plain = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, header, tag, false)
    {:ok, database, objects} = Archive.decode(plain)
    {database, objects}
  end
end
