defmodule WotexHome.Profiles.EnvelopeCodecTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{EnvelopeCodec, ExternalEnvelope}

  defp fixture do
    __DIR__
    |> Path.join("../fixtures/profiles/temperature.json")
    |> File.read!()
    |> JSON.decode!()
  end

  test "the independently authored closed envelope round trips without profile interpretation" do
    envelope = fixture()["envelope"]
    assert {:ok, ^envelope} = EnvelopeCodec.decode(JSON.encode!(envelope))
    assert EnvelopeCodec.reference?(envelope["profile"])
    assert EnvelopeCodec.references?(envelope["definitions"])
    refute EnvelopeCodec.references?(envelope["definitions"] ++ envelope["definitions"])
    refute EnvelopeCodec.reference?(Map.put(envelope["profile"], "version", "65536.0.0"))
    refute EnvelopeCodec.reference?(Map.put(envelope["profile"], "id", "relative"))
  end

  test "duplicates, hidden numbers, controls, oversized strings and unknown fields fail closed" do
    data = fixture()["envelope"]
    bytes = JSON.encode!(data)

    repeated_key = "\"format\":\"wotex-home.portable-profile.v2\",\"format\":"
    duplicate = String.replace(bytes, "\"format\":", repeated_key, global: false)

    for bad <- [
          duplicate,
          "{",
          "true",
          "[]",
          <<255>>,
          JSON.encode!(Map.put(data, "private-canary", "secret-canary")),
          JSON.encode!(Map.put(data, "id", 1)),
          JSON.encode!(Map.put(data, "id", 1.1)),
          JSON.encode!(put_in(data, ["provenance", "source"], "private\u0000canary")),
          JSON.encode!(put_in(data, ["profile", "version"], "01.0.0")),
          JSON.encode!(Map.put(data, "home_contracts", [%{}]))
        ] do
      assert {:error, :invalid_external_envelope} = EnvelopeCodec.decode(bad)
    end
  end

  test "decoder depth and cumulative node bounds refuse before shape construction" do
    refute EnvelopeCodec.references?(nil)
    refute EnvelopeCodec.key?("private/route")
    refute EnvelopeCodec.text?("bad\u0000text", 256)
    refute EnvelopeCodec.digest?("bad")
    refute EnvelopeCodec.bounded_list?([1 | :bad])
    refute EnvelopeCodec.references?([1 | :bad])
    data = fixture()["envelope"]

    for large <- [
          String.duplicate(" ", 65_537),
          JSON.encode!(Map.put(data, "id", String.duplicate("x", 257))),
          JSON.encode!(Map.put(data, "definitions", List.duplicate(hd(data["definitions"]), 33)))
        ] do
      assert {:error, :external_profile_limit} = EnvelopeCodec.decode(large)
    end

    nested = Enum.reduce(1..9, "null", fn _, inner -> "[" <> inner <> "]" end)
    assert {:error, :external_profile_limit} = EnvelopeCodec.decode(nested)
    many = List.duplicate(List.duplicate(List.duplicate(nil, 32), 32), 5)
    assert {:error, :external_profile_limit} = EnvelopeCodec.decode(JSON.encode!(many))
    assert {:error, :invalid_external_closure} = ExternalEnvelope.to_map(%URI{}, %{})

    assert {:error, :external_profile_limit} =
             ExternalEnvelope.compile(String.duplicate(" ", 65_537), nil, nil, nil, nil)
  end

  test "an absent optional producer is unavailable and does not trigger an alternative reader" do
    v = fixture()

    records =
      Enum.map(v["definitions"], fn data ->
        bytes = JSON.encode!(data)

        %{
          "bytes" => bytes,
          "raw_sha256" => digest(bytes),
          "reference" => hd(v["envelope"]["definitions"])
        }
      end)

    bytes = JSON.encode!(v["profile"])

    documents = %{
      "profile" => %{
        "bytes" => bytes,
        "raw_sha256" => digest(bytes),
        "reference" => v["envelope"]["profile"]
      },
      "definitions" => records
    }

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", %{
        "core_archive_sha256" => String.duplicate("a", 64),
        "runtime_archive_sha256" => String.duplicate("b", 64),
        "profiles_archive_sha256" => String.duplicate("c", 64)
      })

    assert {:ok, _} =
             ExternalEnvelope.compile(
               JSON.encode!(v["envelope"]),
               documents,
               installed,
               v["capture"],
               v["reader_limits"]
             )
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
