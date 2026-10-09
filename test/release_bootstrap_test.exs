defmodule WotexHome.ReleaseBootstrapTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Woh.Tool.{ReleaseBootstrap, ReleaseInventory}

  @revision String.duplicate("a", 40)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "woh-bootstrap-#{System.unique_integer([:positive])}")

    source = Path.join(directory, "release")
    File.mkdir_p!(Path.join(source, "bin"))
    File.chmod!(directory, 0o700)
    File.write!(Path.join(source, "bin/fixture"), "bootstrap fixture bytes")
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, source: source, manifest: Path.join(directory, "bootstrap.tsv")}
  end

  test "binds the complete issued payload, inventory and modes outside its tree", context do
    assert {:ok, 1} = ReleaseInventory.create(context.source, @revision)
    assert {:ok, bytes} = ReleaseBootstrap.render(context.source)
    assert bytes =~ "WOTEX_HOME_BOOTSTRAP\t1\t#{@revision}\n"
    assert bytes =~ "\trelease-inventory.json\n"
    assert {:ok, pin} = ReleaseBootstrap.create(context.source, context.manifest)
    assert {:ok, ^pin} = ReleaseBootstrap.verify(context.source, context.manifest, pin)
    assert {:ok, 1} = ReleaseInventory.verify(context.source)
    assert {:error, _} = ReleaseBootstrap.create(context.source, context.manifest)

    assert {:error, reason} =
             ReleaseBootstrap.create(context.source, context.source <> "/bootstrap.tsv")

    assert reason =~ "outside"

    File.write!(Path.join(context.source, "bin/fixture"), "changed")
    assert {:error, _} = ReleaseBootstrap.verify(context.source, context.manifest, pin)
  end

  test "rejects ambiguous names and group writable files even when inventoried", context do
    File.write!(Path.join(context.source, "ambiguous name"), "fixture")
    assert {:ok, _} = ReleaseInventory.create(context.source, @revision)
    assert {:error, reason} = ReleaseBootstrap.render(context.source)
    assert reason =~ "unsafe bootstrap"
    File.rm!(Path.join(context.source, "ambiguous name"))
    File.chmod!(Path.join(context.source, "bin/fixture"), 0o664)
    assert {:ok, _} = ReleaseInventory.create(context.source, @revision)
    assert {:error, reason} = ReleaseBootstrap.render(context.source)
    assert reason =~ "writable-group"
    File.chmod!(Path.join(context.source, "bin/fixture"), 0o4644)
    assert {:ok, _} = ReleaseInventory.create(context.source, @revision)
    assert {:error, reason} = ReleaseBootstrap.render(context.source)
    assert reason =~ "special file mode"
  end

  test "changed, linked and mismatched-pin manifests refuse", context do
    assert {:ok, _} = ReleaseInventory.create(context.source, @revision)
    assert {:ok, pin} = ReleaseBootstrap.create(context.source, context.manifest)

    assert {:error, _} =
             ReleaseBootstrap.verify(context.source, context.manifest, String.duplicate("b", 64))

    File.write!(context.manifest, File.read!(context.manifest) <> "changed")
    assert {:error, _} = ReleaseBootstrap.verify(context.source, context.manifest, pin)
    File.rm!(context.manifest)
    File.ln_s!(Path.join(context.source, "release-inventory.json"), context.manifest)
    assert {:error, _} = ReleaseBootstrap.verify(context.source, context.manifest, pin)
  end

  if :os.type() == {:unix, :linux} and File.regular?("/usr/bin/perl") do
    alias Woh.Tool.Hash
    @script Path.expand("../native/linux/bootstrap", __DIR__)

    test "independent base-tool staging copies verified bytes without running payload code",
         context do
      # If this payload were executed it would create an unwanted marker.
      file = Path.join(context.source, "bin/fixture")
      File.write!(file, "#!/bin/sh\ntouch '#{context.directory}/executed'\n")
      File.chmod!(file, 0o755)
      File.write!(Path.join(context.source, "journald@fixture.conf"), "fixture namespace")
      assert {:ok, _} = ReleaseInventory.create(context.source, @revision)
      assert {:ok, pin} = ReleaseBootstrap.create(context.source, context.manifest)
      staged = Path.join(context.directory, "staged")

      {output, status} =
        System.cmd(@script, [context.source, context.manifest, String.duplicate("b", 64), staged],
          stderr_to_stdout: true
        )

      assert status != 0 and output =~ "pin differs"
      refute File.exists?(staged)
      File.write!(Path.join(context.source, "unlisted"), "not copied")

      {output, 0} =
        System.cmd(@script, [context.source, context.manifest, pin, staged],
          stderr_to_stdout: true
        )

      assert output =~ "VERIFIED_STAGE\t"
      assert {:ok, 2} = ReleaseInventory.verify(staged)
      refute File.exists?(Path.join(context.directory, "executed"))
      refute File.exists?(Path.join(staged, "unlisted"))

      {_, status} =
        System.cmd(@script, [context.source, context.manifest, pin, staged],
          stderr_to_stdout: true
        )

      assert status != 0
      assert {:ok, 2} = ReleaseInventory.verify(staged)
    end

    test "staging refuses source tampering, links and FIFOs without retaining partial files",
         context do
      assert {:ok, _} = ReleaseInventory.create(context.source, @revision)
      assert {:ok, pin} = ReleaseBootstrap.create(context.source, context.manifest)
      file = Path.join(context.source, "bin/fixture")
      original = File.read!(file)
      staged = Path.join(context.directory, "staged")
      File.write!(file, String.duplicate("x", byte_size(original)))

      {output, status} =
        System.cmd(@script, [context.source, context.manifest, pin, staged],
          stderr_to_stdout: true
        )

      assert status != 0 and output =~ "bytes differ"
      refute File.exists?(staged)

      File.write!(file, original)
      File.chmod!(file, 0o4644)

      {output, status} =
        System.cmd(@script, [context.source, context.manifest, pin, staged],
          stderr_to_stdout: true
        )

      assert status != 0 and output =~ "type/size/mode differs"
      refute File.exists?(staged)

      File.rm!(file)
      File.ln_s!(context.manifest, file)

      {_, status} =
        System.cmd(@script, [context.source, context.manifest, pin, staged],
          stderr_to_stdout: true
        )

      assert status != 0
      refute File.exists?(staged)

      File.rm!(file)
      {_, 0} = System.cmd("mkfifo", [file])

      {output, status} =
        System.cmd(@script, [context.source, context.manifest, pin, staged],
          stderr_to_stdout: true
        )

      assert status != 0 and output =~ "type/size/mode differs"
      refute File.exists?(staged)
    end

    test "independently validates pinned manifest limits and traversal", context do
      for suffix <- [
            "#{String.duplicate("b", 64)}\t644\t1\t../escaped\n",
            "#{String.duplicate("b", 64)}\t644\t1073741825\tfile\n",
            "#{String.duplicate("b", 64)}\t666\t1\tfile\n"
          ] do
        File.write!(context.manifest, "WOTEX_HOME_BOOTSTRAP\t1\t#{@revision}\n" <> suffix)
        pin = Hash.sha256(context.manifest)
        staged = Path.join(context.directory, "staged")

        {_, status} =
          System.cmd(@script, [context.source, context.manifest, pin, staged],
            stderr_to_stdout: true
          )

        assert status != 0
        refute File.exists?(staged)
      end
    end
  end
end
