defmodule WotexHome.RoutineExternalFactSchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  setup_all do
    vector = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-facts.json"))
    raw = JSON.decode!(File.read!("priv/profiles/routine-external-fact.schema.json"))
    %{vector: vector, raw: raw, schema: ExJsonSchema.Schema.resolve(raw)}
  end

  test "the frozen original reader, Home value and routine result have distinct exact coordinates",
       c do
    assert c.vector["proposal"]["normalized_value"] == %{
             "type" => "decimal",
             "coefficient" => "25",
             "exponent" => -1
           }

    assert c.vector["home_value_data"]["normalized_value"] == %{
             "type" => "sint",
             "value" => "2500"
           }

    result = c.vector["expected_result"]
    assert result["fact"]["value"] == 250
    assert result["fact"]["received_at"] == nil
    assert result["fact"]["receipt_ms"] == 9998
    assert result["fact"]["expires_ms"] == 10_998

    assert result["source_proposal_sha256"] ==
             hash("wotex.routines.input-proposal@1", c.vector["proposal"])

    assert result["external_value_sha256"] ==
             hash("wotex-home.external-value@1", c.vector["home_value_data"])

    assert :ok = ExJsonSchema.Validator.validate(c.schema, result)
  end

  test "the Home envelope is closed and has no current authority or manufactured receive UTC",
       c do
    result = c.vector["expected_result"]

    for changed <- [
          Map.delete(result, "scope"),
          Map.put(result, "current", true),
          Map.put(result, "scope", "admitted_fact"),
          put_in(result, ["fact", "received_at"], "2026-10-15T00:00:00Z"),
          update_in(result, ["fact"], &Map.delete(&1, "received_at")),
          put_in(result, ["binding_basis", "extra"], true),
          update_in(result, ["binding_basis"], &Map.delete(&1, "input_mapping"))
        ] do
      refute ExJsonSchema.Validator.valid?(c.schema, changed)
    end
  end

  test "every embedded schema reference resolves offline", c do
    assert local_refs?(c.raw)

    assert c.raw["definitions"]["external_binding"]["properties"]["input_mapping"] ==
             %{"$ref" => "#/definitions/input_mapping"}
  end

  defp hash(prefix, value) do
    {:ok, bytes} = Wotex.JSON.encode(value)
    Base.encode16(:crypto.hash(:sha256, prefix <> "\n" <> bytes), case: :lower)
  end

  defp local_refs?(data) when is_map(data) do
    (not Map.has_key?(data, "$ref") or String.starts_with?(data["$ref"], "#/definitions/")) and
      Enum.all?(Map.values(data), &local_refs?/1)
  end

  defp local_refs?(data) when is_list(data), do: Enum.all?(data, &local_refs?/1)
  defp local_refs?(_), do: true
end
