defmodule WotexHome.RecoveryOwnerTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Recovery
  alias WotexHome.Recovery.{Owner, PrivateFile}

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-owner-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "owner.json")}
  end

  test "fresh immutable custody yields exact public commitments without authority", c do
    assert {:ok, first} = Owner.create(c.path)
    assert {:ok, ^first} = Owner.read(c.path)
    bytes = File.read!(c.path)
    assert bytes == JSON.encode!(["wotex-home.controller-owner.v1", first.owner_id])
    assert first.owner_custody_digest == Artifact.digest(bytes)
    assert first.owner_id =~ ~r/\A[0-9a-f]{64}\z/
    assert map_size(first) == 2
    assert band(File.stat!(c.path).mode, 0o777) == 0o400
    assert File.stat!(c.path).links == 1
    assert {:error, :private_custody_exists} = Owner.create(c.path)
    assert {:ok, ^first} = Owner.read(c.path)
    assert {:ok, second} = Owner.create(Path.join(c.root, "second.json"))
    refute second.owner_id == first.owner_id
    assert Enum.sort(File.ls!(c.root)) == ["owner.json", "second.json"]
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end

  test "canonical bounded documents reject altered format, fields, whitespace and identities",
       c do
    for bytes <- [
          "",
          :binary.copy(" ", 129),
          "[]",
          JSON.encode!(["wotex-home.controller-owner.v2", String.duplicate("a", 64)]),
          JSON.encode!(["wotex-home.controller-owner.v1", String.duplicate("A", 64)]),
          JSON.encode!(["wotex-home.controller-owner.v1", String.duplicate("a", 64), nil]),
          JSON.encode!(["wotex-home.controller-owner.v1", String.duplicate("a", 64)]) <> "\n"
        ] do
      File.write!(c.path, bytes)
      File.chmod!(c.path, 0o400)
      assert {:error, :owner_custody_unavailable} = Owner.read(c.path)
      File.rm!(c.path)
    end
  end

  test "private modes, links, aliases and missing custody fail closed", c do
    {:ok, _} = Owner.create(c.path)

    for mode <- [0o600, 0o440, 0o644, 0o700] do
      File.chmod!(c.path, mode)
      assert {:error, :owner_custody_unavailable} = Owner.read(c.path)
    end

    File.chmod!(c.path, 0o400)
    linked = Path.join(c.root, "linked.json")
    File.ln!(c.path, linked)
    assert {:error, :owner_custody_unavailable} = Owner.read(c.path)
    assert {:error, :owner_custody_unavailable} = Owner.read(linked)
    File.rm!(linked)
    File.ln_s!(c.path, linked)
    assert {:error, :owner_custody_unavailable} = Owner.read(linked)
    assert {:error, :private_custody_exists} = Owner.create(linked)
    assert {:error, :owner_custody_unavailable} = Owner.read(Path.join(c.root, "absent"))

    assert {:error, :owner_custody_unavailable} =
             Owner.read(c.root <> "/../" <> Path.basename(c.root) <> "/owner.json")

    assert {:ok, _} = Owner.read(c.path)
  end

  test "symlinked or permissive parents cannot publish or read custody", c do
    real = Path.join(c.root, "real")
    File.mkdir!(real)
    File.chmod!(real, 0o700)
    path = Path.join(real, "owner.json")
    {:ok, _} = Owner.create(path)
    alias_path = Path.join(c.root, "alias")
    File.ln_s!(real, alias_path)

    assert {:error, :private_custody_unavailable} =
             Owner.create(Path.join(alias_path, "new.json"))

    assert {:error, :owner_custody_unavailable} = Owner.read(Path.join(alias_path, "owner.json"))
    File.chmod!(real, 0o755)
    assert {:error, :private_custody_unavailable} = Owner.create(Path.join(real, "new.json"))
    assert {:error, :owner_custody_unavailable} = Owner.read(path)
    assert File.ls!(real) == ["owner.json"]
  end

  test "failed file and directory synchronization publish no successful or partial custody", c do
    for stage <- [1, 2] do
      Process.put(:custody_sync_count, 0)

      sync = fn handle ->
        count = Process.get(:custody_sync_count) + 1
        Process.put(:custody_sync_count, count)
        if count == stage, do: {:error, :eio}, else: :file.sync(handle)
      end

      assert {:error, :private_custody_unavailable} =
               PrivateFile.write(c.path, "bounded", 128, sync)

      assert File.ls!(c.root) == []
    end

    assert {:ok, _} = Owner.create(c.path)
  end

  test "parent replacement during publication never removes a substituted path", c do
    parent = Path.join(c.root, "private")
    moved = Path.join(c.root, "old")
    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    path = Path.join(parent, "owner.json")

    sync = fn handle ->
      File.rename!(parent, moved)
      File.mkdir!(parent)
      File.chmod!(parent, 0o700)
      File.write!(path, "replacement")
      :file.sync(handle)
    end

    assert {:error, :private_custody_unavailable} = PrivateFile.write(path, "original", 128, sync)
    assert File.read!(path) == "replacement"
    assert {:error, :owner_custody_unavailable} = Owner.read(path)
  end

  test "trusted command creates custody without reading a key or starting Home", c do
    assert {:ok, first} = Recovery.run(["new-owner", c.path], "")
    assert {:ok, ^first} = Owner.read(c.path)
    other = Path.join(c.root, "child.json")

    assert {:ok, output} =
             Woh.Tool.Command.run(
               "mix",
               ["run", "--no-start", "bin/recovery.exs", "new-owner", other],
               65_536,
               30_000,
               [
                 {"WOTEX_HOME_DATA_DIR", c.root},
                 {"WOTEX_HOME_GIT_DEPS", "1"},
                 {"MIX_ENV", "test"}
               ],
               ""
             )

    assert {:ok, %{"owner_id" => child_owner, "owner_custody_digest" => child_digest}} =
             JSON.decode(String.trim(output))

    assert {:ok, %{owner_id: ^child_owner, owner_custody_digest: ^child_digest}} =
             Owner.read(other)

    refute File.exists?(Path.join(c.root, "home.sqlite"))
    refute File.exists?(Path.join(c.root, "ipc/home.sock"))
  end
end
