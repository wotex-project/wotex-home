defmodule HomeReaderArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{ExternalInspection, InspectionPreparation, ReaderSelection}
  defp fixture, do: JSON.decode!(File.read!("fixtures/external-inspections.json"))["temperature"]

  defp read_records(family) do
    vector = JSON.decode!(File.read!("fixtures/external-inspections.json"))[family]
    v = JSON.decode!(File.read!("fixtures/" <> family <> ".json"))

    [v["envelope"], v["profile"], hd(v["definitions"])]
    |> Enum.zip(vector["objects"])
    |> Enum.with_index(1)
    |> Enum.map(fn {{data, summary}, revision} ->
      {:ok, bytes} = Wotex.JSON.encode(data)
      %{"object" => summary, "payload" => bytes, "first_revision" => revision}
    end)
    |> Enum.sort_by(& &1["object"]["object_digest"])
  end

  test "explicit independently framed byte closures produce the exact inspection result for both quantities" do
    for family <- ~w(temperature research) do
      v = JSON.decode!(File.read!("fixtures/external-inspections.json"))[family]
      i = v["reader_inputs"]
      {:ok, reader} = ReaderSelection.new(i["installed"], i["capture"], i["reader_limits"])
      assert {:ok, result} = InspectionPreparation.build(v["input"], read_records(family), reader)
      assert result == v["result"]
      assert {:ok, bytes} = ExternalInspection.encode_result(result)
      assert bytes == v["result_document"]
    end
  end

  test "missing, forged and extra byte records cannot enter the pure inspection closure" do
    v = fixture()
    i = v["reader_inputs"]
    {:ok, reader} = ReaderSelection.new(i["installed"], i["capture"], i["reader_limits"])
    records = read_records("temperature")
    [first | rest] = records

    for bad <- [
          rest,
          [Map.put(first, "payload", first["payload"] <> "x") | rest],
          [put_in(first, ["object", "payload_sha256"], String.duplicate("0", 64)) | rest],
          [Map.put(first, "extra", true) | rest],
          records ++ [first],
          Enum.reverse(records)
        ] do
      assert {:error, :invalid_external_inspection} =
               InspectionPreparation.build(v["input"], bad, reader)
    end

    assert {:error, :stale_external_reference} =
             InspectionPreparation.build(
               v["input"],
               [Map.put(first, "first_revision", 4) | rest],
               reader
             )

    assert {:error, :stale_external_basis} =
             InspectionPreparation.build(
               put_in(
                 v["input"],
                 ["inspection", "reader_basis_sha256"],
                 String.duplicate("0", 64)
               ),
               records,
               reader
             )

    assert {:error, :external_profile_limit} =
             InspectionPreparation.build(v["input"], List.duplicate(first, 35), reader)

    assert {:error, :external_profile_limit} =
             InspectionPreparation.build(
               v["input"],
               [Map.put(first, "payload", String.duplicate("x", 65537)) | rest],
               reader
             )

    excess =
      for n <- 1..6 do
        digest = String.pad_leading(Integer.to_string(n, 16), 64, "0")

        first
        |> put_in(["object", "object_digest"], digest)
        |> Map.put("payload", String.duplicate("x", 65536))
      end

    # This must refuse the aggregate before hashing these deliberately unproven payloads.
    assert {:error, :external_profile_limit} =
             InspectionPreparation.build(v["input"], excess, reader)

    assert {:error, :invalid_external_closure} =
             InspectionPreparation.build(
               put_in(
                 v["input"],
                 ["inspection", "profile", "reference", "sha256"],
                 String.duplicate("0", 64)
               ),
               records,
               reader
             )
  end

  test "independent checked reader basis retains only capture identities and installed references" do
    v = fixture()
    i = v["reader_inputs"]
    assert {:ok, reader} = ReaderSelection.new(i["installed"], i["capture"], i["reader_limits"])
    assert reader.data == v["reader_summary"]
    assert {:ok, data} = ReaderSelection.to_map(reader)
    assert data == v["reader_summary"]
    refute inspect(data) =~ "synthetic-industrial"
    refute Map.has_key?(data, "fields") or Map.has_key?(data, "selector_schema")

    schema =
      ExJsonSchema.Schema.resolve(
        JSON.decode!(File.read!("fixtures/external-inspection.schema.json"))
      )

    assert :ok = ExJsonSchema.Validator.validate(schema, v["input"])
    assert {:ok, bytes} = ExternalInspection.encode_result(v["result"])
    assert bytes == v["result_document"]
  end

  test "reader bindings, captured digest and complete native fields must revalidate" do
    v = fixture()["reader_inputs"]
    {:ok, reader} = ReaderSelection.new(v["installed"], v["capture"], v["reader_limits"])

    for invalid <- [
          Map.put(reader, :extra, true),
          %{reader | data: Map.put(reader.data, "basis_sha256", String.duplicate("0", 64))}
        ] do
      assert {:error, :invalid_external_reader} = ReaderSelection.to_map(invalid)
    end

    for installed <- [
          Map.put(v["installed"], "extra", true),
          Map.put(v["installed"], "bindings", []),
          put_in(v["installed"], ["bindings", Access.at(0), "sha256"], String.duplicate("0", 64))
        ] do
      assert {:error, :invalid_external_reader} =
               ReaderSelection.new(installed, v["capture"], v["reader_limits"])
    end

    for capture <- [
          Map.put(v["capture"], "digest", String.duplicate("0", 64)),
          put_in(v["capture"], ["binding", "sha256"], String.duplicate("0", 64)),
          Map.put(v["capture"], "fields", %{})
        ] do
      assert {:error, :invalid_external_reader} =
               ReaderSelection.new(v["installed"], capture, v["reader_limits"])
    end
  end

  test "reader bounds stop before public registration and malformed native lists are refused" do
    v = fixture()["reader_inputs"]
    [binding] = v["installed"]["bindings"]

    assert {:error, :external_profile_limit} =
             ReaderSelection.new(
               Map.put(v["installed"], "bindings", List.duplicate(binding, 33)),
               v["capture"],
               v["reader_limits"]
             )

    assert {:error, :invalid_external_reader} =
             ReaderSelection.new(
               Map.put(v["installed"], "bindings", [binding | :bad]),
               v["capture"],
               v["reader_limits"]
             )

    assert {:error, :external_profile_limit} =
             ReaderSelection.new(
               v["installed"],
               v["capture"],
               Map.put(v["reader_limits"], "max_channels", 33)
             )

    assert {:error, :invalid_external_reader} =
             ReaderSelection.new(
               v["installed"],
               v["capture"],
               Map.delete(v["reader_limits"], "max_channels")
             )

    capture = put_in(v["capture"], ["fields", "model", "value"], String.duplicate("x", 4097))

    assert {:error, :external_profile_limit} =
             ReaderSelection.new(v["installed"], capture, v["reader_limits"])
  end

  test "changed trusted archive, limits or accepted references create a distinct reader basis" do
    v = fixture()["reader_inputs"]
    {:ok, reader} = ReaderSelection.new(v["installed"], v["capture"], v["reader_limits"])

    for {installed, limits} <- [
          {put_in(v["installed"], ["producer", "core_archive_sha256"], String.duplicate("0", 64)),
           v["reader_limits"]},
          {v["installed"], Map.put(v["reader_limits"], "max_numeric_digits", 63)},
          {Map.put(v["installed"], "home_contracts", []), v["reader_limits"]}
        ] do
      assert {:ok, changed} = ReaderSelection.new(installed, v["capture"], limits)
      assert changed.data["basis_sha256"] != reader.data["basis_sha256"]
      assert {:ok, _} = ReaderSelection.to_map(changed)
    end
  end
end
