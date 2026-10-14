defmodule WotexHome.ExternalObservationTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.ExternalObservation
  defp vectors, do: JSON.decode!(File.read!("test/fixtures/profiles/external-observations.json"))

  test "independent original, outcome and receipt bytes round trip for both quantities and multi-channel" do
    for family <- ~w(temperature research multi) do
      v = vectors()[family]
      assert {:ok, i} = ExternalObservation.encode(v["input"])
      assert i == v["input_document"]
      assert {:ok, _} = ExternalObservation.decode(i)
      assert {:ok, o} = ExternalObservation.encode_outcome(v["outcome"])
      assert o == v["outcome_document"]
      assert {:ok, data} = ExternalObservation.decode_outcome(o)
      assert data == v["outcome"]
      assert {:ok, r} = ExternalObservation.encode_receipt(v["receipt"])
      assert r == v["receipt_document"]
      assert {:ok, data} = ExternalObservation.decode_receipt(r)
      assert data == v["receipt"]
    end
  end

  test "closed originals and exact hash/provenance joins refuse drift" do
    v = vectors()["temperature"]
    assert {:error, _} = ExternalObservation.encode(Map.put(v["input"], "target_id", "chosen"))

    assert {:error, _} =
             ExternalObservation.encode_outcome(
               Map.put(v["outcome"], "value_sha256", String.duplicate("0", 64))
             )

    assert {:error, _} =
             ExternalObservation.encode_outcome(
               Map.put(
                 v["outcome"],
                 "report_document",
                 vectors()["research"]["outcome"]["report_document"]
               )
             )

    assert {:error, _} = ExternalObservation.decode(v["input_document"] <> " ")
  end
end
