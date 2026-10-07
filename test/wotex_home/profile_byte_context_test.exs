defmodule WotexHome.ProfileByteContextTest do
  use ExUnit.Case, async: true
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.{ProfileByteContext, SQL}
  alias WotexHome.Lifx.ProfileBasis
  alias WotexHome.Profiles.{Artifact, Custody}

  setup do
    temp = System.tmp_dir!()
    temp = if String.starts_with?(temp, "/var/"), do: "/private" <> temp, else: temp
    root = Path.join(temp, "woh-profile-context-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    custody = start_supervised!({Custody, root: root})
    bytes = File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))
    {:ok, artifact} = Artifact.parse(bytes)
    {:ok, _} = Custody.stage(custody, bytes)
    {:ok, db} = Sqlite3.open(":memory:")
    # This tests only the transient commitment mechanism; these minimal rows
    # are not a Store fixture, a selection ledger or qualification evidence.
    :ok =
      Sqlite3.execute(
        db,
        "CREATE TABLE portable_profiles (artifact_digest TEXT,projection_digest TEXT,registry_digest TEXT); CREATE TABLE profile_current (selection_revision INTEGER,state TEXT); CREATE TABLE profile_selection_history (revision INTEGER,artifact_digest TEXT);"
      )

    {:ok, []} =
      SQL.query(db, "INSERT INTO portable_profiles VALUES (?,?,?)", [
        artifact.digest,
        artifact.projection_digest,
        hd(artifact.data["dependencies"])["sha256"]
      ])

    :ok = Sqlite3.execute(db, "INSERT INTO profile_current VALUES (1,'selected')")

    {:ok, []} =
      SQL.query(db, "INSERT INTO profile_selection_history VALUES (1,?)", [artifact.digest])

    :ok = ProfileByteContext.initialize(db)

    on_exit(fn ->
      Sqlite3.close(db)
      File.rm_rf!(root)
    end)

    %{
      db: db,
      custody: custody,
      root: root,
      artifact: artifact,
      registry: hd(artifact.data["dependencies"])["sha256"]
    }
  end

  test "verification binds this call's exact raw projection registry and host runtime", c do
    assert :ok = ProfileByteContext.prepare(c.db, c.custody, {:record, nil, nil})
    {:ok, runtime} = ProfileBasis.runtime_digest()
    assert :ok = available(c, runtime)
    assert {:error, :profile_basis_changed} = available(c, String.duplicate("a", 64))
    assert :ok = ProfileByteContext.clear(c.db)
    assert {:error, :profile_artifact_unavailable} = available(c, runtime)
  end

  test "a subsequent historical call and missing custody cannot inherit verification", c do
    {:ok, runtime} = ProfileBasis.runtime_digest()
    assert :ok = ProfileByteContext.prepare(c.db, c.custody, {:claim_lifx_power, nil})
    assert :ok = available(c, runtime)
    assert :ok = ProfileByteContext.prepare(c.db, c.custody, {:profile_operation_status, nil})
    assert {:error, :profile_artifact_unavailable} = available(c, runtime)
    assert :ok = ProfileByteContext.prepare(c.db, c.custody, {:record, nil})
    File.rm!(Path.join(c.root, c.artifact.digest <> ".json"))
    assert :ok = ProfileByteContext.prepare(c.db, c.custody, {:handoff_claimed_power, nil})
    assert {:error, :profile_artifact_unavailable} = available(c, runtime)
    assert :ok = ProfileByteContext.prepare(c.db, nil, {:record, nil})
    assert {:error, :profile_artifact_unavailable} = available(c, runtime)
  end

  test "TEMP commitments cannot enter a serialized recovery snapshot", c do
    assert :ok = ProfileByteContext.prepare(c.db, c.custody, {:record, nil})
    {:ok, bytes} = Sqlite3.serialize(c.db, "main")
    {:ok, copy} = Sqlite3.open(":memory:")

    try do
      assert :ok = Sqlite3.deserialize(copy, "main", bytes)

      assert {:ok, [[0]]} =
               SQL.query(
                 copy,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name='profile_byte_checks'"
               )

      assert {:ok, [[0]]} =
               SQL.query(
                 copy,
                 "SELECT COUNT(*) FROM sqlite_temp_master WHERE name='profile_byte_checks'"
               )
    after
      Sqlite3.close(copy)
    end
  end

  defp available(c, runtime),
    do:
      ProfileByteContext.available?(
        c.db,
        c.artifact.digest,
        c.artifact.projection_digest,
        c.registry,
        runtime
      )
end
