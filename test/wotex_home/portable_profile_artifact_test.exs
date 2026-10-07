defmodule WotexHome.PortableProfileArtifactTest do
  use ExUnit.Case, async: true

  alias WotexHome.Profiles.{Artifact, Codec}

  @fixture Path.expand("../support/profiles/lifx-power.json", __DIR__)

  test "independent author bytes derive only pending ordinary direct power" do
    bytes = File.read!(@fixture)
    assert {:ok, artifact} = Artifact.parse(bytes)
    assert artifact.bytes == bytes
    assert artifact.digest == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert artifact.profile_ref == "test.portable-light:1.0.0"
    assert artifact.profile.rank == 0

    assert artifact.profile.qualification_ref ==
             "qualification:pending:profile:" <> artifact.digest

    assert {:ok, thing} = Artifact.declaration(artifact, "light:test")
    assert thing.role == "Light"
    assert Map.keys(thing.capabilities) == ["power"]
    assert thing.capabilities["power"].risk_class == "ordinary"
    assert thing.capabilities["power"].operations == ["read", "write"]
    assert thing.capabilities["power"].freshness_ms == 5_000

    assert {:ok, _} = Artifact.parse(File.read!("priv/profiles/lifx-power-example.json"))

    # A registry-supported tuple outside the compiled catalogue can be
    # delivered as data; it still has only pending qualification.
    data = JSON.decode!(bytes)

    assert {:ok, added} =
             data
             |> put_in(["fingerprint", "model"], "lifx.product.1")
             |> JSON.encode!()
             |> Artifact.parse()

    assert added.profile.model == "lifx.product.1"
    assert String.starts_with?(added.profile.qualification_ref, "qualification:pending:")
  end

  test "raw serialization identity is distinct from exact ordered semantic projection" do
    bytes = File.read!(@fixture)
    {:ok, first} = Artifact.parse(bytes)
    {:ok, second} = Artifact.parse(" \n" <> bytes)
    refute first.digest == second.digest
    assert first.projection_digest == second.projection_digest
    refute first.profile.qualification_ref == second.profile.qualification_ref

    expected =
      ~s(["wotex-home.profile-projection.v1","wotex-home.profile-binding-compiler.v1","test.portable-light","1.0.0",["udp",1,22,["1.22"]],"lifx-direct-power-v1","09f6b87367ea3a974cd4be9e7a562db73e1776d012854fb487b00ac9be520360",["Light","power","boolean","none",["read","write"],"ordinary",5000,0],["explicit_selection","pending_physical_evidence",0]])

    assert first.projection_document == expected
    assert first.projection_digest == Base.encode16(:crypto.hash(:sha256, expected), case: :lower)

    data = JSON.decode!(bytes)
    changed = put_in(data["provenance"]["publisher"], "Different attribution")
    {:ok, third} = Artifact.parse(JSON.encode!(changed))
    assert third.projection_digest == first.projection_digest
    refute third.digest == first.digest
  end

  test "duplicate keys at every supported depth, including escaped duplicates, fail" do
    bytes = File.read!(@fixture)

    for {original, replacement} <- [
          {~s("version":"1.0.0"), ~s("version":"1.0.0","version":"1.0.0")},
          {~s("model":"lifx.product.22"),
           ~s("model":"lifx.product.22","model":"lifx.product.22")},
          {~s("kind":"registry"), ~s("kind":"registry","kind":"registry")},
          {~s("publisher":"Fixture author"),
           ~s("publisher":"Fixture author","publis\u0068er":"Fixture author")}
        ] do
      assert {:error, :invalid_profile_data} =
               Codec.decode(String.replace(bytes, original, replacement))
    end
  end

  test "preallocation bounds reject deep, broad, oversized and numeric inputs" do
    for bytes <- [
          String.duplicate("[", 9) <> "0" <> String.duplicate("]", 9),
          "[" <> Enum.map_join(1..33, ",", fn _ -> ~s("x") end) <> "]",
          ~s({"x":") <> String.duplicate("x", 257) <> ~s("}),
          ~s({"x":) <> String.duplicate("9", 30_000) <> "}",
          ~s({"x":1.0}),
          ~s({"x":1e999999999999999999}),
          :binary.copy(" ", Codec.max_bytes() + 1),
          <<255, 254>>,
          "{",
          ""
        ] do
      assert {:error, :invalid_profile_data} = Codec.decode(bytes)
    end

    assert {:error, :invalid_profile_data} = Codec.decode(File.read!(@fixture) <> "{}")
  end

  test "host controls bindings, dependencies, declarations and reserved compiled labels" do
    data = JSON.decode!(File.read!(@fixture))

    for changed <- [
          Map.put(data, "binding", "author.module"),
          Map.put(data, "module", "Elixir.System"),
          Map.put(data, "capabilities", []),
          put_in(data["dependencies"], [
            %{"kind" => "registry", "sha256" => String.duplicate("0", 64)}
          ]),
          put_in(data["fingerprint"]["manufacturer"], "lifx.vendor.999"),
          put_in(data["fingerprint"]["model"], "lifx.product.999999"),
          put_in(data["fingerprint"]["model"], "lifx.product.022"),
          put_in(data["fingerprint"]["firmware_versions"], ["01.22"]),
          put_in(data["fingerprint"]["firmware_versions"], ["1.22", "1.22"]),
          put_in(data["fingerprint"]["firmware_versions"], [nil]),
          put_in(data["fingerprint"]["transport"], "zigbee"),
          Map.put(data, "id", "lifx.product-22"),
          Map.merge(data, %{"id" => String.duplicate("i", 128), "version" => "1"})
        ] do
      assert {:error, _} = Artifact.parse(JSON.encode!(changed))
    end
  end

  test "provenance rejects controls, invisible formatting and UTF-8 byte overflow" do
    data = JSON.decode!(File.read!(@fixture))

    for value <- [
          nil,
          "",
          "line\nbreak",
          "nul\0byte",
          "hidden\u202Etext",
          String.duplicate("é", 129)
        ] do
      assert {:error, :invalid_profile_data} =
               data |> put_in(["provenance", "source"], value) |> JSON.encode!() |> Codec.decode()
    end
  end

  test "forged in-memory derived values cannot change a declaration" do
    {:ok, artifact} = Artifact.parse(File.read!(@fixture))

    forged = %{
      artifact
      | profile: %{artifact.profile | qualification_ref: "qualification:approved"}
    }

    assert {:ok, thing} = Artifact.declaration(forged, "light:test")
    assert thing.capabilities["power"].evidence_ref == artifact.profile.qualification_ref
    assert {:error, _} = Artifact.declaration(artifact, "invalid thing")
  end
end
