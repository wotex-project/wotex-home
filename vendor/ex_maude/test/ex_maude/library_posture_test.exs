defmodule ExMaude.LibraryPostureTest do
  @moduledoc false

  use ExUnit.Case, async: true

  test "the Hex library has no automatic application callback" do
    assert Application.spec(:ex_maude, :mod) == []
    refute Code.ensure_loaded?(ExMaude.Application)
  end

  test "callers receive a configurable pool child spec" do
    %{id: id, start: {:poolboy, :start_link, [pool_config, worker_opts]}} =
      ExMaude.Pool.child_spec(name: :formal_verification, pool_size: 2)

    assert id == :formal_verification
    assert Supervisor.child_spec(ExMaude.Pool.child_spec(), []).id == :ex_maude_pool
    assert pool_config[:name] == {:local, :formal_verification}
    assert pool_config[:size] == 2
    assert worker_opts[:pool] == :formal_verification
  end

  test "every public documentation extra is included in the Hex package" do
    config = Mix.Project.config()
    package_files = config[:package][:files]

    public_extras =
      config[:docs][:extras]
      |> Keyword.keys()
      |> Enum.map(&to_string/1)

    assert "CONTRIBUTING.md" in public_extras
    refute "AGENTS.md" in public_extras

    for extra <- public_extras do
      assert Enum.any?(package_files, fn packaged ->
               extra == packaged or String.starts_with?(extra, packaged <> "/")
             end),
             "#{extra} is an ExDoc extra but is absent from package.files"
    end
  end
end
