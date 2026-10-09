defmodule Woh.Tool.CommandTest do
  use ExUnit.Case, async: true
  alias Woh.Tool.Command

  test "ordinary failed tools discard private output; diagnostics require explicit public use" do
    assert {:error, "tool exited with status 7"} =
             Command.run(
               "sh",
               ["-c", "IFS= read -r line; printf '%s' \"$line\"; exit 7"],
               1024,
               5000,
               [],
               "private tool canary\n"
             )

    assert {:error, "tool exited with status 7\npublic fixture diagnostic\n"} =
             Command.run_diagnostic(
               "sh",
               ["-c", "printf 'public fixture diagnostic\\n'; exit 7"],
               1024,
               5000
             )
  end

  test "diagnostic output keeps the ordinary byte bound and discards partial failures" do
    assert {:error, "tool output exceeds development bound"} =
             Command.run_diagnostic(
               "sh",
               ["-c", "printf 'output above the bound'; exit 7"],
               8,
               5000
             )
  end
end
