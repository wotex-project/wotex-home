defmodule HomeReaderArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Profiles.{
    ExternalApprovalPreparation,
    ExternalInspection,
    ExternalSourceSelection,
    InspectionPreparation,
    ReaderSelection
  }

  defp fixture, do: JSON.decode!(File.read!("fixtures/external-inspections.json"))["temperature"]

  defp source_vector(family),
    do: JSON.decode!(File.read!("fixtures/external-source-selections.json"))[family]

  defp source_reader(v) do
    i = v["inputs"]["reader"]
    {:ok, reader} = ReaderSelection.new(i["installed"], i["capture"], i["reader_limits"])
    reader
  end

  for family <- ~w(temperature research multi) do
    @source_family family
    test "#{@source_family} explicit source selection matches independent identity and safe summary" do
      v = source_vector(@source_family)
      reader = source_reader(v)
      i = v["inputs"]
      assert {:ok, value} = ExternalSourceSelection.new(i["source"], reader, i["channels"])
      assert value.data == v["data"] and value.sha256 == v["sha256"]
      assert {:ok, exported} = ExternalSourceSelection.to_map(value)
      assert exported == %{"data" => v["data"], "sha256" => v["sha256"]}

      for field <- ~w(stable_id channels consumer policy capture inputs reader) do
        refute Map.has_key?(value.data, field)
      end

      for forged <- [
            Map.put(value, :extra, true),
            Map.put(value, :sha256, String.duplicate("0", 64)),
            put_in(value.data["trust"], "authenticated_device"),
            put_in(value.inputs["source"]["source_generation"], 2)
          ] do
        assert {:error, :invalid_external_source} = ExternalSourceSelection.to_map(forged)
      end

      for {field, new} <- [
            {"stable_id", "fixture:other"},
            {"source_epoch", String.duplicate("f", 32)},
            {"source_generation", 2},
            {"trust", "unauthenticated_local"},
            {"method", "legacy_tofu"}
          ] do
        assert {:ok, changed} =
                 ExternalSourceSelection.new(
                   Map.put(i["source"], field, new),
                   reader,
                   i["channels"]
                 )

        refute changed.sha256 == value.sha256
      end

      channels = update_in(i["channels"], [Access.at(0), "policy", "freshness_ms"], &(&1 + 1))
      assert {:ok, changed} = ExternalSourceSelection.new(i["source"], reader, channels)
      refute changed.sha256 == value.sha256

      consumer_change =
        put_in(
          i["channels"],
          [Access.at(0), "consumer", "constraints", "max"],
          9_223_372_036_854_775_806
        )

      assert {:ok, changed} = ExternalSourceSelection.new(i["source"], reader, consumer_change)
      refute changed.sha256 == value.sha256

      capture = Map.put(reader.inputs["capture"], "capture_epoch", String.duplicate("d", 32))

      {:ok, digest} =
        Wotex.Profiles.Capture.digest(
          Map.delete(capture, "digest"),
          hd(reader.inputs["installed"]["bindings"]),
          reader.inputs["reader_limits"]
        )

      {:ok, recaptured} =
        ReaderSelection.new(
          reader.inputs["installed"],
          Map.put(capture, "digest", digest),
          reader.inputs["reader_limits"]
        )

      assert {:ok, changed} = ExternalSourceSelection.new(i["source"], recaptured, i["channels"])
      refute changed.sha256 == value.sha256
    end
  end

  test "source input, policy ordering, uninstalled consumers and aggregate resources are closed" do
    v = source_vector("multi")
    reader = source_reader(v)
    i = v["inputs"]

    for source <- [
          Map.put(i["source"], "extra", true),
          Map.put(i["source"], "stable_id", "bad/id"),
          Map.put(i["source"], "source_generation", 0),
          Map.put(i["source"], "source_epoch", String.duplicate("g", 32)),
          Map.put(i["source"], "trust", "trusted")
        ] do
      assert {:error, :invalid_external_source} =
               ExternalSourceSelection.new(source, reader, i["channels"])
    end

    for channels <- [
          [],
          Enum.reverse(i["channels"]),
          i["channels"] ++ [hd(i["channels"])],
          put_in(i["channels"], [Access.at(0), "policy", "risk_class"], "trusted"),
          put_in(i["channels"], [Access.at(0), "policy", "freshness_ms"], 86_400_001),
          put_in(i["channels"], [Access.at(0), "policy", "capability_key"], "sample")
        ] do
      assert {:error, :invalid_external_source} =
               ExternalSourceSelection.new(i["source"], reader, channels)
    end

    channels =
      put_in(
        i["channels"],
        [Access.at(0), "consumer", "reference", "sha256"],
        String.duplicate("0", 64)
      )

    assert {:error, :unsupported_external_source} =
             ExternalSourceSelection.new(i["source"], reader, channels)

    assert {:error, :external_profile_limit} =
             ExternalSourceSelection.new(
               i["source"],
               reader,
               List.duplicate(hd(i["channels"]), 33)
             )

    huge =
      put_in(i["channels"], [Access.at(0), "consumer", "oversized"], String.duplicate("x", 4097))

    assert {:error, :external_profile_limit} =
             ExternalSourceSelection.new(i["source"], reader, huge)
  end

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

  test "current byte preparation reproduces independent artifact identity without conferring approval" do
    for family <- ~w(temperature research) do
      v = JSON.decode!(File.read!("fixtures/external-inspections.json"))[family]
      expected = JSON.decode!(File.read!("fixtures/external-trust.json"))[family]
      i = v["reader_inputs"]
      {:ok, reader} = ReaderSelection.new(i["installed"], i["capture"], i["reader_limits"])

      assert {:ok, prepared} =
               ExternalApprovalPreparation.build(v["input"], read_records(family), reader)

      assert prepared["artifact"] == expected["artifact"]
      assert prepared["artifact_digest"] == expected["artifact_digest"]
      assert prepared["inspection"] == v["result"]
      refute Map.has_key?(prepared, "approved") or Map.has_key?(prepared, "credential")

      other_input =
        v["input"]
        |> Map.put("expected_revision", 103)
        |> update_in(["inspection", "envelope_ref", "first_revision"], &(&1 + 100))
        |> update_in(["inspection", "profile", "object_ref", "first_revision"], &(&1 + 100))
        |> update_in(
          ["inspection", "definitions"],
          &Enum.map(&1, fn d ->
            update_in(d, ["object_ref", "first_revision"], fn r -> r + 100 end)
          end)
        )

      other_records =
        Enum.map(read_records(family), &Map.update!(&1, "first_revision", fn r -> r + 100 end))

      assert {:ok, other} = ExternalApprovalPreparation.build(other_input, other_records, reader)
      assert other["artifact_digest"] == prepared["artifact_digest"]
    end
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
