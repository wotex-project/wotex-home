defmodule WotexHome.AuthoringCandidateTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringCandidate, AuthoringWire}
  defp vector, do: JSON.decode!(File.read!("test/fixtures/profiles/authoring-candidate.json"))

  test "independent ordered original, receipt and full assessment encodings round trip without a producer" do
    v = vector()

    for {encode, decode, key} <- [
          {:encode, :decode, "input"},
          {:encode_receipt, :decode_receipt, "receipt"},
          {:encode_assessment, :decode_assessment, "assessment"}
        ] do
      assert {:ok, bytes} = apply(AuthoringCandidate, encode, [v[key]])
      assert bytes == v[key <> "_document"]
      assert {:ok, value} = apply(AuthoringCandidate, decode, [bytes])
      assert value == v[key]

      assert {:error, :invalid_authoring_candidate} =
               apply(AuthoringCandidate, decode, [bytes <> " "])
    end
  end

  test "closed original and retained metadata cannot manufacture manual or compatible results" do
    v = vector()
    input = v["input"]

    for changed <- [
          Map.put(input, "extra", "secret"),
          put_in(input, ["request", "base_draft_ref", "first_revision"], 0),
          put_in(input, ["request", "source_refs"], [%{} | :bad]),
          put_in(input, ["request", "instruction"], "x\0"),
          put_in(input, ["request", "limits", "reader", "max_depth"], 0)
        ] do
      assert {:error, :invalid_authoring_candidate} = AuthoringCandidate.encode(changed)
    end

    assert {:error, :unsupported_authoring_mode} =
             AuthoringCandidate.encode(put_in(input, ["request", "mode"], "generated"))

    assert {:error, :authoring_limit} =
             AuthoringCandidate.encode(
               put_in(input, ["request", "source_refs"], List.duplicate(%{}, 33))
             )

    assert {:error, :authoring_limit} =
             AuthoringCandidate.encode(
               put_in(input, ["request", "limits", "max_bundle_bytes"], 262_145)
             )

    for changed <- [
          Map.put(v["assessment"], "disposition", "compatible"),
          put_in(v["assessment"], ["report", "candidate_sha256"], String.duplicate("0", 64)),
          Map.put(v["receipt"], "capture_status", "matched")
        ] do
      method = if Map.has_key?(changed, "report"), do: :encode_assessment, else: :encode_receipt
      assert {:error, :invalid_authoring_candidate} = apply(AuthoringCandidate, method, [changed])
    end
  end

  test "wire depth, node, array, string and byte budgets precede construction" do
    assert {:error, :authoring_limit} =
             AuthoringWire.decode(JSON.encode!(List.duplicate(List.duplicate(0, 255), 17)), 65536)

    assert {:error, :authoring_limit} =
             AuthoringWire.decode(
               String.duplicate("[", 9) <> "0" <> String.duplicate("]", 9),
               65536
             )

    assert {:error, :authoring_limit} =
             AuthoringWire.decode(JSON.encode!(List.duplicate(0, 257)), 65536)

    assert {:error, :authoring_limit} =
             AuthoringWire.decode(JSON.encode!(String.duplicate("x", 4097)), 65536)

    assert {:error, :authoring_limit} = AuthoringWire.decode(String.duplicate("x", 65537), 65536)
    assert {:error, :invalid_authoring_candidate} = AuthoringWire.decode("{}", 65536)
    assert {:error, :invalid_authoring_candidate} = AuthoringWire.decode("1.0", 65536)

    assert {:error, :invalid_authoring_candidate} =
             AuthoringWire.decode("9223372036854775808", 65536)
  end
end
