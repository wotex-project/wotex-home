defmodule WotexHome.AuthoringUnavailableTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.AuthoringContract

  test "absent producer has no replacement validator or ambient grammar" do
    refute Code.ensure_loaded?(Wotex.Profiles.Contract)
    vectors = JSON.decode!(File.read!("test/fixtures/profiles/authoring-mechanics.json"))
    v = JSON.decode!(File.read!("test/fixtures/profiles/temperature.json"))

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", v["expected"]["producer"])

    assert {:error, :profiles_producer_unavailable} =
             AuthoringContract.export(installed, vectors["temperature"]["limits"])

    assert {:error, :invalid_authoring_contract} = AuthoringContract.export(%{}, %{})
  end
end
