defmodule WotexHome.Profiles.AuthoringObjectTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.AuthoringObject

  test "independent binary/digest vectors preserve originals and separate kind identities" do
    corpus =
      __DIR__
      |> Path.join("../fixtures/profiles/authoring-objects.json")
      |> File.read!()
      |> JSON.decode!()

    for v <- corpus["vectors"] do
      assert {:ok, object} = AuthoringObject.new(v["kind"], v["payload"])
      assert Base.encode16(object.bytes, case: :lower) == v["frame_hex"]
      assert object.digest == v["object_digest"]
      assert object.payload_sha256 == v["payload_sha256"]
      assert {:ok, ^object} = AuthoringObject.parse(object.bytes)
      assert {:ok, summary} = AuthoringObject.summary(object)
      assert summary == Map.take(v, ~w(kind object_digest payload_sha256 payload_bytes))
      assert AuthoringObject.valid_summary?(summary)
    end

    [source, draft | _] = corpus["vectors"]
    assert source["payload_sha256"] == draft["payload_sha256"]
    refute source["object_digest"] == draft["object_digest"]
  end

  test "each installed kind accepts its exact byte boundary and refuses one byte more" do
    for {kind, maximum} <- [
          {"source", 262_144},
          {"draft", 262_144},
          {"bundle", 262_144},
          {"fixture", 65_536},
          {"contract", 262_144},
          {"envelope", 65_536},
          {"profile", 65_536},
          {"definition", 65_536}
        ] do
      assert {:ok, value} = AuthoringObject.new(kind, :binary.copy(<<255>>, maximum))
      assert {:ok, ^value} = AuthoringObject.parse(value.bytes)

      assert {:error, :invalid_authoring_object} =
               AuthoringObject.new(kind, :binary.copy(<<255>>, maximum + 1))
    end

    for {kind, bytes} <- [
          {"source", ""},
          {"unknown", "x"},
          {String.duplicate("x", 100_000), "x"},
          {%URI{}, "x"},
          {"source", %URI{}}
        ] do
      assert {:error, :invalid_authoring_object} = AuthoringObject.new(kind, bytes)
    end
  end

  test "wrong version, tag, size, checksum, trailing bytes and forged native fields refuse" do
    {:ok, object} = AuthoringObject.new("source", "secret-canary")
    <<"WOHA", 1, tag, length::32, digest::binary-size(32), payload::binary>> = object.bytes

    for bytes <- [
          <<"WOHA", 2, tag, length::32, digest::binary, payload::binary>>,
          <<"WOHA", 1, 255, length::32, digest::binary, payload::binary>>,
          <<"WOHA", 1, tag, 1::32, digest::binary, payload::binary>>,
          <<"WOHA", 1, tag, length::32, 0::256, payload::binary>>,
          object.bytes <> "x",
          "{}",
          %URI{}
        ] do
      assert {:error, :invalid_authoring_object} = AuthoringObject.parse(bytes)
    end

    for bad <- [
          %{object | digest: String.duplicate("0", 64)},
          %{object | kind: "draft"},
          %{object | payload: "other"},
          %{object | payload_sha256: digest},
          Map.put(object, :extra, "secret-canary"),
          %URI{}
        ] do
      assert {:error, :invalid_authoring_object} = AuthoringObject.summary(bad)
    end

    {:ok, summary} = AuthoringObject.summary(object)

    for bad <- [
          Map.put(summary, "extra", true),
          Map.put(summary, "payload_bytes", 0),
          Map.put(summary, "kind", %URI{}),
          Map.put(summary, "object_digest", "bad"),
          %URI{}
        ] do
      refute AuthoringObject.valid_summary?(bad)
    end
  end
end
