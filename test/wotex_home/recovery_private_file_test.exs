defmodule WotexHome.RecoveryPrivateFileTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias WotexHome.Recovery.PrivateFile

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-private-review-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "custody"), credential: :crypto.strong_rand_bytes(32)}
  end

  test "receiving credential is synchronized canonical CLI-compatible private custody", c do
    assert :ok = PrivateFile.write_credential(c.path, c.credential)
    assert File.read!(c.path) == Base.url_encode64(c.credential, padding: false) <> "\n"
    assert {:ok, c.credential} == PrivateFile.read_credential(c.path)
    assert band(File.stat!(c.path).mode, 0o777) == 0o600
    assert File.stat!(c.path).size == 44 and File.stat!(c.path).links == 1

    assert {:error, :private_custody_exists} =
             PrivateFile.write_credential(c.path, :crypto.strong_rand_bytes(32))

    assert {:ok, c.credential} == PrivateFile.read_credential(c.path)
    assert {:error, :private_custody_unavailable} = PrivateFile.read(c.path, 44)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert 1 ==
                 WotexHome.CLI.main([
                   "--socket",
                   Path.join(c.root, "absent.sock"),
                   "--credential-file",
                   c.path,
                   "health"
                 ])
      end)

    assert output =~ "home CLI error:"
    refute output =~ "invalid_credential_file"
    refute output =~ Base.url_encode64(c.credential, padding: false)
  end

  test "credential reads reject every changed line representation and permissive mode", c do
    line = Base.url_encode64(c.credential, padding: false)

    for bytes <- [
          line,
          line <> "\n\n",
          line <> "\r\n",
          line <> " \n",
          String.duplicate("!", 43) <> "\n",
          "\n",
          :binary.copy("x", 45)
        ] do
      File.write!(c.path, bytes)
      File.chmod!(c.path, 0o600)
      assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(c.path)
      File.rm!(c.path)
    end

    assert :ok = PrivateFile.write_credential(c.path, c.credential)

    for mode <- [0o400, 0o440, 0o640, 0o644, 0o700] do
      File.chmod!(c.path, mode)
      assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(c.path)
    end
  end

  test "hard links, symbolic links and changed parent custody cannot deliver credentials", c do
    assert :ok = PrivateFile.write_credential(c.path, c.credential)
    linked = Path.join(c.root, "linked")
    File.ln!(c.path, linked)
    assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(c.path)
    assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(linked)
    File.rm!(linked)
    File.ln_s!(c.path, linked)
    assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(linked)
    assert {:error, :private_custody_exists} = PrivateFile.write_credential(linked, c.credential)
    assert {:ok, c.credential} == PrivateFile.read_credential(c.path)
    File.chmod!(c.root, 0o755)
    assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(c.path)

    assert {:error, :private_custody_unavailable} =
             PrivateFile.write_credential(Path.join(c.root, "new"), c.credential)
  end

  test "bounded immutable domain files support four MiB while preserving each smaller limit", c do
    bytes = :binary.copy("x", 4_194_304)
    assert :ok = PrivateFile.write(c.path, bytes, 4_194_304)
    assert {:ok, ^bytes} = PrivateFile.read(c.path, 4_194_304)
    assert band(File.stat!(c.path).mode, 0o777) == 0o400
    assert {:error, :private_custody_unavailable} = PrivateFile.read(c.path, 4_194_303)
    assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(c.path)

    for limit <- [0, 4_194_305, 128.0, nil] do
      assert {:error, :private_custody_unavailable} = PrivateFile.read(c.path, limit)

      assert {:error, :private_custody_unavailable} =
               PrivateFile.write(Path.join(c.root, "new"), "small", limit)
    end

    assert {:error, :private_custody_unavailable} =
             PrivateFile.write(Path.join(c.root, "new"), bytes <> "x", 4_194_304)

    assert File.ls!(c.root) == ["custody"]
  end

  test "failed file or directory synchronization leaves no receiving credential", c do
    for stage <- [1, 2] do
      counter = :counters.new(1, [])

      sync = fn handle ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == stage, do: {:error, :eio}, else: :file.sync(handle)
      end

      assert {:error, :private_custody_unavailable} =
               PrivateFile.write_credential(c.path, c.credential, sync)

      assert File.ls!(c.root) == []
    end
  end

  test "original seals reject identical-byte replacement while sibling publication remains valid",
       c do
    assert :ok = PrivateFile.write(c.path, "exact", 128)
    assert {:ok, "exact", seal} = PrivateFile.read_sealed(c.path, 128)
    assert :ok = PrivateFile.check(seal)
    sibling = Path.join(c.root, "sibling")
    assert :ok = PrivateFile.write(sibling, "other", 128)
    assert :ok = PrivateFile.check(seal)
    File.rename!(c.path, Path.join(c.root, "original"))
    assert :ok = PrivateFile.write(c.path, "exact", 128)
    assert {:error, :private_custody_unavailable} = PrivateFile.check(seal)
    assert {:ok, "exact", replacement} = PrivateFile.read_sealed(c.path, 128)
    refute replacement == seal
    assert :ok = PrivateFile.check(replacement)
  end

  test "credential seals retain original identity and canonical mode without secret data", c do
    assert :ok = PrivateFile.write_credential(c.path, c.credential)
    assert {:ok, credential, seal} = PrivateFile.read_credential_sealed(c.path)
    assert credential == c.credential
    assert :ok = PrivateFile.check(seal)
    refute inspect(seal) =~ Base.url_encode64(credential, padding: false)
    File.rename!(c.path, Path.join(c.root, "original"))
    assert :ok = PrivateFile.write_credential(c.path, credential)
    assert {:error, :private_custody_unavailable} = PrivateFile.check(seal)
    assert {:ok, credential, replacement} = PrivateFile.read_credential_sealed(c.path)
    assert credential == c.credential
    assert :ok = PrivateFile.check(replacement)
    File.chmod!(c.root, 0o755)
    assert {:error, :private_custody_unavailable} = PrivateFile.check(replacement)
    assert {:error, :private_custody_unavailable} = PrivateFile.check(nil)
  end

  test "changed parent during credential publication never deletes substituted custody", c do
    parent = Path.join(c.root, "private")
    moved = Path.join(c.root, "displaced")
    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    path = Path.join(parent, "credential")

    sync = fn handle ->
      File.rename!(parent, moved)
      File.mkdir!(parent)
      File.chmod!(parent, 0o700)
      File.write!(path, "replacement")
      :file.sync(handle)
    end

    assert {:error, :private_custody_unavailable} =
             PrivateFile.write_credential(path, c.credential, sync)

    assert File.read!(path) == "replacement"
    assert {:error, :private_custody_unavailable} = PrivateFile.read_credential(path)
  end
end
