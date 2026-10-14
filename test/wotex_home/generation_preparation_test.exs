defmodule WotexHome.GenerationPreparationTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias Exqlite.Sqlite3
  alias WotexHome.{Authority, Profiles.Custody}
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{GenerationPreparations, Integrity, RecoverySnapshot, SQL}

  alias WotexHome.Profiles.{
    AuthoringContract,
    AuthoringObject,
    GenerationPolicy,
    GenerationPreparation,
    ProducerIdentity
  }

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "generation-preparation-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(Path.join(root, "profiles"))
    File.chmod!(Path.join(root, "profiles"), 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp contract(family) do
    {:ok, producer} = ProducerIdentity.current()

    installed =
      Map.take(fixture(family), ~w(bindings contracts home_contracts))
      |> Map.put("producer", producer)

    {:ok, contract} =
      AuthoringContract.export(installed, fixture("authoring-mechanics")[family]["limits"])

    contract
  end

  defp boot(root, family, overrides \\ []) do
    vector = fixture("generation-preparations")[family]
    {:ok, policy} = GenerationPolicy.new(vector["policy"])
    selected = contract(family)

    opts =
      [
        path: Path.join(root, "home.sqlite"),
        profile_custody: __MODULE__.Custody,
        authoring_contract: selected,
        generation_policies: [policy]
      ]
      |> Keyword.merge(overrides)

    store = start_supervised!({Store, opts}, id: :store)

    custody =
      start_supervised!(
        {Custody,
         root: Path.join(root, "profiles"), store_owner: store, name: __MODULE__.Custody},
        id: :custody
      )

    %{
      store: store,
      family: family,
      custody: custody,
      opts: opts,
      vector: vector,
      policy: policy,
      contract: selected,
      authority: Authority.new(store: store)
    }
  end

  defp seed(ctx) do
    {:ok, credential, 1} =
      Store.provision_principal(
        ctx.store,
        "author:fixture",
        ["profile:manage", "host:maintain"],
        []
      )

    for n <- 2..6,
        do:
          assert({:ok, _, ^n} = Store.provision_principal(ctx.store, "reader:#{n}", ["read"], []))

    source =
      Enum.find(fixture("generation-inputs")[family(ctx)]["objects"], &(&1["kind"] == "source"))

    example =
      Enum.find(fixture("generation-inputs")[family(ctx)]["objects"], &(&1["kind"] == "fixture"))

    import_object(ctx.store, credential, source, 6, "source:import")
    assert {:ok, _, 8} = Store.provision_principal(ctx.store, "reader:8", ["read"], [])
    import_object(ctx.store, credential, example, 8, "fixture:import")
    Map.put(ctx, :credential, credential)
  end

  defp family(ctx), do: ctx.family

  defp import_object(store, credential, row, revision, operation) do
    payload = Base.decode64!(row["payload_base64"])
    {:ok, object} = AuthoringObject.new(row["kind"], payload)
    {:ok, summary} = AuthoringObject.summary(object)

    input = %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "object" => summary
    }

    assert {:ok, receipt} = Store.import_authoring_object(store, credential, input, payload)
    assert receipt["first_revision"] == row["reference"]["first_revision"]
  end

  defp input(ctx, operation \\ "generation:fixture") do
    {:ok, revision} = Store.revision(ctx.store)

    ctx.vector["request"]
    |> Map.put("operation_id", operation)
    |> Map.put("expected_revision", revision)
  end

  defp restart(ctx) do
    stop_supervised!(:custody)
    stop_supervised!(:store)
    store = start_supervised!({Store, ctx.opts}, id: :store)

    custody =
      start_supervised!(
        {Custody,
         root: Path.join(Path.dirname(ctx.opts[:path]), "profiles"),
         store_owner: store,
         name: __MODULE__.Custody},
        id: :custody
      )

    %{ctx | store: store, custody: custody, authority: Authority.new(store: store)}
  end

  test "independent ordered policy, operation and receipt vectors round-trip exactly" do
    for family <- ~w(temperature research) do
      v = fixture("generation-preparations")[family]
      assert {:ok, p} = GenerationPolicy.new(v["policy"])
      assert p.sha256 == v["policy_sha256"] and p.provider_sha256 == v["provider_sha256"]
      assert :ok = GenerationPolicy.validate(p)
      assert {:ok, document} = GenerationPreparation.encode(v["request"])
      assert document == v["document"]
      assert {:ok, decoded} = GenerationPreparation.decode(document)
      assert decoded == v["request"]
      assert {:ok, receipt} = GenerationPreparation.encode_receipt(v["receipt"])
      assert receipt == v["receipt_document"]
      assert {:ok, decoded} = GenerationPreparation.decode_receipt(receipt)
      assert decoded == v["receipt"]
      refute inspect(p, limit: :infinity) =~ "author:fixture"
      refute inspect(p, limit: :infinity) =~ "first_revision"
    end
  end

  test "two actual installed families retain originals before policy, file or clock work", c do
    for family <- ~w(temperature research) do
      root = Path.join(c.root, family)
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      File.mkdir!(Path.join(root, "profiles"))
      File.chmod!(Path.join(root, "profiles"), 0o700)
      ctx = boot(root, family) |> seed()
      {:ok, summary} = AuthoringContract.to_map(ctx.contract)
      basis_input = JSON.encode!(Map.delete(summary, "basis_sha256"))

      assert {:ok, independent_basis} =
               Woh.Tool.Command.run_diagnostic(
                 "python3",
                 [
                   "-c",
                   "import hashlib,json,sys; v=json.loads(sys.stdin.buffer.read(int(sys.argv[1]))); print(hashlib.sha256(('wotex-home.authoring-contract-basis@1\\n'+json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False)).encode()).hexdigest())",
                   to_string(byte_size(basis_input))
                 ],
                 16384,
                 5000,
                 basis_input
               )

      assert String.trim(independent_basis) == ctx.contract.basis_sha256
      r = input(ctx)

      assert {:ok, receipt} =
               Authority.prepare_authoring_generation(ctx.authority, ctx.credential, r)

      expected = Map.put(ctx.vector["receipt"], "basis_sha256", ctx.contract.basis_sha256)
      assert receipt == expected

      assert {:ok, ^receipt} =
               Authority.prepare_authoring_generation(ctx.authority, ctx.credential, r)

      assert {:ok,
              %{"original" => ^receipt, "state" => "prepared", "cancellation_revision" => nil}} =
               Authority.authoring_generation_status(
                 ctx.authority,
                 ctx.credential,
                 1,
                 "generation:fixture"
               )

      assert {:ok, 10} = Store.revision(ctx.store)

      assert {:error, :authoring_operation_conflict} =
               Store.prepare_authoring_generation(
                 ctx.store,
                 ctx.credential,
                 put_in(r["projection"]["instruction"], "changed")
               )

      assert :ok = Integrity.validate_snapshot(:sys.get_state(ctx.store).db)
      # Returned receipt and normal OTP status do not expose the source or instruction.
      refute JSON.encode!(receipt) =~ "reveal credentials"

      assert %{state: :private_home_store, message: :redacted} =
               Store.format_status(%{
                 state: :sys.get_state(ctx.store),
                 message: {:prepare_authoring_generation, ctx.credential, r}
               })

      stop_supervised!(:custody)
      stop_supervised!(:store)
      # Reconstruct without any installation/custody. Originals still resolve.
      restarted = start_supervised!({Store, path: Path.join(root, "home.sqlite")}, id: :store)
      assert {:ok, ^receipt} = Store.prepare_authoring_generation(restarted, ctx.credential, r)

      assert {:ok, %{"state" => "retired", "original" => ^receipt}} =
               Store.authoring_generation_status(
                 restarted,
                 ctx.credential,
                 1,
                 "generation:fixture"
               )

      assert {:ok, 10} = Store.revision(restarted)
      stop_supervised!(:store)
    end
  end

  test "current actor, source ownership, policy consent and CAS precede reads", c do
    ctx = boot(c.root, "temperature") |> seed()
    original = input(ctx)

    for {changed, reason} <- [
          {Map.put(original, "authority_epoch", 2), :stale_authority_epoch},
          {Map.put(original, "expected_revision", 8), :resnapshot_required},
          {Map.put(original, "policy_sha256", String.duplicate("0", 64)),
           :stale_generation_policy},
          {Map.put(original, "provider_sha256", String.duplicate("0", 64)),
           :generation_unavailable},
          {Map.put(original, "remote_export", false), :generation_export_denied},
          {put_in(original["projection"]["contract_digest"], String.duplicate("0", 64)),
           :stale_authoring_basis},
          {put_in(original["projection"]["passages"], [
             put_in(hd(original["projection"]["passages"])["reference"]["first_revision"], 6)
           ]), :stale_authoring_reference},
          {put_in(original["projection"]["passages"], [
             Map.update!(hd(original["projection"]["passages"]), "length", &(&1 - 1))
           ]), :generation_export_denied}
        ] do
      assert {:error, ^reason} =
               Store.prepare_authoring_generation(ctx.store, ctx.credential, changed)

      assert {:ok, 9} = Store.revision(ctx.store)
    end

    assert {:ok, reader, 10} = Store.provision_principal(ctx.store, "reader:10", ["read"], [])

    assert {:error, :permission_denied} =
             Store.prepare_authoring_generation(ctx.store, reader, input(ctx))

    assert {:ok, other, 11} =
             Store.provision_principal(ctx.store, "other:author", ["profile:manage"], [])

    assert :not_found = Store.prepare_authoring_generation(ctx.store, other, input(ctx))

    assert {:ok, _} =
             Store.begin_maintenance(ctx.store, ctx.credential, 1, "maintenance:prepare", 11)

    assert {:error, :maintenance_active} =
             Store.prepare_authoring_generation(ctx.store, ctx.credential, input(ctx))
  end

  test "cancellation, expiry, live capacity and original replay never renew", c do
    ctx = boot(c.root, "temperature") |> seed()
    first = input(ctx, "generation:1")
    assert {:ok, receipt} = Store.prepare_authoring_generation(ctx.store, ctx.credential, first)

    for n <- 2..16 do
      assert {:ok, _} =
               Store.prepare_authoring_generation(
                 ctx.store,
                 ctx.credential,
                 input(ctx, "generation:#{n}")
               )
    end

    r = input(ctx, "generation:17")

    assert {:error, :generation_preparation_capacity} =
             Store.prepare_authoring_generation(ctx.store, ctx.credential, r)

    assert {:ok, %{"state" => "cancelled", "cancellation_revision" => revision} = cancelled} =
             Store.cancel_authoring_generation(ctx.store, ctx.credential, 1, "generation:1")

    assert {:ok, ^cancelled} =
             Store.cancel_authoring_generation(ctx.store, ctx.credential, 1, "generation:1")

    assert {:ok, ^revision} = Store.revision(ctx.store)
    assert {:ok, ^receipt} = Store.prepare_authoring_generation(ctx.store, ctx.credential, first)

    assert {:ok, _} =
             Store.prepare_authoring_generation(
               ctx.store,
               ctx.credential,
               input(ctx, "generation:17")
             )

    state = :sys.get_state(ctx.store)
    # Supply an independent future monotonic instant to the stateless status oracle;
    # do not rewrite the stored original clock or wait for the whole deadline.
    assert {:ok, %{"state" => "expired"}} =
             GenerationPreparations.status(
               state.db,
               ctx.credential,
               1,
               "generation:2",
               state.clock_epoch,
               9_000_000
             )

    assert {:ok, [[16]]} =
             SQL.query(
               state.db,
               "SELECT COUNT(*) FROM profile_authoring_generations WHERE cancellation_revision IS NULL"
             )

    assert :ok = Integrity.validate_snapshot(state.db)
  end

  test "prepare and cancel SQL faults roll back all rows and original revisions", c do
    ctx = boot(c.root, "temperature") |> seed()
    db = :sys.get_state(ctx.store).db

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TRIGGER generation_fault BEFORE INSERT ON profile_authoring_generations BEGIN SELECT RAISE(ABORT,'synthetic fault'); END"
      )

    assert {:error, _} = Store.prepare_authoring_generation(ctx.store, ctx.credential, input(ctx))
    assert {:ok, 9} = Store.revision(ctx.store)

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_generation_prepared'"
             )

    :ok = Sqlite3.execute(db, "DROP TRIGGER generation_fault")
    ctx = restart(ctx)
    db = :sys.get_state(ctx.store).db
    assert {:ok, _} = Store.prepare_authoring_generation(ctx.store, ctx.credential, input(ctx))

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TRIGGER generation_cancel_fault BEFORE UPDATE ON profile_authoring_generations BEGIN SELECT RAISE(ABORT,'synthetic fault'); END"
      )

    assert {:error, _} =
             Store.cancel_authoring_generation(ctx.store, ctx.credential, 1, "generation:fixture")

    assert {:ok, 10} = Store.revision(ctx.store)

    assert {:ok, %{"state" => "prepared"}} =
             Store.authoring_generation_status(ctx.store, ctx.credential, 1, "generation:fixture")

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_generation_cancelled'"
             )

    :ok = Sqlite3.execute(db, "DROP TRIGGER generation_cancel_fault")
  end

  defp retain_expired_fixture(
         ctx,
         n,
         instruction,
         budget \\ %{"attempts" => 1, "attempt_ms" => 1, "total_ms" => 1}
       ) do
    db = :sys.get_state(ctx.store).db

    r =
      ctx.vector["request"]
      |> Map.put("operation_id", "capacity:#{n}")
      |> Map.put("expected_revision", 9 + n)
      |> Map.put("budget", budget)
      |> put_in(["projection", "instruction"], instruction)

    {:ok, document} = GenerationPreparation.encode(r)

    receipt =
      ctx.vector["receipt"]
      |> Map.put("operation_id", r["operation_id"])
      |> Map.put("revision", 10 + n)
      |> Map.put("input_sha256", WotexHome.Profiles.AuthoringProducer.sha(document))
      |> Map.put("basis_sha256", ctx.contract.basis_sha256)

    {:ok, encoded} = GenerationPreparation.encode_receipt(receipt)

    :ok =
      WotexHome.Durable.Store.Journal.authority_event(
        db,
        10 + n,
        "authoring_generation_prepared",
        r["operation_id"]
      )

    assert {:ok, []} =
             SQL.query(
               db,
               "INSERT INTO profile_authoring_generations (#{GenerationPreparations.columns()}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
               [
                 "author:fixture",
                 1,
                 r["operation_id"],
                 document,
                 receipt["projection_sha256"],
                 receipt["basis_sha256"],
                 encoded,
                 "boot:" <> String.duplicate("0", 32),
                 0,
                 1,
                 10 + n,
                 nil
               ]
             )

    byte_size(document)
  end

  test "retained count and aggregate byte ceilings are inclusive on actual SQLite rows", c do
    ctx = boot(c.root, "temperature") |> seed()
    db = :sys.get_state(ctx.store).db
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    for n <- 0..1023, do: retain_expired_fixture(ctx, n, "")
    :ok = Sqlite3.execute(db, "COMMIT")
    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :generation_preparation_capacity} =
             Store.prepare_authoring_generation(ctx.store, ctx.credential, input(ctx))

    assert {:ok, 1033} = Store.revision(ctx.store)

    # Start another actual Store for an independently constructed exact byte ceiling.
    stop_supervised!(:custody)
    stop_supervised!(:store)
    root = Path.join(c.root, "bytes")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(Path.join(root, "profiles"))
    File.chmod!(Path.join(root, "profiles"), 0o700)
    ctx = boot(root, "temperature") |> seed()
    db = :sys.get_state(ctx.store).db
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    count =
      Enum.reduce_while(0..1023, {0, 0}, fn n, {total, _} ->
        # Quotes use two encoded bytes each; ordinary letters allow an odd residual.
        template =
          ctx.vector["request"]
          |> Map.put("operation_id", "capacity:#{n}")
          |> Map.put("expected_revision", 9 + n)
          |> Map.put("budget", %{"attempts" => 1, "attempt_ms" => 1, "total_ms" => 1})
          |> put_in(["projection", "instruction"], "")

        {:ok, empty} = GenerationPreparation.encode(template)
        remaining = 4_194_304 - total - byte_size(empty)
        needed = min(remaining, 8192)

        instruction =
          String.duplicate("\"", div(needed, 2)) <> if(rem(needed, 2) == 1, do: "a", else: "")

        size = retain_expired_fixture(ctx, n, instruction)
        if total + size == 4_194_304, do: {:halt, n + 1}, else: {:cont, {total + size, n + 1}}
      end)

    assert is_integer(count) and count < 1024
    :ok = Sqlite3.execute(db, "COMMIT")

    assert {:ok, [[4_194_304]]} =
             SQL.query(
               db,
               "SELECT SUM(length(CAST(input_document AS BLOB))) FROM profile_authoring_generations"
             )

    assert :ok = Integrity.validate_snapshot(db)

    assert {:error, :generation_preparation_capacity} =
             Store.prepare_authoring_generation(ctx.store, ctx.credential, input(ctx))

    assert {:ok, revision} = Store.revision(ctx.store)
    assert revision == 9 + count
  end

  test "encrypted archives include exact generation history and owned frames", c do
    ctx = boot(c.root, "research") |> seed()

    assert {:ok, receipt} =
             Store.prepare_authoring_generation(ctx.store, ctx.credential, input(ctx))

    key = :crypto.strong_rand_bytes(32)
    complete = Path.join(c.root, "complete.backup")
    assert {:ok, %{authoring_objects: 2}} = Store.export_profile_backup(ctx.store, complete, key)
    assert {:ok, report} = Backup.verify(complete, key)
    assert report.dependencies.authoring_bytes_included
    destination = Path.join(c.root, "quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(complete, key, destination)
    {:ok, restored} = Sqlite3.open(Path.join(destination, "home.sqlite"))

    try do
      assert :ok = Integrity.validate_snapshot(restored)

      assert {:ok, [[bytes]]} =
               SQL.query(restored, "SELECT receipt_document FROM profile_authoring_generations")

      assert {:ok, ^receipt} = GenerationPreparation.decode_receipt(bytes)

      assert {:ok, %{"state" => "retired"}} =
               GenerationPreparations.status(
                 restored,
                 ctx.credential,
                 1,
                 "generation:fixture",
                 "boot:" <> String.duplicate("0", 32),
                 0
               )

      # Full commitments require a retired source; normalized retained commitment
      # directly proves the new table participates without retiring this controller.
      assert {:ok, before} = RecoverySnapshot.retained_commitment(restored, 10, "fresh:principal")

      :ok =
        Sqlite3.execute(
          restored,
          "UPDATE profile_authoring_generations SET projection_sha256='" <>
            String.duplicate("0", 64) <> "'"
        )

      assert {:error, :corrupt_generation_preparations} = Integrity.validate_snapshot(restored)

      case RecoverySnapshot.retained_commitment(restored, 10, "fresh:principal") do
        {:ok, changed} -> refute changed == before
        {:error, _} -> :ok
      end

      assert byte_size(before) == 64
    after
      Sqlite3.close(restored)
    end

    only = Path.join(c.root, "only.backup")
    assert {:ok, _} = Store.export_backup(ctx.store, only, key)
    assert {:ok, report} = Backup.verify(only, key)
    refute report.dependencies.authoring_bytes_included
    assert length(report.dependencies.authoring_objects) == 2
  end

  test "real schema 35 migration creates no preparation authority and corrupt migration rolls back",
       c do
    path = Path.join(c.root, "migration.sqlite")
    {:ok, store} = Store.start_link(path: path)

    {:ok, credential, 1} =
      Store.provision_principal(store, "author:migration", ["profile:manage"], [])

    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE IF EXISTS profile_authoring_generation_attempts; DROP TABLE profile_authoring_generations; PRAGMA user_version=35"
      )

    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, historical_commitment} =
             RecoverySnapshot.retained_commitment(db, 1, "fresh:principal")

    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: path)
    assert {:ok, 1} = Store.revision(store)
    assert :not_found = Store.authoring_generation_status(store, credential, 1, "absent")
    assert {:ok, [[37]]} = SQL.query(:sys.get_state(store).db, "PRAGMA user_version")

    assert {:ok, ^historical_commitment} =
             RecoverySnapshot.retained_commitment(:sys.get_state(store).db, 1, "fresh:principal")

    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE IF EXISTS profile_authoring_generation_attempts; DROP TABLE profile_authoring_generations; PRAGMA user_version=35; UPDATE meta SET value=9 WHERE key='revision'"
      )

    :ok = Sqlite3.close(db)
    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, {:schema_failed, _}}} = Store.start_link(path: path)
    {:ok, db} = Sqlite3.open(path)
    assert {:ok, [[35]]} = SQL.query(db, "PRAGMA user_version")

    assert {:ok, [[0]]} =
             SQL.query(
               db,
               "SELECT COUNT(*) FROM sqlite_master WHERE name='profile_authoring_generations'"
             )

    :ok = Sqlite3.close(db)
  end

  test "closed inputs, native policy mutation and malformed installation refuse" do
    v = fixture("generation-preparations")["temperature"]
    {:ok, policy} = GenerationPolicy.new(v["policy"])

    for bad <- [
          nil,
          [],
          Map.put(v["request"], "credential", "private"),
          Map.put(v["request"], "authority_epoch", 1.0),
          put_in(v["request"]["budget"]["attempts"], 0),
          put_in(v["request"]["budget"]["attempt_ms"], 60001)
        ] do
      assert {:error, reason} = GenerationPreparation.encode(bad)
      assert reason in [:invalid_generation_preparation, :authoring_limit]
    end

    for bytes <- [
          v["document"] <> " ",
          "{}",
          "[]",
          String.replace(v["document"], "60000", "60000.0"),
          String.duplicate("x", 32769)
        ] do
      assert {:error, _} = GenerationPreparation.decode(bytes)
    end

    assert {:error, :invalid_generation_policy} =
             GenerationPolicy.validate(%{policy | sha256: String.duplicate("0", 64)})

    assert {:error, :invalid_generation_policy} = GenerationPolicy.installation([policy, policy])

    assert {:error, :invalid_generation_policy} =
             GenerationPolicy.installation(List.duplicate(policy, 33))

    assert {:error, :invalid_generation_policy} =
             GenerationPolicy.installation([policy | :improper])
  end

  test "locality and revoked export policy stay explicit without provider fallback", c do
    v = fixture("generation-preparations")["temperature"]

    local =
      v["policy"] |> put_in(["provider", "locality"], "local") |> Map.put("remote_export", false)

    assert {:ok, policy} = GenerationPolicy.new(local)
    ctx = boot(c.root, "temperature", generation_policies: [policy]) |> seed()

    request =
      input(ctx)
      |> Map.put("provider_sha256", policy.provider_sha256)
      |> Map.put("policy_sha256", policy.sha256)
      |> Map.put("remote_export", false)

    assert {:ok, receipt} = Store.prepare_authoring_generation(ctx.store, ctx.credential, request)
    assert receipt["provider_sha256"] == policy.provider_sha256

    assert {:error, :generation_export_denied} =
             Store.prepare_authoring_generation(
               ctx.store,
               ctx.credential,
               input(ctx, "another")
               |> Map.put("provider_sha256", policy.provider_sha256)
               |> Map.put("policy_sha256", policy.sha256)
             )

    assert {:error, :invalid_generation_policy} =
             GenerationPolicy.new(Map.put(local, "remote_export", true))

    assert {:ok, no_remote} = GenerationPolicy.new(Map.put(v["policy"], "remote_export", false))
    denied = v["request"] |> Map.put("policy_sha256", no_remote.sha256)

    assert {:error, :generation_export_denied} =
             GenerationPolicy.select([no_remote], "author:fixture", denied)

    assert :not_found = Store.cancel_authoring_generation(ctx.store, ctx.credential, 1, "absent")
    assert {:ok, _} = Store.revoke_principal(ctx.store, "author:fixture")

    assert {:error, :unauthorized} =
             Store.authoring_generation_status(ctx.store, ctx.credential, 1, "generation:fixture")

    assert {:error, :unauthorized} =
             Store.prepare_authoring_generation(ctx.store, ctx.credential, request)

    assert {:error, :unauthorized} =
             Store.cancel_authoring_generation(ctx.store, ctx.credential, 1, "generation:fixture")
  end

  test "the original total deadline is checked again before any durable mutation", c do
    ctx = boot(c.root, "temperature") |> seed()
    state = :sys.get_state(ctx.store)
    {:ok, document} = GenerationPreparation.encode(input(ctx))

    assert {:rollback, {:policy, :generation_deadline_expired}} =
             GenerationPreparations.retain_tx(
               state.db,
               ctx.credential,
               document,
               ctx.vector["receipt"]["projection_sha256"],
               ctx.contract.basis_sha256,
               state.clock_epoch,
               0,
               60000
             )

    assert {:ok, 9} = Store.revision(ctx.store)

    assert {:ok, [[0]]} =
             SQL.query(state.db, "SELECT COUNT(*) FROM profile_authoring_generations")
  end
end
