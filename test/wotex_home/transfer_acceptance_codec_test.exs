defmodule WotexHome.TransferAcceptanceCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.Recovery.{IsolationDecision, TransferAcceptanceCodec}
  @maximum 9_223_372_036_854_775_807
  @operation ~w(principal_id source_epoch operation_id retirement_revision destination_owner_id review_digest isolation_package_digest)
  @receipt ~w(principal_id source_epoch authority_epoch operation_id retirement_revision source_maintenance_revision source_rule_generation rule_generation fence_revision principal_revision revision deployment_id source_owner_id destination_owner_id review_digest isolation_package_digest isolation_decision_digest domain_digest domain_count counter_state counter_state_digest revoked_principals revoked_qualifications cleared_observations cleared_target_grants cleared_source_grants cleared_override_leases)
  @policy ~w(issuer_id public_key generation method procedure_ref policy_digest counter_state)

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      public_key: public,
      generation: 1,
      method: "physical_disconnection",
      procedure_ref: "procedure:fixture",
      policy_digest: digest("a"),
      counter_state: "no_radio_state"
    }

    {:ok, policy_document} = TransferAcceptanceCodec.policy_document("issuer:fixture", policy)
    {:ok, policy_value} = TransferAcceptanceCodec.decode("policy", policy_document)

    scope = %{
      "deployment_id" => digest("1"),
      "source_owner_id" => digest("2"),
      "destination_owner_id" => digest("3"),
      "source_epoch" => 1,
      "retirement_revision" => 19,
      "archive_digest" => digest("4"),
      "review_digest" => digest("5"),
      "runtime_digest" => digest("6"),
      "challenge_id" => "challenge:fixture",
      "domain_digest" => digest("7"),
      "domain_count" => 1,
      "counter_state" => "no_radio_state",
      "counter_state_digest" => nil
    }

    decision =
      Map.merge(scope, %{
        "format" => "wotex-home.controller-isolation.v1",
        "method" => policy.method,
        "procedure_ref" => policy.procedure_ref,
        "issuer_id" => "issuer:fixture",
        "issuer_generation" => policy.generation,
        "isolation_policy_digest" => policy.policy_digest,
        "issued_at_utc_ms" => 1_000,
        "expires_at_utc_ms" => 61_000
      })

    {:ok, payload} = IsolationDecision.signing_payload(decision)

    {:ok, package} =
      IsolationDecision.encode(
        decision,
        :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      )

    {:ok, parsed} = IsolationDecision.decode(package)

    operation = %{
      "principal_id" => "operator:fresh",
      "source_epoch" => 1,
      "operation_id" => "accept:original",
      "retirement_revision" => 19,
      "destination_owner_id" => scope["destination_owner_id"],
      "review_digest" => scope["review_digest"],
      "isolation_package_digest" => parsed.package_digest
    }

    receipt =
      Map.merge(operation, %{
        "authority_epoch" => 2,
        "source_maintenance_revision" => 10,
        "source_rule_generation" => 2,
        "rule_generation" => 3,
        "fence_revision" => 20,
        "principal_revision" => 21,
        "revision" => 22,
        "deployment_id" => scope["deployment_id"],
        "source_owner_id" => scope["source_owner_id"],
        "isolation_decision_digest" => parsed.decision_digest,
        "domain_digest" => scope["domain_digest"],
        "domain_count" => 1,
        "counter_state" => "no_radio_state",
        "counter_state_digest" => nil,
        "revoked_principals" => 3,
        "revoked_qualifications" => 0,
        "cleared_observations" => 1,
        "cleared_target_grants" => 1,
        "cleared_source_grants" => 0,
        "cleared_override_leases" => 0
      })

    %{
      policy: policy,
      policy_value: policy_value,
      policy_document: policy_document,
      operation: operation,
      receipt: receipt,
      scope: scope,
      decision: decision,
      package: package,
      parsed: parsed
    }
  end

  test "all three closed encodings preserve exact authored order and bytes", c do
    for {kind, format, fields, value} <- [
          {"operation", "wotex-home.controller-acceptance-operation.v1", @operation, c.operation},
          {"acceptance", "wotex-home.controller-acceptance.v1", @receipt, c.receipt},
          {"policy", "wotex-home.controller-isolation-policy-record.v1", @policy, c.policy_value}
        ] do
      assert {:ok, document} = TransferAcceptanceCodec.encode(kind, value)
      assert document == JSON.encode!([format, Enum.map(fields, &value[&1])])
      assert {:ok, ^value} = TransferAcceptanceCodec.decode(kind, document)

      for bytes <- [document <> "\n", " " <> document, :binary.copy(" ", 4_097), "[]", nil] do
        assert {:error, :invalid_transfer_acceptance} =
                 TransferAcceptanceCodec.decode(kind, bytes)
      end

      for field <- fields do
        assert {:error, :invalid_transfer_acceptance} =
                 TransferAcceptanceCodec.encode(kind, Map.delete(value, field))
      end

      for other <- ["operation", "acceptance", "policy"] -- [kind] do
        assert {:error, :invalid_transfer_acceptance} =
                 TransferAcceptanceCodec.decode(other, document)
      end
    end
  end

  test "epoch, generation and exactly three revisions require bounded integers", c do
    for field <- ~w(authority_epoch rule_generation fence_revision principal_revision revision) do
      for value <- [c.receipt[field] - 1, c.receipt[field] + 1, c.receipt[field] / 1, nil] do
        assert {:error, :invalid_transfer_acceptance} =
                 TransferAcceptanceCodec.encode("acceptance", Map.put(c.receipt, field, value))
      end
    end

    for {field, value} <- [
          {"source_epoch", @maximum},
          {"retirement_revision", @maximum - 2},
          {"source_rule_generation", @maximum},
          {"source_maintenance_revision", 0},
          {"source_maintenance_revision", 19}
        ] do
      assert {:error, :invalid_transfer_acceptance} =
               TransferAcceptanceCodec.encode("acceptance", Map.put(c.receipt, field, value))
    end

    final = %{
      c.receipt
      | "retirement_revision" => @maximum - 3,
        "fence_revision" => @maximum - 2,
        "principal_revision" => @maximum - 1,
        "revision" => @maximum
    }

    assert {:ok, _} = TransferAcceptanceCodec.encode("acceptance", final)
  end

  test "receiving original identity and exact commitments cannot widen recovery input", c do
    for {field, value} <- [
          {"principal_id", "../operator"},
          {"operation_id", ""},
          {"source_epoch", 0},
          {"source_epoch", 1.0},
          {"retirement_revision", 1},
          {"review_digest", digest("A")},
          {"isolation_package_digest", nil}
        ] do
      assert {:error, :invalid_transfer_acceptance} =
               TransferAcceptanceCodec.encode("operation", Map.put(c.operation, field, value))
    end

    for field <- ["target_ids", "credential", "isolated", "clock", "public_key", "permissions"] do
      assert {:error, :invalid_transfer_acceptance} =
               TransferAcceptanceCodec.encode("operation", Map.put(c.operation, field, true))
    end

    assert {:error, :invalid_transfer_acceptance} =
             TransferAcceptanceCodec.encode("acceptance", %{
               c.receipt
               | "source_owner_id" => c.receipt["destination_owner_id"]
             })
  end

  test "accepted counters and actual finite change counts are closed", c do
    for {field, maximum} <- [
          {"revoked_principals", 63},
          {"revoked_qualifications", 64},
          {"cleared_observations", 131_072},
          {"cleared_target_grants", 131_072},
          {"cleared_source_grants", 131_072},
          {"cleared_override_leases", 64},
          {"domain_count", 64}
        ] do
      for value <- [-1, maximum + 1, 0.0] do
        assert {:error, :invalid_transfer_acceptance} =
                 TransferAcceptanceCodec.encode("acceptance", Map.put(c.receipt, field, value))
      end

      assert {:ok, _} =
               TransferAcceptanceCodec.encode("acceptance", Map.put(c.receipt, field, maximum))
    end

    for {state, counter_digest} <- [
          {"unknown", nil},
          {"no_radio_state", digest("a")},
          {"verified_continuity", nil}
        ] do
      assert {:error, :invalid_transfer_acceptance} =
               TransferAcceptanceCodec.encode("acceptance", %{
                 c.receipt
                 | "counter_state" => state,
                   "counter_state_digest" => counter_digest
               })
    end

    assert {:ok, _} =
             TransferAcceptanceCodec.encode("acceptance", %{
               c.receipt
               | "counter_state" => "verified_continuity",
                 "counter_state_digest" => digest("a")
             })
  end

  test "historical policy retains exact public inputs without adding current issuer trust", c do
    assert {:ok, "issuer:fixture", c.policy} ==
             TransferAcceptanceCodec.historical_issuer(c.policy_document)

    for {field, value} <- [
          {"public_key", c.policy_value["public_key"] <> "="},
          {"public_key", "bad"},
          {"generation", 0},
          {"method", "process_stopped"},
          {"policy_digest", digest("A")},
          {"counter_state", "unknown"}
        ] do
      assert {:error, :invalid_transfer_acceptance} =
               TransferAcceptanceCodec.encode("policy", Map.put(c.policy_value, field, value))
    end

    for value <- [nil, Map.put(c.policy, :clock, :trusted), %{c.policy | public_key: <<0>>}] do
      assert {:error, :invalid_transfer_acceptance} =
               TransferAcceptanceCodec.policy_document("issuer:fixture", value)
    end
  end

  test "past audit remains valid while current expiry, clock and trust gates still refuse acceptance",
       c do
    assert {:ok, c.parsed} == IsolationDecision.audit(c.package, c.scope, c.policy_document)
    issuers = %{"issuer:fixture" => c.policy}

    assert {:error, :isolation_decision_expired} =
             IsolationDecision.verify(c.package, c.scope, issuers, %{
               confidence: :trusted,
               now_utc_ms: 61_000
             })

    assert {:error, :isolation_clock_unavailable} =
             IsolationDecision.verify(c.package, c.scope, issuers, %{
               confidence: :unknown,
               now_utc_ms: 1_500
             })

    assert {:error, :isolation_trust_unavailable} =
             IsolationDecision.verify(c.package, c.scope, %{}, %{
               confidence: :trusted,
               now_utc_ms: 1_500
             })

    assert {:ok, c.parsed} == IsolationDecision.audit(c.package, c.scope, c.policy_document)

    assert {:error, :invalid_transfer_acceptance} =
             IsolationDecision.audit(c.package, c.scope, nil)
  end

  test "historical audit rejects every substituted policy commitment, scope and signature", c do
    for {field, value} <- [
          {"issuer_id", "issuer:other"},
          {"generation", 2},
          {"method", "qualified_network_isolation"},
          {"procedure_ref", "procedure:other"},
          {"policy_digest", digest("b")},
          {"counter_state", "verified_continuity"}
        ] do
      {:ok, document} =
        TransferAcceptanceCodec.encode("policy", Map.put(c.policy_value, field, value))

      assert {:error, :isolation_trust_unavailable} =
               IsolationDecision.audit(c.package, c.scope, document)
    end

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, changed_key} =
      TransferAcceptanceCodec.policy_document("issuer:fixture", %{c.policy | public_key: public})

    assert {:error, :invalid_isolation_decision} =
             IsolationDecision.audit(c.package, c.scope, changed_key)

    {:ok, forged} = IsolationDecision.encode(c.decision, :binary.copy(<<0>>, 64))

    assert {:error, :invalid_isolation_decision} =
             IsolationDecision.audit(forged, c.scope, c.policy_document)

    assert {:error, :isolation_scope_changed} =
             IsolationDecision.audit(
               c.package,
               %{c.scope | "runtime_digest" => digest("b")},
               c.policy_document
             )
  end

  test "canonical signature history does not collapse exact private operation package identity",
       c do
    assert {:ok, altered} = IsolationDecision.audit(" " <> c.package, c.scope, c.policy_document)
    assert altered.decision_digest == c.parsed.decision_digest
    refute altered.package_digest == c.parsed.package_digest
    assert {:ok, original} = TransferAcceptanceCodec.encode("operation", c.operation)

    assert {:ok, other} =
             TransferAcceptanceCodec.encode("operation", %{
               c.operation
               | "isolation_package_digest" => altered.package_digest
             })

    refute original == other
  end

  test "every receipt withdrawal count equals its original signed source commitment", c do
    counts = %{
      principal_rows: 4,
      active_principal_rows: 3,
      qualified_profile_heads: 0,
      current_observation_rows: 1,
      target_grant_rows: 1,
      source_grant_rows: 0,
      override_lease_rows: 0
    }

    assert :ok = TransferAcceptanceCodec.match_source_counts(c.receipt, counts)

    for field <-
          ~w(revoked_principals revoked_qualifications cleared_observations cleared_target_grants cleared_source_grants cleared_override_leases) do
      assert {:error, :transfer_source_counts_changed} =
               TransferAcceptanceCodec.match_source_counts(
                 Map.update!(c.receipt, field, &(&1 + 1)),
                 counts
               )
    end

    for altered <- [
          %{counts | principal_rows: 64},
          %{counts | principal_rows: 2},
          %{counts | active_principal_rows: 3.0},
          %{counts | current_observation_rows: 2},
          Map.put(counts, :caller_grants, 0),
          Map.delete(counts, :override_lease_rows),
          nil
        ] do
      assert {:error, :transfer_source_counts_changed} =
               TransferAcceptanceCodec.match_source_counts(c.receipt, altered)
    end
  end

  defp digest(value), do: String.duplicate(value, 64)
end
