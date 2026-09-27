defmodule WotexHome.QualificationEvidenceTest do
  use ExUnit.Case, async: true

  alias WotexHome.Qualification.Evidence

  @source_identity_ref :crypto.mac(:hmac, :sha256, :binary.copy(<<7>>, 32), "d073d5000001")
                       |> Base.encode16(case: :lower)

  @cohort %{
    "source_identity_ref" => @source_identity_ref,
    "hardware_sku" => "lifx.old-eu",
    "hardware_revision" => "rev.1",
    "firmware" => "2.0",
    "adapter_profile" => "lifx.old-eu:1.0.0",
    "native_stack" => "wotex-udp:pending",
    "host_os" => "macos:dev",
    "runtime" => "otp:dev",
    "network_topology" => "isolated-lan:1",
    "application" => "home:test",
    "model" => "none"
  }

  @fixture_case %{
    "case_id" => "H03-T1-fixture",
    "requirement_id" => "H03-T1",
    "capability_key" => "power",
    "environment" => "fixture"
  }

  @hardware_case %{@fixture_case | "case_id" => "H03-T1-hardware", "environment" => "hardware"}

  test "a passing fixture cannot promote a hardware case" do
    receipt = passing_receipt()

    assert {:ok, [fixture, hardware]} =
             Evidence.summarize([@fixture_case, @hardware_case], [receipt], @cohort)

    assert %{"status" => "passed", "required_environment" => "fixture"} = fixture
    assert %{"status" => "not_run", "reason" => "receipt_missing"} = hardware

    wrong_environment = %{receipt | "case_id" => "H03-T1-hardware"}
    assert {:ok, [hardware]} = Evidence.summarize([@hardware_case], [wrong_environment], @cohort)
    assert %{"status" => "blocked", "reason" => "environment_mismatch"} = hardware
  end

  test "cohort drift blocks an otherwise passing receipt" do
    assert {:ok, [current]} = Evidence.summarize([@fixture_case], [passing_receipt()], @cohort)
    assert current["status"] == "passed"

    next_cohort = %{@cohort | "firmware" => "2.1"}
    assert {:ok, [stale]} = Evidence.summarize([@fixture_case], [passing_receipt()], next_cohort)
    assert %{"status" => "blocked", "reason" => "cohort_drift"} = stale

    swapped_source = %{@cohort | "source_identity_ref" => String.duplicate("b", 64)}

    assert {:ok, [stale_source]} =
             Evidence.summarize([@fixture_case], [passing_receipt()], swapped_source)

    assert %{"status" => "blocked", "reason" => "cohort_drift"} = stale_source
  end

  test "receipt validation rejects invented success, duplicate cases and private free text" do
    receipt = passing_receipt()

    assert {:error, :invalid_evidence_receipt} =
             Evidence.receipt(%{receipt | "artifact_digests" => []})

    assert {:error, :invalid_evidence_receipt} =
             Evidence.receipt(%{
               receipt
               | "assertions" => [%{"id" => "matches", "expected" => true, "actual" => false}]
             })

    assert {:error, :invalid_evidence_receipt} =
             Evidence.receipt(%{receipt | "reviewer_ref" => "operator@example.com"})

    assert {:error, :mismatched_or_duplicate_receipt} =
             Evidence.summarize([@fixture_case], [receipt, receipt], @cohort)

    same_id_for_other_case = %{
      receipt
      | "case_id" => "H03-T1-hardware",
        "environment" => "hardware"
    }

    assert {:error, :mismatched_or_duplicate_receipt} =
             Evidence.summarize(
               [@fixture_case, @hardware_case],
               [receipt, same_id_for_other_case],
               @cohort
             )
  end

  test "source references are keyed and raw device IDs are not accepted as references" do
    key = :binary.copy(<<7>>, 32)
    assert {:ok, reference} = Evidence.source_identity_ref(key, "d073d5000001")
    assert byte_size(reference) == 64
    refute reference == "d073d5000001"
    assert {:error, :invalid_identity_input} = Evidence.source_identity_ref(<<7>>, "d073d5000001")

    assert {:error, :invalid_evidence_receipt} =
             Evidence.receipt(%{passing_receipt() | "source_identity_ref" => "d073d5000001"})
  end

  defp passing_receipt do
    Map.merge(@fixture_case, %{
      "receipt_id" => "receipt:fixture:1",
      "status" => "passed",
      "cohort" => @cohort,
      "source_identity_ref" => @source_identity_ref,
      "command_sequence" => ["step:request", "step:report"],
      "assertions" => [%{"id" => "matches", "expected" => true, "actual" => true}],
      "artifact_digests" => [String.duplicate("a", 64)],
      "exclusions" => [],
      "blockers" => [],
      "reviewer_ref" => "operator:lab"
    })
  end
end
