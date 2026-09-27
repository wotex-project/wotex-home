defmodule WotexHome.MaudePayloadCheckTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.MaudePayload

  @source Path.expand("../vendor/ex_maude/priv/maude/bin", __DIR__)

  test "the pinned vendor payload passes and a changed byte fails" do
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
