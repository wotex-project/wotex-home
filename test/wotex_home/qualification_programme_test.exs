defmodule WotexHome.QualificationProgrammeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Qualification.{Attestation, Programme}

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

  test "direct-power report requires its own nine signed and present cases" do
    assert {:ok, power_cases, programme_digest} = Programme.lifx_power_cases()
    assert length(power_cases) == 9
    refute Enum.any?(power_cases, &(&1["capability_key"] != "power"))

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = "reviewer:power:fixture"
    artifact = "synthetic qualification bytes"
    artifact_digest = :crypto.hash(:sha256, artifact) |> Base.encode16(case: :lower)

    root =
      Path.join(System.tmp_dir!(), "wotex-power-artifacts-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, artifact_digest)
    File.write!(path, artifact)
    File.chmod!(path, 0o600)

    attestations =
      Enum.map(power_cases, fn case_definition ->
        receipt =
          case_definition
          |> passing_receipt()
          |> Map.put("artifact_digests", [artifact_digest])
          |> Map.put("reviewer_ref", key_id)

        assert {:ok, payload} =
                 Attestation.signing_payload(key_id, programme_digest, receipt)

        %{
          "receipt" => receipt,
          "reviewer_key_id" => key_id,
          "programme_digest" => programme_digest,
          "signature" =>
            :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
            |> Base.url_encode64(padding: false)
        }
      end)

    keys = %{key_id => public_key}

    assert {:ok, report} =
             Programme.lifx_power_artifact_report(@cohort, attestations, keys, root)

    assert report["scope"] == "lifx_direct_power_v1"
    assert report["counts"]["passed"] == 9
    assert report["artifact_count"] == 1
    assert report["status"] == "claims_complete_physical_review_pending"

    assert {:ok, incomplete} =
             Programme.lifx_power_artifact_report(@cohort, tl(attestations), keys, root)

    assert incomplete["counts"]["not_run"] == 1
    assert incomplete["status"] == "incomplete"

    assert {:error, :invalid_attestation} =
             Programme.lifx_power_artifact_report(@cohort, attestations, %{}, root)
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
