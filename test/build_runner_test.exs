defmodule WotexHome.BuildRunnerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  test "invalid or duplicate cache selection never begins a build" do
    runner = Path.expand("../bin/build.exs", __DIR__)

    for arguments <- [
          ["--dependency-env", "dev"],
          ["--dependency-env", "prod", "--dependency-env", "test"],
          ["--overwrite"],
          ["unexpected-path"]
        ] do
      {output, status} =
        System.cmd(System.find_executable("elixir"), [runner | arguments], stderr_to_stdout: true)

      assert status != 0
      assert output =~ "usage: elixir bin/build.exs"
      refute output =~ "Compiling"
      refute output =~ "assembling"
    end
  end
end
