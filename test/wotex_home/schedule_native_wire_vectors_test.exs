defmodule WotexHome.ScheduleNativeWireVectorsTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Codec, OperationInput}
  @path Path.expand("../fixtures/schedules/native_wire_vectors.json", __DIR__)

  test "independently authored native originals preserve canonical core source and digest joins" do
    bytes = File.read!(@path)
    assert byte_size(bytes) <= 65_536
    corpus = JSON.decode!(bytes)
    assert Enum.sort(Map.keys(corpus)) == ~w(format refusals scope vectors)
    assert corpus["format"] == "wotex-home.native-schedule-input-vectors.v1"
    assert corpus["scope"] == "inert_schedule_input_correspondence"
    assert length(corpus["vectors"]) == 15
    ids = Enum.map(corpus["vectors"], & &1["id"])
    assert length(Enum.uniq(ids)) == length(ids)

    for vector <- corpus["vectors"] do
      assert Enum.sort(Map.keys(vector)) == ~w(digest document id)
      assert vector["id"] =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/
      assert {:ok, kind, input} = OperationInput.decode(vector["document"])
      assert {:ok, document} = OperationInput.encode(kind, input)
      assert document == vector["document"]
      assert Codec.hash(document) == vector["digest"]

      if kind in ["review", "admit"] do
        assert {:ok, source, rule} = OperationInput.source(kind, input)
        assert source["author_id"] == "operator:one"
        assert elem(rule.effect, 0) == source["target_id"]
        assert source["rule_source_digest"] == Codec.hash(input["rule_document"])
      end
    end
  end

  test "native refusal corpus also refuses actual core alternate shapes and effect grammar" do
    corpus = @path |> File.read!() |> JSON.decode!()
    assert length(corpus["refusals"]) in 1..128

    for document <- corpus["refusals"] do
      assert {:error, :invalid_schedule_operation} = OperationInput.decode(document)
    end
  end
end
