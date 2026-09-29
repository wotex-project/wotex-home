defmodule WotexHome.IsolatedSmokeTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.IsolatedSmoke

  test "staged Git dependencies contain only the pinned committed source" do
    root =
      Path.join(System.tmp_dir!(), "wotex-source-stage-#{System.unique_integer([:positive])}")

    project = Path.join(root, "project")
    checkout = Path.join(root, "checkout")
    on_exit(fn -> File.rm_rf!(root) end)

    pins =
      for app <- [:ex_maude, :wotex_udp], into: %{} do
        source = Path.join([project, "deps", Atom.to_string(app)])
        File.mkdir_p!(source)
        git!(source, ["init", "-q"])
        File.write!(Path.join(source, ".gitignore"), "ignored.tmp\n")
        File.write!(Path.join(source, "README.md"), "committed\n")
        git!(source, ["add", "."])

        git!(source, [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.invalid",
          "commit",
          "-qm",
          "fixture"
        ])

        pin = git!(source, ["rev-parse", "HEAD"])
        File.write!(Path.join(source, "README.md"), "modified\n")
        File.write!(Path.join(source, "ignored.tmp"), "local artifact\n")
        {app, pin}
      end

    assert :ok = IsolatedSmoke.stage_pinned_git_deps(project, checkout, pins)

    for {app, pin} <- pins do
      staged = Path.join([checkout, "deps", Atom.to_string(app)])
      assert git!(staged, ["rev-parse", "HEAD"]) == pin
      assert git!(staged, ["status", "--porcelain"]) == ""
      assert File.read!(Path.join(staged, "README.md")) == "committed\n"
      refute File.exists?(Path.join(staged, "ignored.tmp"))
    end
  end

  defp git!(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git exited #{status}: #{output}")
    end
  end
end
