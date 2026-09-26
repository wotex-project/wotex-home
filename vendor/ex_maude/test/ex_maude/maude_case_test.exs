defmodule ExMaude.MaudeCaseTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.MaudeCase

  describe "maude_available?/0" do
    test "returns boolean" do
      result = MaudeCase.maude_available?()
      assert is_boolean(result)
    end
  end

  describe "maude_path/0" do
    test "returns nil or string" do
      result = MaudeCase.maude_path()
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "create_temp_module/1" do
    test "creates a file with given content" do
      source = "fmod TEST-MODULE is sort Foo . endfm"
      path = MaudeCase.create_temp_module(source)

      assert File.exists?(path)
      assert File.read!(path) == source
      assert String.ends_with?(path, ".maude")
    end

    test "creates unique files for each call" do
      path1 = MaudeCase.create_temp_module("fmod A is endfm")
      path2 = MaudeCase.create_temp_module("fmod B is endfm")

      assert path1 != path2
      assert File.exists?(path1)
      assert File.exists?(path2)
    end

    test "file is in temp directory" do
      path = MaudeCase.create_temp_module("fmod C is endfm")
      tmp_dir = System.tmp_dir!()

      assert String.starts_with?(path, tmp_dir)
    end
  end
end
