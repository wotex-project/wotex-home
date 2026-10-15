defmodule WotexHome.TestSupport.LifxQualificationFixture do
  @moduledoc false

  # Synthetic software evidence shared by execution and historical-runtime
  # tests. These data and test keys do not qualify hardware or enable dispatch.
  import ExUnit.Assertions
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.{ProductRegistry, ProfileBasis}
  alias WotexHome.Qualification.{Attestation, Claims, Decision, Evidence, Programme}

  @candidate %{
    "interface_id" => "en0",
    "transport" => "udp",
    "source_endpoint" => "192.0.2.10:56700",
    "receive_epoch" => "scan:1",
    "received_monotonic_ms" => 100,
    "raw_ref" => "capture:1",
    "claimed_identifiers" => %{
      "manufacturer" => "LIFX",
      "model" => "old-eu",
      "stable_id" => "lifx:d073d5000001"
    },
    "trust_class" => "untrusted_network"
  }

  @interview %{
    "candidate_ref" => "capture:1",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware" => "2.0",
    "stable_id" => "lifx:d073d5000001"
  }

  @profile %{
    "id" => "lifx.old-eu",
    "version" => "1.0.0",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware_versions" => ["2.0"],
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
    "stable_id" => "lifx:d073d5000001",
    "profile_ref" => "lifx.old-eu:1.0.0",
    "qualification_ref" => "cohort:old-eu:1",
    "method" => "legacy_tofu",
    "review_ref" => "review:1"
  }

  @qualification_cohort %{
    "source_identity_ref" => String.duplicate("a", 64),
    "hardware_sku" => "lifx.old-eu",
    "hardware_revision" => "rev.1",
    "firmware" => "2.0",
    "adapter_profile" => "lifx.old-eu:1.0.0",
    "native_stack" => "wotex-udp:test",
    "host_os" => "macos:test",
    "runtime" => "otp:test",
    "network_topology" => "isolated-lan:1",
    "application" => "home:test",
    "model" => "none"
  }

  def data,
    do: %{
      candidate: @candidate,
      interview: @interview,
      profile: @profile,
      power: @power,
      selection: @selection,
      qualification_cohort: @qualification_cohort
    }

  def install(path, revision, thing) do
    {case_public, case_private} =
      :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<1>>, 32))

    {decision_public, decision_private} =
      :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<2>>, 32))

    case_key_id = "fixture:case-reviewer"
    decision_key_id = "fixture:physical-reviewer"
    assert {:ok, runtime_digest} = ProfileBasis.runtime_digest()
    assert {:ok, document} = Registry.encode_thing(thing)
    assert {:ok, cases, programme_digest} = Programme.lifx_power_cases()
    assert {:ok, cohort_digest} = Evidence.cohort_digest(@qualification_cohort)
    assert {:ok, db} = Sqlite3.open(path)
    assert [[identity_digest]] = rows(db, "SELECT identity_digest FROM enrollment_bindings")

    basis = %{
      profile: "lifx-direct-power-v1",
      thing_id: thing.id,
      profile_ref: thing.profile_ref,
      qualification_ref: @selection["qualification_ref"],
      identity_digest: identity_digest,
      product: {1, 27},
      firmware: {2, 0},
      registry_digest: ProductRegistry.pinned_digest(),
      declaration_digest: test_digest(document),
      runtime_digest: runtime_digest,
      scope: :profile_mapping_only,
      status: :pending_physical_qualification
    }

    basis = Map.put(basis, :basis_digest, test_digest(basis))
    assert ProfileBasis.valid?(basis)

    attestations =
      Enum.map(cases, fn case_definition ->
        receipt =
          Map.merge(case_definition, %{
            "receipt_id" => "receipt:#{case_definition["case_id"]}",
            "status" => "passed",
            "cohort" => @qualification_cohort,
            "source_identity_ref" => @qualification_cohort["source_identity_ref"],
            "command_sequence" => ["fixture:request", "fixture:report"],
            "assertions" => [%{"id" => "matches", "expected" => true, "actual" => true}],
            "artifact_digests" => [String.duplicate("d", 64)],
            "exclusions" => [],
            "blockers" => [],
            "reviewer_ref" => case_key_id
          })

        assert {:ok, payload} =
                 Attestation.signing_payload(case_key_id, programme_digest, receipt)

        %{
          "receipt" => receipt,
          "reviewer_key_id" => case_key_id,
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
      "resource_revision" => 0,
      "identity_digest" => identity_digest,
      "basis_digest" => basis.basis_digest,
      "registry_digest" => basis.registry_digest,
      "runtime_digest" => runtime_digest,
      "programme_digest" => programme_digest,
      "cohort_digest" => cohort_digest,
      "evidence_set_digest" => Decision.evidence_set_digest(attestations),
      "reviewer_key_id" => decision_key_id
    }

    assert {:ok, payload} = Decision.signing_payload(decision)

    signed = %{
      "decision" => decision,
      "signature" =>
        :crypto.sign(:eddsa, :none, payload, [decision_private, :ed25519])
        |> Base.url_encode64(padding: false)
    }

    case_keys = %{case_key_id => case_public}
    decision_keys = %{decision_key_id => decision_public}

    assert {:ok, verified} =
             Decision.verify(
               signed,
               basis,
               @qualification_cohort,
               attestations,
               case_keys,
               decision_keys
             )

    assert :ok =
             Claims.put(Path.join(Path.dirname(path), "qualification_claims"), verified)

    assert :ok =
             Sqlite3.execute(
               db,
               "INSERT INTO authority_journal VALUES (#{revision}, 'profile_qualified', 'light:desk')"
             )

    assert {:ok, statement} =
             Sqlite3.prepare(
               db,
               "INSERT INTO profile_qualifications VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'qualified', ?)"
             )

    assert :ok =
             Sqlite3.bind(statement, [
               "light:desk",
               "lifx.old-eu:1.0.0",
               0,
               identity_digest,
               basis.basis_digest,
               ProductRegistry.pinned_digest(),
               runtime_digest,
               verified.evidence_ref,
               revision
             ])

    assert {:ok, []} = Sqlite3.fetch_all(db, statement)
    assert :ok = Sqlite3.release(db, statement)

    assert :ok =
             Sqlite3.execute(
               db,
               "INSERT INTO profile_qualification_history (thing_id,profile_ref,resource_revision,identity_digest,basis_digest,registry_digest,runtime_digest,evidence_ref,revision,provenance,declaration_document,principal_id,authority_epoch,binding_revision) SELECT q.thing_id,q.profile_ref,q.resource_revision,q.identity_digest,q.basis_digest,q.registry_digest,q.runtime_digest,q.evidence_ref,q.revision,'guarded_current',t.document,b.operator_id,(SELECT value FROM meta WHERE key='authority_epoch'),b.revision FROM profile_qualifications q JOIN enrolled_things t ON t.thing_id=q.thing_id JOIN enrollment_bindings b ON b.thing_id=q.thing_id"
             )

    assert :ok = Sqlite3.execute(db, "UPDATE meta SET value = #{revision} WHERE key = 'revision'")
    :ok = Sqlite3.close(db)
    [qualification_case_keys: case_keys, qualification_decision_keys: decision_keys]
  end

  defp test_digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp rows(db, sql, values \\ []) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, values)
      {:ok, result} = Sqlite3.fetch_all(db, statement)
      result
    after
      :ok = Sqlite3.release(db, statement)
    end
  end
end
