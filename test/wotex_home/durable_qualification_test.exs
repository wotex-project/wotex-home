defmodule WotexHome.DurableQualificationTest do
  @moduledoc false

  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Discovery.{Candidate, EnrollmentReview, Interview, Profile}
  alias WotexHome.Durable.{Backup, Registry, Store}
  alias WotexHome.Durable.Store.Integrity
  alias WotexHome.Lifx.{ProductRegistry, ProfileBasis}
  alias WotexHome.Qualification.{Attestation, Claims, Decision, Evidence, Programme}
  alias WotexHome.Semantics.Thing

  @serial "lifx:d073d5000001"
  @candidate %{
    "interface_id" => "en0",
    "transport" => "udp",
    "source_endpoint" => "192.0.2.10:56700",
    "receive_epoch" => "scan:1",
    "received_monotonic_ms" => 100,
    "raw_ref" => "capture:1",
    "claimed_identifiers" => %{"stable_id" => @serial},
    "trust_class" => "untrusted_network"
  }
  @interview %{
    "candidate_ref" => "capture:1",
    "transport" => "udp",
    "manufacturer" => "lifx.vendor.1",
    "model" => "lifx.product.27",
    "firmware" => "2.80",
    "stable_id" => @serial
  }
  @profile %{
    "id" => "lifx.old-eu",
    "version" => "1.0.0",
    "transport" => "udp",
    "manufacturer" => "lifx.vendor.1",
    "model" => "lifx.product.27",
    "firmware_versions" => ["2.80"],
    "rank" => 10,
    "qualification_ref" => "cohort:old-eu:1"
  }
  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old-eu:1.0.0",
    "evidence_ref" => "cohort:old-eu:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }
  @selection %{
    "operator_id" => "owner:1",
    "candidate_ref" => "capture:1",
    "stable_id" => @serial,
    "profile_ref" => "lifx.old-eu:1.0.0",
    "qualification_ref" => "cohort:old-eu:1",
    "method" => "legacy_tofu",
    "review_ref" => "review:1"
  }
  @cohort %{
    "source_identity_ref" => String.duplicate("a", 64),
    "hardware_sku" => "lifx.old-eu",
    "hardware_revision" => "rev.1",
    "firmware" => "2.80",
    "adapter_profile" => "lifx.old-eu:1.0.0",
    "native_stack" => "wotex-udp:test",
    "host_os" => "macos:test",
    "runtime" => "otp:test",
    "network_topology" => "isolated-lan:1",
    "application" => "home:test",
    "model" => "none"
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-qualification-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, path: Path.join(directory, "home.sqlite")}
  end

  test "only a pinned reviewed basis can create one durable qualification row", %{path: path} do
    {case_public, case_private} = :crypto.generate_key(:eddsa, :ed25519)
    {decision_public, decision_private} = :crypto.generate_key(:eddsa, :ed25519)
    case_id = "reviewer:cases"
    decision_id = "reviewer:physical"

    keys = [
      qualification_case_keys: %{case_id => case_public},
      qualification_decision_keys: %{decision_id => decision_public}
    ]

    assert {:ok, store} = Store.start_link([path: path] ++ keys)
    assert {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = enrollment_fixture()

    assert {:ok, 2} =
             Store.commit_enrollment(
               store,
               owner,
               [candidate],
               interview,
               [profile],
               thing,
               @selection
             )

    assert {:ok, qualifier, 3} =
             Store.provision_principal(store, "qualifier:1", ["qualify:profile"], [thing.id])

    assert {:ok, reader, 4} = Store.provision_principal(store, "reader:1", ["read"], [thing.id])

    {signed, basis, attestations} =
      decision_fixture(
        candidate,
        interview,
        profile,
        thing,
        case_id,
        case_private,
        decision_id,
        decision_private
      )

    assert {:error, :permission_denied} =
             Store.qualify_lifx_power(store, reader, signed, basis, @cohort, attestations)

    assert {:error, :unauthorized} =
             Store.qualify_lifx_power(
               store,
               :binary.copy(<<1>>, 32),
               signed,
               basis,
               @cohort,
               attestations
             )

    assert {:error, :invalid_qualification_decision} =
             Store.qualify_lifx_power(store, qualifier, signed, basis, @cohort, tl(attestations))

    assert {:ok, 5} =
             Store.qualify_lifx_power(store, qualifier, signed, basis, @cohort, attestations)

    assert {:ok, 5} =
             Store.qualify_lifx_power(store, qualifier, signed, basis, @cohort, attestations)

    assert {:ok, %{store_revision: 5, dispatch_enabled: false}} = Store.health(store)

    assert {:ok, verified} =
             Decision.verify(signed, basis, @cohort, attestations, %{case_id => case_public}, %{
               decision_id => decision_public
             })

    assert {:ok, db} = Sqlite3.open(path)
    evidence_ref = verified.evidence_ref

    assert [[^evidence_ref, "qualified", 5]] =
             rows(db, "SELECT evidence_ref, status, revision FROM profile_qualifications")

    :ok = Sqlite3.close(db)

    claim_root = Path.join(Path.dirname(path), "qualification_claims")

    assert {:ok, %{evidence_ref: ^evidence_ref}} =
             Claims.verify(claim_root, evidence_ref, %{case_id => case_public}, %{
               decision_id => decision_public
             })

    assert {:error, :qualification_artifact_unavailable} =
             Claims.verify(claim_root, evidence_ref, %{}, %{decision_id => decision_public})

    claim_path = Path.join(claim_root, String.replace_prefix(evidence_ref, "qualification:", ""))
    original_claim = File.read!(claim_path)
    File.write!(claim_path, original_claim <> <<0>>)

    assert {:error, :qualification_artifact_unavailable} =
             Claims.verify(claim_root, evidence_ref, %{case_id => case_public}, %{
               decision_id => decision_public
             })

    File.write!(claim_path, original_claim)

    archive = path <> ".backup"
    backup_key = :binary.copy(<<9>>, 32)
    assert {:ok, %{store_revision: 5}} = Store.export_backup(store, archive, backup_key)

    assert {:ok,
            %{
              dependencies: %{
                qualified_profile_rows: 1,
                claim_package_refs: [^evidence_ref],
                non_claim_qualification_rows: 0,
                reviewer_keys_required: true,
                raw_qualification_artifacts_included: false,
                device_credentials_and_counters: "external"
              }
            }} = Backup.verify(archive, backup_key)

    :ok = GenServer.stop(store)
    assert {:ok, restarted} = Store.start_link([path: path] ++ keys)
    assert {:ok, %{store_revision: 5, dispatch_enabled: false}} = Store.health(restarted)
    :ok = GenServer.stop(restarted)
  end

  test "no pinned reviewer keys means qualification is unavailable", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)

    assert {:error, :qualification_unavailable} =
             Store.qualify_lifx_power(store, :binary.copy(<<1>>, 32), %{}, %{}, %{}, [])
  end

  test "revoked qualification can be replaced without restoring historical evidence", %{
    path: path
  } do
    c = qualified_fixture(path)
    assert {:ok, 4} = qualify(c)

    narrower = %{
      c.thing
      | capabilities: %{"power" => %{c.thing.capabilities["power"] | freshness_ms: 4_000}}
    }

    assert {:ok, 5} = Store.narrow_thing(c.store, narrower, 0)
    {:ok, db} = Sqlite3.open(path)
    assert [["revoked", 4]] = rows(db, "SELECT status,revision FROM profile_qualifications")
    assert :ok = Integrity.validate_snapshot(db)
    Sqlite3.close(db)

    claim_root = Path.join(Path.dirname(path), "qualification_claims")
    File.rm_rf!(claim_root)
    assert {:ok, 4} = qualify(c)
    assert {:ok, 5} = Store.revision(c.store)
    assert not File.exists?(claim_root)

    assert {:ok, 6} =
             Store.rereview_enrollment(
               c.store,
               c.owner,
               [c.candidate],
               c.interview,
               [c.profile],
               narrower,
               Map.put(@selection, "review_ref", "review:2")
             )

    {signed, basis, attestations} =
      decision_fixture(
        c.candidate,
        c.interview,
        c.profile,
        narrower,
        c.case_id,
        c.case_private,
        c.decision_id,
        c.decision_private,
        1
      )

    newer = %{c | signed: signed, basis: basis, attestations: attestations}
    assert {:ok, 7} = qualify(newer)
    assert {:ok, 4} = qualify(c)
    assert {:ok, 7} = qualify(newer)
    {:ok, db} = Sqlite3.open(path)

    assert [["qualified", 1, 7]] =
             rows(db, "SELECT status,resource_revision,revision FROM profile_qualifications")

    assert [[4, "guarded_current"], [7, "guarded_current"]] =
             rows(
               db,
               "SELECT revision,provenance FROM profile_qualification_history ORDER BY revision"
             )

    assert :ok = Integrity.validate_snapshot(db)
    Sqlite3.close(db)
    key = :crypto.strong_rand_bytes(32)
    archive = path <> ".history.woh"
    assert {:ok, _} = Store.export_backup(c.store, archive, key)

    assert {:ok,
            %{
              dependencies: %{
                qualified_profile_rows: 1,
                retained_qualification_rows: 2,
                claim_package_refs: refs
              }
            }} = Backup.verify(archive, key)

    assert length(refs) == 2
    GenServer.stop(c.store)
    assert {:ok, restarted} = Store.start_link([path: path] ++ c.keys)
    assert {:ok, 4} = qualify(%{c | store: restarted})
    assert {:ok, 7} = Store.revision(restarted)
    GenServer.stop(restarted)
  end

  test "schema 19 migration retains unavailable provenance and original status", %{path: path} do
    c = qualified_fixture(path)
    assert {:ok, 4} = qualify(c)
    GenServer.stop(c.store)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "DROP TABLE schedule_lifecycle_operations; DROP TABLE schedule_admissions; DROP TABLE native_target_operations; DROP TABLE controller_acceptances; DROP TABLE controller_retirements; DROP TABLE controller_identity; DROP TABLE profile_qualification_history; DELETE FROM meta WHERE key='qualification_history_migration_revision'; UPDATE profile_qualifications SET status='revoked'; PRAGMA user_version=19"
             )

    assert :ok = Integrity.validate_snapshot(db)
    key = :crypto.strong_rand_bytes(32)
    archive = path <> ".v19.woh"
    assert {:ok, _} = Backup.export(db, archive, key)

    assert {:ok, %{dependencies: %{qualified_profile_rows: 0, claim_package_refs: []}}} =
             Backup.verify(archive, key)

    Sqlite3.close(db)
    assert {:ok, upgraded} = Store.start_link([path: path] ++ c.keys)
    assert {:ok, 4} = Store.revision(upgraded)
    {:ok, db} = Sqlite3.open(path)
    assert [[25]] = rows(db, "PRAGMA user_version")

    assert [[4]] =
             rows(
               db,
               "SELECT value FROM meta WHERE key='qualification_history_migration_revision'"
             )

    assert [["legacy_migrated", nil, nil, nil, nil, 4]] =
             rows(
               db,
               "SELECT provenance,declaration_document,principal_id,authority_epoch,binding_revision,revision FROM profile_qualification_history"
             )

    assert [["revoked", 4]] = rows(db, "SELECT status,revision FROM profile_qualifications")
    Sqlite3.close(db)
    assert {:ok, 4} = qualify(%{c | store: upgraded})
    GenServer.stop(upgraded)
  end

  test "history and current head roll back together after a journal failure", %{path: path} do
    c = qualified_fixture(path)
    {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER fail_qualification BEFORE INSERT ON authority_journal WHEN NEW.event_type='profile_qualified' BEGIN SELECT RAISE(ABORT,'injected'); END"
             )

    assert {:error, :store_unavailable} = qualify(c)
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM profile_qualification_history")
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM profile_qualifications")
    assert [[3]] = rows(db, "SELECT value FROM meta WHERE key='revision'")
    assert :ok = Sqlite3.execute(db, "DROP TRIGGER fail_qualification")
    Sqlite3.close(db)
    GenServer.stop(c.store)
    assert {:ok, restarted} = Store.start_link([path: path] ++ c.keys)
    assert {:ok, 4} = qualify(%{c | store: restarted})
    GenServer.stop(restarted)
  end

  for damage <- [
        "DELETE FROM profile_qualification_history",
        "DELETE FROM profile_qualifications",
        "UPDATE profile_qualification_history SET authority_epoch=2",
        "UPDATE profile_qualification_history SET binding_revision=1",
        "UPDATE profile_qualification_history SET provenance='legacy_migrated',declaration_document=NULL,principal_id=NULL,authority_epoch=NULL,binding_revision=NULL",
        "UPDATE profile_qualification_history SET basis_digest='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'"
      ] do
    @damage damage
    test "damaged qualification history fails current use and archive verification: #{damage}", %{
      path: path
    } do
      c = qualified_fixture(path)
      assert {:ok, 4} = qualify(c)
      {:ok, db} = Sqlite3.open(path)
      assert :ok = Sqlite3.execute(db, @damage)
      assert {:error, _} = Integrity.validate_snapshot(db)
      key = :crypto.strong_rand_bytes(32)
      archive = path <> ".damaged.woh"
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
      Sqlite3.close(db)
      assert {:error, :corrupt_qualification_history} = qualify(c)
      assert {:ok, %{writable: false}} = Store.health(c.store)
      GenServer.stop(c.store)
    end
  end

  defp qualified_fixture(path) do
    {case_public, case_private} = :crypto.generate_key(:eddsa, :ed25519)
    {decision_public, decision_private} = :crypto.generate_key(:eddsa, :ed25519)
    case_id = "reviewer:cases"
    decision_id = "reviewer:physical"

    keys = [
      qualification_case_keys: %{case_id => case_public},
      qualification_decision_keys: %{decision_id => decision_public}
    ]

    {:ok, store} = Store.start_link([path: path] ++ keys)
    {:ok, owner, 1} = Store.provision_principal(store, "owner:1", ["enroll:review"], [])
    {candidate, interview, profile, thing} = enrollment_fixture()

    assert {:ok, 2} =
             Store.commit_enrollment(
               store,
               owner,
               [candidate],
               interview,
               [profile],
               thing,
               @selection
             )

    {:ok, qualifier, 3} =
      Store.provision_principal(store, "qualifier:1", ["qualify:profile"], [thing.id])

    {signed, basis, attestations} =
      decision_fixture(
        candidate,
        interview,
        profile,
        thing,
        case_id,
        case_private,
        decision_id,
        decision_private
      )

    %{
      store: store,
      owner: owner,
      qualifier: qualifier,
      keys: keys,
      candidate: candidate,
      interview: interview,
      profile: profile,
      thing: thing,
      case_id: case_id,
      case_private: case_private,
      decision_id: decision_id,
      decision_private: decision_private,
      signed: signed,
      basis: basis,
      attestations: attestations
    }
  end

  defp qualify(c),
    do: Store.qualify_lifx_power(c.store, c.qualifier, c.signed, c.basis, @cohort, c.attestations)

  defp enrollment_fixture do
    assert {:ok, candidate} = Candidate.new(@candidate)
    assert {:ok, interview} = Interview.new(@interview, candidate)
    assert {:ok, profile} = Profile.new(@profile)

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old-eu:1.0.0",
               "capabilities" => [@power]
             })

    {candidate, interview, profile, thing}
  end

  defp decision_fixture(
         candidate,
         interview,
         profile,
         thing,
         case_id,
         case_private,
         decision_id,
         decision_private,
         resource_revision \\ 0
       ) do
    assert {:ok, review} =
             EnrollmentReview.new([candidate], interview, [profile], thing, @selection)

    assert {:ok, document} = Registry.encode_thing(thing)
    assert {:ok, runtime_digest} = ProfileBasis.runtime_digest()
    assert {:ok, cases, programme_digest} = Programme.lifx_power_cases()
    assert {:ok, cohort_digest} = Evidence.cohort_digest(@cohort)

    basis = %{
      profile: "lifx-direct-power-v1",
      thing_id: thing.id,
      profile_ref: thing.profile_ref,
      qualification_ref: review.qualification_ref,
      identity_digest: review.identity_digest,
      product: {1, 27},
      firmware: {2, 80},
      registry_digest: ProductRegistry.pinned_digest(),
      declaration_digest: digest(document),
      runtime_digest: runtime_digest,
      scope: :profile_mapping_only,
      status: :pending_physical_qualification
    }

    basis = Map.put(basis, :basis_digest, digest(basis))

    attestations =
      Enum.map(cases, fn case_definition ->
        receipt =
          Map.merge(case_definition, %{
            "receipt_id" => "receipt:#{case_definition["case_id"]}",
            "status" => "passed",
            "cohort" => @cohort,
            "source_identity_ref" => @cohort["source_identity_ref"],
            "command_sequence" => ["step:request", "step:report"],
            "assertions" => [%{"id" => "matches", "expected" => true, "actual" => true}],
            "artifact_digests" => [String.duplicate("d", 64)],
            "exclusions" => [],
            "blockers" => [],
            "reviewer_ref" => case_id
          })

        assert {:ok, payload} = Attestation.signing_payload(case_id, programme_digest, receipt)

        %{
          "receipt" => receipt,
          "reviewer_key_id" => case_id,
          "programme_digest" => programme_digest,
          "signature" =>
            :crypto.sign(:eddsa, :none, payload, [case_private, :ed25519])
            |> Base.url_encode64(padding: false)
        }
      end)

    decision = %{
      "schema" => "wotex-home.lifx-power-decision.v1",
      "scope" => "lifx_direct_power_v1",
      "outcome" => "allow_direct_power",
      "thing_id" => thing.id,
      "profile_ref" => thing.profile_ref,
      "resource_revision" => resource_revision,
      "identity_digest" => basis.identity_digest,
      "basis_digest" => basis.basis_digest,
      "registry_digest" => basis.registry_digest,
      "runtime_digest" => basis.runtime_digest,
      "programme_digest" => programme_digest,
      "cohort_digest" => cohort_digest,
      "evidence_set_digest" => Decision.evidence_set_digest(attestations),
      "reviewer_key_id" => decision_id
    }

    assert {:ok, payload} = Decision.signing_payload(decision)

    signed = %{
      "decision" => decision,
      "signature" =>
        :crypto.sign(:eddsa, :none, payload, [decision_private, :ed25519])
        |> Base.url_encode64(padding: false)
    }

    {signed, basis, attestations}
  end

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp rows(db, sql) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      {:ok, result} = Sqlite3.fetch_all(db, statement)
      result
    after
      :ok = Sqlite3.release(db, statement)
    end
  end
end
