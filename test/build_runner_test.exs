defmodule WotexHome.BuildRunnerTest do
  @moduledoc false

  # The packaged probe launches its own BEAM and exercises real crypto,
  # SQLite, finite Authority guards and private custody. Run its positive
  # release checks after the suite's concurrent fixtures rather than competing
  # for their CPU/filesystem budget. Production guards/deadlines stay unchanged.
  use ExUnit.Case, async: false

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
    # A failing probe reports only a bounded class/line, never the exception
    # term or arguments, which may contain random fixture custody.
    wrapped =
      "try do\n" <>
        probe <>
        "\nrescue\n error ->\n" <>
        " class = case error do\n" <>
        " %MatchError{} -> \"unexpected_result\"\n" <>
        " %File.Error{} -> \"private_file_unavailable\"\n" <>
        " %ArgumentError{} -> \"invalid_fixture\"\n" <>
        " _ -> \"probe_exception\"\n end\n" <>
        " IO.puts(\"PACKAGED_STORE_FAILED \" <> class <> \" at line \" <> to_string(Keyword.get(elem(hd(__STACKTRACE__), 3), :line, 0)))\nend"

    arguments = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", wrapped]

    assert {:ok, output} =
             Woh.Tool.Command.run(System.find_executable("elixir"), arguments, 1_048_576, 30_000)

    assert output =~ "PACKAGED_STORE_OK;"
    assert output =~ "private installation identity custody/TLS options"
    assert output =~ "schema28 schedule admission/original restart/backup"
  end
end
