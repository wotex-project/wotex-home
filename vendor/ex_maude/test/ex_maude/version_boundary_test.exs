defmodule ExMaude.VersionBoundaryTest do
  use ExUnit.Case, async: false

  alias ExMaude.{Error, Maude}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    timeout = Application.get_env(:ex_maude, :timeout)

    on_exit(fn ->
      if timeout,
        do: Application.put_env(:ex_maude, :timeout, timeout),
        else: Application.delete_env(:ex_maude, :timeout)
    end)

    %{path: Path.join(tmp_dir, "maude")}
  end

  test "returns version output and preserves nonzero-exit errors", %{path: path} do
    executable(path, ~s([ "$1" = "--version" ] || exit 2\nprintf '3.5.1\\n'))
    assert Maude.version(path) == {:ok, "3.5.1"}

    executable(path, "printf 'bad executable'\nexit 3")
    assert {:error, %Error{type: :maude_crash, message: message}} = Maude.version(path)
    assert message =~ "exited 3: bad executable"
  end

  test "bounds output from a noisy executable", %{path: path} do
    executable(path, "while :; do printf '0123456789abcdef'; done")

    assert {:error, %Error{type: :response_too_large, details: %{max_response_bytes: 65_536}}} =
             Maude.version(path)
  end

  test "terminates a stuck version probe", %{path: path} do
    executable(path, ~s|printf '%s' "$$" > "$0.pid"\nkill -STOP "$$"|)
    Application.put_env(:ex_maude, :timeout, 1_000)

    assert {:error, %Error{type: :timeout, details: %{timeout_ms: 1_000}}} = Maude.version(path)
    os_pid = File.read!(path <> ".pid")

    assert Enum.any?(1..100, fn _ ->
             case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
               {_, 0} ->
                 Process.sleep(10)
                 false

               _ ->
                 true
             end
           end)
  end

  test "returns an explicit error for a missing executable", %{path: path} do
    assert {:error, %Error{type: :file_not_found}} = Maude.version(path)
  end

  defp executable(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end
end
