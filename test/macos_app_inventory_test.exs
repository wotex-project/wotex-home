defmodule WotexHome.MacosAppInventoryTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.{MacosAppInventory, ReleaseInventory}

  @revision String.duplicate("a", 40)
  @helper "Contents/Library/LoginItems/WotexHomeAgent.app/Contents"

  @tag skip: :os.type() != {:unix, :darwin}
  test "binds the outer app to its embedded release and detects drift" do
    directory =
      Path.join(System.tmp_dir!(), "wotex-app-inventory-#{System.unique_integer([:positive])}")

    app = Path.join(directory, "WotexHome.app")
    release = Path.join(app, MacosAppInventory.release_path())
    File.mkdir_p!(release)
    on_exit(fn -> File.rm_rf!(directory) end)

    for {relative, bytes} <- [
          {"Contents/MacOS/WotexHome", "swift"},
          {"#{@helper}/MacOS/WotexHomeAgent", "helper"},
          {"Contents/Resources/app.spdx.json", "{}"},
          {"#{MacosAppInventory.release_path()}/bin/wotex_home", "otp"},
          {"#{MacosAppInventory.release_path()}/release-components.json", "{}"},
          {"#{MacosAppInventory.release_path()}/release.spdx.json", "{}"}
        ] do
      path = Path.join(app, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    for relative <- [
          "Contents/MacOS/WotexHome",
          "#{@helper}/MacOS/WotexHomeAgent",
          "#{MacosAppInventory.release_path()}/bin/wotex_home"
        ] do
      File.chmod!(Path.join(app, relative), 0o755)
    end

    info = Path.join(app, "Contents/Info.plist")

    File.write!(
      info,
      plist(%{
        "WotexHomeSourceRevision" => @revision,
        "CFBundleIdentifier" => "org.wotex.home"
      })
    )

    agent = Path.join(app, "Contents/Library/LaunchAgents/org.wotex.home.agent.plist")
    File.mkdir_p!(Path.dirname(agent))

    File.write!(
      agent,
      plist(%{
        "BundleProgram" => "#{@helper}/MacOS/WotexHomeAgent",
        "Label" => "org.wotex.home.agent",
        "ThrottleInterval" => 10
      })
    )

    helper = Path.join(app, "#{@helper}/Info.plist")

    metadata = %{
      "CFBundleIdentifier" => "org.wotex.home.agent",
      "CFBundleExecutable" => "WotexHomeAgent",
      "CFBundlePackageType" => "APPL",
      "LSMinimumSystemVersion" => "15.0",
      "WotexHomeSourceRevision" => @revision
    }

    File.write!(helper, plist(metadata))
    assert {:ok, 3} = ReleaseInventory.create(release, @revision)

    assert {:ok, count} = MacosAppInventory.create(app, @revision)
    assert count > 3
    assert {:ok, ^count} = MacosAppInventory.verify(app)

    for {field, wrong} <- [
          {"CFBundleIdentifier", "org.wotex.home"},
          {"CFBundleExecutable", "elsewhere"},
          {"CFBundlePackageType", "BNDL"},
          {"LSMinimumSystemVersion", "14.0"},
          {"WotexHomeSourceRevision", String.duplicate("b", 40)}
        ] do
      File.write!(helper, plist(Map.put(metadata, field, wrong)))

      assert {:error, "agent helper metadata differs from its fixed profile"} =
               MacosAppInventory.create(app, @revision)
    end

    File.write!(helper, plist(metadata))

    File.write!(Path.join(app, "Contents/MacOS/WotexHome"), "changed")
    assert {:error, _} = MacosAppInventory.verify(app)
  end

  test "refuses a symlink in the app bundle" do
    directory =
      Path.join(System.tmp_dir!(), "wotex-app-link-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    File.ln_s!("elsewhere", Path.join(directory, "shortcut"))
    assert {:error, "symlink in app: shortcut"} = MacosAppInventory.entries(directory)
  end

  defp plist(values) do
    fields =
      Enum.map_join(values, "", fn {key, value} ->
        tag = if is_integer(value), do: "integer", else: "string"
        "<key>#{key}</key><#{tag}>#{value}</#{tag}>"
      end)

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" <>
      "<plist version=\"1.0\"><dict>#{fields}</dict></plist>"
  end
end
