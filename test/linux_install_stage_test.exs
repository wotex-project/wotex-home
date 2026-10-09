defmodule WotexHome.LinuxInstallStageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Woh.Tool.{
    LinuxInstallFiles,
    LinuxInstallStage,
    ReleaseBootstrap,
    ReleaseInventory
  }

  @revision String.duplicate("a", 40)
  @artifact String.duplicate("b", 64)
  @nonce String.duplicate("c", 64)
  @owner "{\"fixture\":\"initial owner\"}\n"
  @marker "{\"fixture\":\"original update stage\"}\n"
  @payload "public fixture payload\n"

  setup do
    root = Path.join(System.tmp_dir!(), "woh-update-stage-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    base = Path.join(root, "installation")
    stage = Path.join(base, ".installer/update-stage-" <> @nonce)

    for path <- [
          root,
          source,
          base,
          Path.join(base, ".installer"),
          Path.join(base, "releases"),
          stage
        ],
        do: File.mkdir_p!(path)

    File.chmod!(root, 0o700)
    File.chmod!(base, 0o755)
    File.chmod!(Path.join(base, ".installer"), 0o700)
    File.chmod!(Path.join(base, "releases"), 0o755)
    File.chmod!(stage, 0o700)
    owner = Path.join(base, ".installer/owner.json")
    File.write!(owner, @owner)
    File.chmod!(owner, 0o600)
    File.write!(Path.join(stage, "stage.json"), @marker)
    File.chmod!(Path.join(stage, "stage.json"), 0o600)
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "lib/payload"), @payload)
    File.chmod!(Path.join(source, "lib/payload"), 0o644)
    assert {:ok, _} = ReleaseInventory.create(source, @revision)
    assert {:ok, manifest} = ReleaseBootstrap.render(source)
    pin = LinuxInstallFiles.digest(manifest)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      source: source,
      base: base,
      stage: stage,
      owner: owner,
      release: Path.join(stage, "release"),
      destination: Path.join(base, "releases/" <> @artifact),
      manifest: manifest,
      pin: pin
    }
  end

  test "pinned manifest rejects ambiguous paths, fields, rows and limits", c do
    assert {:ok, declared} = LinuxInstallStage.decode_manifest(c.manifest, c.pin)
    assert declared.source_revision == @revision
    assert MapSet.member?(declared.directories, "lib")
    assert {:error, _} = LinuxInstallStage.decode_manifest(c.manifest, String.duplicate("d", 64))
    header = "WOTEX_HOME_BOOTSTRAP\t1\t" <> @revision <> "\n"
    row = LinuxInstallFiles.digest(@payload) <> "\t644\t#{byte_size(@payload)}\tlib/payload\n"

    for bytes <- [
          header <> row,
          header <> row <> row,
          String.trim_trailing(c.manifest, "\n"),
          String.replace(c.manifest, "\tlib/payload", "\t../payload"),
          String.replace(c.manifest, "\tlib/payload", "\tlib//payload"),
          String.replace(c.manifest, "\tlib/payload", "\tlib/./payload"),
          String.replace(c.manifest, "\t644\t", "\t0644\t"),
          String.replace(c.manifest, "\t644\t", "\t666\t"),
          String.replace(c.manifest, "\t644\t", "\t4644\t"),
          String.replace(c.manifest, "\t#{byte_size(@payload)}\t", "\t0#{byte_size(@payload)}\t"),
          header <> String.duplicate("x", 2_097_153)
        ] do
      assert {:error, _} =
               LinuxInstallStage.decode_manifest(bytes, LinuxInstallFiles.digest(bytes))
    end
  end

  test "complete and empty staging snapshots are distinct and contain no administrative bytes",
       c do
    assert {:ok, %{complete: false, files: 1, directories: 1} = empty} = snapshot(c)
    complete_copy!(c)
    assert {:ok, %{complete: true, files: 3} = ready} = snapshot(c)
    refute ready.sha256 == empty.sha256
    assert byte_size(ready.sha256) == 64
    assert :erlang.term_to_binary(ready) |> :binary.match(@marker) == :nomatch
    assert File.read!(c.owner) == @owner
  end

  test "partial copy permits only exact source prefixes and private temporary mode", c do
    File.mkdir_p!(Path.join(c.release, "lib"))
    private_directories!(c.release)
    path = Path.join(c.release, "lib/payload")
    File.write!(path, binary_part(@payload, 0, 7))
    File.chmod!(path, 0o600)
    assert {:error, _} = snapshot(c)
    assert {:ok, %{complete: false}} = snapshot(c, c.source)
    File.write!(path, "altered")
    assert {:error, _} = snapshot(c, c.source)
    File.write!(path, binary_part(@payload, 0, 7))
    File.chmod!(path, 0o644)
    assert {:error, _} = snapshot(c, c.source)
    File.chmod!(path, 0o600)
    File.write!(Path.join(c.source, "lib/payload"), "changed original source\n")
    assert {:error, _} = snapshot(c, c.source)
  end

  test "unknown directories, changed bytes, links and marker changes are preserved", c do
    complete_copy!(c)
    unknown = Path.join(c.release, "foreign")
    File.mkdir!(unknown)
    assert {:error, _} = snapshot(c)
    assert File.dir?(unknown)
    File.rmdir!(unknown)
    path = Path.join(c.release, "lib/payload")
    File.write!(path, "changed payload")
    assert {:error, _} = snapshot(c)
    assert File.read!(path) == "changed payload"
    File.write!(path, @payload)
    File.rm!(path)
    File.ln_s!(Path.join(c.source, "lib/payload"), path)
    assert {:error, _} = snapshot(c)
    File.rm!(path)
    File.ln!(Path.join(c.source, "lib/payload"), path)
    assert {:error, _} = snapshot(c)
    File.rm!(path)
    File.cp!(Path.join(c.source, "lib/payload"), path)
    File.write!(Path.join(c.stage, "stage.json"), "foreign marker")
    assert {:error, _} = snapshot(c)
    assert File.read!(Path.join(c.stage, "stage.json")) == "foreign marker"
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    alias Woh.Tool.Command
    @native Path.expand("../native/linux", __DIR__)
    setup c do
      # A real marked lock, transferred into the native operation, avoids an
      # unlocked fixture bypass. Only this test's private namespace is touched.
      tools = Path.join(c.root, "tools")
      File.mkdir!(tools)
      File.chmod!(tools, 0o700)

      for name <- ~w(installer-files installer-files.pl) do
        File.cp!(Path.join(@native, name), Path.join(tools, name))
      end

      wrapper = Path.join(tools, "locked-file-tool")

      File.write!(wrapper, ~S"""
      #!/bin/sh
      set -eu
      stage_directory=$(dirname "$0")
      exec "$stage_directory/installer-files" lock-run "$stage_directory/fixture.lock" /bin/sh -c '
        stage_tool=$1
        stage_operation=$2
        shift 2
        exec "$stage_tool" "$stage_operation" --lock-owner "$$" "$WOTEX_HOME_INSTALL_LOCK_FD" "$WOTEX_HOME_INSTALL_LOCK_PATH" "$@"
      ' stage-fixture "$stage_directory/installer-files" "$@"
      """)

      File.chmod!(wrapper, 0o755)
      %{tool: wrapper, native: Path.join(tools, "installer-files")}
    end

    test "publication preserves inventory and keeps original ownership outside the payload", c do
      complete_copy!(c)
      assert {:ok, %{complete: true} = tree} = snapshot(c)

      inventory =
        LinuxInstallFiles.digest(File.read!(Path.join(c.release, "release-inventory.json")))

      assert :ok = publish(c, tree.sha256, inventory)
      refute File.exists?(c.release)
      assert {:ok, _} = ReleaseInventory.verify(c.destination)
      manifest = c.manifest
      assert {:ok, ^manifest} = ReleaseBootstrap.render(c.destination)
      assert File.read!(c.owner) == @owner
      assert File.read!(Path.join(c.stage, "stage.json")) == @marker
      refute File.exists?(Path.join(c.destination, ".installer"))
      assert Bitwise.band(File.lstat!(c.destination).mode, 0o7777) == 0o755
      assert Bitwise.band(File.lstat!(Path.join(c.destination, "lib")).mode, 0o7777) == 0o755

      assert :ok =
               LinuxInstallFiles.sync_release(c.destination, c.owner, @owner, inventory, c.tool)

      assert {:ok, empty} = snapshot(c)
      assert :ok = remove(c, empty.sha256)
      refute File.exists?(c.stage)
      assert {:ok, _} = ReleaseInventory.verify(c.destination)
      assert File.read!(c.owner) == @owner
    end

    test "occupied destinations and changed tree/inventory bindings refuse without publication",
         c do
      complete_copy!(c)
      assert {:ok, tree} = snapshot(c)

      inventory =
        LinuxInstallFiles.digest(File.read!(Path.join(c.release, "release-inventory.json")))

      assert {:error, _} = publish(c, String.duplicate("d", 64), inventory)
      assert {:error, _} = publish(c, tree.sha256, String.duplicate("d", 64))
      File.mkdir!(c.destination)
      File.write!(Path.join(c.destination, "foreign"), "preserve occupied payload")
      assert {:error, _} = publish(c, tree.sha256, inventory)
      assert File.read!(Path.join(c.destination, "foreign")) == "preserve occupied payload"
      assert {:ok, _} = ReleaseInventory.verify(c.release)
      assert Bitwise.band(File.lstat!(c.release).mode, 0o7777) == 0o700
    end

    test "unchanged interrupted prefix can be removed, while changed or linked staging survives",
         c do
      File.mkdir_p!(Path.join(c.release, "lib"))
      private_directories!(c.release)
      path = Path.join(c.release, "lib/payload")
      File.write!(path, binary_part(@payload, 0, 7))
      File.chmod!(path, 0o600)
      assert {:ok, tree} = snapshot(c, c.source)
      File.write!(path, "altered")
      assert {:error, _} = remove(c, tree.sha256)
      assert File.read!(path) == "altered"
      File.write!(path, binary_part(@payload, 0, 7))
      File.ln_s!(c.source, Path.join(c.release, "outside"))
      assert {:error, _} = remove(c, tree.sha256)
      assert File.read!(Path.join(c.source, "lib/payload")) == @payload
      File.rm!(Path.join(c.release, "outside"))
      assert :ok = remove(c, tree.sha256)
      refute File.exists?(c.stage)
      assert File.read!(c.owner) == @owner
      assert File.read!(Path.join(c.source, "lib/payload")) == @payload
    end

    test "unlocked, foreign owner and nonscoped operations cannot mutate a release", c do
      complete_copy!(c)
      assert {:ok, tree} = snapshot(c)

      inventory =
        LinuxInstallFiles.digest(File.read!(Path.join(c.release, "release-inventory.json")))

      args = [
        "publish-release",
        c.release,
        c.destination,
        c.owner,
        LinuxInstallFiles.digest(@owner),
        LinuxInstallFiles.digest(@marker),
        tree.sha256,
        inventory
      ]

      assert {:error, _} = Command.run(c.native, args, 4096, 5000)

      assert {:error, _} =
               LinuxInstallFiles.publish_release(
                 c.release,
                 c.destination,
                 c.owner,
                 "foreign owner",
                 @marker,
                 tree.sha256,
                 inventory,
                 c.tool
               )

      assert {:error, _} =
               LinuxInstallFiles.publish_release(
                 c.release,
                 Path.join(c.root, "outside"),
                 c.owner,
                 @owner,
                 @marker,
                 tree.sha256,
                 inventory,
                 c.tool
               )

      assert {:error, _} =
               LinuxInstallFiles.remove_stage(
                 Path.join(c.base, "releases"),
                 c.owner,
                 @owner,
                 @marker,
                 tree.sha256,
                 c.tool
               )

      refute File.exists?(c.destination)
      assert {:ok, _} = ReleaseInventory.verify(c.release)
      assert File.read!(c.owner) == @owner
    end

    defp publish(c, tree, inventory),
      do:
        LinuxInstallFiles.publish_release(
          c.release,
          c.destination,
          c.owner,
          @owner,
          @marker,
          tree,
          inventory,
          c.tool
        )

    defp remove(c, tree),
      do: LinuxInstallFiles.remove_stage(c.stage, c.owner, @owner, @marker, tree, c.tool)
  end

  defp snapshot(c, source \\ nil),
    do: LinuxInstallStage.snapshot(c.stage, @marker, c.manifest, c.pin, source)

  defp complete_copy!(c) do
    File.cp_r!(c.source, c.release)
    private_directories!(c.release)
  end

  defp private_directories!(path) do
    File.chmod!(path, 0o700)

    for name <- File.ls!(path),
        child = Path.join(path, name),
        File.lstat!(child).type == :directory,
        do: private_directories!(child)
  end
end
