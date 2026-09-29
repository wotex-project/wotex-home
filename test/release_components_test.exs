defmodule WotexHome.ReleaseComponentsTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.ReleaseComponents

  @project Path.expand("..", __DIR__)
  @revision String.duplicate("a", 40)
  @otp_license "docs/provenance/license-inputs/otp-28.5.0.6-LICENSE.txt"
  @elixir_license "docs/provenance/license-inputs/elixir-1.19.6-LICENSE"
  @maude_license "docs/provenance/license-inputs/maude-3.5.1-COPYING"
  @maude_notice "docs/provenance/license-inputs/ex-maude-THIRD_PARTY_NOTICES.md"
  @ex_maude_license "docs/provenance/license-inputs/ex-maude-LICENSE"
  @wotex_udp_license "docs/provenance/license-inputs/wotex-udp-LICENSE"
  @wotex_udp_notice "docs/provenance/license-inputs/wotex-udp-NOTICE"
  @apache_license "docs/provenance/license-inputs/apache-2.0-LICENSE.txt"

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-components-#{System.unique_integer([:positive])}")

    source = Path.join(directory, "source")
    release = Path.join(directory, "release")
    File.mkdir_p!(source)
    File.mkdir_p!(release)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, source: source, release: release}
  end

  test "pins OTP and Elixir inputs to exact source bytes", %{source: source} do
    copy_input(source, @otp_license)
    copy_input(source, @elixir_license)

    for component <- ~w(erts-16.4.0.6 compiler-9.0.6.2 elixir-1.19.6 logger-1.19.6) do
      assert {:ok, [%{"sha256" => digest}]} = ReleaseComponents.license_inputs(source, component)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
    end

    assert {:ok, []} = ReleaseComponents.license_inputs(source, "erts-16.4.0.7")
    assert {:ok, [_, _]} = ReleaseComponents.license_inputs(source, "release-wrapper")
    assert ReleaseComponents.component_for("bin/wotex_home_cli") == "home-cli"

    assert ReleaseComponents.component_for("lib/ex_maude-0.4.3/priv/maude/COPYING") ==
             "maude-bundled"

    File.write!(Path.join(source, @otp_license), "changed")
    assert {:error, reason} = ReleaseComponents.license_inputs(source, "erts-16.4.0.6")
    assert String.contains?(reason, "pinned otp license input differs")
  end

  test "keeps package notices distinct from complete license inputs", %{
    source: source,
    release: release
  } do
    for {component, name} <- [
          {"db_connection-2.10.2", "db_connection"},
          {"rustler_precompiled-0.9.0", "rustler_precompiled"}
        ] do
      for file <- ~w(README.md hex_metadata.config) do
        copy_input(source, Path.join(["deps", name, file]))
      end

      write_release(release, "lib/#{component}/ebin/package.beam", "beam")
    end

    assert {:ok, first} = ReleaseComponents.report(release, source, @revision)

    assert MapSet.new(Enum.map(first["components"], & &1["license_input_status"])) ==
             MapSet.new(["notice_only"])

    copy_input(source, @apache_license)
    assert {:ok, second} = ReleaseComponents.report(release, source, @revision)
    assert Enum.all?(second["components"], &(&1["license_input_status"] == "present"))

    assert Enum.all?(second["components"], fn item ->
             Enum.any?(item["license_inputs"], &(&1["path"] == @apache_license))
           end)

    File.write!(Path.join(source, @apache_license), "changed")
    assert {:error, reason} = ReleaseComponents.report(release, source, @revision)
    assert String.contains?(reason, "pinned Apache license input differs")
  end

  test "pins both Git dependency legal inputs independently", %{source: source} do
    for relative <- [@ex_maude_license, @maude_notice, @wotex_udp_license, @wotex_udp_notice] do
      copy_input(source, relative)
    end

    assert {:ok, [%{"path" => @ex_maude_license}, %{"path" => @maude_notice}]} =
             ReleaseComponents.license_inputs(source, "ex_maude-0.4.3")

    assert {:ok, [%{"path" => @wotex_udp_license}, %{"path" => @wotex_udp_notice}]} =
             ReleaseComponents.license_inputs(source, "wotex_udp-0.1.0")

    File.write!(Path.join(source, @wotex_udp_notice), "changed")

    assert {:error, reason} = ReleaseComponents.license_inputs(source, "wotex_udp-0.1.0")
    assert String.contains?(reason, "pinned WoTEx UDP notice license input differs")
  end

  test "binds payload groups and detects drift or symlinks", %{source: source, release: release} do
    write_release(release, "lib/foo-1.0/ebin/foo.beam", "beam")
    write_release(release, "lib/ex_maude-0.4.3/priv/maude/bin/maude", "native")
    write_release(release, "erts-1/bin/beam.smp", "runtime")
    copy_input(source, @maude_notice)
    File.mkdir_p!(Path.join(source, "deps/foo"))
    File.write!(Path.join(source, "deps/foo/LICENSE"), "license input")

    assert {:ok, first} = ReleaseComponents.create(release, source, @revision)
    assert {:ok, _} = ReleaseComponents.verify(release, source, @revision)
    groups = Map.new(first["components"], &{&1["name"], &1})
    assert first["file_count"] == 3
    assert groups["maude-bundled"]["license_input_status"] == "notice_only"
    assert groups["erts-1"]["license_input_status"] == "missing"
    assert groups["foo-1.0"]["license_input_status"] == "present"

    copy_input(source, @maude_license)
    assert {:ok, with_license} = ReleaseComponents.report(release, source, @revision)
    licensed = Map.new(with_license["components"], &{&1["name"], &1})
    assert licensed["maude-bundled"]["license_input_status"] == "present"

    assert {:error, "release components or license inputs differ from report"} =
             ReleaseComponents.verify(release, source, @revision)

    File.write!(Path.join(release, "lib/foo-1.0/ebin/foo.beam"), "changed")
    assert {:ok, changed} = ReleaseComponents.report(release, source, @revision)
    changed_groups = Map.new(changed["components"], &{&1["name"], &1})
    refute groups["foo-1.0"]["files_sha256"] == changed_groups["foo-1.0"]["files_sha256"]

    File.ln_s!("foo.beam", Path.join(release, "lib/foo-1.0/ebin/link"))

    assert {:error, "symlink in release: lib/foo-1.0/ebin/link"} =
             ReleaseComponents.packaged_components(release)
  end

  defp copy_input(source, relative) do
    destination = Path.join(source, relative)
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Path.join(@project, relative), destination)
  end

  defp write_release(root, relative, bytes) do
    destination = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, bytes)
  end
end
