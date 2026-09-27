defmodule WotexHome.ReleaseSpdxTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.{ReleaseComponents, ReleaseSpdx}

  @revision String.duplicate("a", 40)
  @created "2026-09-27T00:00:00Z"

  test "enumerates payload files without claiming license conclusions" do
    directory = Path.join(System.tmp_dir!(), "wotex-spdx-#{System.unique_integer([:positive])}")
    source = Path.join(directory, "source")
    release = Path.join(directory, "release")
    File.mkdir_p!(source)
    file = Path.join(release, "lib/foo-1.0/ebin/foo.beam")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "beam")
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:ok, components} = ReleaseComponents.report(release, source, @revision)
    assert {:ok, document} = ReleaseSpdx.document(release, components, @created)
    assert document["spdxVersion"] == "SPDX-2.3"
    assert length(document["packages"]) == 1
    assert length(document["files"]) == 1
    assert hd(document["packages"])["licenseConcluded"] == "NOASSERTION"
    assert hd(document["files"])["fileName"] == "./lib/foo-1.0/ebin/foo.beam"

    assert MapSet.new(Enum.map(document["relationships"], & &1["relationshipType"])) ==
             MapSet.new(~w(DESCRIBES CONTAINS))

    File.write!(file, "changed")
    assert {:ok, changed_components} = ReleaseComponents.report(release, source, @revision)
    assert {:ok, changed} = ReleaseSpdx.document(release, changed_components, @created)
    refute changed["documentNamespace"] == document["documentNamespace"]
  end

  test "rejects an invalid creation timestamp" do
    assert {:error, _} = ReleaseSpdx.document("missing", %{"components" => []}, "yesterday")
    assert ReleaseSpdx.package_id("a_b") == "SPDXRef-Package-a-b-648fa9b31bc7"
  end
end
