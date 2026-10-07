defmodule WotexHome.IsolationDecisionTest do
  use ExUnit.Case, async: true
  alias WotexHome.Recovery.IsolationDecision

  @scope ~w(deployment_id source_owner_id destination_owner_id source_epoch retirement_revision archive_digest review_digest runtime_digest challenge_id domain_digest domain_count counter_state counter_state_digest)
  @fields ~w(format deployment_id source_owner_id destination_owner_id source_epoch retirement_revision archive_digest review_digest runtime_digest challenge_id domain_digest domain_count counter_state counter_state_digest method procedure_ref issuer_id issuer_generation isolation_policy_digest issued_at_utc_ms expires_at_utc_ms)

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<7>>, 32))

    decision = %{
      "format" => "wotex-home.controller-isolation.v1",
      "deployment_id" => digest("1"),
      "source_owner_id" => digest("2"),
      "destination_owner_id" => digest("3"),
      "source_epoch" => 4,
      "retirement_revision" => 19,
      "archive_digest" => digest("4"),
      "review_digest" => digest("5"),
      "runtime_digest" => digest("6"),
      "challenge_id" => "transfer:one-use",
      "domain_digest" => digest("7"),
      "domain_count" => 2,
      "counter_state" => "no_radio_state",
      "counter_state_digest" => nil,
      "method" => "physical_disconnection",
      "procedure_ref" => "isolation:qualified-fixture",
      "issuer_id" => "issuer:fixture",
      "issuer_generation" => 8,
      "isolation_policy_digest" => digest("8"),
      "issued_at_utc_ms" => 1_000,
      "expires_at_utc_ms" => 601_000
    }

    policy = %{
      public_key: public,
      generation: 8,
      method: decision["method"],
      procedure_ref: decision["procedure_ref"],
      policy_digest: decision["isolation_policy_digest"],
      counter_state: decision["counter_state"]
    }

    %{decision: decision, private: private, policy: policy}
  end

  test "ordered signed payload and record bind distinct exact package bytes", c do
    values = Enum.map(@fields, &c.decision[&1])
    assert {:ok, payload} = IsolationDecision.signing_payload(c.decision)
    assert payload == "WOH15-controller-isolation-v1\0" <> JSON.encode!(values)
    bytes = signed(c.decision, c.private)
    assert {:ok, parsed} = verify(bytes, c)
    assert parsed.decision == c.decision
    assert parsed.package_bytes == bytes
    assert parsed.package_digest == sha(bytes)

    assert parsed.document ==
             JSON.encode!([
               "wotex-home.controller-isolation-record.v1",
               values,
               Base.url_encode64(parsed.signature, padding: false)
             ])

    assert parsed.decision_digest == sha(parsed.document)
    assert {:ok, changed} = verify(" " <> bytes <> "\n", c)
    assert changed.document == parsed.document
    assert changed.decision_digest == parsed.decision_digest
    refute changed.package_digest == parsed.package_digest
  end

  test "every reviewed scope field is required and cannot be substituted", c do
    bytes = signed(c.decision, c.private)
    expected = Map.take(c.decision, @scope)

    for field <- @scope do
      assert {:error, :isolation_scope_changed} = verify(bytes, c, Map.delete(expected, field))

      replacement = if is_integer(expected[field]), do: expected[field] + 1, else: "changed"

      assert {:error, :isolation_scope_changed} =
               verify(bytes, c, Map.put(expected, field, replacement))
    end

    assert {:error, :isolation_scope_changed} =
             verify(bytes, c, Map.put(expected, "approved", true))
  end

  test "issuer keys and all policy commitments come from separate explicit trust", c do
    bytes = signed(c.decision, c.private)
    expected = Map.take(c.decision, @scope)
    clock = %{confidence: :trusted, now_utc_ms: 1_000}

    assert {:error, :isolation_trust_unavailable} =
             IsolationDecision.verify(bytes, expected, %{}, clock)

    for {key, value} <- [
          {:generation, 9},
          {:method, "qualified_network_isolation"},
          {:procedure_ref, "isolation:other"},
          {:policy_digest, digest("9")},
          {:counter_state, "verified_continuity"},
          {:public_key, "short"}
        ] do
      assert {:error, :isolation_trust_unavailable} =
               verify(bytes, %{c | policy: Map.put(c.policy, key, value)})

      assert {:error, :isolation_trust_unavailable} =
               verify(bytes, %{c | policy: Map.delete(c.policy, key)})
    end

    assert {:error, :isolation_trust_unavailable} =
             verify(bytes, %{c | policy: Map.put(c.policy, :approved, true)})

    {wrong, _} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:error, :invalid_isolation_decision} =
             verify(bytes, %{c | policy: %{c.policy | public_key: wrong}})

    issuers = Map.new(1..9, &{"issuer:#{&1}", c.policy})

    assert {:error, :invalid_isolation_decision} =
             IsolationDecision.verify(bytes, expected, issuers, clock)
  end

  test "trusted clock has original inclusive issue and exclusive expiry bounds", c do
    bytes = signed(c.decision, c.private)
    expected = Map.take(c.decision, @scope)
    issuers = %{c.decision["issuer_id"] => c.policy}

    for now <- [1_000, 600_999] do
      assert {:ok, _} =
               IsolationDecision.verify(bytes, expected, issuers, %{
                 confidence: :trusted,
                 now_utc_ms: now
               })
    end

    for now <- [999, 601_000, 601_001, -1, "1000"] do
      assert {:error, :isolation_decision_expired} =
               IsolationDecision.verify(bytes, expected, issuers, %{
                 confidence: :trusted,
                 now_utc_ms: now
               })
    end

    for clock <- [
          nil,
          %{},
          %{confidence: :unknown, now_utc_ms: 1_000},
          %{confidence: :trusted, now_utc_ms: 1_000, renewed: true}
        ] do
      assert {:error, :isolation_clock_unavailable} =
               IsolationDecision.verify(bytes, expected, issuers, clock)
    end
  end

  test "only explicit continuity or explicit absence can be signed", c do
    decision =
      Map.merge(c.decision, %{
        "counter_state" => "verified_continuity",
        "counter_state_digest" => digest("a")
      })

    for method <-
          ~w(physical_disconnection qualified_network_isolation device_credential_revocation) do
      decision = Map.put(decision, "method", method)
      policy = %{c.policy | method: method, counter_state: "verified_continuity"}

      assert {:ok, _} =
               verify(signed(decision, c.private), %{c | decision: decision, policy: policy})
    end

    for {state, digest} <- [
          {"unknown", nil},
          {"not_applicable", nil},
          {"no_radio_state", digest("a")},
          {"verified_continuity", nil},
          {"verified_continuity", "invalid"}
        ] do
      decision =
        Map.merge(c.decision, %{"counter_state" => state, "counter_state_digest" => digest})

      assert {:error, :invalid_isolation_decision} = IsolationDecision.signing_payload(decision)
    end
  end

  test "closed shape, finite bounds and distinct owners reject malformed decisions", c do
    for {key, value} <- [
          {"format", "wotex-home.controller-isolation.v2"},
          {"deployment_id", digest("A")},
          {"destination_owner_id", c.decision["source_owner_id"]},
          {"source_epoch", 0},
          {"source_epoch", 9_223_372_036_854_775_807},
          {"retirement_revision", 0},
          {"domain_count", -1},
          {"domain_count", 65},
          {"challenge_id", "../challenge"},
          {"procedure_ref", ""},
          {"issuer_generation", 0},
          {"method", "stopped_process"},
          {"issued_at_utc_ms", -1},
          {"expires_at_utc_ms", 1_000},
          {"expires_at_utc_ms", 601_001}
        ] do
      assert {:error, :invalid_isolation_decision} =
               IsolationDecision.signing_payload(Map.put(c.decision, key, value))
    end

    for field <- @fields do
      assert {:error, :invalid_isolation_decision} =
               IsolationDecision.signing_payload(Map.delete(c.decision, field))
    end

    assert {:error, :invalid_isolation_decision} =
             IsolationDecision.signing_payload(Map.put(c.decision, "isolation_confirmed", true))
  end

  test "strict bounded JSON rejects duplicate names and noncanonical signatures", c do
    bytes = signed(c.decision, c.private)
    package = JSON.decode!(bytes)

    for invalid <- [
          "",
          :binary.copy(" ", 8_193),
          "[]",
          bytes <> "x",
          String.replace(bytes, "\"signature\":", "\"signature\":\"bad\",\"signature\":"),
          String.replace(bytes, "\"format\":", "\"format\":\"bad\",\"format\":"),
          JSON.encode!(Map.put(package, "public_key", "caller-key")),
          JSON.encode!(%{package | "signature" => package["signature"] <> "="}),
          JSON.encode!(%{package | "signature" => " " <> package["signature"]}),
          JSON.encode!(%{
            package
            | "signature" => Base.url_encode64(<<0::size(504)>>, padding: false)
          })
        ] do
      assert {:error, :invalid_isolation_decision} = IsolationDecision.decode(invalid)
    end

    assert {:error, :invalid_isolation_decision} = IsolationDecision.encode(c.decision, <<0>>)
    assert {:error, :invalid_isolation_decision} = IsolationDecision.decode(nil)
  end

  test "signed-field tampering and forged signatures cannot authorize even matching scope", c do
    package = JSON.decode!(signed(c.decision, c.private))
    decision = Map.put(c.decision, "domain_count", 1)
    altered = JSON.encode!(%{package | "decision" => decision})
    assert {:error, :invalid_isolation_decision} = verify(altered, %{c | decision: decision})

    forged =
      JSON.encode!(%{
        package
        | "signature" => Base.url_encode64(:binary.copy(<<0>>, 64), padding: false)
      })

    assert {:error, :invalid_isolation_decision} = verify(forged, c)
  end

  defp signed(decision, private) do
    assert {:ok, payload} = IsolationDecision.signing_payload(decision)
    signature = :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
    assert {:ok, bytes} = IsolationDecision.encode(decision, signature)
    bytes
  end

  defp verify(bytes, c, expected \\ nil) do
    IsolationDecision.verify(
      bytes,
      expected || Map.take(c.decision, @scope),
      %{c.decision["issuer_id"] => c.policy},
      %{confidence: :trusted, now_utc_ms: 1_000}
    )
  end

  defp digest(char), do: String.duplicate(char, 64)
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
