defmodule WotexHome.LifxProductRegistryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Lifx.ProductRegistry

  @defaults %{
    "hev" => false,
    "color" => false,
    "chain" => false,
    "matrix" => false,
    "relays" => false,
    "buttons" => false,
    "infrared" => false,
    "multizone" => false,
    "temperature_range" => nil,
    "extended_multizone" => false
  }

  test "pinned exact vendor/product metadata applies ordered firmware upgrades" do
    bytes = fixture()
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert {:ok, registry} = ProductRegistry.new(bytes, digest)

    assert {:ok, before} = ProductRegistry.lookup(registry, 1, 27, 2, 79)
    assert before.features["temperature_range"] == [2_500, 9_000]
    assert before.features["color"] == true

    assert {:ok, after_upgrade} = ProductRegistry.lookup(registry, 1, 27, 2, 80)
    assert after_upgrade.features["temperature_range"] == [1_500, 9_000]
    assert after_upgrade.registry_digest == digest

    assert {:ok, later_major} = ProductRegistry.lookup(registry, 1, 27, 3, 0)
    assert later_major.features["temperature_range"] == [1_500, 9_000]
    assert {:error, :unknown_product} = ProductRegistry.lookup(registry, 1, 999, 2, 80)
    assert {:error, :invalid_product_identity} = ProductRegistry.lookup(registry, 1, 27, -1, 0)
  end

  test "digest mismatch, duplicate members and duplicate product IDs fail closed" do
    bytes = fixture()

    assert {:error, :registry_digest_mismatch} =
             ProductRegistry.new(bytes, String.duplicate("0", 64))

    duplicate_member = "[{\"vid\":1,\"vid\":2}]"
    digest = :crypto.hash(:sha256, duplicate_member) |> Base.encode16(case: :lower)
    assert {:error, :invalid_registry} = ProductRegistry.new(duplicate_member, digest)

    [vendor] = JSON.decode!(bytes)
    malformed = JSON.encode!([%{vendor | "products" => vendor["products"] ++ vendor["products"]}])
    malformed_digest = :crypto.hash(:sha256, malformed) |> Base.encode16(case: :lower)
    assert {:error, :invalid_registry} = ProductRegistry.new(malformed, malformed_digest)
  end

  defp fixture do
    JSON.encode!([
      %{
        "vid" => 1,
        "name" => "LIFX",
        "defaults" => @defaults,
        "products" => [
          %{
            "pid" => 27,
            "name" => "Example A19",
            "features" => %{"color" => true, "temperature_range" => [2_500, 9_000]},
            "upgrades" => [
              %{
                "major" => 2,
                "minor" => 80,
                "features" => %{"temperature_range" => [1_500, 9_000]}
              }
            ]
          }
        ]
      }
    ])
  end
end
