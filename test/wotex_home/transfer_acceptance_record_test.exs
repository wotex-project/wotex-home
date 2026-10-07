defmodule WotexHome.TransferAcceptanceRecordTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.Artifact

  alias WotexHome.Recovery.{
    DomainCodec,
    IsolationDecision,
    TransferAcceptanceCodec,
    TransferAcceptanceRecord,
    TransferReviewCodec
  }

  setup do
    transport = [
      "lifx-direct-power-v1",
      "udp",
      "no_authenticated_radio_state",
      "profile:fixture",
      "lifx:d073d5000001",
      "vendor:fixture",
      "model:fixture",
      "1.22",
      "compiled",
      digest("c")
    ]

    identity = [
      4,
      "light:fixture",
      "lifx:d073d5000001",
      digest("d"),
      2,
      "candidate:fixture",
      "review:fixture",
      "legacy_tofu",
      "qualification:fixture",
      "operator:source",
      "profile:fixture",
      "vendor:fixture",
      "model:fixture",
      "1.22"
    ]

    binding = Enum.map([1, 2, 3, 5, 6, 7, 8, 9, 10, 0, 4], &Enum.at(identity, &1))
    caps = [["power", ["read", "write"], "ordinary", "boolean", "none"]]

    record = [
      "light:fixture",
      "active",
      "profile:fixture",
      0,
      digest("e"),
      caps,
      binding,
      [[identity, transport]],
      [],
      transport
    ]

    domain = ["wotex-home.controller-domains.v2", digest("f"), [4, 3, 0, 1, 1, 0, 0], [record]]
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

    review = %{
      "deployment_id" => digest("1"),
      "source_owner_id" => digest("2"),
      "destination_owner_id" => digest("3"),
      "source_epoch" => 1,
      "retirement_revision" => 19,
      "source_maintenance_revision" => 10,
      "source_rule_generation" => 2,
      "archive_digest" => digest("4"),
      "snapshot_digest" => digest("5"),
      "runtime_digest" => digest("6"),
      "owner_custody_digest" => digest("7"),
      "challenge_id" => "challenge:fixture",
      "principal_id" => "operator:fresh",
      "credential_hash" => digest("8"),
      "permissions_document" =>
        "[\"read\",\"host:maintain\",\"profile:manage\",\"enroll:review\"]",
      "domain_digest" => Artifact.digest(JSON.encode!(domain)),
      "domain_count" => 1,
      "counter_state" => "no_radio_state",
      "counter_state_digest" => nil,
      "issued_at_utc_ms" => 1_000,
      "expires_at_utc_ms" => 61_000
    }

    %{
      domain: domain,
      review: review,
      policy: policy,
      policy_document: policy_document,
      private: private
    }
  end

  test "canonical complete v2 domains audit exact original accepted history after expiry", c do
    document = JSON.encode!(c.domain)
    assert {:ok, decoded} = DomainCodec.decode(document)
    assert decoded.domain_count == 1 and decoded.counter_state == "no_radio_state"
    assert decoded.source_counts.principal_rows == 4
    assert {:ok, ^decoded} = DomainCodec.acceptance_basis(document, "qualified_network_isolation")
    row = row(c)
    assert {:ok, accepted} = TransferAcceptanceRecord.audit(row)
    assert accepted.receipt["revision"] == 22
    assert accepted.review["credential_hash"] == digest("8")

    assert {:error, :isolation_decision_expired} =
             IsolationDecision.verify(
               Enum.at(row, 6),
               accepted.isolation.decision
               |> Map.take(Map.keys(elem(TransferReviewCodec.isolation_scope(c.review), 1))),
               %{"issuer:fixture" => c.policy},
               %{confidence: :trusted, now_utc_ms: 61_000}
             )
  end

  test "v1 and incomplete domains remain inert and cannot acquire v2 source counts", c do
    [_, logical, _, records] = c.domain

    assert {:ok, %{version: 1, source_counts: nil}} =
             DomainCodec.decode(
               JSON.encode!(["wotex-home.controller-domains.v1", logical, records])
             )

    for domain <- [
          ["wotex-home.controller-domains.v1", logical, records],
          List.replace_at(c.domain, 3, []),
          c.domain
          |> update_record(6, fn _ -> nil end)
          |> update_record(9, fn _ -> ["unknown"] end),
          update_record(c.domain, 9, fn _ -> ["unknown"] end),
          [
            "wotex-home.controller-domains.v2",
            logical,
            [4, 3, 0, 1, 1, 0, 0],
            [["sensor:unknown", "unresolved", nil, nil, nil, [], nil, [], [], ["unknown"]]]
          ]
        ] do
      assert {:ok, _} = DomainCodec.decode(JSON.encode!(domain))

      assert {:error, :transfer_domain_isolation_unavailable} =
               DomainCodec.acceptance_basis(JSON.encode!(domain), "physical_disconnection")
    end

    assert {:error, :transfer_domain_isolation_unavailable} =
             DomainCodec.acceptance_basis(JSON.encode!(c.domain), "device_credential_revocation")
  end

  test "domain decoding rejects bounded shape, canonical, sorting and binding substitutions", c do
    for domain <- [
          c.domain ++ [nil],
          List.replace_at(c.domain, 1, digest("F")),
          List.replace_at(c.domain, 2, [4, 5, 0, 1, 1, 0, 0]),
          List.replace_at(c.domain, 2, [4.0, 3, 0, 1, 1, 0, 0]),
          List.replace_at(c.domain, 3, List.duplicate(hd(List.last(c.domain)), 65)),
          update_record(c.domain, 3, fn _ -> 0.0 end),
          update_record(c.domain, 5, fn _ ->
            [["power", ["write", "read"], "ordinary", "boolean", "none"]]
          end),
          update_record(c.domain, 6, &List.replace_at(&1, 9, 3)),
          update_record(c.domain, 7, &List.duplicate(hd(&1), 33)),
          update_record(c.domain, 7, fn [[identity, basis]] ->
            [[List.replace_at(identity, 4, 1), basis]]
          end),
          update_record(c.domain, 9, &List.replace_at(&1, 4, "lifx:000000000000")),
          update_record(c.domain, 9, &List.replace_at(&1, 7, "1.23")),
          update_record(c.domain, 9, &(&1 ++ [nil])),
          update_record(c.domain, 8, fn _ ->
            [
              [
                8,
                1,
                "selected",
                digest("a"),
                digest("b"),
                1,
                4,
                digest("c"),
                digest("d"),
                [["power", ["read"], "ordinary", "boolean", "none"]],
                List.last(hd(List.last(c.domain)))
              ]
            ]
          end)
        ] do
      assert {:error, :invalid_transfer_domains} = DomainCodec.decode(JSON.encode!(domain))
    end

    for bytes <- [
          " " <> JSON.encode!(c.domain),
          "null",
          JSON.encode!(c.domain) <> "\n",
          String.duplicate("x", 4_194_305),
          nil
        ] do
      assert {:error, :invalid_transfer_domains} = DomainCodec.decode(bytes)
    end
  end

  test "resolved portable selections bind exact historical identity and projection", c do
    basis =
      List.last(hd(List.last(c.domain)))
      |> List.replace_at(8, "portable")
      |> List.replace_at(9, digest("b"))

    selection = [
      8,
      1,
      "selected",
      digest("a"),
      digest("b"),
      1,
      4,
      digest("c"),
      digest("d"),
      [["power", ["read"], "ordinary", "boolean", "none"]],
      basis
    ]

    domain = update_record(c.domain, 8, fn _ -> [selection] end)
    assert {:ok, %{counter_state: "no_radio_state"}} = DomainCodec.decode(JSON.encode!(domain))

    for changed <- [
          List.replace_at(selection, 6, 3),
          List.replace_at(selection, 4, digest("c")),
          List.replace_at(selection, 0, 4),
          List.replace_at(selection, 1, 1.0)
        ] do
      assert {:error, :invalid_transfer_domains} =
               DomainCodec.decode(JSON.encode!(update_record(domain, 8, fn _ -> [changed] end)))
    end
  end

  test "retained audit refuses every changed row commitment and owning identity", c do
    original = row(c)

    for {index, replacement} <- [{0, "operator:other"}, {1, 2}, {2, "accept:other"}, {10, 23}] do
      assert {:error, :corrupt_controller_acceptance} =
               TransferAcceptanceRecord.audit(List.replace_at(original, index, replacement))
    end

    for index <- 3..9 do
      assert {:error, :corrupt_controller_acceptance} =
               TransferAcceptanceRecord.audit(List.update_at(original, index, &(&1 <> " ")))
    end

    assert {:error, :corrupt_controller_acceptance} =
             TransferAcceptanceRecord.audit(original ++ [nil])

    assert {:error, :corrupt_controller_acceptance} = TransferAcceptanceRecord.audit(nil)
  end

  test "a correctly signed narrowed domain or invalid withdrawal count cannot pass historical audit",
       c do
    for {review, domain, receipt} <- [
          {%{c.review | "domain_count" => 0}, c.domain, %{"domain_count" => 0}},
          {c.review, c.domain, %{"cleared_observations" => 2}},
          {c.review, c.domain, %{"source_maintenance_revision" => 9}},
          {c.review, c.domain, %{"review_digest" => digest("9")}}
        ] do
      assert {:error, :corrupt_controller_acceptance} =
               TransferAcceptanceRecord.audit(row(%{c | review: review, domain: domain}, receipt))
    end
  end

  test "historical policy cannot permit credential revocation on unauthenticated LIFX", c do
    policy = %{c.policy | method: "device_credential_revocation"}
    {:ok, document} = TransferAcceptanceCodec.policy_document("issuer:fixture", policy)

    assert {:error, :corrupt_controller_acceptance} =
             TransferAcceptanceRecord.audit(row(%{c | policy: policy, policy_document: document}))
  end

  test "a valid signed decision must retain the original review time window", c do
    for times <- [%{"issued_at_utc_ms" => 999}, %{"expires_at_utc_ms" => 61_001}] do
      assert {:error, :corrupt_controller_acceptance} =
               TransferAcceptanceRecord.audit(row(c, %{}, times))
    end
  end

  defp row(c, receipt_changes \\ %{}, decision_changes \\ %{}) do
    domain_document = JSON.encode!(c.domain)
    review = %{c.review | "domain_digest" => Artifact.digest(domain_document)}
    {:ok, review_document} = TransferReviewCodec.encode(review)
    {:ok, scope} = TransferReviewCodec.isolation_scope(review)

    decision =
      Map.merge(scope, %{
        "format" => "wotex-home.controller-isolation.v1",
        "method" => c.policy.method,
        "procedure_ref" => c.policy.procedure_ref,
        "issuer_id" => "issuer:fixture",
        "issuer_generation" => c.policy.generation,
        "isolation_policy_digest" => c.policy.policy_digest,
        "issued_at_utc_ms" => 1_000,
        "expires_at_utc_ms" => 61_000
      })
      |> Map.merge(decision_changes)

    {:ok, payload} = IsolationDecision.signing_payload(decision)

    {:ok, package} =
      IsolationDecision.encode(
        decision,
        :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519])
      )

    {:ok, parsed} = IsolationDecision.decode(package)

    input = %{
      "principal_id" => review["principal_id"],
      "source_epoch" => review["source_epoch"],
      "operation_id" => "accept:original",
      "retirement_revision" => review["retirement_revision"],
      "destination_owner_id" => review["destination_owner_id"],
      "review_digest" => scope["review_digest"],
      "isolation_package_digest" => parsed.package_digest
    }

    receipt =
      Map.merge(
        review
        |> Map.take(
          ~w(principal_id source_epoch retirement_revision source_maintenance_revision source_rule_generation deployment_id source_owner_id destination_owner_id domain_digest domain_count counter_state counter_state_digest)
        ),
        input
      )
      |> Map.merge(%{
        "authority_epoch" => 2,
        "rule_generation" => 3,
        "fence_revision" => 20,
        "principal_revision" => 21,
        "revision" => 22,
        "isolation_decision_digest" => parsed.decision_digest,
        "revoked_principals" => 3,
        "revoked_qualifications" => 0,
        "cleared_observations" => 1,
        "cleared_target_grants" => 1,
        "cleared_source_grants" => 0,
        "cleared_override_leases" => 0
      })
      |> Map.merge(receipt_changes)

    {:ok, input_document} = TransferAcceptanceCodec.encode("operation", input)
    {:ok, receipt_document} = TransferAcceptanceCodec.encode("acceptance", receipt)

    [
      review["principal_id"],
      1,
      "accept:original",
      input_document,
      receipt_document,
      review_document,
      package,
      parsed.document,
      c.policy_document,
      domain_document,
      22
    ]
  end

  defp update_record(domain, index, fun),
    do: List.update_at(domain, 3, fn [record] -> [List.update_at(record, index, fun)] end)

  defp digest(value), do: String.duplicate(value, 64)
end
