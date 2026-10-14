defmodule WotexHome.AuthoringUnavailableTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.AuthoringContract

  test "ordinary producer is available while malformed installation remains rejected" do
    assert Code.ensure_loaded?(Wotex.Profiles.Contract)
    vectors = JSON.decode!(File.read!("test/fixtures/profiles/authoring-mechanics.json"))
    v = JSON.decode!(File.read!("test/fixtures/profiles/temperature.json"))

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", v["expected"]["producer"])

    assert {:ok, contract} =
             AuthoringContract.export(installed, vectors["temperature"]["limits"])

    assert {:ok, _} = AuthoringContract.to_map(contract)

    assert {:error, :invalid_authoring_contract} = AuthoringContract.export(%{}, %{})
  end
end
