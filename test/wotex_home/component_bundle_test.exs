defmodule WotexHome.ComponentBundleTest do
  use ExUnit.Case, async: true
  alias WotexHome.Plugins.{Bundle, IPC}

  setup do
    root = Path.join(System.tmp_dir!(), "woh-components-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    source = Path.join(root, "source.wasm")
    File.write!(source, <<0, 97, 115, 109, 13, 0, 1, 0>>)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, source: source}
  end

  test "immutable publication, exact retry and tamper rejection", %{root: root, source: source} do
    assert {:ok, digest} = Bundle.install(root, source)
    assert {:ok, bundle} = Bundle.read(root, digest)
    assert bundle.bytes == File.read!(source)
    assert {:ok, ^digest} = Bundle.install(root, source)
    File.write!(Path.join([root, digest, "component.wasm"]), bundle.bytes <> <<0>>)
    assert {:error, :invalid_bundle} = Bundle.read(root, digest)
    assert {:error, :invalid_bundle} = Bundle.install(root, source)
    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".stage-"))
  end

  test "symlinks, traversal, oversize and source/native cache bytes fail", context do
    %{root: root, source: source} = context
    link = Path.join(root, "link.wasm")
    File.ln_s!(source, link)
    assert {:error, :invalid_bundle} = Bundle.install(root, link)
    assert {:error, :invalid_bundle} = Bundle.read(root, "../outside")

    for bytes <- [
          "(component)",
          <<127, 69, 76, 70>>,
          :binary.copy(<<0>>, Bundle.max_component() + 1)
        ] do
      File.write!(source, bytes)
      assert {:error, :invalid_bundle} = Bundle.install(root, source)
    end

    File.chmod!(root, 0o755)
    assert {:error, :invalid_bundle} = Bundle.install(root, source)
  end

  test "manifest rejects unknown fields, duplicates, world drift and WIT drift", context do
    %{root: root, source: source} = context
    {:ok, digest} = Bundle.install(root, source)
    path = Path.join([root, digest, "manifest.json"])
    original = File.read!(path)

    for bytes <- [
          "{",
          <<255, 254>>,
          String.replace(original, "\"format\":1", "\"format\":1,\"format\":1"),
          String.replace(original, "\"format\":1", "\"format\":1,\"url\":\"local\""),
          String.replace(original, Bundle.world(), "unsupported@9.0.0"),
          String.replace(original, Bundle.wit_digest(), String.duplicate("0", 64))
        ] do
      File.write!(path, bytes)
      assert {:error, :invalid_bundle} = Bundle.read(root, digest)
    end

    File.rm!(path)
    File.ln_s!(source, path)
    assert {:error, :invalid_bundle} = Bundle.read(root, digest)
  end

  test "closed IPC rejects unknown codes, Boolean abuse and unsafe encoding" do
    assert :ok = IPC.input(:decode_power, <<>>)
    assert {:error, :invalid_input} = IPC.input(:decode_power, <<0, 0, 0>>)
    assert {:error, :invalid_input} = IPC.input(:encode_power, "true")
    assert {:ok, true} = IPC.response(<<1, 0, 1>>, :decode_power, <<255, 255>>)
    assert {:error, :invalid_response} = IPC.response(<<1, 0, 2>>, :decode_power, <<>>)
    assert {:error, :invalid_response} = IPC.response(<<1, 3, 255>>, :decode_power, <<>>)

    assert {:error, :invalid_output} =
             IPC.response(<<1, 2, 0, 0, 0, 0, 0, 0>>, :encode_power, true)
  end
end
