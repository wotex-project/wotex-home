defmodule WotexHome.Profiles.AuthoringImportTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringImport, AuthoringObject}

  test "independent ordered-array vectors exactly match input and receipt encodings" do
    v =
      __DIR__
      |> Path.join("../fixtures/profiles/authoring-import.json")
      |> File.read!()
      |> JSON.decode!()

    assert {:ok, input} = AuthoringImport.encode(v["input"])
    assert input == v["input_document"]
    assert {:ok, data} = AuthoringImport.decode(input)
    assert data == v["input"]
    assert {:ok, receipt} = AuthoringImport.encode_receipt(v["receipt"])
    assert receipt == v["receipt_document"]
    assert {:ok, data} = AuthoringImport.decode_receipt(receipt)
    assert data == v["receipt"]
    assert {:error, :invalid_authoring_import} = AuthoringImport.decode(input <> " ")
    assert {:error, :invalid_authoring_import} = AuthoringImport.decode_receipt(receipt <> " ")
  end

  test "unknown/native/malformed/over-budget values and forged receipts refuse" do
    {:ok, object} = AuthoringObject.new("source", "original")
    {:ok, summary} = AuthoringObject.summary(object)

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "operation",
      "expected_revision" => 0,
      "object" => summary
    }

    for bad <- [
          %URI{},
          Map.put(input, "private-canary", "secret-canary"),
          Map.put(input, "authority_epoch", 0),
          Map.put(input, "expected_revision", -1),
          Map.put(input, "operation_id", "bad/id"),
          Map.put(input, "object", %{})
        ] do
      assert {:error, :invalid_authoring_import} = AuthoringImport.encode(bad)
    end

    receipt = AuthoringImport.receipt(input, 1, 1)

    for bad <- [
          %URI{},
          Map.put(receipt, "first_revision", 2),
          Map.put(receipt, "revision", 0),
          Map.put(receipt, "extra", true)
        ] do
      assert {:error, :invalid_authoring_import} = AuthoringImport.encode_receipt(bad)
    end

    for bad <- [%URI{}, "{}", "[", String.duplicate("x", 4097)] do
      assert {:error, :invalid_authoring_import} = AuthoringImport.decode(bad)
      assert {:error, :invalid_authoring_import} = AuthoringImport.decode_receipt(bad)
    end
  end
end
