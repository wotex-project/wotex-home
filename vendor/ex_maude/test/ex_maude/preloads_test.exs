defmodule ExMaude.PreloadsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ExMaude.Preloads

  setup do
    configured = Application.get_env(:ex_maude, :preload_modules)

    Application.put_env(:ex_maude, :preload_modules, ["/configured.maude"])

    for pool <- [:pool_a, :pool_b] do
      start_supervised!(
        ExMaude.Pool.child_spec(
          name: pool,
          pool_size: 1,
          pool_max_overflow: 0,
          maude_path: Path.expand("../support/fake_maude.sh", __DIR__),
          preload_modules: []
        )
      )
    end

    on_exit(fn ->
      restore(:preload_modules, configured)
    end)
  end

  test "keeps remembered modules isolated by pool" do
    assert :ok = Preloads.remember(:pool_a, "/a.maude")
    assert :ok = Preloads.remember(:pool_b, "/b.maude")

    assert Preloads.for_pool(:pool_a) == ["/configured.maude", "/a.maude"]
    assert Preloads.for_pool(:pool_b) == ["/configured.maude", "/b.maude"]
    assert Preloads.runtime_for_pool(:pool_a) == ["/a.maude"]
    assert Preloads.runtime_for_pool(:pool_b) == ["/b.maude"]
  end

  test "deduplicates configured and remembered modules" do
    assert :ok = Preloads.remember(:pool_a, "/configured.maude")
    assert Preloads.for_pool(:pool_a) == ["/configured.maude"]
  end

  test "reloaded configured sources follow later runtime sources" do
    :ok = Preloads.remember(:pool_a, "/runtime.maude")
    :ok = Preloads.remember(:pool_a, "/configured.maude")
    assert Preloads.for_pool(:pool_a) == ["/runtime.maude", "/configured.maude"]
  end

  test "does not lose concurrent updates" do
    paths = Enum.map(1..50, &"/concurrent-#{&1}.maude")

    paths
    |> Task.async_stream(&Preloads.remember(:pool_a, &1),
      max_concurrency: 50,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, result} -> assert result == :ok end)

    remembered = Preloads.for_pool(:pool_a) -- ["/configured.maude"]
    assert MapSet.new(remembered) == MapSet.new(paths)
  end

  test "tracks loaded content without replaying its source path" do
    suffix = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "preload_identity_#{suffix}.maude")
    File.write!(path, "fmod PRELOAD-IDENTITY is endfm")
    on_exit(fn -> File.rm(path) end)

    assert :ok = Preloads.mark_loaded(:pool_a, [path], ExMaude.Pool.checkout(pool: :pool_a))
    assert {:ok, identity} = Preloads.identity(path)
    assert identity in Preloads.loaded_for_pool(:pool_a)
    refute path in Preloads.runtime_for_pool(:pool_a)
  end

  @tag :tmp_dir
  test "loaded identities require every live worker and exclude replacements", %{tmp_dir: dir} do
    pool = :partial_identity_pool

    start_supervised!(
      ExMaude.Pool.child_spec(
        name: pool,
        pool_size: 2,
        pool_max_overflow: 0,
        preload_modules: [],
        worker_module: ExMaude.Backend.Port,
        maude_path: Path.expand("../support/fake_maude.sh", __DIR__)
      )
    )

    path = Path.join(dir, "module.maude")
    File.write!(path, "fmod IDENTITY is endfm")
    {:ok, identity} = Preloads.identity(path)
    first = ExMaude.Pool.checkout(pool: pool)
    second = ExMaude.Pool.checkout(pool: pool)

    assert :ok = Preloads.mark_loaded(pool, [path], first)
    refute identity in Preloads.loaded_for_pool(pool)
    assert :ok = Preloads.mark_loaded(pool, [path], second)
    assert identity in Preloads.loaded_for_pool(pool)

    GenServer.stop(first)
    replacement = ExMaude.Pool.checkout(pool: pool)
    refute replacement in [first, second]
    refute identity in Preloads.loaded_for_pool(pool)
    assert :ok = Preloads.mark_loaded(pool, [path], replacement)
    assert identity in Preloads.loaded_for_pool(pool)
  end

  test "identical source has distinct pool-owned files" do
    source = "fmod PRIVATE-SOURCE is endfm"
    assert {:ok, first} = Preloads.cache_source(:pool_a, source)
    assert {:ok, ^first} = Preloads.cache_source(:pool_a, source)
    assert {:ok, second} = Preloads.cache_source(:pool_b, source)
    refute Path.dirname(first) == Path.dirname(second)
    assert File.read!(first) == source
    assert File.read!(second) == source
    assert Bitwise.band(File.stat!(Path.dirname(first)).mode, 0o777) == 0o700
  end

  defp restore(key, nil), do: Application.delete_env(:ex_maude, key)
  defp restore(key, value), do: Application.put_env(:ex_maude, key, value)
end
