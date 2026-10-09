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

  test "embedded packaged Store probe verifies schedule custody and restart against current code" do
    runner = File.read!(Path.expand("../bin/build.exs", __DIR__))
    [_, probe] = Regex.run(~r/@packaged_store_check ~S"""\n(.*?)\n  """/s, runner)
    paths = :code.get_path() |> Enum.map(&to_string/1)
    # A failing probe reports only its source line, never random fixture custody.
    wrapped =
      "try do\n" <>
        probe <>
        "\nrescue\n _ -> IO.puts(\"PACKAGED_STORE_FAILED at line \" <> to_string(Keyword.get(elem(hd(__STACKTRACE__), 3), :line, 0)))\nend"

    arguments = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", wrapped]

    assert {:ok, output} =
             Woh.Tool.Command.run(System.find_executable("elixir"), arguments, 1_048_576, 30_000)

    assert output =~ "PACKAGED_STORE_OK; schema28 schedule admission/original restart/backup"
  end
end
