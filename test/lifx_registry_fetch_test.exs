defmodule WotexHome.LifxRegistryFetchTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.LifxRegistry

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

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
