defmodule WotexHome.Profiles.AuthoringArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringArchive, AuthoringObject}

  defp item(kind, payload) do
    {:ok, object} = AuthoringObject.new(kind, payload)
    {:ok, summary} = AuthoringObject.summary(object)
    Map.put(summary, "bytes", object.bytes)
  end

  test "exact sorted tagged bytes round trip beside the unchanged legacy archive frame" do
    tagged =
      [item("source", "original"), item("draft", "original")]
      |> Enum.sort_by(& &1["object_digest"])

    assert {:ok, encoded} = AuthoringArchive.encode("fixture database", [], tagged)
    assert {:ok, "fixture database", objects} = AuthoringArchive.decode(encoded)
    assert Enum.all?(objects, &AuthoringArchive.tagged?/1)

    assert Enum.map(objects, &AuthoringArchive.summary/1) ==
             Enum.map(tagged, &Map.delete(&1, "bytes"))

    assert Enum.map(objects, & &1.bytes) == Enum.map(tagged, & &1["bytes"])
    assert {:error, :invalid_authoring_archive} = AuthoringArchive.decode(encoded <> "trailing")

    assert {:error, :invalid_authoring_archive} =
             AuthoringArchive.decode(binary_part(encoded, 0, byte_size(encoded) - 1))
  end

  test "duplicate, forged, unordered, improper and over-budget frames refuse before output" do
    first = item("source", "original")
    second = item("draft", "other")
    ordered = Enum.sort_by([first, second], & &1["object_digest"])

    for bad <- [
          [first, first],
          Enum.reverse(ordered),
          [Map.put(first, "object_digest", String.duplicate("0", 64))],
          [Map.put(first, "bytes", "bad")],
          [first | :bad],
          List.duplicate(first, 129),
          %URI{}
        ] do
      assert {:error, :invalid_authoring_archive} =
               AuthoringArchive.encode("fixture database", [], bad)
    end

    large = for value <- 1..17, do: item("source", :binary.copy(<<value>>, 262_144))
    large = Enum.sort_by(large, & &1["object_digest"])

    assert {:error, :invalid_authoring_archive} =
             AuthoringArchive.encode("fixture database", [], large)

    for bad <- [nil, "", <<1::32>>, :binary.copy(<<0>>, AuthoringArchive.max_bytes() + 1)] do
      assert {:error, :invalid_authoring_archive} = AuthoringArchive.decode(bad)
    end
  end
end
