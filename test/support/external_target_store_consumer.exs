System.fetch_env!("HOME_AUTHORING_ARCHIVE_EBINS")
|> JSON.decode!()
|> Enum.each(&Code.prepend_path/1)

:code.purge(String.Chars)

{:module, String.Chars} =
  :code.load_abs(
    Path.join(:code.lib_dir(:elixir, :ebin), "Elixir.String.Chars")
    |> String.to_charlist()
  )

defmodule HomeExternalTargetStoreArchiveTest do
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{ExternalTargets, Integrity, SQL}

  alias WotexHome.Profiles.{
    AuthoringObject,
    Custody,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ReaderSelection
  }

  alias Exqlite.Sqlite3
  @owner __MODULE__.Store

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/" <> name <> ".json"))

  setup do
    root = Path.join(System.tmp_dir!(), "external-target-#{System.unique_integer([:positive])}")
    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root, store_owner: @owner})
    sources = start_supervised!({ExternalSourceOwner, publisher: self()})
    %{root: root, path: Path.join(root, "home.sqlite"), custody: custody, sources: sources}
  end

  defp prepare(c, family \\ "temperature") do
    source = fixture("external-source-selections")[family]["inputs"]
    r = source["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, selection} = ExternalSourceSelection.new(source["source"], reader, source["channels"])
    {:ok, _} = ExternalSourceOwner.publish(c.sources, selection)
    {:ok, catalogue} = ExternalSourceOwner.catalogue(c.sources)

    store =
      start_supervised!(
        {Store,
         path: c.path,
         profile_custody: c.custody,
         external_reader: reader,
         external_source_owner: c.sources,
         name: @owner}
      )

    {:ok, credential, revision} =
      Store.provision_principal(
        store,
        "operator:1",
        ["enroll:review", "host:maintain", "profile:manage"],
        []
      )

    v =
      if family == "multi",
        do: fixture("generic-read-semantics")["multi"]["fixture"],
        else: fixture(family)

    docs =
      [{"envelope", v["envelope"]}, {"profile", v["profile"]}] ++
        Enum.map(v["definitions"], &{"definition", &1})

    {handles, revision} =
      Enum.map_reduce(Enum.with_index(docs), revision, fn {{kind, data}, n}, revision ->
        {:ok, bytes} = Wotex.JSON.encode(data)
        {:ok, object} = AuthoringObject.new(kind, bytes)
        {:ok, summary} = AuthoringObject.summary(object)

        {:ok, receipt} =
          Store.import_authoring_object(
            store,
            credential,
            %{
              "authority_epoch" => 1,
              "operation_id" => "import:#{n}",
              "expected_revision" => revision,
              "object" => summary
            },
            bytes
          )

        {%{
           "object_digest" => summary["object_digest"],
           "first_revision" => receipt["first_revision"]
         }, receipt["revision"]}
      end)

    [envelope, profile | definitions] = handles

    objects = %{
      "envelope_ref" => envelope,
      "profile" => %{"reference" => v["envelope"]["profile"], "object_ref" => profile},
      "definitions" =>
        Enum.zip_with(
          v["envelope"]["definitions"],
          definitions,
          &%{"reference" => &1, "object_ref" => &2}
        )
    }

    {:ok, inspected} =
      Store.inspect_external_profile(store, credential, %{
        "authority_epoch" => 1,
        "operation_id" => "inspection:1",
        "expected_revision" => revision,
        "inspection" => Map.put(objects, "reader_basis_sha256", reader.data["basis_sha256"])
      })

    {:ok, barrier} =
      Store.begin_maintenance(store, credential, 1, "maintenance:1", inspected["revision"])

    artifact = fixture("external-target-selections")[family]["select"]["input"]["artifact_digest"]

    {:ok, approved} =
      Store.change_external_trust(store, credential, %{
        "authority_epoch" => 1,
        "operation_id" => "trust:1",
        "expected_revision" => barrier.revision,
        "action" => "approve",
        "artifact_digest" => artifact,
        "expected_trust_revision" => 0,
        "expected_policy_generation" => 0,
        "inspection_ref" =>
          Map.take(
            inspected,
            ~w(authority_epoch operation_id revision input_sha256 result_sha256)
          ),
        "acknowledgement" => "operator_digest_approval"
      })

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "selection:1",
      "expected_revision" => approved["revision"],
      "action" => "select",
      "target_id" => "sensor:external",
      "artifact_digest" => artifact,
      "expected_trust_revision" => approved["revision"],
      "expected_policy_generation" => approved["policy_generation"],
      "expected_selection_revision" => 0,
      "expected_resource_revision" => 0,
      "source_ref" => source["source"]["source_ref"],
      "source_owner_epoch" => catalogue["owner_epoch"],
      "source_selection_sha256" => selection.sha256,
      "objects" => objects,
      "acknowledgement" => "operator_external_selection"
    }

    Map.merge(c, %{
      store: store,
      credential: credential,
      reader: reader,
      selection: selection,
      input: input,
      trust: approved,
      authority: Authority.new(store: store, profile_custody: c.custody)
    })
  end

  test "source replacement during byte preparation fails the final commit guard and rolls back every target row",
       c do
    c = prepare(c)
    :ok = :sys.suspend(c.custody)
    source_owner = c.sources
    :erlang.trace(source_owner, true, [:receive])
    task = Task.async(fn -> Store.change_external_target(c.store, c.credential, c.input) end)

    try do
      assert_receive {:trace, ^source_owner, :receive, {:"$gen_call", _, {:checkout, _, _, _}}},
                     2000

      assert {:ok, %{"state" => "checked_out"}} =
               ExternalSourceOwner.status(source_owner, "operator:1", 1, "selection:1")

      s = c.selection

      assert {:ok, newer} =
               ExternalSourceSelection.new(
                 Map.put(s.inputs["source"], "source_generation", 2),
                 s.inputs["reader"],
                 s.inputs["channels"]
               )

      assert {:ok, _} = ExternalSourceOwner.publish(source_owner, newer)
    after
      :erlang.trace(source_owner, false, [:receive])
      :ok = :sys.resume(c.custody)
    end

    assert {:error, :external_source_retired} = Task.await(task, 5000)
    assert revision(c) == c.input["expected_revision"]
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_target_history")
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM enrolled_things")
    assert :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "stable identity cannot be rebound to another target even after revocation", c do
    c = prepare(c)
    {:ok, first} = Store.change_external_target(c.store, c.credential, c.input)
    {:ok, _} = Store.change_external_target(c.store, c.credential, revoke_input(c, first))

    other =
      Map.merge(c.input, %{
        "target_id" => "sensor:other",
        "operation_id" => "selection:other",
        "expected_revision" => revision(c)
      })

    assert {:error, :external_target_collision} =
             Store.change_external_target(c.store, c.credential, other)

    assert {:ok, [[1]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_target_current")
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "both operator permissions are required and exact originals are actor-scoped", c do
    c = prepare(c)
    {:ok, first} = Store.change_external_target(c.store, c.credential, c.input)
    {:ok, denied, _} = Store.provision_principal(c.store, "author:other", ["profile:manage"], [])

    assert {:error, :permission_denied} =
             Store.external_target_status(c.store, denied, 1, "selection:1")

    {:ok, other, _} =
      Store.provision_principal(
        c.store,
        "operator:other",
        ["enroll:review", "profile:manage"],
        []
      )

    assert :not_found = Store.external_target_status(c.store, other, 1, "selection:1")
    assert {:ok, ^first} = Store.external_target_status(c.store, c.credential, 1, "selection:1")
  end

  defp db(c), do: :sys.get_state(c.store).db

  test "actual optional producer removal preserves cold Store boot, original lookup and metadata-only revoke",
       c do
    c = prepare(c)
    {:ok, first} = Store.change_external_target(c.store, c.credential, c.input)
    stop_supervised(Store)
    module = Wotex.JSON
    {^module, beam, path} = :code.get_object_code(module)
    :code.purge(module)
    :code.delete(module)
    directory = path |> List.to_string() |> Path.dirname()
    true = :code.del_path(String.to_charlist(directory))

    try do
      refute Code.ensure_loaded?(module)
      store = start_supervised!({Store, path: c.path, name: @owner})
      c = %{c | store: store}
      assert {:ok, ^first} = Store.external_target_status(store, c.credential, 1, "selection:1")
      assert {:ok, ^first} = Store.change_external_target(store, c.credential, c.input)
      assert {:ok, _} = Store.change_external_target(store, c.credential, revoke_input(c, first))
      assert :ok = Integrity.validate_snapshot(db(c))
      refute Code.ensure_loaded?(module)
    after
      true = :code.add_patha(String.to_charlist(directory))
      {:module, ^module} = :code.load_binary(module, path, beam)
    end
  end

  test "erasing dependent retirement cannot revive selected authority while retaining its actual withdrawal cause",
       c do
    c = prepare(c)
    {:ok, first} = Store.change_external_target(c.store, c.credential, c.input)
    {:ok, retired_revision} = Store.revoke_principal(c.store, "operator:1")

    assert {:ok, []} =
             SQL.query(
               db(c),
               "UPDATE profile_external_target_current SET selection_revision=?,generation=1,state='selected',resource_revision=0",
               [first["revision"]]
             )

    assert {:ok, []} =
             SQL.query(
               db(c),
               "UPDATE enrolled_things SET status='active',resource_revision=0 WHERE thing_id='sensor:external'"
             )

    assert {:ok, []} =
             SQL.query(
               db(c),
               "DELETE FROM profile_external_target_history WHERE action='dependency_revoked'"
             )

    assert {:ok, []} =
             SQL.query(db(c), "DELETE FROM authority_journal WHERE revision=?", [retired_revision])

    assert {:error, :corrupt_external_targets} = ExternalTargets.validate(db(c))
  end

  for damage <- ~w(journal orphan binding generation import) do
    @damage damage
    test "#{@damage} corruption is detected without trusting a recomputed receipt digest", c do
      c = prepare(c)
      {:ok, receipt} = Store.change_external_target(c.store, c.credential, c.input)

      case @damage do
        "journal" ->
          SQL.query(
            db(c),
            "UPDATE authority_journal SET entity_id='sensor:wrong' WHERE revision=?",
            [receipt["revision"]]
          )

        "orphan" ->
          SQL.query(db(c), "DELETE FROM profile_external_target_operations")

        "binding" ->
          SQL.query(
            db(c),
            "UPDATE profile_external_source_bindings SET source_ref='source:wrong'"
          )

        "generation" ->
          SQL.query(db(c), "UPDATE profile_external_target_history SET generation=3")

        "import" ->
          changed = update_in(c.input, ["objects", "envelope_ref", "first_revision"], &(&1 + 1))
          {:ok, document} = WotexHome.Profiles.ExternalTarget.encode(changed)
          digest = Base.encode16(:crypto.hash(:sha256, document), case: :lower)

          {:ok, receipt_document} =
            WotexHome.Profiles.ExternalTarget.encode_receipt(
              Map.put(receipt, "input_sha256", digest)
            )

          SQL.query(
            db(c),
            "UPDATE profile_external_target_operations SET input_document=?,receipt_document=?",
            [document, receipt_document]
          )
      end

      assert {:error, :corrupt_external_targets} = Integrity.validate_snapshot(db(c))

      assert {:error, :corrupt_external_targets} =
               Store.external_target_status(c.store, c.credential, 1, "selection:1")

      refute :sys.get_state(c.store).writable
    end
  end

  test "schema 33 migration preserves approval and imports without promoting a target", c do
    c = prepare(c)
    stop_supervised(Store)
    {:ok, database} = Sqlite3.open(c.path)

    assert :ok =
             Sqlite3.execute(
               database,
               "DROP TABLE profile_external_source_bindings; DROP TABLE profile_external_target_current; DROP TABLE profile_external_target_history; DROP TABLE profile_external_target_operations; PRAGMA user_version=33"
             )

    assert :ok = Integrity.validate_snapshot(database)
    Sqlite3.close(database)
    store = start_supervised!({Store, path: c.path, name: @owner})
    c = %{c | store: store}
    assert {:ok, [[34]]} = SQL.query(db(c), "PRAGMA user_version")
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_target_current")
    assert {:ok, [[1]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_artifacts")
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  defp revision(c),
    do: SQL.query(db(c), "SELECT value FROM meta WHERE key='revision'") |> elem(1) |> hd() |> hd()

  defp revoke_input(c, receipt, operation \\ "selection:revoke"),
    do:
      c.input
      |> Map.merge(%{
        "action" => "revoke",
        "operation_id" => operation,
        "expected_revision" => revision(c),
        "expected_selection_revision" => receipt["revision"],
        "expected_resource_revision" => receipt["resource_revision"],
        "source_ref" => nil,
        "source_owner_epoch" => nil,
        "source_selection_sha256" => nil,
        "objects" => nil,
        "acknowledgement" => nil
      })

  for family <- ~w(temperature research multi) do
    @family family
    test "#{@family} selection persists in the shared Registry and exact original survives restart without source",
         c do
      c = prepare(c, @family)
      assert {:ok, first} = Authority.change_external_target(c.authority, c.credential, c.input)

      assert first["revision"] == c.input["expected_revision"] + 1 and
               first["resource_revision"] == 0

      assert {:ok, ^first} = Authority.change_external_target(c.authority, c.credential, c.input)

      assert {:ok, ^first} =
               Authority.external_target_status(c.authority, c.credential, 1, "selection:1")

      assert {:ok, [["active", 0]]} =
               SQL.query(
                 db(c),
                 "SELECT status,resource_revision FROM enrolled_things WHERE thing_id='sensor:external'"
               )

      assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM principal_targets")
      assert :ok = Integrity.validate_snapshot(db(c))
      stop_supervised(Store)
      store = start_supervised!({Store, path: c.path, name: @owner})
      assert {:ok, ^first} = Store.change_external_target(store, c.credential, c.input)
      c = %{c | store: store}

      assert {:ok, revoked} =
               Store.change_external_target(store, c.credential, revoke_input(c, first))

      assert revoked["resource_revision"] == 1 and
               revoked["binding_revision"] == first["revision"]

      assert :ok = Integrity.validate_snapshot(db(c))
    end
  end

  test "replacement withdraws explicit grants and revocation keeps a reusable identity tombstone",
       c do
    c = prepare(c)
    {:ok, first} = Store.change_external_target(c.store, c.credential, c.input)

    {:ok, _reader, grant_revision} =
      Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

    replacement =
      Map.merge(c.input, %{
        "operation_id" => "selection:replace",
        "expected_revision" => grant_revision,
        "expected_selection_revision" => first["revision"]
      })

    assert {:ok, second} = Store.change_external_target(c.store, c.credential, replacement)
    assert second["withdrawn_grants"] == 1 and second["resource_revision"] == 1
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM principal_targets")

    assert {:ok, revoked} =
             Store.change_external_target(c.store, c.credential, revoke_input(c, second))

    next =
      Map.merge(c.input, %{
        "operation_id" => "selection:again",
        "expected_revision" => revision(c),
        "expected_selection_revision" => revoked["revision"],
        "expected_resource_revision" => revoked["resource_revision"]
      })

    assert {:ok, third} = Store.change_external_target(c.store, c.credential, next)
    assert third["resource_revision"] == 3 and third["selection_generation"] == 4
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "fresh CAS, owner SHA and previous target guards refuse without durable mutation", c do
    c = prepare(c)

    for {key, value, reason} <- [
          {"expected_revision", 0, :resnapshot_required},
          {"authority_epoch", 2, :stale_authority_epoch},
          {"expected_policy_generation", 0, :external_policy_changed},
          {"expected_trust_revision", 0, :external_trust_changed},
          {"expected_selection_revision", 1, :external_selection_changed},
          {"source_selection_sha256", String.duplicate("0", 64), :stale_external_source},
          {"source_owner_epoch", String.duplicate("0", 32), :external_source_owner_changed}
        ] do
      assert {:error, ^reason} =
               Store.change_external_target(c.store, c.credential, Map.put(c.input, key, value))

      assert revision(c) == c.input["expected_revision"]

      assert {:ok, [[0]]} =
               SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_target_operations")
    end

    assert {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)

    assert {:error, :external_target_conflict} =
             Store.change_external_target(
               c.store,
               c.credential,
               Map.put(c.input, "target_id", "sensor:other")
             )
  end

  test "actual SQLite refusal rolls back target rows and retires the original source snapshot",
       c do
    c = prepare(c)

    assert :ok =
             Sqlite3.execute(
               db(c),
               "CREATE TEMP TRIGGER refuse_target BEFORE INSERT ON profile_external_target_current BEGIN SELECT RAISE(ABORT,'fixture'); END"
             )

    assert {:error, :store_unavailable} =
             Store.change_external_target(c.store, c.credential, c.input)

    assert revision(c) == c.input["expected_revision"]
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_target_history")
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM enrolled_things")

    assert {:ok, %{"state" => "consumed"}} =
             ExternalSourceOwner.status(c.sources, "operator:1", 1, "selection:1")
  end

  test "trust withdrawal retires selection in the same transaction and replay cannot revive it",
       c do
    c = prepare(c)
    {:ok, first} = Store.change_external_target(c.store, c.credential, c.input)

    revoke = %{
      "authority_epoch" => 1,
      "operation_id" => "trust:revoke",
      "expected_revision" => revision(c),
      "action" => "revoke",
      "artifact_digest" => c.input["artifact_digest"],
      "expected_trust_revision" => c.trust["revision"],
      "expected_policy_generation" => 1,
      "inspection_ref" => nil,
      "acknowledgement" => nil
    }

    assert {:ok, trust} = Store.change_external_trust(c.store, c.credential, revoke)

    assert {:ok, [["revoked", 1]]} =
             SQL.query(
               db(c),
               "SELECT state,resource_revision FROM profile_external_target_current"
             )

    assert {:ok, [[cause]]} =
             SQL.query(
               db(c),
               "SELECT cause_revision FROM profile_external_target_history WHERE action='dependency_revoked'"
             )

    assert cause == trust["revision"]
    assert {:ok, ^first} = Store.change_external_target(c.store, c.credential, c.input)
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "latest selector withdrawal retires the target and hides actor originals", c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    assert {:ok, final} = Store.revoke_principal(c.store, "operator:1")
    assert final == revision(c)

    assert {:ok, [["revoked"]]} =
             SQL.query(db(c), "SELECT state FROM profile_external_target_current")

    assert {:error, :unauthorized} =
             Store.external_target_status(c.store, c.credential, 1, "selection:1")

    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "retirement SQL fault rolls back the trust original and its policy generation", c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    before = revision(c)

    assert :ok =
             Sqlite3.execute(
               db(c),
               "CREATE TEMP TRIGGER refuse_retirement BEFORE INSERT ON profile_external_target_history WHEN NEW.action='dependency_revoked' BEGIN SELECT RAISE(ABORT,'fixture'); END"
             )

    revoke = %{
      "authority_epoch" => 1,
      "operation_id" => "trust:revoke",
      "expected_revision" => before,
      "action" => "revoke",
      "artifact_digest" => c.input["artifact_digest"],
      "expected_trust_revision" => c.trust["revision"],
      "expected_policy_generation" => 1,
      "inspection_ref" => nil,
      "acknowledgement" => nil
    }

    assert {:error, :store_unavailable} =
             Store.change_external_trust(c.store, c.credential, revoke)

    assert revision(c) == before

    assert {:ok, [[1]]} =
             SQL.query(
               db(c),
               "SELECT value FROM meta WHERE key='external_profile_policy_generation'"
             )

    assert {:ok, [["selected"]]} =
             SQL.query(db(c), "SELECT state FROM profile_external_target_current")

    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "deep current corruption refuses original reads and fences writes", c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)

    assert {:ok, []} =
             SQL.query(db(c), "UPDATE profile_external_target_current SET resource_revision=3")

    assert {:error, :corrupt_external_targets} = ExternalTargets.validate(db(c))

    assert {:error, :corrupt_external_targets} =
             Store.external_target_status(c.store, c.credential, 1, "selection:1")

    refute :sys.get_state(c.store).writable
  end

  test "inclusive and database-only encrypted quarantine retain target originals and private basis",
       c do
    c = prepare(c)
    {:ok, first} = Store.change_external_target(c.store, c.credential, c.input)
    key = :crypto.strong_rand_bytes(32)
    source_revision = revision(c)

    assert {:ok, retained} =
             WotexHome.Durable.Store.RecoverySnapshot.retained_commitment(
               db(c),
               source_revision,
               "operator:fresh"
             )

    for mode <- [:inclusive, :database] do
      archive = Path.join(c.root, "#{mode}.backup")

      if mode == :inclusive do
        assert {:ok, _} = Store.export_profile_backup(c.store, archive, key)
      else
        assert {:ok, _} = Store.export_backup(c.store, archive, key)
      end

      assert {:ok, _} = Backup.verify(archive, key)
      target = Path.join(c.root, "restore-#{mode}")

      path =
        if mode == :inclusive do
          assert {:ok, _} = Backup.stage_profile_restore(archive, key, target)
          Path.join(target, "home.sqlite")
        else
          assert {:ok, _} = Backup.stage_restore(archive, key, target)
          target
        end

      {:ok, database} = Sqlite3.open(path)
      assert :ok = Integrity.validate_snapshot(database)

      assert {:ok, [[document]]} =
               SQL.query(
                 database,
                 "SELECT receipt_document FROM profile_external_target_operations"
               )

      assert {:ok, ^first} = WotexHome.Profiles.ExternalTarget.decode_receipt(document)

      assert {:ok, [[1]]} =
               SQL.query(database, "SELECT COUNT(*) FROM profile_external_source_bindings")

      assert {:ok, ^retained} =
               WotexHome.Durable.Store.RecoverySnapshot.retained_commitment(
                 database,
                 source_revision,
                 "operator:fresh"
               )

      Sqlite3.close(database)
    end
  end
end
