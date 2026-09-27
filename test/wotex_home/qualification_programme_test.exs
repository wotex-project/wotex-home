defmodule WotexHome.QualificationProgrammeTest do
  use ExUnit.Case, async: true

  alias WotexHome.Qualification.Programme

  @cohort %{
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

  test "every LIFX integration obligation stays visible without receipts" do
    assert {:ok, cases, digest} = Programme.lifx_cases()
    assert length(cases) == 11
    assert byte_size(digest) == 64
    assert Enum.any?(cases, &(&1["environment"] == "hardware"))
    assert {:ok, report} = Programme.lifx_report(@cohort, [])
    assert report["counts"] == %{"passed" => 0, "failed" => 0, "blocked" => 0, "not_run" => 11}
    assert report["status"] == "incomplete"
    assert report["provenance"] == "unverified"
    refute inspect(report) =~ @cohort["source_identity_ref"]
  end

  test "syntactically complete receipts still cannot claim trusted qualification" do
    assert {:ok, cases, _digest} = Programme.lifx_cases()
    receipts = Enum.map(cases, &passing_receipt/1)

    assert {:ok, report} = Programme.lifx_report(@cohort, receipts)
    assert report["counts"]["passed"] == 11
    assert report["status"] == "complete_unverified"
    assert report["provenance"] == "unverified"

    [first | rest] = receipts
    wrong_environment = %{first | "environment" => "hardware"}
    assert {:ok, drift} = Programme.lifx_report(@cohort, [wrong_environment | rest])
    assert drift["counts"]["blocked"] == 1
    assert drift["status"] == "incomplete"

    assert {:ok, stale} = Programme.lifx_report(%{@cohort | "firmware" => "2.1"}, receipts)
    assert stale["counts"]["blocked"] == 11
  end

  defp passing_receipt(case_definition) do
    Map.merge(case_definition, %{
      "receipt_id" => "receipt:#{case_definition["case_id"]}",
      "status" => "passed",
      "cohort" => @cohort,
      "source_identity_ref" => @cohort["source_identity_ref"],
      "command_sequence" => ["step:request", "step:report"],
      "assertions" => [%{"id" => "matches", "expected" => true, "actual" => true}],
      "artifact_digests" => [String.duplicate("b", 64)],
      "exclusions" => [],
      "blockers" => [],
      "reviewer_ref" => "operator:test"
    })
  end
end
