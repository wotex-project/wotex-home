defmodule WotexHome.ExternalTargetTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{DocumentChunks, ExternalTarget, RetainedJSON, RetainedSource}

  defp vectors,
    do: JSON.decode!(File.read!("test/fixtures/profiles/external-target-selections.json"))

  test "independent single and multi-channel originals, private outcomes and receipts retain exact bytes" do
    for family <- ~w(temperature research multi), action <- ~w(select revoke) do
      v = vectors()[family][action]
      assert {:ok, bytes} = ExternalTarget.encode(v["input"])
      assert bytes == v["input_document"]
      assert {:ok, input} = ExternalTarget.decode(bytes)
      assert input == v["input"]
      assert {:ok, bytes} = ExternalTarget.encode_outcome(v["outcome"])
      assert bytes == v["outcome_document"]
      assert {:ok, outcome} = ExternalTarget.decode_outcome(bytes)
      assert outcome == v["outcome"]
      assert {:ok, bytes} = ExternalTarget.encode_receipt(v["receipt"])
      assert bytes == v["receipt_document"]
      assert {:ok, receipt} = ExternalTarget.decode_receipt(bytes)
      assert receipt == v["receipt"]
    end
  end

  test "fixed byte splits accept UTF-8 boundary vectors and refuse redundant boundaries" do
    for v <- vectors()["chunk_vectors"] do
      assert {:ok, chunks} = DocumentChunks.encode(v["document"], 16384)
      assert chunks == v["chunks"]
      assert {:ok, bytes} = DocumentChunks.decode(chunks, 16384)
      assert bytes == v["document"]
    end

    assert {:error, :invalid_document_chunks} = DocumentChunks.decode(["a", "b"], 100)
    assert {:error, :invalid_document_chunks} = DocumentChunks.decode(["", "a"], 100)
    assert {:error, :invalid_document_chunks} = DocumentChunks.encode(<<255>>, 100)
    assert {:error, :external_profile_limit} = DocumentChunks.encode("ab", 1)

    assert {:error, :external_profile_limit} =
             DocumentChunks.decode(List.duplicate("x", 257), 4096)
  end

  test "closed originals refuse unknown keys, implicit fields, native data and cross-action fields" do
    i = vectors()["temperature"]["select"]["input"]

    for bad <- [
          Map.put(i, "extra", true),
          Map.delete(i, "expected_resource_revision"),
          Map.put(i, "source_owner_epoch", String.duplicate("F", 32)),
          Map.put(i, "expected_revision", -1),
          Map.put(i, "acknowledgement", nil),
          Map.put(i, "action", "revoke"),
          Map.put(i, "objects", %{})
        ] do
      assert {:error, :invalid_external_target} = ExternalTarget.encode(bad)
    end

    assert {:error, :invalid_external_target} = ExternalTarget.decode("{}")

    assert {:error, :invalid_external_target} =
             ExternalTarget.decode(" " <> vectors()["temperature"]["select"]["input_document"])
  end

  test "private outcome validates source-reader-channel-artifact-declaration correspondence" do
    o = vectors()["temperature"]["select"]["outcome"]
    other = vectors()["research"]["select"]["outcome"]

    for key <- ~w(artifact_document inspection_document thing_document source_document) do
      assert {:error, :invalid_external_target} =
               ExternalTarget.encode_outcome(Map.put(o, key, other[key]))
    end

    assert {:error, :invalid_external_target} =
             ExternalTarget.encode_outcome(Map.put(o, "target_id", "sensor:other"))

    source = JSON.decode!(o["source_document"])

    assert {:error, :invalid_retained_source} =
             RetainedSource.decode(
               JSON.encode!(List.replace_at(source, 2, String.duplicate("0", 64)))
             )

    assert {:ok, decoded} = RetainedSource.decode(o["source_document"])
    assert decoded.inputs["source"]["stable_id"] == "fixture:private:stable"
  end

  test "historical JSON refuses duplicate names and bounds before interpreting containers" do
    assert {:error, :invalid_retained_json} = RetainedJSON.decode(~s({"a":1,"a":2}))
    assert {:error, :invalid_retained_json} = RetainedJSON.decode("{broken")

    assert {:error, :external_profile_limit} =
             RetainedJSON.decode(JSON.encode!(%{"a" => String.duplicate("x", 4097)}))

    assert {:error, :external_profile_limit} =
             RetainedJSON.decode("[" <> Enum.join(List.duplicate("0", 257), ",") <> "]")

    assert {:error, :external_profile_limit} =
             RetainedJSON.decode(String.duplicate("[", 9) <> "0" <> String.duplicate("]", 9))

    assert {:ok, %{"n" => 1000.0}} = RetainedJSON.decode(~s({"n":1e3}))
    assert {:error, :invalid_retained_json} = RetainedJSON.decode(~s({"n":1e1000}))

    assert {:error, :invalid_authoring_candidate} =
             WotexHome.Profiles.AuthoringWire.decode(
               "[" <> String.duplicate("9", 10000) <> "]",
               32768
             )
  end
end
