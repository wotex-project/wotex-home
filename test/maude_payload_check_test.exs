defmodule WotexHome.MaudePayloadCheckTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.MaudePayload

  @source Path.join(Mix.Project.deps_paths()[:ex_maude], "priv/maude/bin")
  @archive "_build/maude-assets/Maude-3.5.1-macos-arm64.zip"

  test "standalone archive staging verifies bytes and refuses replacement or a changed archive" do
    root = temporary_directory()
    destination = Path.join(root, "payload")
    assert :ok = MaudePayload.stage_archive(@archive, destination)
    assert {:ok, 14} = MaudePayload.check_directory(destination, true)
    assert {:error, _} = MaudePayload.stage_archive(@archive, destination)

    changed = Path.join(root, "changed.zip")
    File.write!(changed, "untrusted archive")

    assert {:error, "Maude release archive hash differs"} =
             MaudePayload.stage_archive(changed, Path.join(root, "refused"))

    refute File.exists?(Path.join(root, "refused"))
    assert Path.wildcard(Path.join(root, "*.stage-*")) == []
  end

  test "the pinned dependency payload passes and a changed byte fails" do
    assert {:ok, 14} = MaudePayload.check_directory(@source)
    directory = temporary_directory()
    copy_payload(directory)
    assert {:ok, 14} = MaudePayload.check_directory(directory, true)
    File.write!(Path.join(directory, "prelude.maude"), "changed")

    assert {:error, "Maude payload hash differs: prelude.maude"} =
             MaudePayload.check_directory(directory, true)
  end

  test "release rejects a linked file or foreign binary" do
    directory = temporary_directory()
    copy_payload(directory)
    path = Path.join(directory, "maude-darwin-arm64")
    File.rm!(path)
    File.ln_s!(Path.join(@source, "maude-darwin-arm64"), path)
    assert {:error, reason} = MaudePayload.check_directory(directory, true)
    assert String.contains?(reason, "linked")

    File.rm!(path)
    File.cp!(Path.join(@source, "maude-darwin-arm64"), path)
    File.write!(Path.join(directory, "maude-linux-x64"), "foreign")

    assert {:error, "Maude payload file set differs from pinned asset"} =
             MaudePayload.check_directory(directory, true)
  end

  defp temporary_directory do
    directory = Path.join(System.tmp_dir!(), "wotex-maude-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp copy_payload(directory) do
    for name <- Map.keys(MaudePayload.files()) do
      local = if name == "maude", do: "maude-darwin-arm64", else: name
      File.cp!(Path.join(@source, local), Path.join(directory, local))
    end
  end
end
