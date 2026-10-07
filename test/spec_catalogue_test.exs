defmodule WotexHome.SpecCatalogueTest do
  @moduledoc false

  use ExUnit.Case

  alias Mix.Tasks.Woh.Spec.Check

  setup do
    directory = Path.join(System.tmp_dir!(), "wotex-specs-#{System.unique_integer([:positive])}")
    File.cp_r!(Path.expand("../docs/specs", __DIR__), directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "the committed catalogue matches its spec contracts", %{directory: directory} do
    assert {:ok, count} = Check.check(directory)
    assert count > 0
  end

  test "a missing case and a dependency cycle fail the catalogue gate", %{directory: directory} do
    spec = Path.join(directory, "WOH.00-foundation.md")
    File.write!(spec, String.replace(File.read!(spec), "H00-T1", "removed-case"))

    catalogue = Path.join(directory, "catalogue.yaml")

    File.write!(
      catalogue,
      String.replace(File.read!(catalogue), "requires: []", "requires: [\"WOH.01\"]",
        global: false
      )
    )

    assert {:error, failures} = Check.check(directory)
    assert Enum.any?(failures, &String.contains?(&1, "H00-T1 absent"))
    assert Enum.any?(failures, &String.contains?(&1, "dependency cycle"))
  end
end
