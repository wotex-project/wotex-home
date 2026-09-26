defmodule ExMaude.SubprocessTest do
  use ExUnit.Case, async: true

  test "collects output and exit status" do
    assert {:ok, "hello", 3} =
             ExMaude.Subprocess.run(
               System.find_executable("sh"),
               ["-c", "printf hello; exit 3"],
               1000,
               100
             )
  end

  @tag :tmp_dir
  test "terminates a child that never exits", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "child.pid")
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             ExMaude.Subprocess.run(
               System.find_executable("sh"),
               ["-c", ~s(printf '%s' "$$" > "$1"; kill -STOP "$$"), "child", pid_file],
               1000,
               100
             )

    assert System.monotonic_time(:millisecond) - started < 3000
    pid = File.read!(pid_file)
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "caps command output" do
    assert {:error, :output_too_large} =
             ExMaude.Subprocess.run(System.find_executable("sh"), ["-c", "printf 12345"], 1000, 4)
  end
end
