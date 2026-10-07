Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableCandidatesTest do
  @moduledoc false
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.CLI
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.LocalAPI.{Frame, Server}
  alias WotexHome.Rules.{CandidateArtifact, CandidateReview, Codec, Rule}
  alias WotexHome.Semantics.Thing

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:candidate:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @rule %{
    "version" => 1,
    "id" => "rule:review:1",
    "source_revision" => 7,
    "trigger" => %{"kind" => "explicit_request"},
    "predicate" => %{"op" => "literal_true"},
    "effect" => %{
      "target_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    },
    "authority_class" => "automation",
    "unknown_policy" => "block",
    "ownership_ms" => 10_000,
    "cooldown_ms" => 1_000,
    "causal_budget" => 4
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "home-candidates-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!({Store, path: path})
    gate = start_supervised!(ReviewGate)

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:desk",
        "role" => "Light",
        "profile_ref" => "lifx.old:1",
        "capabilities" => [@power]
      })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, reviewer, 2} =
             Store.provision_principal(store, "reviewer:1", ["rule:review"], [thing.id])

    assert {:ok, other, 3} =
             Store.provision_principal(store, "reviewer:2", ["rule:review"], [thing.id])

    assert {:ok, controller, 4} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], [thing.id])

    authority = Authority.new(store: store, review_gate: gate, capture: nil)

    {:ok,
     directory: directory,
     path: path,
     store: store,
     authority: authority,
     reviewer: reviewer,
     other: other,
     controller: controller}
  end

  test "canonical codec roundtrips every supported value, trigger and predicate without rounding" do
    fact = %{"thing_id" => "sensor:1", "capability_key" => "reading"}

    values = [
      %{"type" => "boolean", "value" => false},
      %{"type" => "fraction", "ppm" => 1},
      %{"type" => "kelvin", "kelvin" => 1_000_000},
      %{"type" => "hsv", "hue_mdeg" => 359_999, "saturation_ppm" => 999_999},
      %{"type" => "xy", "x_ppm" => 1, "y_ppm" => 999_999},
      %{"type" => "smoke_state", "state" => "alarm"}
    ]

    rules =
      for {value, n} <- Enum.with_index(values),
          trigger <- ["explicit_request", "rising_edge", "falling_edge"] do
        trigger =
          if trigger == "explicit_request",
            do: %{"kind" => trigger},
            else: %{"kind" => trigger, "fact" => fact}

        predicate = %{
          "op" => "all",
          "predicates" => [
            %{"op" => "eq", "fact" => fact, "value" => value},
            %{
              "op" => "not",
              "predicate" => %{
                "op" => "any",
                "predicates" => [
                  %{"op" => "literal_true"},
                  %{
                    "op" => "gt",
                    "fact" => fact,
                    "value" => %{"type" => "kelvin", "kelvin" => 2_701}
                  }
                ]
              }
            }
          ]
        }

        assert {:ok, rule} =
                 Rule.new(%{
                   @rule
                   | "id" => "rule:#{n}",
                     "trigger" => trigger,
                     "predicate" => predicate,
                     "effect" => %{@rule["effect"] | "value" => value}
                 })

        rule
      end

    assert {:ok, document} = Codec.encode(rules)
    assert {:ok, ^rules} = Codec.decode(document)
    assert {:ok, ^document} = Codec.encode(rules)
    assert {:error, :invalid_rule_document} = Codec.decode(document <> " ")
    assert {:error, :invalid_rule_set} = Codec.encode([%{hd(rules) | causal_budget: 33}])

    assert {:error, :invalid_rule_document} =
             Codec.decode(JSON.encode!(%{"rules" => [Map.put(@rule, "execute", true)]}))

    assert {:error, :invalid_rule_set} = Codec.encode(List.duplicate(hd(rules), 65))
    assert {:error, :invalid_rule_document} = Codec.decode(String.duplicate(" ", 65_537))
  end

  test "rejected candidate is immutable across restart and checker loss, with no work or generation",
       c do
    assert {:ok, receipt} = record(c)
    assert receipt.decision == "rejected"
    assert receipt.reason == "duplicate_rule_id"
    assert receipt.expected_revision == 4 and receipt.revision == 5
    assert {:ok, ^receipt} = record(c)
    assert {:ok, 5} = Store.revision(c.store)
    assert {:ok, ^receipt} = Authority.rule_review_status(c.authority, c.reviewer, 1, "review:1")

    assert {:error, :rule_review_operation_conflict} =
             Authority.record_rule_review(c.authority, c.reviewer, 1, "review:1", 4, [@rule])

    assert {:error, :rule_review_operation_conflict} =
             Authority.record_rule_review(c.authority, c.reviewer, 1, "review:1", 5, [
               @rule,
               @rule
             ])

    assert {:ok, %{rule_generation: 0, held_requests: 0, queued_requests: 0}} =
             Store.authorized_health(c.store, c.controller)

    stop_supervised!(Store)
    restarted = start_supervised!({Store, path: c.path})
    unavailable = %{c.authority | store: restarted, review_gate: nil}

    assert {:ok, ^receipt} =
             Authority.record_rule_review(unavailable, c.reviewer, 1, "review:1", 4, [
               @rule,
               @rule
             ])

    assert {:error, :review_unavailable} =
             Authority.record_rule_review(unavailable, c.reviewer, 1, "review:new", 5, [@rule])

    assert {:ok, 5} = Store.revision(restarted)
  end

  test "status and retry authenticate current reviewer and isolate principal identities", c do
    assert {:ok, _} = record(c)

    assert {:error, :permission_denied} =
             Authority.rule_review_status(c.authority, c.controller, 1, "review:1")

    assert {:error, :rule_review_not_found} =
             Authority.rule_review_status(c.authority, c.other, 1, "review:1")

    assert {:error, :resnapshot_required} =
             Authority.record_rule_review(c.authority, c.other, 1, "review:1", 4, [@rule, @rule])

    assert {:ok, 6} = Store.revoke_principal(c.store, "reviewer:1")
    assert {:error, :unauthorized} = record(c)

    assert {:error, :unauthorized} =
             Authority.rule_review_status(c.authority, c.reviewer, 1, "review:1")
  end

  test "stale inputs, unsupported identity and forged client outcomes never write", c do
    for {epoch, expected, operation, reason} <- [
          {2, 4, "review:epoch", :stale_authority_epoch},
          {1, 3, "review:stale", :resnapshot_required},
          {0, 4, "review:zero", :invalid_rule_review_operation},
          {1, 4, "", :invalid_rule_review_operation}
        ] do
      assert {:error, ^reason} =
               Authority.record_rule_review(c.authority, c.reviewer, epoch, operation, expected, [
                 @rule
               ])
    end

    request = %{
      "api_version" => 1,
      "operation" => "record_rule_review",
      "credential" => Base.url_encode64(c.reviewer, padding: false),
      "rules" => [@rule],
      "authority_epoch" => 1,
      "operation_id" => "review:1",
      "expected_revision" => 4
    }

    assert %{"reason" => "unsupported_operation_or_fields"} =
             Server.route(c.authority, Map.put(request, "decision", "admitted"))

    assert {:ok, 4} = Store.revision(c.store)
  end

  test "Store rechecks full declaration and credential basis when checker work finishes", c do
    {:ok, rule} = Rule.new(@rule)
    rules = [rule, rule]

    assert {:ok, document} = Codec.encode(rules)

    assert {:ok, :new, things, resources} =
             Store.prepare_rule_review(c.store, c.reviewer, 1, "review:race", 4, document)

    assert {:ok, review} = CandidateReview.review(rules, things)
    assert {:ok, artifact} = CandidateArtifact.build(rules, resources, review)
    assert {:ok, 5} = Store.revoke_thing(c.store, "light:desk")

    assert {:error, :review_scope_unavailable} =
             Store.commit_rule_review(
               c.store,
               c.reviewer,
               1,
               "review:race",
               4,
               document,
               artifact
             )

    assert {:error, :rule_review_not_found} =
             Store.rule_review_status(c.store, c.reviewer, 1, "review:race")

    assert {:ok, 5} = Store.revision(c.store)
  end

  test "changed artifact resources cannot substitute for checked current declarations", c do
    {:ok, rule} = Rule.new(@rule)
    {:ok, document} = Codec.encode([rule, rule])

    assert {:ok, :new, things, resources} =
             Store.prepare_rule_review(c.store, c.reviewer, 1, "review:substitute", 4, document)

    {:ok, review} = CandidateReview.review([rule, rule], things)

    {:ok, artifact} =
      CandidateArtifact.build(
        [rule, rule],
        [%{hd(resources) | "resource_revision" => hd(resources)["resource_revision"] + 1}],
        review
      )

    assert {:error, :review_basis_changed} =
             Store.commit_rule_review(
               c.store,
               c.reviewer,
               1,
               "review:substitute",
               4,
               document,
               artifact
             )

    assert {:ok, 4} = Store.revision(c.store)
  end

  test "unrelated writes and credential rotation invalidate checked but uncommitted work", c do
    {:ok, rule} = Rule.new(@rule)
    {:ok, document} = Codec.encode([rule, rule])

    {:ok, :new, things, resources} =
      Store.prepare_rule_review(c.store, c.reviewer, 1, "review:race", 4, document)

    {:ok, review} = CandidateReview.review([rule, rule], things)
    {:ok, artifact} = CandidateArtifact.build([rule, rule], resources, review)
    assert {:ok, _, 5} = Store.provision_principal(c.store, "reader:unrelated", ["read"], [])

    assert {:error, :resnapshot_required} =
             Store.commit_rule_review(
               c.store,
               c.reviewer,
               1,
               "review:race",
               4,
               document,
               artifact
             )

    assert {:ok, :new, ^things, ^resources} =
             Store.prepare_rule_review(c.store, c.reviewer, 1, "review:rotation", 5, document)

    assert {:ok, replacement, 6} = Store.rotate_principal_credential(c.store, "reviewer:1")

    assert {:error, :unauthorized} =
             Store.commit_rule_review(
               c.store,
               c.reviewer,
               1,
               "review:rotation",
               5,
               document,
               artifact
             )

    assert {:error, :resnapshot_required} =
             Store.commit_rule_review(
               c.store,
               replacement,
               1,
               "review:rotation",
               5,
               document,
               artifact
             )

    assert {:ok, 6} = Store.revision(c.store)

    assert {:error, :rule_review_not_found} =
             Store.rule_review_status(c.store, replacement, 1, "review:rotation")
  end

  test "two checked attempts under one operation retain only the first committed outcome", c do
    {:ok, rule} = Rule.new(@rule)
    {:ok, document} = Codec.encode([rule, rule])

    for _ <- 1..2 do
      assert {:ok, :new, _, _} =
               Store.prepare_rule_review(c.store, c.reviewer, 1, "review:1", 4, document)
    end

    assert {:ok, original} = record(c)
    # A losing checked attempt must not replace the original result, or require
    # today's checker/package to remain available merely to return that result.
    assert {:ok, ^original} =
             Store.commit_rule_review(
               c.store,
               c.reviewer,
               1,
               "review:1",
               4,
               document,
               "unused losing attempt"
             )

    assert {:ok, 5} = Store.revision(c.store)
  end

  test "native negative screening retains a receipt commitment but stays pending", c do
    restricted = %{@rule | "cooldown_ms" => 0, "causal_budget" => 1}

    assert {:ok, receipt} =
             Authority.record_rule_review(c.authority, c.reviewer, 1, "review:native", 4, [
               restricted
             ])

    assert receipt.decision == "pending_positive_basis"
    assert receipt.proposal_basis_digest =~ ~r/\A[0-9a-f]{64}\z/
    # Native availability may fail closed on a host without the bundled backend;
    # an unavailable attempt still remains pending, never a positive proof.
    assert is_nil(receipt.checker_receipt_digest) or
             receipt.checker_receipt_digest =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, ^receipt} =
             Authority.rule_review_status(c.authority, c.reviewer, 1, "review:native")
  end

  test "all pending grammar remains retainable and cannot be relabelled admitted", c do
    edge = %{
      @rule
      | "trigger" => %{
          "kind" => "rising_edge",
          "fact" => %{"thing_id" => "light:desk", "capability_key" => "power"}
        }
    }

    assert {:ok, receipt} =
             Authority.record_rule_review(c.authority, c.reviewer, 1, "review:edge", 4, [edge])

    assert receipt.decision == "pending_composed_proof" and
             receipt.reason == "feedback_not_supported"

    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    [[document]] = rows(db, "SELECT artifact_document FROM rule_candidate_reviews")
    Sqlite3.close(db)
    input = JSON.decode!(document)
    modified = JSON.encode!(%{input | "review" => %{input["review"] | "decision" => "admitted"}})
    assert {:error, :corrupt_rule_review} = CandidateArtifact.decode(modified)

    modified =
      JSON.encode!(%{input | "review" => Map.put(input["review"], "native_witness", "private")})

    assert {:error, :corrupt_rule_review} = CandidateArtifact.decode(modified)
  end

  test "framed adapter and CLI preserve operation identity and withhold private documents", c do
    rules_file = Path.join(c.directory, "rules.json")
    File.write!(rules_file, JSON.encode!(%{"rules" => [@rule, @rule]}))
    File.chmod!(rules_file, 0o600)
    credential = Base.url_encode64(c.reviewer, padding: false)

    assert {:ok, request} =
             CLI.build_request(
               ["record-rule-review", "1", "review:cli", "4", rules_file],
               credential
             )

    assert {:ok, frame} = Frame.encode_request(request)
    assert {:ok, response} = Server.route_frame(c.authority, frame)
    <<_size::32, body::binary>> = response
    assert %{"outcome" => "ok", "rule_review_receipt" => receipt} = JSON.decode!(body)
    assert receipt["operation_id"] == "review:cli" and receipt["revision"] == 5

    for private <- ["rules_document", "resources", "light:desk", "native_witness", credential],
        do: refute(body =~ private)

    assert {:ok, status} =
             CLI.build_request(["rule-review-status", "1", "review:cli"], credential)

    assert %{"rule_review_receipt" => ^receipt} = Server.route(c.authority, status)

    assert %{"outcome" => "not_found"} =
             Server.route(c.authority, %{status | "operation_id" => "review:missing"})

    assert %{"reason" => "unsupported_operation_or_fields"} =
             Server.route(c.authority, Map.put(status, "raw", true))

    File.chmod!(rules_file, 0o644)

    assert {:error, :invalid_rules_file} =
             CLI.build_request(
               ["record-rule-review", "1", "review:bad", "5", rules_file],
               credential
             )
  end

  test "encrypted backup retains candidate history but cannot reactivate it", c do
    assert {:ok, receipt} = record(c)
    key = :crypto.strong_rand_bytes(32)
    backup = Path.join(c.directory, "home.backup")
    assert {:ok, _} = Store.export_backup(c.store, backup, key)

    assert {:ok,
            %{
              store_revision: 5,
              dependencies: %{
                rule_candidate_review_rows: 1,
                candidate_history_reactivates_rules: false
              }
            }} = Backup.verify(backup, key)

    staged = Path.join(c.directory, "restore.sqlite")
    assert {:ok, %{quarantined: true}} = Backup.stage_restore(backup, key, staged)
    {:ok, db} = Sqlite3.open(staged, mode: :readonly)

    assert [[receipt.artifact_digest]] ==
             rows(db, "SELECT artifact_digest FROM rule_candidate_reviews")

    Sqlite3.close(db)
    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: staged)
  end

  test "version eleven migrates with empty candidate history and unchanged revision", c do
    stop_supervised!(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
          "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP INDEX power_handoff_time; ALTER TABLE request_execution DROP COLUMN handoff_store_boot_epoch; ALTER TABLE request_execution DROP COLUMN handoff_store_monotonic_ms; DROP TABLE rule_candidate_reviews; PRAGMA user_version=11"
      )

    key = :crypto.strong_rand_bytes(32)
    backup = Path.join(c.directory, "version-eleven.backup")
    assert {:ok, _} = Backup.export(db, backup, key)
    assert {:ok, %{dependencies: %{rule_candidate_review_rows: 0}}} = Backup.verify(backup, key)
    Sqlite3.close(db)
    migrated = start_supervised!({Store, path: c.path})
    assert {:ok, 4} = Store.revision(migrated)

    assert {:error, :rule_review_not_found} =
             Store.rule_review_status(migrated, c.reviewer, 1, "review:1")

    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    assert [[19]] == rows(db, "PRAGMA user_version")
    Sqlite3.close(db)
  end

  test "retention ceiling preserves exact retries and refuses new IDs without pruning", c do
    assert {:ok, original} = record(c)
    stop_supervised!(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(db, """
      WITH RECURSIVE sequence(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM sequence WHERE n<1023)
      INSERT INTO rule_candidate_reviews
      SELECT principal_id, authority_epoch, 'review:fixture:' || n, expected_revision+n,
             rules_document, artifact_document, artifact_digest, revision+n
      FROM rule_candidate_reviews CROSS JOIN sequence WHERE operation_id='review:1';
      INSERT INTO authority_journal SELECT revision, 'rule_candidate_reviewed', operation_id
      FROM rule_candidate_reviews WHERE operation_id!='review:1';
      UPDATE meta SET value=1028 WHERE key='revision';
      """)

    Sqlite3.close(db)
    restarted = start_supervised!({Store, path: c.path})
    authority = %{c.authority | store: restarted, review_gate: nil}

    assert {:ok, ^original} =
             Authority.record_rule_review(authority, c.reviewer, 1, "review:1", 4, [@rule, @rule])

    assert {:error, :rule_review_capacity} =
             Authority.record_rule_review(authority, c.reviewer, 1, "review:full", 1028, [@rule])

    assert {:ok, ^original} = Authority.rule_review_status(authority, c.reviewer, 1, "review:1")
    assert {:ok, 1028} = Store.revision(restarted)
  end

  test "tampered candidate content or journal is refused on startup and backup", c do
    assert {:ok, _} = record(c)
    stop_supervised!(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE rule_candidate_reviews SET artifact_digest='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'"
      )

    assert {:error, _} = Store.validate_snapshot(db)
    key = :crypto.strong_rand_bytes(32)
    backup = Path.join(c.directory, "corrupt.backup")
    assert {:ok, _} = Backup.export(db, backup, key)
    assert {:error, :invalid_backup} = Backup.verify(backup, key)
    Sqlite3.close(db)
    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, {:schema_inconsistent, _}}} =
             Store.start_link(path: c.path)
  end

  test "journal link and resource revision bounds are independently checked", c do
    assert {:ok, _} = record(c)
    stop_supervised!(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE authority_journal SET entity_id='review:different' WHERE event_type='rule_candidate_reviewed'"
      )

    assert {:error, _} = Store.validate_snapshot(db)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE authority_journal SET entity_id='review:1' WHERE event_type='rule_candidate_reviewed'"
      )

    assert :ok = Store.validate_snapshot(db)
    [[document]] = rows(db, "SELECT artifact_document FROM rule_candidate_reviews")
    input = JSON.decode!(document)

    changed =
      JSON.encode!(%{
        input
        | "resources" => [%{hd(input["resources"]) | "resource_revision" => 5}]
      })

    {:ok, statement} =
      Sqlite3.prepare(
        db,
        "UPDATE rule_candidate_reviews SET artifact_document=?, artifact_digest=?"
      )

    :ok = Sqlite3.bind(statement, [changed, CandidateArtifact.digest(changed)])
    {:ok, []} = Sqlite3.fetch_all(db, statement)
    Sqlite3.release(db, statement)
    assert {:error, _} = Store.validate_snapshot(db)
    Sqlite3.close(db)
  end

  defp record(c),
    do: Authority.record_rule_review(c.authority, c.reviewer, 1, "review:1", 4, [@rule, @rule])

  defp rows(db, sql) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      {:ok, rows} = Sqlite3.fetch_all(db, statement)
      rows
    after
      Sqlite3.release(db, statement)
    end
  end
end
