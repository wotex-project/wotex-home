defmodule WotexHome.ReleaseNativeBackendsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Woh.Tool.{ReleaseNativeBackends, ReleaseSmoke}

  setup do
    directory = Path.join(System.tmp_dir!(), "woh-backends-#{System.unique_integer([:positive])}")
    release = Path.join(directory, "release")
    priv = Path.join(release, "lib/ex_maude-0.4.3/priv")
    File.mkdir_p!(Path.join(priv, "maude/bin"))

    for name <- ~w(maude-darwin-arm64 maude-darwin-x64 maude-linux-x64 prelude.maude) do
      File.write!(Path.join(priv, "maude/bin/" <> name), name)
    end

    File.write!(Path.join(priv, "maude_bridge"), "bridge")
    File.write!(Path.join(priv, "maude/iot-rules.maude"), "Home model source")
    File.write!(Path.join(directory, "retained-state"), "unrelated private state")
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory, release: release, priv: priv}
  end

  test "selects only the implemented delivery platforms" do
    assert {:ok, :darwin_arm64} =
             ReleaseNativeBackends.profile({:unix, :darwin}, "aarch64-apple-darwin")

    assert {:ok, :linux_arm64} =
             ReleaseNativeBackends.profile({:unix, :linux}, "aarch64-unknown-linux-gnu")

    for {os, architecture} <- [
          {{:unix, :linux}, "x86_64-unknown-linux-gnu"},
          {{:unix, :darwin}, "x86_64-apple-darwin"},
          {{:unix, :linux}, "armv7-linux-gnueabihf"},
          {{:win32, :nt}, "aarch64"}
        ] do
      assert {:error, _} = ReleaseNativeBackends.profile(os, architecture)
    end
  end

  test "Linux prunes the unavailable binary/library tree and preserves other files", context do
    assert {:error, _} = ReleaseSmoke.backend_files(context.priv, :linux_arm64)
    assert :ok = ReleaseNativeBackends.prune(context.release, :linux_arm64)
    assert :ok = ReleaseNativeBackends.prune(context.release, :linux_arm64)
    assert :ok = ReleaseSmoke.backend_files(context.priv, :linux_arm64)
    assert {:error, :enoent} = File.lstat(Path.join(context.priv, "maude/bin"))
    assert File.read!(Path.join(context.priv, "maude/iot-rules.maude")) == "Home model source"
    assert File.read!(Path.join(context.directory, "retained-state")) == "unrelated private state"
    assert {:error, _} = ReleaseSmoke.backend_files(context.priv, :darwin_arm64)
  end

  test "macOS retains its selected backend and libraries", context do
    assert :ok = ReleaseNativeBackends.prune(context.release, :darwin_arm64)
    assert :ok = ReleaseNativeBackends.prune(context.release, :darwin_arm64)

    assert File.read!(Path.join(context.priv, "maude/bin/maude-darwin-arm64")) ==
             "maude-darwin-arm64"

    assert File.read!(Path.join(context.priv, "maude/bin/prelude.maude")) == "prelude.maude"

    for name <- ~w(maude/bin/maude-darwin-x64 maude/bin/maude-linux-x64 maude_bridge) do
      assert {:error, :enoent} = File.lstat(Path.join(context.priv, name))
    end
  end

  test "linked native trees refuse without deleting outside files", context do
    path = Path.join(context.priv, "maude/bin")
    File.rm_rf!(path)
    outside = Path.join(context.directory, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "retained"), "outside")
    File.ln_s!(outside, path)
    assert {:error, _} = ReleaseNativeBackends.prune(context.release, :linux_arm64)
    assert {:error, _} = ReleaseNativeBackends.prune(context.release, :darwin_arm64)
    assert File.read!(Path.join(outside, "retained")) == "outside"
    assert {:error, _} = ReleaseSmoke.backend_files(context.priv, :linux_arm64)

    File.rm!(path)
    File.ln_s!("missing", path)
    assert {:error, _} = ReleaseSmoke.backend_files(context.priv, :linux_arm64)
  end

  test "unknown platforms and ambiguous dependency trees refuse", context do
    assert {:error, _} = ReleaseNativeBackends.prune(context.release, :other)
    assert File.exists?(Path.join(context.priv, "maude/bin/maude-darwin-arm64"))
    File.mkdir_p!(Path.join(context.release, "lib/ex_maude-other/priv"))
    assert {:error, _} = ReleaseNativeBackends.prune(context.release, :linux_arm64)
  end
end
