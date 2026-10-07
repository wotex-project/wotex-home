defmodule WotexHome.RecoveryClockCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Recovery.ClockCodec

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      issuer_id: "clock:synthetic",
      public_key: public,
      generation: 1,
      procedure_ref: "procedure:synthetic-utc",
      policy_digest: digest("a"),
      maximum_response_ms: 1_000,
      maximum_age_ms: 60_000,
      maximum_error_ms: 25
    }

    {:ok, policy_document} = ClockCodec.policy_document(policy)

    request = %{
      "destination_owner_id" => digest("b"),
      "runtime_digest" => digest("c"),
      "challenge_id" => "clock-challenge:original",
      "issuer_id" => policy.issuer_id,
      "issuer_generation" => policy.generation,
      "policy_digest" => policy.policy_digest,
      "issuer_policy_digest" => Artifact.digest(policy_document)
    }

    {:ok, request_document} = ClockCodec.request_document(request)

    record =
      Map.merge(request, %{"procedure_ref" => policy.procedure_ref, "observed_utc_ms" => 10_000})

    {:ok, payload} = ClockCodec.signing_payload(record)
    signature = :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
    {:ok, package} = ClockCodec.encode(record, signature)

    %{
      policy: policy,
      policy_document: policy_document,
      request: request,
      request_document: request_document,
      record: record,
      private: private,
      public: public,
      signature: signature,
      package: package,
      payload: payload
    }
  end

  test "closed documents round-trip and signature payload has its exact domain separator", c do
    assert {:ok, policy} = ClockCodec.decode_policy(c.policy_document)
    assert policy == c.policy
    assert {:ok, request} = ClockCodec.decode_request(c.request_document)
    assert request == c.request
    assert {:ok, parsed} = ClockCodec.verify(c.package, c.request_document, c.policy_document)
    assert parsed.record == c.record and parsed.signature == c.signature
    assert parsed.package_digest == Artifact.digest(c.package)
    assert {:ok, record_document} = ClockCodec.record_document(c.record)
    assert c.payload == "wotex-home.controller-clock-record.v1" <> <<0>> <> record_document
    assert :crypto.verify(:eddsa, :none, c.payload, c.signature, [c.public, :ed25519])
    refute Map.has_key?(parsed, :confidence)
  end

  test "every substituted signed scope refuses the original request", c do
    changes = %{
      "destination_owner_id" => digest("d"),
      "runtime_digest" => digest("e"),
      "challenge_id" => "clock-challenge:other",
      "issuer_id" => "clock:other",
      "issuer_generation" => 2,
      "policy_digest" => digest("f"),
      "issuer_policy_digest" => digest("0"),
      "procedure_ref" => "procedure:other"
    }

    for {field, replacement} <- changes do
      record = Map.put(c.record, field, replacement)
      {:ok, payload} = ClockCodec.signing_payload(record)

      {:ok, package} =
        ClockCodec.encode(
          record,
          :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519])
        )

      assert {:error, :clock_signature_or_scope_mismatch} =
               ClockCodec.verify(package, c.request_document, c.policy_document)
    end
  end

  test "complete policy commitment refuses substituted timing and error bounds", c do
    for {field, replacement} <- [
          maximum_response_ms: 2_000,
          maximum_age_ms: 120_000,
          maximum_error_ms: 50,
          generation: 2,
          procedure_ref: "procedure:other",
          issuer_id: "clock:other",
          policy_digest: digest("d")
        ] do
      {:ok, changed} = ClockCodec.policy_document(Map.put(c.policy, field, replacement))

      assert {:error, :clock_signature_or_scope_mismatch} =
               ClockCodec.verify(c.package, c.request_document, changed)
    end
  end

  test "a different key or changed signature cannot authenticate the response", c do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, policy} = ClockCodec.policy_document(%{c.policy | public_key: public})
    assert {:error, _} = ClockCodec.verify(c.package, c.request_document, policy)
    <<first, rest::binary>> = c.signature
    {:ok, changed} = ClockCodec.encode(c.record, <<Bitwise.bxor(first, 1), rest::binary>>)

    assert {:error, :clock_signature_or_scope_mismatch} =
             ClockCodec.verify(changed, c.request_document, c.policy_document)
  end

  test "timing policy bounds are integer-only and leave a usable whole-age interval", c do
    for {field, bad} <- [
          generation: 0,
          generation: 1.0,
          maximum_response_ms: 0,
          maximum_response_ms: 60_001,
          maximum_response_ms: 1.0,
          maximum_age_ms: 600_001,
          maximum_age_ms: 1_050,
          maximum_error_ms: -1,
          maximum_error_ms: 1_001,
          maximum_error_ms: 25.0,
          public_key: <<1>>,
          issuer_id: "",
          policy_digest: "bad"
        ] do
      assert {:error, :invalid_clock_document} =
               ClockCodec.policy_document(Map.put(c.policy, field, bad))
    end

    assert {:error, _} = ClockCodec.policy_document(Map.put(c.policy, :unrecognized, true))
    assert {:error, _} = ClockCodec.policy_document(Map.delete(c.policy, :maximum_error_ms))
    assert {:error, _} = ClockCodec.policy_document(nil)
  end

  test "request and record fields are closed, bounded and integer-only", c do
    for {field, bad} <- [
          {"issuer_generation", 1.0},
          {"issuer_generation", 0},
          {"destination_owner_id", String.upcase(digest("b"))},
          {"challenge_id", ""},
          {"issuer_policy_digest", nil}
        ] do
      assert {:error, _} = ClockCodec.request_document(Map.put(c.request, field, bad))
      assert {:error, _} = ClockCodec.record_document(Map.put(c.record, field, bad))
    end

    for utc <- [-1, 10_000.0, 9_223_372_036_854_775_808, nil] do
      assert {:error, _} = ClockCodec.record_document(%{c.record | "observed_utc_ms" => utc})
    end

    assert {:error, _} = ClockCodec.request_document(Map.put(c.request, "confidence", "trusted"))
    assert {:error, _} = ClockCodec.record_document(Map.put(c.record, "clock", %{}))
    assert {:error, _} = ClockCodec.encode(c.record, <<1>>)
    assert {:error, _} = ClockCodec.encode(nil, c.signature)
  end

  test "noncanonical JSON and signature bytes are refused", c do
    {:ok, [format, record, signature]} = JSON.decode(c.package)

    for package <- [
          c.package <> "\n",
          " " <> c.package,
          JSON.encode!([format, record, signature <> "=="]),
          JSON.encode!([format, record, "short"]),
          JSON.encode!([format, record, signature, true]),
          JSON.encode!(["wotex-home.controller-clock-package.v2", record, signature]),
          JSON.encode!([format, tl(record), signature]),
          String.duplicate(" ", 4_097),
          nil
        ] do
      assert {:error, :invalid_clock_document} = ClockCodec.decode(package)
    end

    assert {:error, _} = ClockCodec.decode_request(c.request_document <> "\n")
    assert {:error, _} = ClockCodec.decode_policy(c.policy_document <> "\n")
  end

  test "policy public key encoding and supported versions are canonical", c do
    {:ok, [format, issuer, encoded | rest]} = JSON.decode(c.policy_document)

    for document <- [
          JSON.encode!([format, issuer, encoded <> "=" | rest]),
          JSON.encode!(["wotex-home.controller-clock-policy.v2", issuer, encoded | rest]),
          JSON.encode!([format, issuer, encoded | rest] ++ [true]),
          "{}"
        ] do
      assert {:error, _} = ClockCodec.decode_policy(document)
    end
  end

  test "a valid historical signature remains inert without original boot timing", c do
    # Signed UTC zero is audit data. Only the private clock owner can evaluate
    # the original live challenge and its request/response monotonic bounds.
    record = %{c.record | "observed_utc_ms" => 0}
    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(
        record,
        :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519])
      )

    assert {:ok, %{record: %{"observed_utc_ms" => 0}}} =
             ClockCodec.verify(package, c.request_document, c.policy_document)
  end

  defp digest(character), do: String.duplicate(character, 64)
end
