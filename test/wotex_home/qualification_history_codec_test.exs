defmodule WotexHome.QualificationHistoryCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.ProfileCatalogue
  alias WotexHome.Qualification.HistoryCodec

  setup do
    {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:fixture")
    {:ok, document} = Registry.encode_thing(package.thing)

    row = %{
      "thing_id" => package.thing.id,
      "profile_ref" => package.thing.profile_ref,
      "resource_revision" => 0,
      "identity_digest" => String.duplicate("a", 64),
      "basis_digest" => String.duplicate("b", 64),
      "registry_digest" => String.duplicate("c", 64),
      "runtime_digest" => String.duplicate("d", 64),
      "evidence_ref" => "qualification:" <> String.duplicate("e", 64),
      "revision" => 9,
      "provenance" => "guarded_current",
      "declaration_document" => document,
      "principal_id" => "qualifier:fixture",
      "authority_epoch" => 1,
      "binding_revision" => 2
    }

    %{row: row}
  end

  test "the ordered encoding commits exact historical identities and declaration", c do
    assert {:ok, document} = HistoryCodec.encode(c.row)
    assert ["wotex-home.qualification-history.v1", values] = JSON.decode!(document)
    assert values == Enum.map(HistoryCodec.fields(), &c.row[&1])
    assert {:ok, c.row} == HistoryCodec.decode(document)
    assert {:error, :invalid_qualification_history} = HistoryCodec.decode(document <> " ")
  end

  test "migration preserves unknown provenance without manufacturing current authority", c do
    legacy =
      Map.merge(c.row, %{
        "provenance" => "legacy_migrated",
        "declaration_document" => nil,
        "principal_id" => nil,
        "authority_epoch" => nil,
        "binding_revision" => nil
      })

    assert {:ok, document} = HistoryCodec.encode(legacy)
    assert {:ok, ^legacy} = HistoryCodec.decode(document)

    for key <- ~w(declaration_document principal_id authority_epoch binding_revision) do
      assert {:error, :invalid_qualification_history} =
               HistoryCodec.encode(Map.put(legacy, key, c.row[key]))

      assert {:error, :invalid_qualification_history} =
               HistoryCodec.encode(Map.put(c.row, key, nil))
    end
  end

  test "closed fields, digest syntax, epoch and historical ordering fail closed", c do
    assert {:error, :invalid_qualification_history} =
             HistoryCodec.encode(Map.put(c.row, "status", "qualified"))

    for {key, value} <- [
          {"identity_digest", String.duplicate("A", 64)},
          {"revision", 0},
          {"authority_epoch", 0},
          {"binding_revision", 9},
          {"resource_revision", -1},
          {"principal_id", ""},
          {"provenance", "restored_current"}
        ] do
      assert {:error, :invalid_qualification_history} =
               HistoryCodec.encode(Map.put(c.row, key, value))
    end
  end

  test "a different Thing or profile cannot be paired with the declaration", c do
    for key <- ~w(thing_id profile_ref) do
      assert {:error, :invalid_qualification_history} =
               HistoryCodec.encode(Map.put(c.row, key, "other:fixture"))
    end
  end
end
