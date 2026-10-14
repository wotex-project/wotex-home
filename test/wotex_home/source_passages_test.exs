defmodule WotexHome.SourcePassagesTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringObject, SourcePassages}

  defp source(payload, kind \\ "source") do
    {:ok, object} = AuthoringObject.new(kind, payload)
    {:ok, summary} = AuthoringObject.summary(object)
    %{"object" => summary, "payload" => payload, "first_revision" => 7}
  end

  defp selector(source, offset, size),
    do: %{
      "source_ref" => source["object"]["object_digest"],
      "offset" => offset,
      "length" => size
    }

  test "independent UTF-8 byte-range identities retain exact inert text" do
    v = JSON.decode!(File.read!("test/fixtures/profiles/source-passages.json"))
    s = source(v["source"])
    assert s["object"] == v["object"]
    assert {:ok, passages} = SourcePassages.select(v["selectors"], [s])
    assert passages == v["expected"]
    assert Enum.any?(passages, &String.contains?(&1["text"], "Ignore previous instructions"))
    refute Map.has_key?(hd(passages), "payload")
  end

  test "ranges cannot split UTF-8, run off the original or normalize controls" do
    s = source("μ\n\tZ\r\0" <> <<255>>)
    assert {:ok, [%{"text" => "μ\n\tZ"}]} = SourcePassages.select([selector(s, 0, 5)], [s])

    for {offset, size} <- [{0, 1}, {1, 1}, {5, 1}, {6, 1}, {7, 1}, {8, 1}, {0, 9}] do
      assert {:error, :invalid_source_passage} =
               SourcePassages.select([selector(s, offset, size)], [s])
    end

    s = source("ok" <> <<0xC2, 0x85>>)
    assert {:error, :invalid_source_passage} = SourcePassages.select([selector(s, 2, 2)], [s])
  end

  test "proper closed selector lists preserve ordering and exact limits" do
    s = source(String.duplicate("x", 4096))
    sel = selector(s, 0, 4096)
    assert {:ok, [%{"length" => 4096}]} = SourcePassages.select([sel], [s])
    selectors = Enum.map(0..31, &selector(s, &1, 1))
    assert {:ok, passages} = SourcePassages.select(selectors, [s])
    assert length(passages) == 32

    assert {:error, :authoring_limit} =
             SourcePassages.select(selectors ++ [selector(s, 32, 1)], [s])

    assert {:error, :authoring_limit} = SourcePassages.select([selector(s, 0, 4097)], [s])

    for data <- [
          [],
          [sel | :bad],
          [sel, sel],
          Enum.reverse(selectors),
          [Map.put(sel, "unknown", "secret")],
          [Map.put(sel, "source_ref", "../secret")],
          [selector(s, -1, 1)],
          [selector(s, 0.0, 1)],
          [selector(s, 0, 0)],
          [selector(s, 262_145, 1)]
        ] do
      assert {:error, :invalid_source_passage} = SourcePassages.select(data, [s])
    end
  end

  test "exact complete source records prove raw and framed identity before projection" do
    s = source("original")
    sel = selector(s, 0, 8)

    for changed <- [
          Map.put(s, "payload", "changed!"),
          Map.put(s, "first_revision", 0),
          put_in(s, ["object", "payload_sha256"], String.duplicate("0", 64)),
          put_in(s, ["object", "object_digest"], String.duplicate("0", 64)),
          Map.put(s, "extra", "secret")
        ] do
      assert {:error, :invalid_authoring_source} = SourcePassages.select([sel], [changed])
    end

    for records <- [[], [s, s], [s | :bad], List.duplicate(s, 33)] do
      assert {:error, :invalid_authoring_source} = SourcePassages.select([sel], records)
    end

    draft = source("original", "draft")

    assert {:error, :invalid_authoring_source} =
             SourcePassages.select([selector(draft, 0, 8)], [draft])

    extra = source("unrequested")
    records = Enum.sort_by([s, extra], & &1["object"]["object_digest"])
    assert {:error, :invalid_authoring_source} = SourcePassages.select([sel], records)
  end

  test "overlapping passages consume their full byte budget and source frames include every header" do
    s = source(String.duplicate("x", 4127))
    selectors = Enum.map(0..31, &selector(s, &1, 4096))
    assert {:ok, passages} = SourcePassages.select(selectors, [s])
    assert Enum.reduce(passages, 0, &(&1["length"] + &2)) == 131_072

    sources =
      for index <- 1..16 do
        prefix = Integer.to_string(index)
        source(prefix <> String.duplicate("x", 262_102 - byte_size(prefix)))
      end

    sources = Enum.sort_by(sources, & &1["object"]["object_digest"])
    selectors = Enum.map(sources, &selector(&1, 0, 1))
    assert {:ok, passages} = SourcePassages.select(selectors, sources)
    assert length(passages) == 16
    extra = source("one extra byte")
    sources = Enum.sort_by([extra | sources], & &1["object"]["object_digest"])
    selectors = Enum.map(sources, &selector(&1, 0, 1))
    assert {:error, :invalid_authoring_source} = SourcePassages.select(selectors, sources)
  end
end
