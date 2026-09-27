defmodule WotexHome.ReleaseInventoryTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.ReleaseInventory

  @revision String.duplicate("a", 40)

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "wotex-release-inventory-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "binds bytes, modes, paths and source revision", %{directory: root} do
    File.mkdir_p!(Path.join(root, "bin"))
    executable = Path.join(root, "bin/home")
    File.write!(executable, "release")
    File.chmod!(executable, 0o755)

    assert {:ok, 1} = ReleaseInventory.create(root, @revision)
    assert {:ok, 1} = ReleaseInventory.verify(root)

    first = File.read!(Path.join(root, ReleaseInventory.manifest()))
    assert {:ok, 1} = ReleaseInventory.create(root, @revision)
    assert File.read!(Path.join(root, ReleaseInventory.manifest())) == first

    File.chmod!(executable, 0o700)
    assert {:error, _} = ReleaseInventory.verify(root)
    File.chmod!(executable, 0o755)
    File.write!(executable, "changed")
    assert {:error, _} = ReleaseInventory.verify(root)
  end

  test "rejects links, extra files and a forged manifest", %{directory: root} do
    File.write!(Path.join(root, "home"), "release")
    assert {:ok, 1} = ReleaseInventory.create(root, @revision)

    File.write!(Path.join(root, "extra"), "new")
    assert {:error, _} = ReleaseInventory.verify(root)
    File.rm!(Path.join(root, "extra"))

    File.ln_s!("home", Path.join(root, "link"))
    assert {:error, "symlink in release: link"} = ReleaseInventory.verify(root)
    File.rm!(Path.join(root, "link"))

    manifest = Path.join(root, ReleaseInventory.manifest())

    File.write!(
      manifest,
      String.replace(File.read!(manifest), ~s("schema_version":1), ~s("schema_version":2))
    )

    assert {:error, _} = ReleaseInventory.verify(root)
  end

  test "rejects empty and linked release roots", %{directory: root} do
    assert {:error, "empty release"} = ReleaseInventory.create(root, @revision)
    linked = root <> "-link"
    File.ln_s!(root, linked)
    on_exit(fn -> File.rm!(linked) end)
    assert {:error, "release root must be a real directory"} = ReleaseInventory.entries(linked)
  end
end
