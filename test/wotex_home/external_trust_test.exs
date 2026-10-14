defmodule WotexHome.ExternalTrustTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{ExternalArtifact, ExternalInspection, ExternalTrust}
  defp vectors, do: JSON.decode!(File.read!("test/fixtures/profiles/external-trust.json"))
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  test "independent manifests and approve/revoke originals round trip without producers" do
    for {_, v} <- vectors() do
      assert {:ok, bytes} = ExternalArtifact.encode(v["artifact"])
      assert bytes == v["artifact_document"]
      assert {:ok, manifest} = ExternalArtifact.decode(bytes)
      assert manifest == v["artifact"]
      assert {:ok, digest} = ExternalArtifact.identity(manifest)
      assert digest == v["artifact_digest"]

      for action <- ~w(approve revoke),
          {encode, decode, key} <- [
            {:encode, :decode, "input"},
            {:encode_outcome, :decode_outcome, "outcome"},
            {:encode_receipt, :decode_receipt, "receipt"}
          ] do
        expected = v[action]
        assert {:ok, bytes} = apply(ExternalTrust, encode, [expected[key]])
        assert bytes == expected[key <> "_document"]
        assert {:ok, actual} = apply(ExternalTrust, decode, [bytes])
        assert actual == expected[key]
        assert {:error, :invalid_external_trust} = apply(ExternalTrust, decode, [bytes <> " "])
      end
    end
  end

  test "raw variants and wrong kinds cannot alias an exact artifact" do
    v = vectors()["temperature"]
    original = v["artifact"]

    changed =
      put_in(original, ["objects", Access.at(1), "object_digest"], String.duplicate("0", 64))

    assert {:ok, digest} = ExternalArtifact.identity(changed)
    assert digest != v["artifact_digest"]

    for bad <- [
          Map.put(original, "extra", true),
          put_in(original, ["objects", Access.at(1), "kind"], "bundle"),
          put_in(original, ["version"], "01.0.0"),
          put_in(original, ["objects"], [hd(original["objects"]) | :bad])
        ] do
      assert {:error, :invalid_external_artifact} = ExternalArtifact.encode(bad)
    end

    assert {:error, :external_profile_limit} =
             ExternalArtifact.encode(
               put_in(original, ["objects", Access.at(1), "payload_bytes"], 65537)
             )

    assert {:error, :external_profile_limit} =
             ExternalArtifact.encode(
               put_in(original, ["objects"], List.duplicate(hd(original["objects"]), 35))
             )
  end

  test "acknowledgement, original reference and outcome correspondence are closed" do
    v = vectors()["temperature"]

    for bad <- [
          Map.put(v["approve"]["input"], "extra", true),
          Map.put(v["approve"]["input"], "acknowledgement", nil),
          Map.put(v["approve"]["input"], "inspection_ref", nil),
          Map.put(v["revoke"]["input"], "acknowledgement", "operator_digest_approval")
        ] do
      assert {:error, :invalid_external_trust} = ExternalTrust.encode(bad)
    end

    for bad <- [
          Map.put(v["approve"]["outcome"], "artifact_digest", String.duplicate("0", 64)),
          put_in(
            v["approve"]["outcome"],
            ["inspection_ref", "result_sha256"],
            String.duplicate("0", 64)
          ),
          Map.put(v["revoke"]["outcome"], "artifact_document", v["artifact_document"])
        ] do
      assert {:error, :invalid_external_trust} = ExternalTrust.encode_outcome(bad)
    end

    for bad <- [
          Map.put(v["approve"]["receipt"], "reader_basis_sha256", nil),
          Map.put(v["revoke"]["receipt"], "reader_basis_sha256", String.duplicate("0", 64)),
          Map.put(v["approve"]["receipt"], "trust_generation", 0)
        ] do
      assert {:error, :invalid_external_trust} = ExternalTrust.encode_receipt(bad)
    end

    assert {:error, :external_profile_limit} = ExternalTrust.decode(String.duplicate("x", 4097))
  end

  test "large documents embed as arrays within the wire string and depth bounds" do
    v = vectors()["temperature"]
    [envelope, profile, definition] = v["artifact"]["objects"]

    definitions =
      for n <- 1..32 do
        definition
        |> put_in(
          ["reference", "id"],
          "urn:metadata:" <>
            String.duplicate("x", 220) <> String.pad_leading(Integer.to_string(n), 3, "0")
        )
        |> Map.put(
          "object_digest",
          String.pad_leading(String.downcase(Integer.to_string(n, 16)), 64, "0")
        )
      end

    artifact = Map.put(v["artifact"], "objects", [envelope, profile | definitions])
    {:ok, artifact_doc} = ExternalArtifact.encode(artifact)
    {:ok, digest} = ExternalArtifact.identity(artifact)

    {:ok, inspection} =
      ExternalInspection.decode_result(v["approve"]["outcome"]["inspection_document"])

    docs =
      Enum.map(
        [profile | definitions],
        &%{"reference" => &1["reference"], "raw_sha256" => &1["payload_sha256"]}
      )

    {:ok, inspection_doc} =
      ExternalInspection.encode_result(
        put_in(inspection, ["envelope", "document_identities"], docs)
      )

    assert byte_size(artifact_doc) > 4096 and byte_size(inspection_doc) > 4096

    outcome =
      v["approve"]["outcome"]
      |> Map.merge(%{
        "artifact_digest" => digest,
        "artifact_document" => artifact_doc,
        "inspection_document" => inspection_doc
      })
      |> put_in(["inspection_ref", "result_sha256"], sha(inspection_doc))

    assert {:ok, encoded} = ExternalTrust.encode_outcome(outcome)
    assert {:ok, ^outcome} = ExternalTrust.decode_outcome(encoded)
  end
end
