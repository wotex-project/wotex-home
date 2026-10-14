System.fetch_env!("HOME_AUTHORING_ARCHIVE_EBINS")
|> JSON.decode!()
|> Enum.each(fn path ->
  true = Code.prepend_path(path)
end)

# Home's ordinary test project does not contain these optional dependency
# implementations when it consolidates protocols. Restore OTP/Elixir's original
# dynamic protocol for this isolated archive-backed process only.
:code.purge(String.Chars)

{:module, String.Chars} =
  :code.load_abs(
    Path.join(:code.lib_dir(:elixir, :ebin), "Elixir.String.Chars")
    |> String.to_charlist()
  )

defmodule HomeAuthoringStoreArchiveTest do
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Profiles.{AuthoringCandidate, AuthoringContract, AuthoringObject, Custody}
  alias Exqlite.Sqlite3
  @owner __MODULE__.Store

  defp fixture(family),
    do: JSON.decode!(File.read!("test/fixtures/profiles/" <> family <> ".json"))

  setup do
    root = Path.join(System.tmp_dir!(), "candidate-archive-#{System.unique_integer([:positive])}")
    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root, store_owner: @owner})
    v = fixture("temperature")

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", %{
        "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
        "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
        "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
      })

    limits = fixture("authoring-mechanics")["temperature"]["limits"]
    {:ok, contract} = AuthoringContract.export(installed, limits)
    path = Path.join(root, "home.sqlite")

    store =
      start_supervised!(
        {Store, path: path, profile_custody: custody, authoring_contract: contract, name: @owner}
      )

    {:ok, credential, 1} = Store.provision_principal(store, "author:1", ["profile:manage"], [])

    %{
      root: root,
      path: path,
      store: store,
      custody: custody,
      credential: credential,
      contract: contract,
      authority: Authority.new(store: store, profile_custody: custody)
    }
  end

  defp import(c, kind, bytes, revision, operation) do
    {:ok, o} = AuthoringObject.new(kind, bytes)
    {:ok, s} = AuthoringObject.summary(o)

    {:ok, r} =
      Store.import_authoring_object(
        c.store,
        c.credential,
        %{
          "authority_epoch" => 1,
          "operation_id" => operation,
          "expected_revision" => revision,
          "object" => s
        },
        bytes
      )

    %{"object_digest" => s["object_digest"], "first_revision" => r["first_revision"]}
  end

  defp input(c, ref, revision, operation \\ "candidate:1") do
    %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "request" => %{
        "mode" => "manual",
        "contract_digest" => c.contract.contract_sha256,
        "base_draft_ref" => ref,
        "source_refs" => [],
        "fixture_refs" => [],
        "instruction" => "manual review",
        "limits" => c.contract.inputs["limits"]
      }
    }
  end

  defp draft(family), do: fixture("authoring-mechanics")[family]["draft_bytes"]

  defp retain_fixture_row(db, input, assessment_document, base_receipt) do
    revision = input["expected_revision"] + 1
    {:ok, document} = AuthoringCandidate.encode(input)

    receipt =
      Map.merge(base_receipt, %{
        "operation_id" => input["operation_id"],
        "revision" => revision,
        "input_sha256" => sha(document),
        "assessment_sha256" => sha(assessment_document)
      })

    {:ok, receipt_document} = AuthoringCandidate.encode_receipt(receipt)

    {:ok, []} =
      SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
        revision,
        "authoring_candidate_assessed",
        input["operation_id"]
      ])

    {:ok, []} =
      SQL.query(db, "INSERT INTO profile_authoring_candidates VALUES (?,?,?,?,?,?,?)", [
        "author:1",
        1,
        input["operation_id"],
        document,
        assessment_document,
        receipt_document,
        revision
      ])

    {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [revision])
    {revision, byte_size(document), byte_size(assessment_document)}
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp assessment_fixture_bytes(data, target) do
    [diagnostic] = data["report"]["diagnostics"]
    {:ok, smallest} = AuthoringCandidate.encode_assessment(data)
    two = put_in(data, ["report", "diagnostics"], [diagnostic, diagnostic])
    {:ok, second} = AuthoringCandidate.encode_assessment(two)
    increment = byte_size(second) - byte_size(smallest)
    extra = target - byte_size(smallest)
    count = min(64, div(extra, increment) + 1)
    padding = extra - (count - 1) * increment
    path = if padding == 0, do: "", else: "/" <> String.duplicate("x", padding - 1)

    diagnostics =
      List.duplicate(diagnostic, count)
      |> List.replace_at(count - 1, Map.put(diagnostic, "instance_path", path))

    {:ok, bytes} =
      AuthoringCandidate.encode_assessment(put_in(data, ["report", "diagnostics"], diagnostics))

    assert byte_size(bytes) == target
    bytes
  end

  test "the retained assessment-byte ceiling is exact and cannot be spent by another original",
       c do
    ref = import(c, "draft", "{", 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[original]]} =
      SQL.query(db, "SELECT assessment_document FROM profile_authoring_candidates")

    {:ok, data} = AuthoringCandidate.decode_assessment(original)
    # These are bounded historical metadata fixtures, not new producer truth.
    full =
      put_in(
        data,
        ["report", "diagnostics"],
        List.duplicate(hd(data["report"]["diagnostics"]), 64)
      )

    {:ok, full_document} = AuthoringCandidate.encode_assessment(full)
    :ok = Sqlite3.execute(db, "BEGIN")

    {revision, total, count} =
      Enum.reduce_while(4..1026, {3, byte_size(original), 1}, fn revision, {_, total, count} ->
        remaining = 4_194_304 - total

        if remaining == 0 do
          {:halt, {revision - 1, total, count}}
        else
          size = min(byte_size(full_document), remaining)
          leftover = remaining - size

          size =
            if leftover > 0 and leftover < byte_size(original),
              do: size - byte_size(original),
              else: size

          document = assessment_fixture_bytes(data, size)

          retain_fixture_row(
            db,
            input(c, ref, revision - 1, "candidate:#{revision}"),
            document,
            receipt
          )

          {:cont, {revision, total + size, count + 1}}
        end
      end)

    :ok = Sqlite3.execute(db, "COMMIT")
    assert total == 4_194_304 and count < 1024
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, revision, "over-assessments")
             )

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{object_count: 1, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "explicit source and fixture handles retain ownership without falsely claiming fixture comparison",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    source = import(c, "source", "independent source", 2, "import:2")
    fixture = import(c, "fixture", "[]", 3, "import:3")

    i =
      input(c, ref, 4)
      |> put_in(["request", "source_refs"], [source])
      |> put_in(["request", "fixture_refs"], [fixture])

    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    assert receipt["fixture_status"] == "not_assessed"
    assert receipt["source_review"] == "not_assessed"
    assert {:ok, ^receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    wrong = input(c, ref, 5, "candidate:2") |> put_in(["request", "source_refs"], [ref])

    assert {:error, :stale_authoring_reference} =
             Store.assess_authoring_candidate(c.store, c.credential, wrong)

    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "1024 retained originals refuse a new original before payload publication but allow exact replay",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[assessment]]} =
      SQL.query(db, "SELECT assessment_document FROM profile_authoring_candidates")

    :ok = Sqlite3.execute(db, "BEGIN")

    for revision <- 4..1026 do
      retain_fixture_row(
        db,
        input(c, ref, revision - 1, "candidate:#{revision}"),
        assessment,
        receipt
      )
    end

    :ok = Sqlite3.execute(db, "COMMIT")
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 1026, "over-bound")
             )

    assert {:ok, ^receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    assert {:ok, 1026} = Store.revision(c.store)
    assert {:ok, %{object_count: 2, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "the retained input-byte ceiling refuses even below the original count bound", c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
    db = :sys.get_state(c.store).db

    {:ok, [[assessment, original]]} =
      SQL.query(db, "SELECT assessment_document,input_document FROM profile_authoring_candidates")

    :ok = Sqlite3.execute(db, "BEGIN")

    {revision, total, count} =
      Enum.reduce_while(4..1026, {3, byte_size(original), 1}, fn revision, {_, total, count} ->
        next =
          input(c, ref, revision - 1, "candidate:#{revision}")
          |> put_in(["request", "instruction"], String.duplicate("x", 4096))

        {:ok, doc} = AuthoringCandidate.encode(next)

        if total + byte_size(doc) <= 4_194_304 do
          retain_fixture_row(db, next, assessment, receipt)
          {:cont, {revision, total + byte_size(doc), count + 1}}
        else
          remaining = 4_194_304 - total

          next =
            put_in(
              next,
              ["request", "instruction"],
              String.duplicate("x", max(0, 4096 - (byte_size(doc) - remaining)))
            )

          {:ok, doc} = AuthoringCandidate.encode(next)

          if byte_size(doc) <= remaining do
            retain_fixture_row(db, next, assessment, receipt)
            {:halt, {revision, total + byte_size(doc), count + 1}}
          else
            {:halt, {revision - 1, total, count}}
          end
        end
      end)

    :ok = Sqlite3.execute(db, "COMMIT")
    assert count < 1024 and total == 4_194_304
    assert :ok = Integrity.validate_snapshot(db)

    next =
      input(c, ref, revision, "over-bytes")
      |> put_in(["request", "instruction"], String.duplicate("x", 4096))

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(c.store, c.credential, next)

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{object_count: 2, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "128 shared retained frames stop both a new derived bundle and a new imported source before publication",
       c do
    first = import(c, "draft", draft("temperature"), 1, "import:1")
    second = import(c, "draft", draft("research"), 2, "import:2")

    assert {:ok, candidate} =
             Store.assess_authoring_candidate(c.store, c.credential, input(c, first, 3))

    revision =
      Enum.reduce(1..125, 4, fn index, revision ->
        import(c, "source", "source:#{index}", revision, "source:#{index}")
        revision + 1
      end)

    assert {:ok, %{object_count: 128}} = Custody.inventory(c.custody)

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, second, revision, "candidate:2")
             )

    {:ok, object} = AuthoringObject.new("source", "must remain absent")
    {:ok, summary} = AuthoringObject.summary(object)

    assert {:error, :authoring_object_capacity} =
             Store.import_authoring_object(
               c.store,
               c.credential,
               %{
                 "authority_epoch" => 1,
                 "operation_id" => "over-custody",
                 "expected_revision" => revision,
                 "object" => summary
               },
               "must remain absent"
             )

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{object_count: 128, lease_count: 0}} = Custody.inventory(c.custody)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)

    # Files can be missing while immutable candidate history remains retained.
    # Filling that filesystem hole with v1 bytes must not bypass the logical union.
    File.rm!(Path.join([c.root, "profiles", candidate["bundle"]["object_digest"] <> ".json"]))
    bytes = File.read!("test/support/profiles/lifx-power.json")
    assert {:ok, digest} = Custody.stage(c.custody, bytes)

    {:ok, manager, next} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    assert {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", next)

    assert {:error, :profile_capacity} =
             Store.profile_change(c.store, c.credential, %{
               "action" => "approve",
               "authority_epoch" => 1,
               "operation_id" => "legacy:over",
               "expected_revision" => barrier.revision,
               "artifact_digest" => digest,
               "expected_trust_revision" => 0
             })

    assert {:ok, %{writable: true}} = Store.health(c.store)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  for corruption <- [:receipt, :journal, :reference] do
    @corruption corruption
    test "tampered #{@corruption} correspondence is refused without renewed current authority",
         c do
      ref = import(c, "draft", draft("temperature"), 1, "import:1")
      i = input(c, ref, 2)
      assert {:ok, receipt} = Store.assess_authoring_candidate(c.store, c.credential, i)
      db = :sys.get_state(c.store).db

      case @corruption do
        :receipt ->
          {:ok, doc} =
            AuthoringCandidate.encode_receipt(Map.put(receipt, "operation_id", "other"))

          {:ok, []} =
            SQL.query(db, "UPDATE profile_authoring_candidates SET receipt_document=?", [doc])

        :journal ->
          {:ok, []} =
            SQL.query(db, "UPDATE authority_journal SET entity_id='other' WHERE revision=3")

        :reference ->
          changed = put_in(i, ["request", "base_draft_ref", "first_revision"], 1)
          {:ok, doc} = AuthoringCandidate.encode(changed)
          {:ok, r} = AuthoringCandidate.encode_receipt(Map.put(receipt, "input_sha256", sha(doc)))

          {:ok, []} =
            SQL.query(
              db,
              "UPDATE profile_authoring_candidates SET input_document=?,receipt_document=?",
              [doc, r]
            )
      end

      assert {:error, :corrupt_authoring_candidates} = Integrity.validate_snapshot(db)

      assert {:error, :corrupt_authoring_candidates} =
               Store.authoring_candidate_status(c.store, c.credential, 1, "candidate:1")

      assert {:error, :store_unavailable} =
               Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 3, "new"))
    end
  end

  test "the shared 4-MiB complete-frame ceiling stops a derived bundle below the object count limit",
       c do
    first = import(c, "draft", draft("temperature"), 1, "import:1")
    second = import(c, "draft", draft("research"), 2, "import:2")
    assert {:ok, _} = Store.assess_authoring_candidate(c.store, c.credential, input(c, first, 3))
    {:ok, inventory} = Custody.inventory(c.custody)

    {revision, total} =
      Enum.reduce_while(1..32, {4, inventory.total_bytes}, fn index, {revision, total} ->
        remaining = 4_194_304 - total

        if remaining == 0 do
          {:halt, {revision, total}}
        else
          size = min(262_144, remaining - 42)
          prefix = "source:#{index}:"
          bytes = prefix <> String.duplicate("x", size - byte_size(prefix))
          import(c, "source", bytes, revision, "source:#{index}")
          {:cont, {revision + 1, total + size + 42}}
        end
      end)

    assert total == 4_194_304
    assert {:ok, %{object_count: count, total_bytes: 4_194_304}} = Custody.inventory(c.custody)
    assert count < 128

    assert {:error, :authoring_candidate_capacity} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, second, revision, "candidate:2")
             )

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{total_bytes: 4_194_304, lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "both manual quantities retain exact original bundle/assessment identities and immutable receipts",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, r} = Authority.assess_authoring_candidate(c.authority, c.credential, i)

    assert r["revision"] == 3 and r["disposition"] == "compatible" and
             r["capture_status"] == "not_supplied"

    assert r["bundle"]["payload_sha256"] ==
             fixture("authoring-mechanics")["temperature"]["bundle_sha256"]

    assert {:ok, ^r} = Store.assess_authoring_candidate(c.store, c.credential, i)

    assert {:ok, ^r} =
             Authority.authoring_candidate_status(c.authority, c.credential, 1, "candidate:1")

    assert {:error, :authoring_operation_conflict} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               put_in(i, ["request", "instruction"], "changed")
             )

    ref = import(c, "draft", draft("research"), 3, "import:2")

    assert {:ok, r} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 4, "candidate:2")
             )

    assert r["bundle"]["payload_sha256"] ==
             fixture("authoring-mechanics")["research"]["bundle_sha256"]

    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "original lookup survives missing bytes, absent configured producer and restart", c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)
    assert {:ok, r} = Store.assess_authoring_candidate(c.store, c.credential, i)
    File.rm!(Path.join([c.root, "profiles", ref["object_digest"] <> ".json"]))
    File.rm!(Path.join([c.root, "profiles", r["bundle"]["object_digest"] <> ".json"]))

    producer_path = :code.which(Wotex.Profiles.Artifacts) |> List.to_string() |> Path.dirname()
    true = Code.delete_path(producer_path)
    :code.purge(Wotex.Profiles.Artifacts)
    :code.delete(Wotex.Profiles.Artifacts)

    try do
      refute Code.ensure_loaded?(Wotex.Profiles.Artifacts)
      assert {:ok, ^r} = Store.assess_authoring_candidate(c.store, c.credential, i)

      assert {:error, :profiles_producer_unavailable} =
               Store.assess_authoring_candidate(
                 c.store,
                 c.credential,
                 input(c, ref, 3, "producer:absent")
               )
    after
      true = Code.prepend_path(producer_path)
      assert Code.ensure_loaded?(Wotex.Profiles.Artifacts)
    end

    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @owner})
    assert {:ok, ^r} = Store.assess_authoring_candidate(store, c.credential, i)
    assert {:ok, ^r} = Store.authoring_candidate_status(store, c.credential, 1, "candidate:1")
    assert {:ok, 3} = Store.revision(store)
    assert :not_found = Store.authoring_candidate_status(store, c.credential, 1, "absent")
  end

  test "invalid syntax and producer-compatible shape with unsupported selector stay invalid proposals",
       c do
    ref = import(c, "draft", "{", 1, "import:1")
    assert {:ok, r} = Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))
    assert r["disposition"] == "invalid" and r["bundle"] == nil

    data =
      JSON.decode!(draft("temperature"))
      |> put_in(["profile", "channels", Access.at(0), "selector"], %{
        "unknown-selector" => "private-canary"
      })

    ref = import(c, "draft", JSON.encode!(data), 3, "import:2")

    assert {:ok, r} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 4, "candidate:2")
             )

    assert r["disposition"] == "invalid"
    refute inspect(r) =~ "private-canary"

    assert {:ok, [[_, assessment]]} =
             SQL.query(
               :sys.get_state(c.store).db,
               "SELECT revision,assessment_document FROM profile_authoring_candidates WHERE revision=5"
             )

    assert {:ok, a} = AuthoringCandidate.decode_assessment(assessment)
    assert a["report"]["diagnostics"] != []
  end

  test "permission, current CAS/epoch/contract and complete actor-owned reference checks precede assessment",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    i = input(c, ref, 2)

    assert {:error, :resnapshot_required} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "expected_revision", 1)
             )

    assert {:error, :stale_authority_epoch} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "authority_epoch", 2)
             )

    assert {:error, :stale_authoring_basis} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               put_in(i, ["request", "contract_digest"], String.duplicate("0", 64))
             )

    assert {:error, :stale_authoring_reference} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               put_in(i, ["request", "base_draft_ref", "first_revision"], 1)
             )

    {:ok, other, 3} = Store.provision_principal(c.store, "author:2", ["profile:manage"], [])

    assert :not_found =
             Store.assess_authoring_candidate(c.store, other, Map.put(i, "expected_revision", 3))

    {:ok, reader, 4} = Store.provision_principal(c.store, "reader:1", ["read"], [])
    assert {:error, :permission_denied} = Store.assess_authoring_candidate(c.store, reader, i)
    {:ok, manager, 5} = Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])
    assert {:ok, barrier} = Store.begin_maintenance(c.store, manager, 1, "maint:1", 5)

    assert {:error, :maintenance_active} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               Map.put(i, "expected_revision", barrier.revision)
             )

    assert {:ok, _} = Store.revoke_principal(c.store, "author:1")
    assert {:error, :unauthorized} = Store.assess_authoring_candidate(c.store, c.credential, i)
  end

  test "SQL fault rolls back candidate, event and revision, releases leases and leaves a collectable inert bundle",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    db = :sys.get_state(c.store).db

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TEMP TRIGGER refuse_candidate BEFORE INSERT ON profile_authoring_candidates BEGIN SELECT RAISE(ABORT,'fixture'); END"
      )

    assert {:error, :store_unavailable} =
             Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))

    assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_candidates")
    assert {:ok, [[2]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_candidate_assessed'"
             )

    assert {:ok, %{object_count: 2, lease_count: 0}} = Custody.inventory(c.custody)
    assert :ok = Integrity.validate_snapshot(db)
  end

  test "candidate bundle references survive collection and authenticated inclusive quarantine restore",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    assert {:ok, r} = Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))
    {:ok, manager, 4} = Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])
    assert {:ok, _} = Store.begin_maintenance(c.store, manager, 1, "maint:1", 4)
    assert {:ok, _} = Custody.stage_object(c.custody, "source", "orphan")
    assert {:ok, %{removed_objects: 1}} = Store.collect_profiles(c.store, c.credential)
    assert {:ok, _} = Custody.read_object(c.custody, r["bundle"]["object_digest"])
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "inclusive.backup")
    assert {:ok, %{authoring_objects: 2}} = Store.export_profile_backup(c.store, archive, key)
    assert {:ok, report} = Backup.verify(archive, key)

    assert length(report.dependencies.authoring_objects) == 2 and
             report.dependencies.authoring_bytes_included

    target = Path.join(c.root, "quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, key, target)
    {:ok, db} = Sqlite3.open(Path.join(target, "home.sqlite"))
    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, [[receipt]]} =
             SQL.query(db, "SELECT receipt_document FROM profile_authoring_candidates")

    assert {:ok, ^r} = AuthoringCandidate.decode_receipt(receipt)
    Sqlite3.close(db)

    database = Path.join(c.root, "database.backup")
    assert {:ok, _} = Store.export_backup(c.store, database, key)
    assert {:ok, metadata} = Backup.verify(database, key)
    refute metadata.dependencies.authoring_bytes_included
    assert length(metadata.dependencies.authoring_objects) == 2

    assert {:ok, %{quarantined: true}} =
             Backup.stage_restore(database, key, Path.join(c.root, "database.sqlite"))

    assert {:error, :profile_bytes_missing} =
             Backup.stage_profile_restore(database, key, Path.join(c.root, "incomplete"))

    File.rm!(Path.join([c.root, "profiles", r["bundle"]["object_digest"] <> ".json"]))

    assert {:error, :authoring_object_unavailable} =
             Store.export_profile_backup(c.store, Path.join(c.root, "missing.backup"), key)
  end

  test "changed retained assessment is corrupt history and cannot admit a new candidate", c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    assert {:ok, _} = Store.assess_authoring_candidate(c.store, c.credential, input(c, ref, 2))
    db = :sys.get_state(c.store).db

    assert {:ok, []} =
             SQL.query(db, "UPDATE profile_authoring_candidates SET assessment_document='[]'")

    assert {:error, :corrupt_authoring_candidates} = Integrity.validate_snapshot(db)

    assert {:error, :corrupt_authoring_candidates} =
             Store.authoring_candidate_status(c.store, c.credential, 1, "candidate:1")

    assert {:error, :store_unavailable} =
             Store.assess_authoring_candidate(
               c.store,
               c.credential,
               input(c, ref, 3, "candidate:2")
             )
  end

  test "schema 29 migration retains actual owned drafts and creates only an empty candidate table",
       c do
    ref = import(c, "draft", draft("temperature"), 1, "import:1")
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "DROP TABLE profile_authoring_candidates; PRAGMA user_version=29;")
    assert :ok = Integrity.validate_schema_version(29, db)
    Sqlite3.close(db)

    store =
      start_supervised!(
        {Store,
         path: c.path, profile_custody: c.custody, authoring_contract: c.contract, name: @owner}
      )

    assert {:ok, 2} = Store.revision(store)
    assert {:ok, [[30]]} = SQL.query(:sys.get_state(store).db, "PRAGMA user_version")

    assert {:ok, [[0]]} =
             SQL.query(
               :sys.get_state(store).db,
               "SELECT COUNT(*) FROM profile_authoring_candidates"
             )

    assert {:ok, _} = Store.read_authoring_object(store, c.credential, ref["object_digest"])
  end
end
