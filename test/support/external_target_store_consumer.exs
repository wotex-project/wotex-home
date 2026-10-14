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
  import ExUnit.CaptureIO
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

  setup_all do
    if :os.type() == {:unix, :darwin} do
      root =
        Path.join("/private/tmp", "external-report-sdk-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)
      executable = Path.join(root, "native-client")

      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(root, "cache"),
        "-framework",
        "Security",
        Path.expand("native/macos/Sources/LocalHealthClient.swift"),
        Path.expand("native/macos/Sources/NativeExternalReportClient.swift"),
        Path.expand("native/macos/Tests/NativeExternalReportLiveSmoke.swift"),
        "-o",
        executable
      ]

      assert {:ok, _} = Woh.Tool.Command.run_diagnostic("swiftc", args, 1_048_576, 90_000)
      %{native_report_executable: executable}
    else
      %{native_report_executable: nil}
    end
  end

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

  defp prepare(c, family \\ "temperature", source_changes \\ %{}, policy_changes \\ %{}) do
    source = fixture("external-source-selections")[family]["inputs"]
    r = source["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])

    {:ok, selection} =
      ExternalSourceSelection.new(
        Map.merge(source["source"], source_changes),
        reader,
        Enum.map(
          source["channels"],
          &update_in(&1, ["policy"], fn policy -> Map.merge(policy, policy_changes) end)
        )
      )

    {:ok, _} = ExternalSourceOwner.publish(c.sources, selection)
    {:ok, catalogue} = ExternalSourceOwner.catalogue(c.sources)

    reports =
      start_supervised!(
        {WotexHome.Profiles.ExternalReportOwner,
         publisher: self(), source_owner: c.sources, store_owner: @owner}
      )

    store =
      start_supervised!(
        {Store,
         path: c.path,
         profile_custody: c.custody,
         external_reader: reader,
         external_source_owner: c.sources,
         external_report_owner: reports,
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
      authority: Authority.new(store: store, profile_custody: c.custody),
      reports: reports,
      family: family
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

  defp publish_report(c, id, changes \\ %{}) do
    {:ok, clock} = WotexHome.Profiles.ExternalReportOwner.receipt_clock(c.reports)

    report =
      fixture("external-transport-reports")[c.family]["report"]
      |> Map.put("receipt_time", clock)
      |> Map.merge(changes)

    {:ok, _} =
      WotexHome.Profiles.ExternalReportOwner.publish(
        c.reports,
        id,
        c.selection.data["source_ref"],
        c.selection.sha256,
        report
      )

    %{"report_owner_epoch" => clock["epoch"], "report_id" => id}
  end

  test "actual source receipt commits once with its original elapsed clock and survives Store restart as history",
       c do
    c = prepare(c)
    {:ok, selected} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:1", %{"continuity" => "baseline"})
    assert {:ok, first} = Authority.accept_external_report(c.authority, input)
    assert first["selection_revision"] == selected["revision"]
    assert {:ok, ^first} = Store.accept_external_report(c.store, input)
    assert revision(c) == first["revision"]
    assert :ok = Integrity.validate_snapshot(db(c))

    assert {:ok, [[1]]} =
             SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observation_current")

    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, name: @owner})
    assert {:ok, ^first} = Store.accept_external_report(store, input)
    assert :sys.get_state(store).external_target_boot == %{}
  end

  test "sequence replay under another report owner cannot renew freshness and a valid larger sample advances once",
       c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:1", %{"sequence" => "7", "continuity" => "baseline"})
    assert {:ok, first} = Store.accept_external_report(c.store, input)
    next = publish_report(c, "packet:2", %{"sequence" => "8", "continuity" => "continuous"})
    assert {:ok, second} = Store.accept_external_report(c.store, next)
    assert second["revision"] == first["revision"] + 1
    old = publish_report(c, "packet:old", %{"sequence" => "6", "continuity" => "baseline"})
    assert {:error, :stale_external_sequence} = Store.accept_external_report(c.store, old)
    gap = publish_report(c, "packet:gap", %{"sequence" => "10", "continuity" => "continuous"})
    assert {:error, :continuity_mismatch} = Store.accept_external_report(c.store, gap)
    assert revision(c) == second["revision"]
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "SQL observation fault rolls back all original, pointer and sequence writes", c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    before = revision(c)
    input = publish_report(c, "packet:fault")

    assert :ok =
             Sqlite3.execute(
               db(c),
               "CREATE TEMP TRIGGER refuse_report BEFORE INSERT ON profile_external_observation_current BEGIN SELECT RAISE(ABORT,'fixture'); END"
             )

    assert {:error, :store_unavailable} = Store.accept_external_report(c.store, input)
    assert revision(c) == before
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observations")

    assert {:ok, [[0]]} =
             SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observation_sequences")

    assert {:ok, %{"state" => "consumed"}} =
             WotexHome.Profiles.ExternalReportOwner.status(c.reports, "packet:fault")
  end

  test "unsigned maximum sequence persists as text and never wraps or admits overflow", c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)

    first =
      publish_report(c, "packet:max-before", %{
        "sequence" => "18446744073709551614",
        "continuity" => "baseline"
      })

    assert {:ok, _} = Store.accept_external_report(c.store, first)

    maximum =
      publish_report(c, "packet:max", %{
        "sequence" => "18446744073709551615",
        "continuity" => "continuous"
      })

    assert {:ok, last} = Store.accept_external_report(c.store, maximum)

    assert {:ok, [["18446744073709551615", "text"]]} =
             SQL.query(
               db(c),
               "SELECT sequence,typeof(sequence) FROM profile_external_observation_sequences"
             )

    zero = publish_report(c, "packet:wrapped", %{"sequence" => "0", "continuity" => "baseline"})
    assert {:error, :stale_external_sequence} = Store.accept_external_report(c.store, zero)
    {:ok, clock} = WotexHome.Profiles.ExternalReportOwner.receipt_clock(c.reports)

    report =
      fixture("external-transport-reports")[c.family]["report"]
      |> Map.merge(%{"receipt_time" => clock, "sequence" => "18446744073709551616"})

    assert {:error, _} =
             WotexHome.Profiles.ExternalReportOwner.publish(
               c.reports,
               "packet:overflow",
               c.selection.data["source_ref"],
               c.selection.sha256,
               report
             )

    assert revision(c) == last["revision"]
    assert {:ok, ^last} = Store.accept_external_report(c.store, maximum)
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  for continuity <- ~w(gap retained replayed) do
    @continuity continuity
    test "#{@continuity} report is retained but stays unknown at the authenticated boundary", c do
      c = prepare(c, "temperature", %{"trust" => "unauthenticated_local"})
      {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
      input = publish_report(c, "packet:discontinuous", %{"continuity" => @continuity})
      assert {:ok, receipt} = Store.accept_external_report(c.store, input)

      {:ok, reader, _} =
        Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

      assert {:ok, current} =
               Store.external_report_current(c.store, reader, "sensor:external", "sample")

      assert current["freshness"] == "unknown" and current["reason"] == @continuity
      assert current["value"] == nil and current["remaining_ms"] == 0
      assert {:ok, ^receipt} = Store.external_report_status(c.store, reader, input)
      assert :ok = Integrity.validate_snapshot(db(c))
    end
  end

  test "nullable sequence originals retain separate receipts without inventing a cursor", c do
    c = prepare(c, "temperature", %{"trust" => "unauthenticated_local"})
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:null-1", %{"sequence" => nil, "continuity" => "baseline"})
    assert {:ok, first} = Store.accept_external_report(c.store, input)
    next = publish_report(c, "packet:null-2", %{"sequence" => nil, "continuity" => "baseline"})
    assert {:ok, second} = Store.accept_external_report(c.store, next)
    assert second["revision"] == first["revision"] + 1

    assert {:ok, [[0]]} =
             SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observation_sequences")

    {:ok, reader, _} =
      Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

    assert {:ok, current} =
             Store.external_report_current(c.store, reader, "sensor:external", "sample")

    assert current["reason"] == "missing_sequence" and current["value"] == nil
    assert {:ok, ^first} = Store.external_report_status(c.store, reader, input)
    assert {:ok, ^second} = Store.external_report_status(c.store, reader, next)
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "new report owner and explicit post-restart selection preserve the retained sequence cursor",
       c do
    c = prepare(c)
    {:ok, selected} = Store.change_external_target(c.store, c.credential, c.input)

    original =
      publish_report(c, "packet:before", %{"sequence" => "7", "continuity" => "baseline"})

    assert {:ok, first} = Store.accept_external_report(c.store, original)
    stop_supervised(Store)
    stop_supervised(WotexHome.Profiles.ExternalReportOwner)

    reports =
      start_supervised!(
        {WotexHome.Profiles.ExternalReportOwner,
         publisher: self(), source_owner: c.sources, store_owner: @owner}
      )

    store =
      start_supervised!(
        {Store,
         path: c.path,
         name: @owner,
         profile_custody: c.custody,
         external_reader: c.reader,
         external_source_owner: c.sources,
         external_report_owner: reports}
      )

    c = %{c | store: store, reports: reports}
    assert {:ok, ^first} = Store.accept_external_report(store, original)

    selection =
      Map.merge(c.input, %{
        "operation_id" => "selection:restart",
        "expected_revision" => revision(c),
        "expected_selection_revision" => selected["revision"],
        "expected_resource_revision" => selected["resource_revision"]
      })

    assert {:ok, reselected} = Store.change_external_target(store, c.credential, selection)

    duplicate =
      publish_report(c, "packet:before", %{"sequence" => "7", "continuity" => "baseline"})

    refute duplicate["report_owner_epoch"] == original["report_owner_epoch"]

    assert {:error, :external_observation_duplicate} =
             Store.accept_external_report(store, duplicate)

    next = publish_report(c, "packet:after", %{"sequence" => "8", "continuity" => "continuous"})
    assert {:ok, after_restart} = Store.accept_external_report(store, next)
    assert after_restart["selection_revision"] == reselected["revision"]

    assert {:ok, [["8", revision]]} =
             SQL.query(
               db(c),
               "SELECT sequence,revision FROM profile_external_observation_sequences"
             )

    assert revision == after_restart["revision"]
    assert {:ok, ^first} = Store.accept_external_report(store, original)
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "reported previews require current read grant and lab receipts never become known values",
       c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:1", %{"continuity" => "baseline"})
    {:ok, first} = Store.accept_external_report(c.store, input)

    assert {:error, :permission_denied} =
             Authority.external_report_current(
               c.authority,
               c.credential,
               "sensor:external",
               "sample"
             )

    {:ok, reader, _} =
      Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

    assert {:ok, preview} =
             Authority.external_report_current(c.authority, reader, "sensor:external", "sample")

    assert preview["report_revision"] == first["revision"]
    assert preview["freshness"] == "unknown" and preview["reason"] == "synthetic_lab"
    assert preview["value"] == nil and preview["remaining_ms"] == 0
    assert {:ok, ^first} = Authority.external_report_status(c.authority, reader, input)
    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, name: @owner})
    assert {:ok, old} = Store.external_report_current(store, reader, "sensor:external", "sample")
    assert old["value"] == nil and old["reason"] == "external_selection_restart_required"
    assert {:ok, ^first} = Store.external_report_status(store, reader, input)
  end

  test "target replacement atomically clears current reported values but retains original sequences",
       c do
    c = prepare(c)
    {:ok, selected} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:1")
    {:ok, _} = Store.accept_external_report(c.store, input)

    replace =
      Map.merge(c.input, %{
        "operation_id" => "replace:1",
        "expected_revision" => revision(c),
        "expected_selection_revision" => selected["revision"]
      })

    assert {:ok, _} = Store.change_external_target(c.store, c.credential, replace)

    assert {:ok, [[0]]} =
             SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observation_current")

    assert {:ok, [[1]]} =
             SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observation_sequences")

    assert :ok = Integrity.validate_snapshot(db(c))
  end

  defp db(c), do: :sys.get_state(c.store).db

  test "receipt stamped before this Store boot cannot become a fresh observation", c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    started = :sys.get_state(c.reports).started
    {:ok, clock} = WotexHome.Profiles.ExternalReportOwner.receipt_clock(c.reports)

    input =
      publish_report(c, "packet:preboot", %{
        "receipt_time" => Map.put(clock, "monotonic_us", Integer.to_string(started))
      })

    assert {:error, :external_receipt_before_boot} = Store.accept_external_report(c.store, input)
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observations")
    assert :sys.get_state(c.store).writable
  end

  test "live read reprojection refuses a rehashed normalized coordinate that historical opaque decoding cannot recompute",
       c do
    c = prepare(c, "temperature", %{"trust" => "unauthenticated_local"})
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:current", %{"continuity" => "baseline"})
    {:ok, receipt} = Store.accept_external_report(c.store, input)

    {:ok, [[doc]]} =
      SQL.query(db(c), "SELECT outcome_document FROM profile_external_observations")

    {:ok, o} = WotexHome.Profiles.ExternalObservation.decode_outcome(doc)
    data = o["value_document"] |> JSON.decode!() |> put_in(["normalized_value", "value"], "2501")
    {:ok, value_doc} = Wotex.JSON.encode(data)

    o =
      Map.merge(o, %{
        "value_document" => value_doc,
        "value_sha256" => WotexHome.Profiles.ExternalObservation.value_sha(value_doc)
      })

    {:ok, altered} = WotexHome.Profiles.ExternalObservation.encode_outcome(o)

    {:ok, receipt_doc} =
      WotexHome.Profiles.ExternalObservation.encode_receipt(
        Map.merge(receipt, %{
          "value_sha256" => o["value_sha256"],
          "outcome_sha256" => WotexHome.Profiles.ExternalObservation.sha(altered)
        })
      )

    SQL.query(
      db(c),
      "UPDATE profile_external_observations SET outcome_document=?,receipt_document=?",
      [altered, receipt_doc]
    )

    assert :ok = Integrity.validate_snapshot(db(c))

    {:ok, reader, _} =
      Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

    assert {:ok, current} =
             Store.external_report_current(c.store, reader, "sensor:external", "sample")

    assert current["value"] == nil and current["reason"] == "external_value_changed"
  end

  test "inclusive and database-only quarantine preserve nonempty observation originals and sequence tombstones",
       c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:backup")
    {:ok, first} = Store.accept_external_report(c.store, input)
    key = :crypto.strong_rand_bytes(32)

    for mode <- [:inclusive, :database] do
      archive = Path.join(c.root, "observations-#{mode}.backup")

      if mode == :inclusive,
        do: assert({:ok, _} = Store.export_profile_backup(c.store, archive, key)),
        else: assert({:ok, _} = Store.export_backup(c.store, archive, key))

      assert {:ok, _} = Backup.verify(archive, key)
      target = Path.join(c.root, "observations-restore-#{mode}")

      path =
        if mode == :inclusive do
          assert {:ok, _} = Backup.stage_profile_restore(archive, key, target)
          Path.join(target, "home.sqlite")
        else
          assert {:ok, _} = Backup.stage_restore(archive, key, target)
          target
        end

      {:ok, restored} = Sqlite3.open(path)
      assert :ok = Integrity.validate_snapshot(restored)

      assert {:ok, [[receipt_doc]]} =
               SQL.query(restored, "SELECT receipt_document FROM profile_external_observations")

      assert {:ok, ^first} = WotexHome.Profiles.ExternalObservation.decode_receipt(receipt_doc)

      assert {:ok, [[1]]} =
               SQL.query(restored, "SELECT COUNT(*) FROM profile_external_observation_sequences")

      Sqlite3.close(restored)
    end
  end

  for family <- ~w(temperature research multi) do
    @report_family family
    test "#{@report_family} current reported coordinate matches the independent vector with explicit read scope",
         c do
      c = prepare(c, @report_family, %{"trust" => "unauthenticated_local"})
      {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
      input = publish_report(c, "packet:current", %{"continuity" => "baseline"})
      assert {:ok, first} = Store.accept_external_report(c.store, input)

      {:ok, reader, _} =
        Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

      key = if @report_family == "multi", do: "density", else: "sample"

      assert {:ok, current} =
               Store.external_report_current(c.store, reader, "sensor:external", key)

      assert current["freshness"] == "fresh" and current["reason"] == nil

      assert current["value"]["normalized_value"] ==
               fixture("external-observations")[@report_family]["value"]["normalized_value"]

      assert current["age_ms"] >= 0 and current["remaining_ms"] > 0
      assert {:ok, ^first} = Store.external_report_status(c.store, reader, input)
      assert :ok = Integrity.validate_snapshot(db(c))
      report_operator_roundtrip(c, reader, key, input, first, current)
    end
  end

  test "a distinct Home capability key preserves its original source channel through native presentation",
       c do
    c =
      prepare(c, "temperature", %{"trust" => "unauthenticated_local"}, %{
        "capability_key" => "temperature"
      })

    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    input = publish_report(c, "packet:alias", %{"continuity" => "baseline"})
    assert {:ok, first} = Store.accept_external_report(c.store, input)

    {:ok, reader, _} =
      Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

    assert {:ok, current} =
             Store.external_report_current(c.store, reader, "sensor:external", "temperature")

    assert current["capability_key"] == "temperature" and
             current["value"]["channel_id"] == "sample"

    report_operator_roundtrip(c, reader, "temperature", input, first, current)
  end

  defp report_operator_roundtrip(c, reader, key, input, first, current) do
    socket = Path.join(c.root, "ipc/reports.sock")
    start_supervised!({WotexHome.LocalAPI.Server, authority: c.authority, socket_path: socket})
    encoded = Base.url_encode64(reader, padding: false)

    base = %{"api_version" => 1, "credential" => encoded}

    request =
      Map.merge(base, %{
        "operation" => "external_report_current",
        "target_id" => "sensor:external",
        "capability_key" => key
      })

    original = Map.merge(base, Map.put(input, "operation", "external_report_status"))
    before_revision = revision(c)

    assert {:ok, %{"outcome" => "ok", "external_report_preview" => preview}} =
             WotexHome.LocalAPI.Client.request(socket, request)

    assert Map.drop(preview, ["age_ms", "remaining_ms"]) ==
             Map.drop(current, ["age_ms", "remaining_ms"])

    assert preview["age_ms"] >= current["age_ms"]
    assert preview["remaining_ms"] <= current["remaining_ms"]

    assert {:ok, %{"outcome" => "ok", "external_observation_receipt" => ^first}} =
             WotexHome.LocalAPI.Client.request(socket, original)

    for read <- [request, original] do
      denied = Map.put(read, "credential", Base.url_encode64(c.credential, padding: false))

      assert {:ok, %{"reason" => "permission_denied"}} =
               WotexHome.LocalAPI.Client.request(socket, denied)

      assert {:ok, %{"reason" => "unsupported_operation_or_fields"}} =
               WotexHome.LocalAPI.Client.request(socket, Map.put(read, "report", %{}))
    end

    credential_file = Path.join(c.root, "reported-reader")
    File.write!(credential_file, encoded)
    File.chmod!(credential_file, 0o600)
    flags = ["--socket", socket, "--credential-file", credential_file]
    command = ["external-report-current", "sensor:external", key]
    status = ["external-report-status", input["report_owner_epoch"], input["report_id"]]
    output = capture_io(fn -> assert 0 == WotexHome.CLI.main(flags ++ command) end)
    cli_preview = JSON.decode!(output)["external_report_preview"]

    assert Map.drop(cli_preview, ["age_ms", "remaining_ms"]) ==
             Map.drop(current, ["age_ms", "remaining_ms"])

    assert cli_preview["age_ms"] >= preview["age_ms"]
    assert cli_preview["remaining_ms"] <= preview["remaining_ms"]
    output = capture_io(fn -> assert 0 == WotexHome.CLI.main(flags ++ status) end)
    assert JSON.decode!(output)["external_observation_receipt"] == first
    refute output =~ c.selection.inputs["source"]["stable_id"]
    refute output =~ "report_document"
    assert revision(c) == before_revision

    if executable = c.native_report_executable do
      assert {:ok, output} =
               Woh.Tool.Command.run_diagnostic(
                 executable,
                 [socket, key],
                 65_536,
                 10_000,
                 encoded <> "\n"
               )

      native = JSON.decode!(output)
      assert native["coordinate"] == current["value"]["normalized_value"]["value"]
      assert JSON.decode!(native["unit"]) == current["value"]["unit"]
      assert native["semantic"] == current["value"]["semantic"]["id"]
      assert native["consumer"] == current["value"]["contract_ref"]["id"]
      assert native["report_revision"] == first["revision"]

      assert native["age_ms"] >= cli_preview["age_ms"] and
               native["remaining_ms"] <= cli_preview["remaining_ms"]

      assert revision(c) == before_revision
    end

    stop_supervised(WotexHome.LocalAPI.Server)
    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, name: @owner})
    authority = Authority.new(store: store)
    start_supervised!({WotexHome.LocalAPI.Server, authority: authority, socket_path: socket})

    assert {:ok, old} =
             Authority.external_report_current(authority, reader, "sensor:external", key)

    assert old["value"] == nil and old["reason"] == "external_selection_restart_required"

    assert {:ok, %{"external_report_preview" => ^old}} =
             WotexHome.LocalAPI.Client.request(socket, request)

    output = capture_io(fn -> assert 0 == WotexHome.CLI.main(flags ++ command) end)
    assert JSON.decode!(output)["external_report_preview"] == old
    output = capture_io(fn -> assert 0 == WotexHome.CLI.main(flags ++ status) end)
    assert JSON.decode!(output)["external_observation_receipt"] == first
    assert :ok = Integrity.validate_snapshot(db(%{c | store: store}))
  end

  test "sentinel interpretation retains null and never creates a known zero or false", c do
    c = prepare(c, "temperature", %{"trust" => "unauthenticated_local"})
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)

    sentinel =
      fixture("temperature")["profile"]["channels"]
      |> hd()
      |> Map.fetch!("invalid_values")
      |> hd()

    input =
      publish_report(c, "packet:invalid", %{"value" => sentinel, "continuity" => "baseline"})

    assert {:ok, _} = Store.accept_external_report(c.store, input)

    {:ok, reader, _} =
      Store.provision_principal(c.store, "reader:1", ["read"], ["sensor:external"])

    assert {:ok, current} =
             Store.external_report_current(c.store, reader, "sensor:external", "sample")

    assert current["freshness"] == "unknown" and current["reason"] == "invalid"
    assert current["value"] == nil
  end

  test "source replacement while observation preparation is paused rolls back the original and clocks",
       c do
    c = prepare(c)
    {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
    before = revision(c)
    input = publish_report(c, "packet:race")
    :ok = :sys.suspend(c.custody)
    :erlang.trace(c.reports, true, [:receive])
    owner = c.reports
    task = Task.async(fn -> Store.accept_external_report(c.store, input) end)

    try do
      assert_receive {:trace, ^owner, :receive, {:"$gen_call", _, {:checkout, "packet:race"}}},
                     2000

      {:ok, newer} =
        ExternalSourceSelection.new(
          Map.put(c.selection.inputs["source"], "source_generation", 2),
          c.selection.inputs["reader"],
          c.selection.inputs["channels"]
        )

      {:ok, _} = ExternalSourceOwner.publish(c.sources, newer)
    after
      :erlang.trace(owner, false, [:receive])
      :ok = :sys.resume(c.custody)
    end

    assert {:error, :external_report_retired} = Task.await(task, 5000)
    assert revision(c) == before
    assert {:ok, [[0]]} = SQL.query(db(c), "SELECT COUNT(*) FROM profile_external_observations")
    assert :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  for damage <- ~w(pointer sequence journal value) do
    @observation_damage damage
    test "#{@observation_damage} report corruption refuses history and fences writes", c do
      c = prepare(c)
      {:ok, _} = Store.change_external_target(c.store, c.credential, c.input)
      input = publish_report(c, "packet:1")
      {:ok, receipt} = Store.accept_external_report(c.store, input)

      case @observation_damage do
        "pointer" ->
          SQL.query(db(c), "DELETE FROM profile_external_observation_current")

        "sequence" ->
          SQL.query(db(c), "UPDATE profile_external_observation_sequences SET sequence='8'")

        "journal" ->
          SQL.query(db(c), "UPDATE authority_journal SET entity_id='wrong' WHERE revision=?", [
            receipt["revision"]
          ])

        "value" ->
          {:ok, [[document]]} =
            SQL.query(db(c), "SELECT outcome_document FROM profile_external_observations")

          {:ok, outcome} = WotexHome.Profiles.ExternalObservation.decode_outcome(document)

          changed =
            outcome["value_document"]
            |> JSON.decode!()
            |> Map.put("contract_sha256", String.duplicate("0", 64))

          {:ok, value_doc} = Wotex.JSON.encode(changed)

          outcome =
            Map.merge(outcome, %{
              "value_document" => value_doc,
              "value_sha256" => WotexHome.Profiles.ExternalObservation.value_sha(value_doc)
            })

          {:ok, changed_doc} = WotexHome.Profiles.ExternalObservation.encode_outcome(outcome)

          {:ok, receipt_doc} =
            WotexHome.Profiles.ExternalObservation.encode_receipt(
              Map.merge(receipt, %{
                "value_sha256" => outcome["value_sha256"],
                "outcome_sha256" => WotexHome.Profiles.ExternalObservation.sha(changed_doc)
              })
            )

          SQL.query(
            db(c),
            "UPDATE profile_external_observations SET outcome_document=?,receipt_document=?",
            [changed_doc, receipt_doc]
          )
      end

      assert {:error, :corrupt_external_observations} = Integrity.validate_snapshot(db(c))

      assert {:error, :corrupt_external_observations} =
               Store.accept_external_report(c.store, input)

      refute :sys.get_state(c.store).writable
    end
  end

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
               "DROP TABLE IF EXISTS profile_external_observation_current; DROP TABLE IF EXISTS profile_external_observation_sequences; DROP TABLE IF EXISTS profile_external_observations; DROP TABLE profile_external_source_bindings; DROP TABLE profile_external_target_current; DROP TABLE profile_external_target_history; DROP TABLE profile_external_target_operations; PRAGMA user_version=33"
             )

    assert :ok = Integrity.validate_snapshot(database)
    Sqlite3.close(database)
    store = start_supervised!({Store, path: c.path, name: @owner})
    c = %{c | store: store}
    assert {:ok, [[35]]} = SQL.query(db(c), "PRAGMA user_version")
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
      socket = Path.join(c.root, "ipc/home.sock")
      start_supervised!({WotexHome.LocalAPI.Server, authority: c.authority, socket_path: socket})
      encoded = Base.url_encode64(c.credential, padding: false)

      request = %{
        "api_version" => 1,
        "operation" => "external_target_change",
        "credential" => encoded,
        "change" => c.input
      }

      assert {:ok, %{"outcome" => "ok", "external_target_receipt" => first}} =
               WotexHome.LocalAPI.Client.request(socket, request)

      assert first["revision"] == c.input["expected_revision"] + 1 and
               first["resource_revision"] == 0

      assert {:ok, ^first} = Authority.change_external_target(c.authority, c.credential, c.input)

      assert {:ok, ^first} =
               Authority.external_target_status(c.authority, c.credential, 1, "selection:1")

      assert {:ok, %{"outcome" => "ok", "external_target_receipt" => ^first}} =
               WotexHome.LocalAPI.Client.request(socket, request)

      assert {:ok, %{"reason" => "unsupported_operation_or_fields"}} =
               WotexHome.LocalAPI.Client.request(socket, Map.put(request, "extra", true))

      refute JSON.encode!(first) =~ c.selection.inputs["source"]["stable_id"]
      credential_file = Path.join(c.root, "credential")
      File.write!(credential_file, encoded)
      File.chmod!(credential_file, 0o600)
      original_file = Path.join(c.root, "target-original.json")
      File.write!(original_file, JSON.encode!(c.input))
      File.chmod!(original_file, 0o600)
      flags = ["--socket", socket, "--credential-file", credential_file]

      output =
        capture_io(fn ->
          assert 0 == WotexHome.CLI.main(flags ++ ["external-target-change", original_file])
        end)

      assert JSON.decode!(output)["external_target_receipt"] == first

      output =
        capture_io(fn ->
          assert 0 == WotexHome.CLI.main(flags ++ ["external-target-status", "1", "selection:1"])
        end)

      assert JSON.decode!(output)["external_target_receipt"] == first
      assert revision(c) == first["revision"]

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
      stop_supervised(WotexHome.LocalAPI.Server)
      authority = Authority.new(store: store)
      start_supervised!({WotexHome.LocalAPI.Server, authority: authority, socket_path: socket})
      revoke = revoke_input(c, first)

      assert {:ok, %{"outcome" => "ok", "external_target_receipt" => revoked}} =
               WotexHome.LocalAPI.Client.request(socket, Map.put(request, "change", revoke))

      assert {:ok, ^revoked} = Authority.change_external_target(authority, c.credential, revoke)

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

  for {family, state} <- [{"temperature", "active"}, {"research", "revoked"}, {"multi", "active"}] do
    @recovery_family family
    @recovery_state state
    test "#{@recovery_family} #{@recovery_state} target has an inert complete source/quarantine inventory",
         c do
      alias WotexHome.Durable.Store.{RecoveryDomains, RecoverySnapshot}
      alias WotexHome.Recovery.DomainCodec
      c = prepare(c, @recovery_family)
      {:ok, selected} = Store.change_external_target(c.store, c.credential, c.input)
      input = publish_report(c, "packet:transfer")
      {:ok, receipt} = Store.accept_external_report(c.store, input)

      if @recovery_state == "revoked" do
        assert {:ok, _} =
                 Store.change_external_target(c.store, c.credential, revoke_input(c, selected))
      end

      {:ok, transfer, rev} =
        Store.provision_principal(c.store, "transfer:1", ["host:transfer"], [])

      assert {:ok, retired} =
               Store.retire_controller(c.store, transfer, %{
                 "authority_epoch" => 1,
                 "operation_id" => "retire:external",
                 "expected_revision" => rev,
                 "destination_owner_id" => String.duplicate("a", 64)
               })

      assert {:ok, inventory} = RecoveryDomains.derive(db(c), :source)
      assert inventory.domain_count == 1 and inventory.counter_state == "unknown"

      assert {:ok, ["wotex-home.controller-domains.v3", _, _, [record]]} =
               JSON.decode(inventory.document)

      assert Enum.at(record, 1) == @recovery_state
      assert List.last(record) == ["unknown"]

      assert Enum.all?(Enum.at(record, 5), fn [tag, _, sha] ->
               tag == "external_read" and byte_size(sha) == 64
             end)

      assert {:ok, retained} =
               RecoverySnapshot.retained_commitment(db(c), retired["revision"], "operator:fresh")

      key = :crypto.strong_rand_bytes(32)
      archive = Path.join(c.root, "external-retired.woh")
      assert {:ok, _} = Store.export_profile_backup(c.store, archive, key)
      assert {:ok, basis} = Backup.retired_transfer_basis(archive, key)
      assert basis.domains == inventory
      target = Path.join(c.root, "external-quarantine")
      assert {:ok, _} = Backup.stage_profile_restore(archive, key, target)
      stop_supervised(Store)
      stop_supervised(ExternalSourceOwner)
      stop_supervised(Custody)
      File.rm_rf!(Path.join(target, "profiles"))
      {:ok, database} = Sqlite3.open(Path.join(target, "home.sqlite"))

      try do
        without_profile_producer(fn ->
          refute Code.ensure_loaded?(Wotex.JSON)
          assert {:ok, absent_basis} = Backup.retired_transfer_basis(archive, key)
          assert absent_basis.domains == inventory
          assert :ok = Integrity.validate_snapshot(database)
          assert {:ok, ^inventory} = RecoveryDomains.derive(database, :quarantine)

          assert {:ok, ^retained} =
                   RecoverySnapshot.retained_commitment(
                     database,
                     retired["revision"],
                     "operator:fresh"
                   )

          assert {:ok, [[doc]]} =
                   SQL.query(
                     database,
                     "SELECT receipt_document FROM profile_external_observations"
                   )

          assert {:ok, ^receipt} = WotexHome.Profiles.ExternalObservation.decode_receipt(doc)

          assert {:ok, [[1]]} =
                   SQL.query(
                     database,
                     "SELECT COUNT(*) FROM profile_external_observation_sequences"
                   )

          assert {:error, :transfer_domain_isolation_unavailable} =
                   DomainCodec.acceptance_basis(inventory.document, "physical_disconnection")

          assert {:error, :fixture_rollback} =
                   SQL.transaction(database, fn db ->
                     assert {:ok, []} =
                              SQL.query(
                                db,
                                "UPDATE profile_external_observation_sequences SET sequence='999'"
                              )

                     assert {:ok, changed} =
                              RecoverySnapshot.retained_commitment(
                                db,
                                retired["revision"],
                                "operator:fresh"
                              )

                     refute changed == retained

                     assert {:error, :invalid_transfer_domains} =
                              RecoveryDomains.derive(db, :quarantine)

                     {:rollback, :fixture_rollback}
                   end)

          assert {:ok, ^inventory} = RecoveryDomains.derive(database, :quarantine)
          refute Code.ensure_loaded?(Wotex.JSON)
        end)
      after
        Sqlite3.close(database)
      end
    end
  end

  defp without_profile_producer(fun) do
    module = Wotex.JSON
    {^module, beam, path} = :code.get_object_code(module)
    :code.purge(module)
    :code.delete(module)
    directory = path |> List.to_string() |> Path.dirname()
    true = :code.del_path(String.to_charlist(directory))

    try do
      fun.()
    after
      true = :code.add_patha(String.to_charlist(directory))
      {:module, ^module} = :code.load_binary(module, path, beam)
    end
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
