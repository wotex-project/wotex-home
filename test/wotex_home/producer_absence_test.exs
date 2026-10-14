defmodule WotexHome.ProducerAbsenceTest do
  use ExUnit.Case, async: true

  test "fresh Home-only consumer refuses absent public producers without a local substitute" do
    home_ebin =
      :code.which(WotexHome.Profiles.AuthoringContract) |> List.to_string() |> Path.dirname()

    script = """
    ExUnit.start()
    unless Code.ensure_loaded?(WotexHome.Profiles.AuthoringContract), do: System.halt(2)
    if Code.ensure_loaded?(Wotex.Profiles.Contract), do: System.halt(3)
    for file <- Path.wildcard("test/support/producer_absence/*.exs"), do: Code.require_file(file)
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa", home_ebin, "-e", script],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "4 tests, 0 failures"
  end
end
