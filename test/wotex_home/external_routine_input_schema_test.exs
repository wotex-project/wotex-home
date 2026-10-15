defmodule WotexHome.ExternalRoutineInputSchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Profiles.{AuthoringWire, DocumentChunks}
  alias WotexHome.Qualification.{Attestation, Evidence}

  setup_all do
    vector = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    raw = JSON.decode!(File.read!("priv/profiles/routine-external-input.schema.json"))
    %{v: vector, raw: raw, schema: ExJsonSchema.Schema.resolve(raw)}
  end

  test "all closed entry objects and independent ordered documents match their declared identities",
       %{v: v, schema: schema} do
    assert v["scope"] == "synthetic_software_entry_only"

    for value <- [
          v["definition"]["context"]["runtime"],
          v["definition"]["context"],
          v["definition"],
          v["package"]["signed"]["decision"],
          v["package"],
          v["change"],
          v["outcome"],
          v["receipt"],
          v["snapshot"]
        ] do
      assert :ok = ExJsonSchema.Validator.validate(schema, value)
    end

    assert v["definition_sha256"] ==
             hash("wotex-home.external-input-definition@1", v["definition_document"])

    assert v["package_sha256"] ==
             hash("wotex-home.external-input-package@1", v["package_document"])

    assert v["receipt"]["input_sha256"] ==
             hash("wotex-home.external-input.v1", v["change_document"])

    assert v["receipt"]["outcome_sha256"] ==
             hash("wotex-home.external-input-result.v1", v["outcome_document"])

    assert {:ok, ["wotex-home.external-input-definition.v1", context, mapping, registry, limits]} =
             AuthoringWire.decode(v["definition_document"], 262_144)

    for {chunks, expected} <- [
          {context, v["definition"]["context"]},
          {mapping, v["definition"]["mapping"]},
          {registry, v["definition"]["registry"]}
        ] do
      assert {:ok, bytes} = DocumentChunks.decode(chunks, 131_072)
      assert JSON.decode!(bytes) == expected
    end

    assert limits == [262_144, 16, 20_000, 8192, 128, 9_223_372_036_854_775_807]
    assert {:ok, _} = AuthoringWire.decode(v["change_document"], 524_288)
    assert {:ok, _} = AuthoringWire.decode(v["outcome_document"], 524_288)
    assert {:ok, _} = AuthoringWire.decode(v["receipt_document"], 4096)
  end

  test "public producer constructors accept the independently rehashed read-only correspondence",
       %{v: v} do
    d = v["definition"]
    assert {:ok, _} = Wotex.Routines.InputMapping.new(d["mapping"], d["registry"], d["limits"])

    assert {:ok, binding} =
             Wotex.Routines.Input.binding_basis(d["mapping"], d["registry"], d["limits"])

    assert binding == hd(v["snapshot"]["items"])["binding_basis"]
    assert d["mapping"]["basis"]["output"] == nil

    assert d["mapping"]["basis"]["implementation_digest"] ==
             "sha256:" <> d["context"]["runtime_sha256"]
  end

  test "Python ETF and public-key signatures agree without invoking a new qualification helper",
       %{v: v} do
    package = v["package"]
    programme = File.read!("priv/qualification/external-routine-input-v1.json")
    assert Base.encode16(:crypto.hash(:sha256, programme), case: :lower) == v["programme_sha256"]
    assert {:ok, digest} = Evidence.cohort_digest(package["cohort"])
    assert digest == package["signed"]["decision"]["cohort_sha256"]
    {:ok, case_key} = Base.url_decode64(v["case_public_key"], padding: false)
    {:ok, decision_key} = Base.url_decode64(v["decision_public_key"], padding: false)
    refute case_key == decision_key

    for {attestation, encoded} <-
          Enum.zip(package["attestations"], v["case_signing_payloads_base64"]) do
      assert {:ok, payload} =
               Attestation.signing_payload(
                 "case-entry",
                 v["programme_sha256"],
                 attestation["receipt"]
               )

      assert Base.encode64(payload) == encoded

      assert {:ok, _} =
               Attestation.verify(attestation, v["programme_sha256"], %{"case-entry" => case_key})
    end

    signed = package["signed"]

    payload =
      "WOH11-external-input-decision-v1\0" <>
        :erlang.term_to_binary(signed["decision"], [:deterministic])

    assert Base.encode64(payload) == v["decision_signing_payload_base64"]
    signature = Base.url_decode64!(signed["signature"], padding: false)
    assert :crypto.verify(:eddsa, :none, payload, signature, [decision_key, :ed25519])

    refute :crypto.verify(:eddsa, :none, payload <> "changed", signature, [decision_key, :ed25519])

    assert signed["decision"]["evidence_set_sha256"] ==
             Base.encode16(
               :crypto.hash(
                 :sha256,
                 :erlang.term_to_binary(package["attestations"], [:deterministic])
               ),
               case: :lower
             )
  end

  test "entry schemas reject forged scope, write behavior, synthetic source and extra authority",
       c do
    d = c.v["definition"]

    for value <- [
          Map.put(d, "authorized", true),
          put_in(d, ["context", "source_trust"], "synthetic_lab"),
          put_in(d, ["mapping", "basis", "output"], d["mapping"]["basis"]["value"]),
          put_in(d, ["mapping", "basis", "effects", "repeat"], "bounded"),
          put_in(d, ["mapping", "basis", "affordance", "operation"], "writeproperty"),
          put_in(d, ["limits", "max_depth"], 32),
          Map.put(c.v["snapshot"], "scope", "admitted_effects"),
          put_in(
            c.v["snapshot"],
            ["items", Access.at!(0), "projection", "fact", "received_at"],
            "2026-10-15T00:00:00Z"
          )
        ] do
      refute ExJsonSchema.Validator.valid?(c.schema, value)
    end

    assert local_refs?(c.raw)
  end

  test "snapshot witnesses preserve distinct units, original coordinates and narrower expiry", %{
    v: v
  } do
    item = hd(v["snapshot"]["items"])
    fact = item["projection"]["fact"]
    assert fact["value"] == 250
    assert fact["receipt_ms"] == 9998
    assert fact["expires_ms"] == 10_998
    assert item["owner_expires_ms"] == 69_998
    assert fact["received_at"] == nil

    assert fact["profile_digest"] !=
             item["binding_basis"]["input_mapping"]["basis"]["semantic_digest"]

    assert String.starts_with?(fact["thing_id"], "urn:wotex-home:thing:")
    assert v["snapshot"]["scope"] == "qualified_external_input_snapshot_only"
  end

  defp hash(prefix, bytes),
    do: Base.encode16(:crypto.hash(:sha256, prefix <> "\n" <> bytes), case: :lower)

  defp local_refs?(data) when is_map(data),
    do:
      (not Map.has_key?(data, "$ref") or String.starts_with?(data["$ref"], "#/definitions/")) and
        Enum.all?(Map.values(data), &local_refs?/1)

  defp local_refs?(data) when is_list(data), do: Enum.all?(data, &local_refs?/1)
  defp local_refs?(_), do: true
end
