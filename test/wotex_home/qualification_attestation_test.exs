defmodule WotexHome.QualificationAttestationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Qualification.{Attestation, Programme}

  test "only a caller-pinned reviewer key verifies a case-bound receipt" do
    assert {:ok, [case_definition | _], programme_digest} = Programme.lifx_cases()
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = "reviewer:lab:1"
    artifact = "wire fixture bytes"
    artifact_digest = :crypto.hash(:sha256, artifact) |> Base.encode16(case: :lower)

    cohort = %{
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

    receipt =
      Map.merge(case_definition, %{
        "receipt_id" => "receipt:1",
        "status" => "passed",
        "cohort" => cohort,
        "source_identity_ref" => cohort["source_identity_ref"],
        "command_sequence" => ["step:wire"],
        "assertions" => [%{"id" => "decoded", "expected" => true, "actual" => true}],
        "artifact_digests" => [artifact_digest],
        "exclusions" => [],
        "blockers" => [],
        "reviewer_ref" => key_id
      })

    assert {:ok, payload} = Attestation.signing_payload(key_id, programme_digest, receipt)
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    attestation = %{
      "receipt" => receipt,
      "reviewer_key_id" => key_id,
      "programme_digest" => programme_digest,
      "signature" => Base.url_encode64(signature, padding: false)
    }

    assert {:ok, ^receipt} =
             Attestation.verify(attestation, programme_digest, %{key_id => public_key})

    assert {:ok, report} =
             Programme.lifx_attested_report(cohort, [attestation], %{key_id => public_key})

    assert report["provenance"] == "signatures_verified_against_supplied_keys"
    assert report["status"] == "incomplete"
    assert report["counts"]["passed"] == 1

    artifact_root =
      Path.join(System.tmp_dir!(), "wotex-artifacts-#{System.unique_integer([:positive])}")

    File.mkdir!(artifact_root)
    File.chmod!(artifact_root, 0o700)
    on_exit(fn -> File.rm_rf!(artifact_root) end)
    artifact_path = Path.join(artifact_root, artifact_digest)
    File.write!(artifact_path, artifact)
    File.chmod!(artifact_path, 0o600)

    assert {:ok, custody_report} =
             Programme.lifx_artifact_report(
               cohort,
               [attestation],
               %{key_id => public_key},
               artifact_root
             )

    assert custody_report["artifact_count"] == 1
    assert custody_report["provenance"] == "signatures_and_artifact_digests_verified"
    assert custody_report["status"] == "incomplete"

    File.write!(artifact_path, "changed fixture")

    assert {:error, :artifact_missing_or_changed} =
             Programme.lifx_artifact_report(
               cohort,
               [attestation],
               %{key_id => public_key},
               artifact_root
             )

    File.write!(artifact_path, artifact)
    File.chmod!(artifact_root, 0o755)

    assert {:error, :invalid_artifact_store} =
             Programme.lifx_artifact_report(
               cohort,
               [attestation],
               %{key_id => public_key},
               artifact_root
             )

    File.chmod!(artifact_root, 0o700)
    File.rm!(artifact_path)
    File.ln_s!("elsewhere", artifact_path)

    assert {:error, :artifact_missing_or_changed} =
             Programme.lifx_artifact_report(
               cohort,
               [attestation],
               %{key_id => public_key},
               artifact_root
             )

    assert {:error, :invalid_attestation} = Attestation.verify(attestation, programme_digest, %{})

    assert {:error, :invalid_attestation} =
             Programme.lifx_attested_report(cohort, [attestation], %{})

    {other_public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:error, :invalid_attestation} =
             Attestation.verify(attestation, programme_digest, %{key_id => other_public_key})

    changed =
      put_in(
        attestation,
        ["receipt", "artifact_digests"],
        [String.duplicate("c", 64)]
      )

    assert {:error, :invalid_attestation} =
             Attestation.verify(changed, programme_digest, %{key_id => public_key})

    assert {:error, :invalid_attestation} =
             Attestation.verify(attestation, String.duplicate("c", 64), %{key_id => public_key})
  end
end
