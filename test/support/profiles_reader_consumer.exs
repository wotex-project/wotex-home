defmodule HomeReaderArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{ExternalInspection, ReaderSelection}
  defp fixture, do: JSON.decode!(File.read!("fixtures/external-inspections.json"))["temperature"]

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
