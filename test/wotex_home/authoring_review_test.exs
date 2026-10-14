defmodule WotexHome.AuthoringReviewTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.AuthoringReview
  defp vector, do: JSON.decode!(File.read!("test/fixtures/profiles/authoring-review.json"))

  test "independent original/result/receipt arrays round trip without producer code" do
    v = vector()

    for {encode, decode, key} <- [
          {:encode, :decode, "input"},
          {:encode_result, :decode_result, "result"},
          {:encode_receipt, :decode_receipt, "receipt"}
        ] do
      assert {:ok, bytes} = apply(AuthoringReview, encode, [v[key]])
      assert bytes == v[key <> "_document"]
      assert {:ok, value} = apply(AuthoringReview, decode, [bytes])
      assert value == v[key]
      assert {:error, :invalid_authoring_review} = apply(AuthoringReview, decode, [bytes <> " "])
    end
  end

  test "original metadata is closed, ordered and cannot fabricate complete proposal authority" do
    v = vector()
    i = v["input"]
    [first | _] = i["review"]["evidence"]

    for bad <- [
          Map.put(i, "extra", true),
          put_in(i, ["review", "candidate_ref", "revision"], 0),
          put_in(i, ["review", "evidence"], [first | :bad]),
          put_in(i, ["review", "evidence"], [first, first]),
          put_in(i, ["review", "evidence"], [Map.put(first, "instance_path", "/profile")]),
          put_in(i, ["review", "mode"], "complete"),
          put_in(i, ["review", "evidence"], [Map.put(first, "locator", "x\0")])
        ] do
      assert {:error, :invalid_authoring_review} = AuthoringReview.encode(bad)
    end

    assert {:error, :authoring_limit} =
             AuthoringReview.encode(put_in(i, ["review", "evidence"], List.duplicate(first, 257)))

    assert {:error, :invalid_authoring_review} =
             AuthoringReview.encode_receipt(Map.put(v["receipt"], "proposal_status", "complete"))

    assert {:error, :invalid_authoring_review} =
             AuthoringReview.encode_result(put_in(v["result"], ["source", "covered_paths"], []))

    assert {:error, :invalid_authoring_review} =
             AuthoringReview.encode_result(
               put_in(v["result"], ["source", "status"], "incomplete")
             )
  end
end
