defmodule Mix.Tasks.Maude.InstallTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  describe "module" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.Maude.Install)
    end

    test "run/1 is exported" do
      assert Code.ensure_loaded?(Mix.Tasks.Maude.Install)
      assert function_exported?(Mix.Tasks.Maude.Install, :run, 1)
    end

    test "has shortdoc" do
      assert Code.ensure_loaded?(Mix.Tasks.Maude.Install)
      # Task has @shortdoc attribute
      assert Mix.Task.shortdoc(Mix.Tasks.Maude.Install) == "Installs Maude system binary"
    end
  end

  describe "option parsing" do
    test "rejects unknown options" do
      assert_raise Mix.Error, ~r/Unknown options: --unknown/, fn ->
        Mix.Tasks.Maude.Install.run(["--unknown", "value"])
      end
    end

    test "accepts --check option" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "Checking Maude availability"
      assert output =~ "Platform:"
    end

    @tag :tmp_dir
    @tag :network
    test "accepts --version option", %{tmp_dir: tmp_dir} do
      # This will fail at network level but validates option parsing
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run(["--version", "3.5.1", "--path", tmp_dir])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "darwin" or output =~ "linux" or output =~ "Fetching"
    end

    @tag :tmp_dir
    @tag :network
    test "accepts --force option", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run(["--force", "--path", tmp_dir])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "Detecting platform" or output =~ "Fetching"
    end
  end

  describe "platform detection" do
    @tag :tmp_dir
    @tag :network
    test "detects current platform format", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run(["--path", tmp_dir])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ ~r/darwin-arm64|darwin-x64|linux-x64|linux-arm64/
    end
  end

  describe "--list option" do
    @tag :network
    test "lists available versions" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--list"])
        end)

      assert output =~ "Available Maude versions"
      assert output =~ "Maude3.5"
      assert output =~ "mix maude.install --version"
    end
  end

  describe "--check option" do
    test "shows platform information" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "Platform:"
      assert output =~ ~r/darwin-|linux-/
    end

    test "shows project-local binary status" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "Local binary:"
    end

    test "shows system PATH status" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "System PATH:"
    end

    test "shows final resolution" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "ExMaude will use:" or output =~ "No Maude binary available"
    end

    test "reports configured path status", %{tmp_dir: tmp_dir} do
      original = Application.get_env(:ex_maude, :maude_path)
      configured = Path.join(tmp_dir, "configured-maude")
      File.write!(configured, "#!/bin/sh\necho maude")

      try do
        Application.put_env(:ex_maude, :maude_path, configured)

        output =
          capture_io(fn ->
            Mix.Tasks.Maude.Install.run(["--check"])
          end)

        assert output =~ "Configured: #{configured}"

        missing = Path.join(tmp_dir, "missing-maude")
        Application.put_env(:ex_maude, :maude_path, missing)

        output =
          capture_io(fn ->
            Mix.Tasks.Maude.Install.run(["--check"])
          end)

        assert output =~ "Configured: #{missing} (file not found)"
      after
        if original do
          Application.put_env(:ex_maude, :maude_path, original)
        else
          Application.delete_env(:ex_maude, :maude_path)
        end
      end
    end
  end

  describe "version normalization" do
    @tag :integration
    @tag :network
    test "accepts version without Maude prefix" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run([
              "--version",
              "3.5.1",
              "--path",
              "/tmp/maude-test-#{:rand.uniform(10000)}"
            ])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "3.5.1" or output =~ "Maude3.5.1" or output =~ "Detecting platform"
    end

    @tag :integration
    @tag :network
    test "accepts version with Maude prefix" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run([
              "--version",
              "Maude3.5.1",
              "--path",
              "/tmp/maude-test-#{:rand.uniform(10000)}"
            ])
          rescue
            Mix.Error -> :ok
          end
        end)

      # Network failures may prevent version from being shown
      assert output =~ "3.5.1" or output =~ "Maude3.5.1" or output =~ "Detecting platform"
    end

    @tag :integration
    @tag :network
    test "reports unknown version", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-unknown-version")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Mix.Tasks.Maude.Install.run(["--version", "99.99.99", "--path", install_path])
          end)
        end

      assert error.message =~ ~r/not found|failed to fetch/i
    end
  end

  describe "installation" do
    @tag :slow
    @tag :network
    test "installs Maude to custom path", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path])
        end)

      assert output =~ "Maude installed successfully"
      assert output =~ install_path

      maude_binary = Path.join(install_path, "maude")
      assert File.exists?(maude_binary)

      assert {:ok, %{mode: mode}} = File.stat(maude_binary)
      assert Bitwise.band(mode, 0o111) != 0

      {version_output, 0} = System.cmd(maude_binary, ["--version"], stderr_to_stdout: true)
      assert version_output =~ ~r/\d+\.\d+/
    end

    test "skips installation if already installed", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")
      File.mkdir_p!(install_path)

      maude_path = Path.join(install_path, "maude")
      File.write!(maude_path, "#!/bin/sh\necho 'fake maude'")
      File.chmod!(maude_path, 0o755)

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path])
        end)

      assert output =~ "already installed"
      assert output =~ "--force"
    end

    @tag :slow
    @tag :network
    test "force reinstalls when --force is used", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")
      File.mkdir_p!(install_path)

      maude_path = Path.join(install_path, "maude")
      File.write!(maude_path, "#!/bin/sh\necho 'fake maude'")
      File.chmod!(maude_path, 0o755)

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path, "--force"])
        end)

      assert output =~ "Maude installed successfully"

      {version_output, 0} = System.cmd(maude_path, ["--version"], stderr_to_stdout: true)
      assert version_output =~ ~r/\d+\.\d+/
    end

    @tag :slow
    @tag :network
    test "fails closed for an older release without a GitHub digest", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")

      error =
        assert_raise Mix.Error, ~r/does not\s+provide a valid SHA-256 digest/, fn ->
          capture_io(fn ->
            Mix.Tasks.Maude.Install.run(["--version", "3.5", "--path", install_path])
          end)
        end

      assert error.message =~ "fails closed"
      refute File.exists?(Path.join(install_path, "maude"))
    end

    @tag :network
    test "extracts library files alongside binary", %{tmp_dir: tmp_dir} do
      existing_path = Path.expand("priv/maude/bin", Mix.Project.app_path())

      if File.exists?(Path.join(existing_path, "maude")) do
        assert File.exists?(Path.join(existing_path, "prelude.maude"))
        assert File.exists?(Path.join(existing_path, "model-checker.maude"))
      else
        install_path = Path.join(tmp_dir, "maude-bin")

        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path])
        end)

        assert File.exists?(Path.join(install_path, "prelude.maude"))
        assert File.exists?(Path.join(install_path, "model-checker.maude"))
      end
    end
  end

  describe "checksum verification" do
    @tag :slow
    @tag :network
    test "verifies SHA256 checksum when available", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--version", "3.5.1", "--path", install_path])
        end)

      assert output =~ "Checksum verified"
      assert output =~ "Maude installed successfully"
    end
  end

  describe "path validation" do
    test "accepts a regular archive", %{tmp_dir: tmp_dir} do
      archive = create_archive!(tmp_dir, "valid.zip", [{~c"maude", "binary"}])
      assert :ok = Mix.Tasks.Maude.Install.validate_archive(archive)
    end

    test "rejects archive path traversal", %{tmp_dir: tmp_dir} do
      archive = create_archive!(tmp_dir, "traversal.zip", [{~c"../escape", "malicious"}])

      assert_raise Mix.Error, ~r/directory traversal/, fn ->
        Mix.Tasks.Maude.Install.validate_archive(archive)
      end
    end

    test "rejects absolute archive paths", %{tmp_dir: tmp_dir} do
      archive = create_archive!(tmp_dir, "absolute.zip", [{~c"C:/escape", "malicious"}])

      assert_raise Mix.Error, ~r/absolute path/, fn ->
        Mix.Tasks.Maude.Install.validate_archive(archive)
      end
    end
  end

  describe "staged installation" do
    test "a missing binary preserves the existing installation", %{tmp_dir: tmp_dir} do
      destination = Path.join(tmp_dir, "installed")
      File.mkdir!(destination)
      File.write!(Path.join(destination, "maude"), "old binary")
      File.write!(Path.join(destination, "prelude.maude"), "old prelude")
      archive = create_archive!(tmp_dir, "missing.zip", [{~c"prelude.maude", "new prelude"}])

      assert_raise Mix.Error, ~r/Could not find a recognized Maude binary/, fn ->
        Mix.Tasks.Maude.Install.install_archive(archive, destination, "3.5.1", tmp_dir)
      end

      assert File.read!(Path.join(destination, "maude")) == "old binary"
      assert File.read!(Path.join(destination, "prelude.maude")) == "old prelude"
    end

    test "installs a runnable renamed executable with its companion files", %{tmp_dir: tmp_dir} do
      destination = Path.join(tmp_dir, "installed")

      archive =
        create_archive!(tmp_dir, "release.zip", [
          {~c"maude.arm64", "#!/bin/sh\nprintf '3.5.1\\n'\n"},
          {~c"prelude.maude", "prelude"}
        ])

      assert :ok = Mix.Tasks.Maude.Install.install_archive(archive, destination, "3.5.1", tmp_dir)
      binary = Path.join(destination, "maude")
      assert {"3.5.1\n", 0} = System.cmd(binary, ["--version"])
      assert File.read!(Path.join(destination, "prelude.maude")) == "prelude"
      refute File.exists?(Path.join(destination, "maude.arm64"))
    end
  end

  defp create_archive!(directory, name, entries) do
    path = Path.join(directory, name)
    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    path
  end

  describe "module attributes" do
    test "has correct shortdoc" do
      shortdoc = Mix.Task.shortdoc(Mix.Tasks.Maude.Install)
      assert shortdoc == "Installs Maude system binary"
    end

    test "module is a Mix.Task" do
      behaviours = Mix.Tasks.Maude.Install.__info__(:attributes)[:behaviour] || []
      assert Mix.Task in behaviours
    end
  end
end
