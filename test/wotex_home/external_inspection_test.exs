defmodule WotexHome.ExternalInspectionTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringReview, ExternalInspection, ReaderSelection}
  defp fixtures, do: JSON.decode!(File.read!("test/fixtures/profiles/external-inspections.json"))

  test "independent original/result/receipt vectors round trip without optional producers" do
    for {_, vector} <- fixtures(),
        {encode, decode, key} <- [
          {:encode, :decode, "input"},
          {:encode_result, :decode_result, "result"},
          {:encode_receipt, :decode_receipt, "receipt"}
        ] do
      assert {:ok, bytes} = apply(ExternalInspection, encode, [vector[key]])
      assert bytes == vector[key <> "_document"]
      assert {:ok, data} = apply(ExternalInspection, decode, [bytes])
      assert data == vector[key]

      assert {:error, :invalid_external_inspection} =
               apply(ExternalInspection, decode, [bytes <> " "])
    end
  end

  test "original closure handles are closed, sorted and bounded before an oversized tail" do
    v = fixtures()["temperature"]["input"]
    [d] = v["inspection"]["definitions"]

    for bad <- [
          Map.put(v, "extra", true),
          put_in(v, ["inspection", "profile", "reference", "sha256"], "bad"),
          put_in(v, ["inspection", "envelope_ref", "first_revision"], 0),
          put_in(v, ["inspection", "definitions"], [d, d]),
          put_in(v, ["inspection", "definitions"], [d | :bad]),
          put_in(v, ["authority_epoch"], 0)
        ] do
      assert {:error, :invalid_external_inspection} = ExternalInspection.encode(bad)
    end

    assert {:error, :external_profile_limit} =
             ExternalInspection.encode(
               put_in(v, ["inspection", "definitions"], List.duplicate(d, 33))
             )

    over = Enum.reduce(1..33, :bad, fn _, tail -> [d | tail] end)

    assert {:error, :external_profile_limit} =
             ExternalInspection.encode(put_in(v, ["inspection", "definitions"], over))

    assert {:error, :external_profile_limit} =
             ExternalInspection.decode(String.duplicate("x", 16385))

    assert {:error, :invalid_external_inspection} = ExternalInspection.decode("{}")
  end

  test "retained envelope representation cannot manufacture a matched result or widen its vocabulary" do
    v = fixtures()["temperature"]

    assert {:error, :invalid_external_inspection} =
             ExternalInspection.encode_result(Map.put(v["result"], "envelope", nil))

    assert {:error, :invalid_external_inspection} =
             ExternalInspection.encode_result(
               put_in(v["result"], ["envelope", "producer", "core_archive_sha256"], "bad")
             )

    assert {:error, :invalid_external_inspection} =
             ExternalInspection.encode_receipt(
               Map.put(v["receipt"], "home_consumption", "approved")
             )

    assert {:error, :external_profile_limit} =
             ExternalInspection.decode_result(String.duplicate("x", 32769))

    # Both owners use the identical historical envelope field order.
    source =
      JSON.decode!(File.read!("test/fixtures/profiles/authoring-review.json"))["result"]["source"]

    fixture_summary = %{
      "format" => "wotex-home.authoring-fixtures@1",
      "consumption_sha256" => v["result"]["envelope"]["consumption_sha256"],
      "fixtures_sha256" => String.duplicate("a", 64),
      "status" => "not_supplied",
      "cases" => [],
      "uncovered_channels" => ["sample"]
    }

    review = %{
      "format" => "wotex-home.authoring-review-result@1",
      "source" => source,
      "envelope" => v["result"]["envelope"],
      "fixtures" => fixture_summary
    }

    assert {:ok, bytes} = AuthoringReview.encode_result(review)
    assert {:ok, ^review} = AuthoringReview.decode_result(bytes)
  end

  test "reader construction uses the ordinary locked producer and rejects forged values" do
    v = fixtures()["temperature"]["reader_inputs"]

    assert {:ok, _} =
             ReaderSelection.new(v["installed"], v["capture"], v["reader_limits"])

    assert {:error, :invalid_external_reader} = ReaderSelection.to_map(%{})
  end
end
