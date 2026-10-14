defmodule WotexHome.GenerationAttemptTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias Exqlite.Sqlite3
  alias WotexHome.{Authority, Profiles.Custody}
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{GenerationAttempts, Integrity, RecoverySnapshot, SQL}

  alias WotexHome.Profiles.{
    AuthoringAssessment,
    AuthoringContract,
    AuthoringObject,
    GenerationAttempt,
    GenerationPolicy,
    GenerationProvider,
    ProducerIdentity
  }

  defmodule Provider do
    @moduledoc false

    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:generate_profile, document, output}, from, state) do
      send(state[:observer], {:provider_call, from, document, output})
      {:noreply, state}
    end
  end

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "generation-attempt-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(Path.join(root, "profiles"))
    File.chmod!(Path.join(root, "profiles"), 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

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

    provider_pid = start_supervised!({Provider, observer: self()}, id: :provider)
    {:ok, provider} = GenerationProvider.new(policy.input["provider"], provider_pid)
    opts = Keyword.put(opts, :generation_providers, [provider])
    store = start_supervised!({Store, opts}, id: :store)

    custody =
      start_supervised!(
        {Custody,
         root: Path.join(root, "profiles"), store_owner: store, name: __MODULE__.Custody},
        id: :custody
      )

    %{
      store: store,
      provider: provider,
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

  defp prepare(ctx, overrides \\ %{}) do
    request = Map.merge(input(ctx), overrides)

    assert {:ok, root} =
             Authority.prepare_authoring_generation(ctx.authority, ctx.credential, request)

    Map.merge(ctx, %{preparation: root, preparation_input: request})
  end

  defp attempt(ctx, operation \\ "attempt:fixture", index \\ 1, previous \\ nil) do
    {:ok, revision} = Store.revision(ctx.store)

    %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "preparation_operation_id" => ctx.preparation["operation_id"],
      "preparation_sha256" => ctx.preparation["input_sha256"],
      "attempt" => index,
      "previous_operation_id" => previous,
      "repair_export" => index > 1
    }
  end

  defp await(ctx, operation \\ "attempt:fixture", n \\ 100) do
    assert {:ok, status} =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               ctx.credential,
               1,
               operation
             )

    if status["result"] == nil and n > 0 do
      Process.sleep(10)
      await(ctx, operation, n - 1)
    else
      status
    end
  end

  defp db(ctx, function) do
    {:ok, db} = Sqlite3.open(ctx.opts[:path])

    try do
      function.(db)
    after
      Sqlite3.close(db)
    end
  end

  test "both actual families reserve before one call and retain manual-parity inert candidates",
       c do
    for family <- ~w(temperature research) do
      ctx = boot(c.root, family) |> seed() |> prepare()
      input = attempt(ctx)
      v = fixture("generation-attempts")[family]

      assert {:ok, receipt} =
               Authority.start_authoring_generation(ctx.authority, ctx.credential, input)

      assert receipt == v["receipt"]
      assert_receive {:provider_call, from, document, output}
      assert document == v["handoff_document"]
      assert output == ctx.contract.inputs["limits"]["max_bundle_bytes"]
      refute document =~ Base.encode64(ctx.credential)
      bytes = fixture("authoring-mechanics")[family]["draft_bytes"]
      {:ok, manual} = AuthoringAssessment.assess(bytes, ctx.contract, nil)
      GenServer.reply(from, {:ok, bytes})
      status = await(ctx)
      assert status["state"] == "candidate" and status["original"] == receipt
      assert status["result"]["assessment"] == manual.data

      assert {:ok, draft} =
               Store.read_authoring_object(
                 ctx.store,
                 ctx.credential,
                 status["result"]["draft_ref"]["object_digest"]
               )

      assert draft["payload"] == bytes and draft["object"]["kind"] == "draft"

      assert {:ok, bundle} =
               Store.read_authoring_object(
                 ctx.store,
                 ctx.credential,
                 status["result"]["bundle_ref"]["object_digest"]
               )

      assert bundle["payload"] == manual.bundle_bytes
      assert {:ok, revision} = Store.revision(ctx.store)

      assert {:ok, ^receipt} =
               Authority.start_authoring_generation(ctx.authority, ctx.credential, input)

      assert {:ok, ^revision} = Store.revision(ctx.store)

      assert {:error, :generation_attempt_unavailable} =
               Authority.start_authoring_generation(
                 ctx.authority,
                 ctx.credential,
                 attempt(ctx, "repair:compatible", 2, "attempt:fixture")
               )

      assert {:error, :authoring_operation_conflict} =
               Authority.start_authoring_generation(
                 ctx.authority,
                 ctx.credential,
                 Map.put(input, "expected_revision", revision)
               )

      refute_receive {:provider_call, _, _, _}, 20

      assert {:ok, _} =
               Authority.cancel_authoring_generation(
                 ctx.authority,
                 ctx.credential,
                 1,
                 ctx.preparation["operation_id"]
               )

      assert {:ok, after_cancel} =
               Authority.authoring_generation_attempt_status(
                 ctx.authority,
                 ctx.credential,
                 1,
                 "attempt:fixture"
               )

      assert after_cancel["result"] == status["result"] and after_cancel["state"] == "candidate"

      db(ctx, fn db ->
        assert :ok = Integrity.validate_snapshot(db)

        for table <- ~w(enrolled_things request_receipts portable_profiles),
            do: assert({:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM " <> table))
      end)

      stop_supervised!(:custody)
      stop_supervised!(:store)
      stop_supervised!(:provider)
      File.rm_rf!(c.root)
      File.mkdir!(c.root)
      File.chmod!(c.root, 0o700)
      File.mkdir!(Path.join(c.root, "profiles"))
      File.chmod!(Path.join(c.root, "profiles"), 0o700)
    end
  end

  test "current guards refuse before provider reads while exact originals recover without resources",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    original = attempt(ctx)

    assert {:error, :resnapshot_required} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               Map.put(original, "expected_revision", 9)
             )

    assert {:error, :stale_authority_epoch} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               Map.put(original, "authority_epoch", 2)
             )

    assert {:error, :stale_authoring_reference} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               Map.put(original, "preparation_sha256", String.duplicate("0", 64))
             )

    assert :not_found =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               Map.put(original, "preparation_operation_id", "missing:root")
             )

    :sys.replace_state(ctx.store, &Map.put(&1, :generation_providers, []))

    assert {:error, :generation_unavailable} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    :sys.replace_state(ctx.store, &Map.put(&1, :generation_providers, [ctx.provider]))

    assert {:ok, receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert_receive {:provider_call, from, _, _}
    GenServer.reply(from, {:error, :unavailable})
    assert await(ctx)["state"] == "unavailable"
    stop_supervised!(:custody)

    :sys.replace_state(ctx.store, fn s ->
      %{s | generation_providers: [], generation_policies: [], authoring_contract: nil}
    end)

    assert {:ok, ^receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert {:ok, %{"original" => ^receipt, "state" => "unavailable"}} =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               ctx.credential,
               1,
               "attempt:fixture"
             )

    refute_receive {:provider_call, _, _, _}, 20
  end

  test "explicit repair uses the exact previous invalid draft/report and shared three-attempt budget",
       c do
    ctx =
      boot(c.root, "temperature")
      |> seed()
      |> prepare(%{"budget" => %{"attempts" => 3, "attempt_ms" => 30000, "total_ms" => 60000}})

    bad = "{\"instruction\":\"change sources\"}"

    for index <- 1..3 do
      operation = "attempt:#{index}"
      previous = if index == 1, do: nil, else: "attempt:#{index - 1}"
      input = attempt(ctx, operation, index, previous)
      assert {:ok, _} = Authority.start_authoring_generation(ctx.authority, ctx.credential, input)
      assert_receive {:provider_call, from, document, _}
      [_, initial, feedback] = JSON.decode!(document)
      assert initial == JSON.decode!(fixture("generation-inputs")["temperature"]["document"])

      if index == 1 do
        assert feedback == nil
      else
        [^bad, report] = feedback
        previous_status = await(ctx, previous)

        {:ok, encoded} =
          WotexHome.Profiles.AuthoringCandidate.encode_assessment(
            previous_status["result"]["assessment"]
          )

        assert report == JSON.decode!(encoded)
      end

      GenServer.reply(from, {:ok, bad})
      result = await(ctx, operation)

      assert result["state"] == "candidate" and
               result["result"]["assessment"]["disposition"] == "invalid"

      refute_receive {:provider_call, _, _, _}, 20
    end

    assert {:error, :generation_attempt_unavailable} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               attempt(ctx, "attempt:excess", 3, "attempt:2")
             )

    db(ctx, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "cancellation retires the channel and discards late responses without erasing originals",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    original = attempt(ctx)

    assert {:ok, receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert_receive {:provider_call, from, _, _}

    assert {:ok, %{"state" => "cancelled"}} =
             Authority.cancel_authoring_generation(
               ctx.authority,
               ctx.credential,
               1,
               ctx.preparation["operation_id"]
             )

    GenServer.reply(from, {:ok, fixture("authoring-mechanics")["temperature"]["draft_bytes"]})
    assert await(ctx)["state"] == "cancelled"
    assert {:ok, revision} = Store.revision(ctx.store)

    assert {:ok, ^receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert {:ok, ^revision} = Store.revision(ctx.store)

    db(ctx, fn db ->
      assert {:ok, [[2]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_objects")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    refute_receive {:provider_call, _, _, _}, 20
  end

  test "restart retires unknown work and metadata retry never invokes a new provider call", c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    original = attempt(ctx)

    assert {:ok, receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert_receive {:provider_call, {helper, _} = from, _, _}
    monitor = Process.monitor(helper)
    ctx = restart(ctx)
    assert_receive {:DOWN, ^monitor, :process, ^helper, _}, 1000
    GenServer.reply(from, {:ok, fixture("authoring-mechanics")["temperature"]["draft_bytes"]})

    assert {:ok, %{"state" => "unknown", "result" => nil, "original" => ^receipt}} =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               ctx.credential,
               1,
               "attempt:fixture"
             )

    assert {:ok, ^receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert {:error, :generation_retired} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               attempt(ctx, "repair:restart", 2, "attempt:fixture")
             )

    refute_receive {:provider_call, _, _, _}, 20
  end

  defp await_private_result(ctx, operation, n \\ 100) do
    result = db(ctx, fn db -> GenerationAttempts.original(db, "author:fixture", 1, operation) end)

    case result do
      {:ok, %{"result" => nil}} when n > 0 ->
        Process.sleep(10)
        await_private_result(ctx, operation, n - 1)

      {:ok, row} ->
        row
    end
  end

  test "another preparation for one author is busy and cancellation releases its owned channel",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    other = prepare(ctx, %{"operation_id" => "generation:other"})

    assert {:ok, _} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               attempt(ctx, "attempt:first")
             )

    assert_receive {:provider_call, _, _, _}

    assert {:error, :generation_busy} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               attempt(other, "attempt:other")
             )

    assert {:ok, _} =
             Authority.cancel_authoring_generation(
               ctx.authority,
               ctx.credential,
               1,
               ctx.preparation["operation_id"]
             )

    assert {:ok, _} =
             Authority.start_authoring_generation(
               ctx.authority,
               ctx.credential,
               attempt(other, "attempt:other")
             )

    assert_receive {:provider_call, _, _, _}

    assert {:ok, _} =
             Authority.cancel_authoring_generation(
               ctx.authority,
               ctx.credential,
               1,
               other.preparation["operation_id"]
             )

    assert await(other, "attempt:other")["state"] == "cancelled"
  end

  test "current credential revocation discards response bytes but retains withdrawal history",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()

    assert {:ok, _} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, attempt(ctx))

    assert_receive {:provider_call, from, _, _}
    assert {:ok, _} = Store.revoke_principal(ctx.store, "author:fixture")
    GenServer.reply(from, {:ok, fixture("authoring-mechanics")["temperature"]["draft_bytes"]})
    row = await_private_result(ctx, "attempt:fixture")
    assert row["result"] == GenerationAttempt.failure("withdrawn", "actor")

    assert {:error, :unauthorized} =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               ctx.credential,
               1,
               "attempt:fixture"
             )

    db(ctx, fn db ->
      assert :ok = Integrity.validate_snapshot(db)
      assert {:ok, [[2]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_objects")
    end)
  end

  test "maintenance, policy replacement and missing source refuse response retention", c do
    for change <- [:maintenance, :policy, :source] do
      ctx = boot(c.root, "temperature") |> seed() |> prepare()

      assert {:ok, _} =
               Authority.start_authoring_generation(ctx.authority, ctx.credential, attempt(ctx))

      assert_receive {:provider_call, from, _, _}

      case change do
        :maintenance ->
          {:ok, revision} = Store.revision(ctx.store)

          assert {:ok, _} =
                   Store.begin_maintenance(
                     ctx.store,
                     ctx.credential,
                     1,
                     "maintenance:fixture",
                     revision
                   )

        :policy ->
          :sys.replace_state(ctx.store, &Map.put(&1, :generation_policies, []))

        :source ->
          ref = hd(ctx.preparation_input["projection"]["passages"])["reference"]
          File.rm!(Path.join([c.root, "profiles", ref["object_digest"] <> ".json"]))
      end

      GenServer.reply(from, {:ok, fixture("authoring-mechanics")["temperature"]["draft_bytes"]})
      result = await(ctx)["result"]
      assert result == GenerationAttempt.failure("withdrawn", Atom.to_string(change))

      db(ctx, fn db ->
        assert :ok = Integrity.validate_snapshot(db)
        assert {:ok, [[2]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_objects")
      end)

      stop_supervised!(:custody)
      stop_supervised!(:store)
      stop_supervised!(:provider)
      File.rm_rf!(c.root)
      File.mkdir!(c.root)
      File.chmod!(c.root, 0o700)
      File.mkdir!(Path.join(c.root, "profiles"))
      File.chmod!(Path.join(c.root, "profiles"), 0o700)
    end
  end

  test "exact attempt deadline and foreign or duplicate channels cannot retain late output", c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()

    assert {:ok, receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, attempt(ctx))

    assert_receive {:provider_call, from, _, _}
    [{token, job}] = Map.to_list(:sys.get_state(ctx.store).generation_jobs)
    bytes = fixture("authoring-mechanics")["temperature"]["draft_bytes"]
    send(ctx.store, {:generation_result, self(), token, {:ok, bytes}})
    send(ctx.store, {:generation_result, job.worker, make_ref(), {:ok, bytes}})
    assert {:ok, revision} = Store.revision(ctx.store)
    assert revision == receipt["revision"]

    :sys.replace_state(
      ctx.store,
      &Map.put(&1, :clock_origin, System.monotonic_time(:millisecond) - job.row["expires_ms"])
    )

    GenServer.reply(from, {:ok, bytes})
    assert await(ctx)["state"] == "deadline_expired"
    assert {:ok, revision} = Store.revision(ctx.store)
    send(ctx.store, {:generation_result, job.worker, token, {:ok, bytes}})
    assert {:ok, ^revision} = Store.revision(ctx.store)

    db(ctx, fn db ->
      assert {:ok, [[2]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_objects")
    end)
  end

  test "provider and worker death preserve unknown originals with no automatic repair", c do
    for loss <- [:provider, :worker] do
      ctx = boot(c.root, "temperature") |> seed() |> prepare()
      original = attempt(ctx)

      assert {:ok, receipt} =
               Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

      assert_receive {:provider_call, _, _, _}

      case loss do
        :provider ->
          stop_supervised!(:provider)

        :worker ->
          [{_, job}] = Map.to_list(:sys.get_state(ctx.store).generation_jobs)
          Process.exit(job.worker, :kill)
      end

      assert await(ctx)["state"] == "unknown"

      assert {:ok, ^receipt} =
               Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

      assert {:error, :generation_attempt_unavailable} =
               Authority.start_authoring_generation(
                 ctx.authority,
                 ctx.credential,
                 attempt(ctx, "repair:unknown", 2, "attempt:fixture")
               )

      refute_receive {:provider_call, _, _, _}, 20
      stop_supervised!(:custody)
      stop_supervised!(:store)
      if loss == :worker, do: stop_supervised!(:provider)
      File.rm_rf!(c.root)
      File.mkdir!(c.root)
      File.chmod!(c.root, 0o700)
      File.mkdir!(Path.join(c.root, "profiles"))
      File.chmod!(Path.join(c.root, "profiles"), 0o700)
    end
  end

  test "reservation and multi-row settlement SQL faults roll back and never replay a provider",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()

    db(ctx, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER generation_fault BEFORE INSERT ON profile_authoring_generation_attempts BEGIN SELECT RAISE(ABORT,'synthetic fault'); END"
        )
    end)

    assert {:error, :store_unavailable} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, attempt(ctx))

    refute_receive {:provider_call, _, _, _}, 20

    db(ctx, fn db ->
      assert {:ok, [[10]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")

      assert {:ok, [[0]]} =
               SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_generation_attempts")

      :ok = Sqlite3.execute(db, "DROP TRIGGER generation_fault")
    end)

    ctx = restart(ctx) |> prepare(%{"operation_id" => "generation:after-fault"})
    original = attempt(ctx)

    assert {:ok, receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert_receive {:provider_call, from, _, _}

    db(ctx, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER generation_fault BEFORE UPDATE OF result_document ON profile_authoring_generation_attempts BEGIN SELECT RAISE(ABORT,'synthetic fault'); END"
        )
    end)

    GenServer.reply(from, {:ok, fixture("authoring-mechanics")["temperature"]["draft_bytes"]})
    row = await_private_result(ctx, "attempt:fixture", 30)
    assert row["result"] == nil

    db(ctx, fn db ->
      assert {:ok, [[revision]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")
      assert revision == receipt["revision"]
      assert {:ok, [[2]]} = SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_objects")

      assert {:ok, [[2]]} =
               SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_object_operations")

      :ok = Sqlite3.execute(db, "DROP TRIGGER generation_fault")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    ctx = restart(ctx)

    assert {:ok, %{"state" => "unknown", "original" => ^receipt, "result" => nil}} =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               ctx.credential,
               1,
               "attempt:fixture"
             )

    assert {:ok, ^receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    refute_receive {:provider_call, _, _, _}, 20
  end

  test "encrypted inclusive/database-only archives retain exact results in quarantine and scope later settlement",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()

    assert {:ok, receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, attempt(ctx))

    assert_receive {:provider_call, from, _, _}

    before =
      db(ctx, fn db ->
        assert {:ok, sha} =
                 RecoverySnapshot.retained_commitment(db, receipt["revision"], "fresh:principal")

        sha
      end)

    GenServer.reply(from, {:ok, fixture("authoring-mechanics")["temperature"]["draft_bytes"]})
    status = await(ctx)
    assert status["state"] == "candidate"

    db(ctx, fn db ->
      assert {:ok, ^before} =
               RecoverySnapshot.retained_commitment(db, receipt["revision"], "fresh:principal")

      assert {:ok, current} =
               RecoverySnapshot.retained_commitment(
                 db,
                 status["result_revision"],
                 "fresh:principal"
               )

      refute current == before
    end)

    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "complete.backup")
    assert {:ok, %{authoring_objects: 4}} = Store.export_profile_backup(ctx.store, archive, key)
    assert {:ok, verified} = Backup.verify(archive, key)
    assert verified.dependencies.authoring_bytes_included
    destination = Path.join(c.root, "quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, key, destination)
    {:ok, restored} = Sqlite3.open(Path.join(destination, "home.sqlite"))

    try do
      assert :ok = Integrity.validate_snapshot(restored)

      assert {:ok, copy} =
               GenerationAttempts.status(
                 restored,
                 ctx.credential,
                 1,
                 "attempt:fixture",
                 "boot:" <> String.duplicate("0", 32),
                 0,
                 false
               )

      assert copy["original"] == status["original"] and copy["result"] == status["result"]

      :ok =
        Sqlite3.execute(
          restored,
          "UPDATE profile_authoring_generation_attempts SET handoff_sha256='" <>
            String.duplicate("0", 64) <> "'"
        )

      assert {:error, :corrupt_generation_attempts} = Integrity.validate_snapshot(restored)
    after
      Sqlite3.close(restored)
    end

    database_only = Path.join(c.root, "database-only.backup")
    assert {:ok, _} = Store.export_backup(ctx.store, database_only, key)
    assert {:ok, verified} = Backup.verify(database_only, key)
    refute verified.dependencies.authoring_bytes_included
  end

  test "actual schema36 migration preserves empty-table commitments and creates no attempt authority",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    stop_supervised!(:custody)
    stop_supervised!(:store)

    before =
      db(ctx, fn db ->
        :ok =
          Sqlite3.execute(
            db,
            "DROP TABLE profile_authoring_generation_attempts; PRAGMA user_version=36"
          )

        assert :ok = Integrity.validate_snapshot(db)
        assert {:ok, sha} = RecoverySnapshot.retained_commitment(db, 10, "fresh:principal")
        sha
      end)

    bad = Path.join(c.root, "corrupt.sqlite")
    File.cp!(ctx.opts[:path], bad)
    {:ok, bad_db} = Sqlite3.open(bad)

    :ok =
      Sqlite3.execute(
        bad_db,
        "UPDATE profile_authoring_generations SET projection_sha256='" <>
          String.duplicate("0", 64) <> "'"
      )

    Sqlite3.close(bad_db)
    Process.flag(:trap_exit, true)
    assert {:error, _} = Store.start_link(Keyword.put(ctx.opts, :path, bad))
    {:ok, bad_db} = Sqlite3.open(bad)
    assert {:ok, [[36]]} = SQL.query(bad_db, "PRAGMA user_version")

    assert {:ok, [[0]]} =
             SQL.query(
               bad_db,
               "SELECT COUNT(*) FROM sqlite_master WHERE name='profile_authoring_generation_attempts'"
             )

    Sqlite3.close(bad_db)
    store = start_supervised!({Store, ctx.opts}, id: :store)

    db(ctx, fn db ->
      assert {:ok, [[37]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0]]} =
               SQL.query(db, "SELECT COUNT(*) FROM profile_authoring_generation_attempts")

      assert {:ok, ^before} = RecoverySnapshot.retained_commitment(db, 10, "fresh:principal")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok, %{"state" => "retired"}} =
             Store.authoring_generation_status(
               store,
               ctx.credential,
               1,
               ctx.preparation["operation_id"]
             )

    refute_receive {:provider_call, _, _, _}, 20
  end

  test "foreign and unprivileged actors cannot recover or export this author's preparation", c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    original = attempt(ctx)

    assert {:ok, _} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert_receive {:provider_call, from, _, _}

    assert {:ok, foreign, _} =
             Store.provision_principal(ctx.store, "author:other", ["profile:manage"], [])

    assert :not_found =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               foreign,
               1,
               "attempt:fixture"
             )

    assert :not_found = Authority.start_authoring_generation(ctx.authority, foreign, original)
    assert {:ok, reader, _} = Store.provision_principal(ctx.store, "reader:new", ["read"], [])

    assert {:error, :permission_denied} =
             Authority.start_authoring_generation(ctx.authority, reader, original)

    assert {:error, :permission_denied} =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               reader,
               1,
               "attempt:fixture"
             )

    refute_receive {:provider_call, _, _, _}, 20
    GenServer.reply(from, {:error, :unavailable})
    assert await(ctx)["state"] == "unavailable"
  end

  test "malformed native provider installation fails before acquiring durable resources", c do
    Process.flag(:trap_exit, true)
    provider_identity = fixture("generation-preparations")["temperature"]["policy"]["provider"]
    {:ok, provider} = GenerationProvider.new(provider_identity, self())
    baseline = File.ls!(c.root) |> Enum.sort()
    path = Path.join(c.root, "invalid.sqlite")

    for providers <- [
          [Map.put(provider, :extra, true)],
          [provider, provider],
          [provider | :improper]
        ] do
      assert {:error, :invalid_store_options} =
               Store.start_link(path: path, generation_providers: providers)

      refute File.exists?(path)
      assert Enum.sort(File.ls!(c.root)) == baseline
    end
  end

  test "sixteen distinct authors hold bounded shared channels and further preparation refuses",
       c do
    ctx = boot(c.root, "temperature")
    initial = fixture("generation-inputs")["temperature"]
    source = Enum.find(initial["objects"], &(&1["kind"] == "source"))
    example = Enum.find(initial["objects"], &(&1["kind"] == "fixture"))

    {authors, _policies} =
      Enum.reduce(1..16, {[], []}, fn n, {authors, policies} ->
        principal = "author:" <> String.pad_leading(Integer.to_string(n), 2, "0")

        assert {:ok, credential, _} =
                 Store.provision_principal(ctx.store, principal, ["profile:manage"], [])

        refs =
          for {row, kind} <- [{source, "source"}, {example, "fixture"}], into: %{} do
            {:ok, object} = AuthoringObject.new(kind, Base.decode64!(row["payload_base64"]))
            {:ok, summary} = AuthoringObject.summary(object)
            {:ok, revision} = Store.revision(ctx.store)

            request = %{
              "authority_epoch" => 1,
              "operation_id" => "import:" <> kind,
              "expected_revision" => revision,
              "object" => summary
            }

            assert {:ok, receipt} =
                     Store.import_authoring_object(ctx.store, credential, request, object.payload)

            {kind,
             %{"object_digest" => object.digest, "first_revision" => receipt["first_revision"]}}
          end

        projection =
          initial["request"]
          |> Map.put(
            "passages",
            Enum.map(initial["request"]["passages"], &Map.put(&1, "reference", refs["source"]))
          )
          |> Map.put("examples", [refs["fixture"]])

        policy_input =
          ctx.policy.input
          |> Map.put("principal_id", principal)
          |> Map.put("passages", projection["passages"])
          |> Map.put("examples", projection["examples"])

        {:ok, policy} = GenerationPolicy.new(policy_input)
        policies = policies ++ [policy]
        :sys.replace_state(ctx.store, &Map.put(&1, :generation_policies, policies))
        actor = Map.merge(ctx, %{credential: credential})

        request =
          input(actor, "generation:" <> Integer.to_string(n))
          |> Map.put("projection", projection)
          |> Map.put("policy_sha256", policy.sha256)

        assert {:ok, preparation} =
                 Authority.prepare_authoring_generation(actor.authority, credential, request)

        actor = Map.merge(actor, %{preparation: preparation, preparation_input: request})

        assert {:ok, _} =
                 Authority.start_authoring_generation(actor.authority, credential, attempt(actor))

        assert_receive {:provider_call, from, _, _}
        {authors ++ [{actor, from}], policies}
      end)

    assert map_size(:sys.get_state(ctx.store).generation_jobs) == 16
    assert Enum.uniq(Enum.map(authors, fn {_, {helper, _}} -> helper end)) |> length() == 16

    assert {:error, :generation_preparation_capacity} =
             Authority.prepare_authoring_generation(
               elem(hd(authors), 0).authority,
               elem(hd(authors), 0).credential,
               input(elem(hd(authors), 0), "generation:excess")
               |> Map.put("projection", elem(hd(authors), 0).preparation_input["projection"])
               |> Map.put(
                 "policy_sha256",
                 elem(hd(authors), 0).preparation_input["policy_sha256"]
               )
             )

    for {actor, from} <- authors do
      GenServer.reply(from, {:error, :unavailable})
      assert await(actor)["state"] == "unavailable"
    end

    assert map_size(:sys.get_state(ctx.store).generation_jobs) == 0
    db(ctx, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end
end
