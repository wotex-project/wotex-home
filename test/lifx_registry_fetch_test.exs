defmodule WotexHome.LifxRegistryFetchTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.LifxRegistry
  alias WotexHome.Lifx.ProductRegistry

  @registry Path.expand("../priv/lifx/products.json", __DIR__)

  test "assembly makes only copied pinned public metadata readable" do
    {release, path} = release_destination()
    source_mode = File.lstat!(@registry).mode
    File.cp!(@registry, path)
    File.chmod!(path, 0o600)
    cookie = Path.join(release, "releases/COOKIE")
    File.mkdir_p!(Path.dirname(cookie))
    File.write!(cookie, "private release fixture")
    File.chmod!(cookie, 0o600)

    assert {:ok, :prepared} = LifxRegistry.prepare_release(release)
    assert Bitwise.band(File.lstat!(path).mode, 0o7777) == 0o644
    assert {:ok, registry} = ProductRegistry.load_pinned(path)
    assert registry.digest == ProductRegistry.pinned_digest()
    assert File.read!(path) == File.read!(@registry)
    assert File.lstat!(@registry).mode == source_mode
    assert Bitwise.band(File.lstat!(cookie).mode, 0o7777) == 0o600
    assert File.read!(cookie) == "private release fixture"
  end

  test "assembly permits absent optional metadata without creating or fetching it" do
    {release, path} = release_destination()
    assert {:ok, :absent} = LifxRegistry.prepare_release(release)
    refute File.exists?(path)
    File.rmdir!(Path.dirname(path))
    assert {:ok, :absent} = LifxRegistry.prepare_release(release)
    refute File.exists?(Path.dirname(path))
  end

  test "assembly refuses altered bytes and issued reports without widening files" do
    {release, path} = release_destination()
    File.write!(path, "changed")
    File.chmod!(path, 0o600)
    assert {:error, _} = LifxRegistry.prepare_release(release)
    assert Bitwise.band(File.lstat!(path).mode, 0o7777) == 0o600

    File.cp!(@registry, path)

    for report <- ~w(release-inventory.json release-components.json release.spdx.json) do
      report_path = Path.join(release, report)
      File.write!(report_path, "issued fixture")
      assert {:error, _} = LifxRegistry.prepare_release(release)
      assert Bitwise.band(File.lstat!(path).mode, 0o7777) == 0o600
      File.rm!(report_path)
    end
  end

  test "assembly refuses symlinks and hard links without widening an outside source" do
    {release, path} = release_destination()
    outside = Path.join(Path.dirname(release), "outside.json")
    File.cp!(@registry, outside)
    File.chmod!(outside, 0o600)

    for link <- [&File.ln_s!/2, &File.ln!/2] do
      link.(outside, path)
      assert {:error, _} = LifxRegistry.prepare_release(release)
      assert Bitwise.band(File.lstat!(outside).mode, 0o7777) == 0o600
      File.rm!(path)
    end

    File.rmdir!(Path.dirname(path))
    File.ln_s!(Path.dirname(outside), Path.dirname(path))
    assert {:error, _} = LifxRegistry.prepare_release(release)
    assert Bitwise.band(File.lstat!(outside).mode, 0o7777) == 0o600
  end

  test "installs a verified artifact once and rejects later mutation" do
    destination = destination()
    bytes = ~s({"vid":1,"products":[]})
    digest = sha256(bytes)

    assert {:ok, :provisioned} =
             LifxRegistry.provision(destination, fn -> {:ok, bytes} end, digest)

    assert File.read!(destination) == bytes
    assert {:ok, %File.Stat{mode: mode}} = File.lstat(destination)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:ok, :verified} =
             LifxRegistry.provision(destination, fn -> flunk("must use local file") end, digest)

    File.write!(destination, "changed")

    assert {:error, "existing local registry does not match the pinned artifact"} =
             LifxRegistry.provision(destination, fn -> flunk("must reject mutation") end, digest)
  end

  test "rejects a linked local artifact" do
    destination = destination()
    source = Path.join(Path.dirname(destination), "source.json")
    bytes = ~s({"vid":1})
    File.write!(source, bytes)
    File.ln_s!(source, destination)

    assert {:error, "existing local registry does not match the pinned artifact"} =
             LifxRegistry.provision(
               destination,
               fn -> flunk("must reject link") end,
               sha256(bytes)
             )
  end

  test "does not overwrite a destination that appears during download" do
    destination = destination()
    bytes = ~s({"vid":1})

    fetcher = fn ->
      File.write!(destination, "another writer")
      {:ok, bytes}
    end

    assert {:error, "registry destination appeared during provisioning"} =
             LifxRegistry.provision(destination, fetcher, sha256(bytes))

    assert File.read!(destination) == "another writer"
  end

  test "rejects an oversized download before writing" do
    destination = destination()
    bytes = :binary.copy("x", 1_048_577)

    assert {:error, "downloaded LIFX registry exceeds the limit or has the wrong SHA-256"} =
             LifxRegistry.provision(destination, fn -> {:ok, bytes} end, sha256(bytes))

    refute File.exists?(destination)
  end

  defp destination do
    directory =
      Path.join(System.tmp_dir!(), "wotex-registry-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    Path.join(directory, "products.json")
  end

  defp release_destination do
    root = Path.dirname(destination())
    release = Path.join(root, "release")
    path = Path.join(release, "lib/wotex_home-0.1.0/priv/lifx/products.json")
    File.mkdir_p!(Path.dirname(path))
    {release, path}
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
