defmodule WotexHome.ScheduleClockTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{ClockCodec, ClockLease, Codec}
  @fixture Path.expand("../fixtures/schedules/clock_vectors.json", __DIR__)

  setup do
    fixture = JSON.decode!(File.read!(@fixture))
    {:ok, policy} = ClockCodec.decode_policy(fixture["policy_document"])
    {:ok, request} = ClockCodec.decode_request(fixture["request_document"])
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    policy = %{policy | public_key: public}
    {:ok, policy_document} = ClockCodec.policy_document(policy)
    request = Map.put(request, "policy_document_digest", Codec.hash(policy_document))
    {:ok, request_document} = ClockCodec.request_document(request)

    record =
      Map.merge(request, %{
        "procedure_ref" => policy.procedure_ref,
        "observed_utc_ms" => 1_000_000
      })

    package = sign(record, private)

    %{
      fixture: fixture,
      policy: policy,
      request: request,
      record: record,
      private: private,
      policy_document: policy_document,
      request_document: request_document,
      package: package,
      scope:
        Map.take(
          request,
          ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest)
        )
    }
  end

  test "independent Python Ed25519 bytes and conservative integer intervals match exactly", c do
    fixture = c.fixture
    {:ok, request} = ClockCodec.decode_request(fixture["request_document"])

    scope =
      Map.take(
        request,
        ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest)
      )

    assert length(fixture["records"]) == 4

    for record <- fixture["records"] do
      package = record["package_document"]

      assert {:ok, parsed} =
               ClockCodec.verify(package, fixture["request_document"], fixture["policy_document"])

      assert parsed.package_digest == record["package_sha256"]
      refute Map.has_key?(parsed, :confidence)

      assert {:ok, lease} =
               ClockLease.establish(
                 fixture["request_document"],
                 fixture["policy_document"],
                 package,
                 record["started_ms"],
                 record["received_ms"]
               )

      assert [lease.sample["utc_lower_ms"], lease.sample["utc_upper_ms"]] ==
               record["initial_interval"]

      for vector <- record["vectors"] do
        assert {:ok, sample, {lower, upper}} = ClockLease.current(lease, scope, vector["now_ms"])
        assert sample == lease.sample && [lower, upper] == vector["interval"]
      end
    end
  end

  test "every signed home, owner, boot, generation, nonce, runtime, issuer and procedure substitution refuses",
       c do
    changes = %{
      "deployment_id" => digest("e"),
      "owner_id" => digest("e"),
      "authority_epoch" => 2,
      "store_boot_epoch" => "boot:other",
      "clock_generation" => 3,
      "runtime_digest" => digest("e"),
      "challenge_nonce" => Base.url_encode64(:binary.copy(<<1>>, 32), padding: false),
      "source_id" => "clock:other",
      "issuer_id" => "issuer:other",
      "issuer_generation" => 2,
      "qualification_digest" => digest("e"),
      "policy_document_digest" => digest("e"),
      "procedure_ref" => "procedure:other"
    }

    for {field, replacement} <- changes do
      changed = sign(Map.put(c.record, field, replacement), c.private)

      assert {:error, :schedule_clock_signature_or_scope_mismatch} =
               ClockCodec.verify(changed, c.request_document, c.policy_document)
    end

    {:ok, parsed} = ClockCodec.decode(c.package)
    {:ok, unsigned} = ClockCodec.encode(parsed.record, <<0::512>>)

    assert {:error, :schedule_clock_signature_or_scope_mismatch} =
             ClockCodec.verify(unsigned, c.request_document, c.policy_document)
  end

  test "complete original policy commits all clock bounds and the purpose-specific runtime", c do
    for {field, replacement} <- [
          maximum_response_ms: 999,
          maximum_age_ms: 59_999,
          maximum_error_ms: 8,
          drift_ppm: 999,
          maximum_discontinuity_ms: 6,
          source_id: "clock:other",
          issuer_generation: 2,
          procedure_ref: "procedure:other",
          runtime_digest: digest("e"),
          qualification_digest: digest("e")
        ] do
      {:ok, changed} = ClockCodec.policy_document(Map.put(c.policy, field, replacement))

      assert {:error, :schedule_clock_signature_or_scope_mismatch} =
               ClockCodec.verify(c.package, c.request_document, changed)
    end
  end

  test "integer timing and explicit discontinuity policy have closed bounds", c do
    for {field, bad} <- [
          maximum_response_ms: 0,
          maximum_response_ms: 60_001,
          maximum_response_ms: 1.0,
          maximum_age_ms: 0,
          maximum_age_ms: 600_001,
          maximum_age_ms: 1_014,
          maximum_error_ms: -1,
          maximum_error_ms: 1_001,
          maximum_error_ms: 7.0,
          drift_ppm: -1,
          drift_ppm: 1_001,
          maximum_discontinuity_ms: -1,
          maximum_discontinuity_ms: 1_001,
          monotonic_policy: "assume_continuous",
          public_key: <<1>>,
          issuer_generation: 0,
          runtime_digest: nil
        ] do
      assert {:error, :invalid_schedule_clock_document} =
               ClockCodec.policy_document(Map.put(c.policy, field, bad))
    end

    assert {:error, _} = ClockCodec.policy_document(Map.put(c.policy, :clock, true))

    for {field, bad} <- [
          {"challenge_nonce", "short"},
          {"challenge_nonce", c.request["challenge_nonce"] <> "="},
          {"clock_generation", 0},
          {"authority_epoch", 1.0},
          {"store_boot_epoch", ""},
          {"owner_id", nil}
        ] do
      assert {:error, _} = ClockCodec.request_document(Map.put(c.request, field, bad))
    end

    for utc <- [-1, 1.0, Codec.utc_maximum(), nil] do
      assert {:error, _} = ClockCodec.record_document(%{c.record | "observed_utc_ms" => utc})
    end
  end

  test "bounded decoders refuse alternate JSON, oversized members and nested records", c do
    {:ok, [format, values, signature]} = Codec.record(c.package)

    for bytes <- [
          c.package <> "\n",
          " " <> c.package,
          JSON.encode!([format, values, signature <> "="]),
          JSON.encode!([format, values, signature, true]),
          JSON.encode!([format, %{}, signature]),
          JSON.encode!([format, List.duplicate(1, 17), signature]),
          String.duplicate("x", 4_097),
          JSON.encode!([format, [[[[1]]]], signature]),
          JSON.encode!([format, values, String.duplicate("x", 129)])
        ] do
      assert {:error, :invalid_schedule_clock_document} = ClockCodec.decode(bytes)
    end

    assert {:error, _} = ClockCodec.decode_policy(c.policy_document <> "\n")
    assert {:error, _} = ClockCodec.decode_request(c.request_document <> "\n")
    assert {:error, _} = ClockCodec.encode(c.record, <<0>>)
  end

  test "recovery and temporal signatures and package domains are mutually unusable", c do
    {:ok, parsed} = ClockCodec.decode(c.package)
    {:ok, record_document} = ClockCodec.record_document(c.record)

    assert parsed.signing_payload ==
             "wotex-home.schedule-clock-record.v1" <> <<0>> <> record_document

    wrong_signature =
      :crypto.sign(
        :eddsa,
        :none,
        "wotex-home.controller-clock-record.v1" <> <<0>> <> record_document,
        [c.private, :ed25519]
      )

    {:ok, wrong} = ClockCodec.encode(c.record, wrong_signature)

    assert {:error, :schedule_clock_signature_or_scope_mismatch} =
             ClockCodec.verify(wrong, c.request_document, c.policy_document)

    assert {:error, :invalid_clock_document} = WotexHome.Recovery.ClockCodec.decode(c.package)

    assert {:error, _} =
             ClockCodec.decode(
               String.replace(c.package, "schedule-clock-package", "controller-clock-package")
             )
  end

  test "response and whole-age deadlines never renew and original sample tampering refuses", c do
    assert {:ok, lease} =
             ClockLease.establish(c.request_document, c.policy_document, c.package, 100, 123)

    assert {:ok, _, _} = ClockLease.current(lease, c.scope, 60_099)

    assert {:error, :schedule_clock_lease_unavailable} =
             ClockLease.current(lease, c.scope, 60_100)

    assert {:error, :schedule_clock_lease_unavailable} = ClockLease.current(lease, c.scope, 122)

    for {start, received} <- [
          {100, 1_100},
          {100, 99},
          {-1, 1},
          {100.0, 123},
          {0, Codec.maximum()}
        ] do
      assert {:error, :schedule_clock_establishment_failed} =
               ClockLease.establish(
                 c.request_document,
                 c.policy_document,
                 c.package,
                 start,
                 received
               )
    end

    for changed <- [
          %{lease | received_monotonic_ms: 124},
          %{lease | started_monotonic_ms: 101},
          %{lease | sample: Map.put(lease.sample, "utc_lower_ms", 1_000_000)},
          Map.put(lease, :renew, true)
        ] do
      assert {:error, :schedule_clock_lease_unavailable} =
               ClockLease.current(changed, c.scope, 123)
    end
  end

  test "current scope is exact and cannot reuse the lease across restart or ownership changes",
       c do
    {:ok, lease} =
      ClockLease.establish(c.request_document, c.policy_document, c.package, 100, 123)

    for {field, value} <- [
          {"deployment_id", digest("e")},
          {"owner_id", digest("e")},
          {"authority_epoch", 2},
          {"store_boot_epoch", "boot:other"},
          {"clock_generation", 3},
          {"runtime_digest", digest("e")}
        ] do
      assert {:error, :schedule_clock_lease_unavailable} =
               ClockLease.current(lease, Map.put(c.scope, field, value), 123)
    end

    assert {:error, _} = ClockLease.current(lease, Map.put(c.scope, "credential", "unused"), 123)
    assert {:error, _} = ClockLease.current(nil, c.scope, 123)
  end

  test "OS wall comparison can only withdraw continuity; drift bounds use integer ceiling", c do
    assert ClockLease.continuous?(c.policy, 100, 9_000, 1_100, 10_006)
    refute ClockLease.continuous?(c.policy, 100, 9_000, 1_100, 10_007)
    refute ClockLease.continuous?(c.policy, 100, 9_000, 99, 8_999)
    refute ClockLease.continuous?(c.policy, 100, 9_000, 1_100, 11_000)
    refute ClockLease.continuous?(c.policy, 100, 9_000, 1_100, 9_000)
    refute ClockLease.continuous?(c.policy, 100, 9_000, 1.0, 9_001)
    refute ClockLease.continuous?(c.policy, 100, 9_000, 101, Codec.maximum() + 1)
    # A passing equality alone returns only a Boolean, never a qualified sample.
    assert ClockLease.continuous?(c.policy, 0, -1_000, 1_000, 0) == true
  end

  test "UTC underflow and conservative upper overflow cannot establish a lease", c do
    for observed <- [0, Codec.utc_maximum() - 60_000] do
      package = sign(%{c.record | "observed_utc_ms" => observed}, c.private)

      assert {:error, :schedule_clock_establishment_failed} =
               ClockLease.establish(c.request_document, c.policy_document, package, 100, 123)
    end
  end

  defp sign(record, private) do
    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(record, :crypto.sign(:eddsa, :none, payload, [private, :ed25519]))

    package
  end

  defp digest(letter), do: String.duplicate(letter, 64)
end
