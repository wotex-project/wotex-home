defmodule WotexHome.ControllerPairingConsumptionCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.ControllerConnections.ConsumptionCodec
  @fixture Path.expand("../fixtures/controller_connections/consumption_vectors.json", __DIR__)
  @corpus JSON.decode!(File.read!(@fixture))

  for vector <- @corpus["valid"] do
    test "independent consumption #{vector["name"]}" do
      v = unquote(Macro.escape(vector))
      assert ConsumptionCodec.decode(v["wire"]) == {:ok, v["value"]}
      assert ConsumptionCodec.encode(v["value"]) == {:ok, v["wire"]}
      assert ConsumptionCodec.principal(v["value"]["approval"]) == v["value"]["principal_id"]
      assert ConsumptionCodec.reserved?(v["value"]["principal_id"])
    end
  end

  for {vector, n} <- Enum.with_index(@corpus["invalid"]) do
    test "independent consumption refusal #{n} #{vector["name"]}" do
      v = unquote(Macro.escape(vector))

      assert ConsumptionCodec.decode(v["wire"]) ==
               {:error, :invalid_controller_pairing_consumption}
    end
  end

  test "malformed encoder terms and secret fields refuse" do
    v = hd(@corpus["valid"])["value"]

    for term <- [
          nil,
          true,
          [],
          %{},
          %URI{},
          Map.put(v, "credential", "secret"),
          Map.put(v, "approval", nil)
        ] do
      assert ConsumptionCodec.encode(term) == {:error, :invalid_controller_pairing_consumption}
    end

    for term <- [nil, <<255>>, String.duplicate("[", 8_192)] do
      assert ConsumptionCodec.decode(term) == {:error, :invalid_controller_pairing_consumption}
    end

    lookup = Map.take(v["approval"], ConsumptionCodec.original_fields())
    assert ConsumptionCodec.lookup?(lookup)
    refute ConsumptionCodec.lookup?(Map.put(lookup, "credential", "secret"))
    refute ConsumptionCodec.lookup?(Map.put(lookup, "client_id", "client"))
    refute ConsumptionCodec.reserved?(nil)
    refute ConsumptionCodec.reserved?("operator:one")
  end
end
