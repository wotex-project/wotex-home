defmodule WotexHome.MacosAppSpdxTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.{MacosAppSpdx, ReleaseComponents, ReleaseInventory, ReleaseSpdx}

  @revision String.duplicate("a", 40)
  @created "2026-09-27T00:00:00Z"

  @tag skip: :os.type() != {:unix, :darwin}
  test "covers the embedded release and native app without license claims" do
    directory =
      Path.join(System.tmp_dir!(), "wotex-app-spdx-#{System.unique_integer([:positive])}")

    app = Path.join(directory, "WotexHome.app")
    source = Path.join(directory, "source")
    release = Path.join(app, "Contents/Resources/WotexHomeRelease")
    File.mkdir_p!(source)
    File.mkdir_p!(release)
    on_exit(fn -> File.rm_rf!(directory) end)

    write_file(release, "bin/wotex_home", "otp")
    assert {:ok, components} = ReleaseComponents.report(release, source, @revision)
    write_file(release, "release-components.json", JSON.encode!(components))
    assert {:ok, document} = ReleaseSpdx.document(release, components, @created)
    write_file(release, "release.spdx.json", JSON.encode!(document))
    assert {:ok, 3} = ReleaseInventory.create(release, @revision)

    write_file(app, "Contents/MacOS/WotexHome", "swift")
    write_file(app, "Contents/MacOS/WotexHomeAgent", "helper")

    write_file(
      app,
      "Contents/Info.plist",
      plist(%{"WotexHomeSourceRevision" => @revision, "CFBundleIdentifier" => "org.wotex.home"})
    )

    write_file(
      app,
      "Contents/Library/LaunchAgents/org.wotex.home.agent.plist",
      plist(%{"BundleProgram" => "Contents/MacOS/WotexHomeAgent"})
    )

    assert {:ok, count} = MacosAppSpdx.create(app)
    assert count > 4
    assert {:ok, ^count} = MacosAppSpdx.verify(app)

    outer = JSON.decode!(File.read!(Path.join(app, MacosAppSpdx.report_name())))
    assert Enum.all?(outer["packages"], &(&1["licenseConcluded"] == "NOASSERTION"))
    assert Enum.any?(outer["packages"], &(&1["name"] == "embedded-release-wrapper"))

    File.write!(Path.join(app, "Contents/MacOS/WotexHome"), "changed")
    assert {:error, _} = MacosAppSpdx.verify(app)
  end

  defp write_file(root, relative, bytes) do
    destination = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, bytes)
  end

  defp plist(values) do
    fields =
      Enum.map_join(values, "", fn {key, value} ->
        "<key>#{key}</key><string>#{value}</string>"
      end)

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" <>
      "<plist version=\"1.0\"><dict>#{fields}</dict></plist>"
  end
end
