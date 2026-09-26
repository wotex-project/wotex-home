defmodule ExMaudeTest do
  @moduledoc false

  use ExUnit.Case

  doctest ExMaude

  @fake_maude Path.expand("support/fake_maude.sh", __DIR__)
  @delegate_pool :ex_maude_delegate_test_pool

  describe "module loading" do
    test "ExMaude module exists" do
      assert Code.ensure_loaded?(ExMaude)
    end

    test "ExMaude.Maude module exists" do
      assert Code.ensure_loaded?(ExMaude.Maude)
    end

    test "ExMaude.Pool module exists" do
      assert Code.ensure_loaded?(ExMaude.Pool)
    end

    test "ExMaude.Server module exists" do
      assert Code.ensure_loaded?(ExMaude.Server)
    end

    test "ExMaude.Parser module exists" do
      assert Code.ensure_loaded?(ExMaude.Parser)
    end
  end

  describe "iot_rules_path/0" do
    test "returns path to iot-rules.maude" do
      path = ExMaude.iot_rules_path()
      assert is_binary(path)
      assert String.ends_with?(path, "iot-rules.maude")
    end

    test "path contains priv directory" do
      path = ExMaude.iot_rules_path()
      assert String.contains?(path, "priv")
    end
  end

  describe "delegated functions" do
    test "reduce/3 is defined" do
      assert function_exported?(ExMaude, :reduce, 3)
    end

    test "rewrite/3 is defined" do
      assert function_exported?(ExMaude, :rewrite, 3)
    end

    test "search/4 is defined" do
      assert function_exported?(ExMaude, :search, 4)
    end

    test "load_file/1 is defined" do
      assert function_exported?(ExMaude, :load_file, 1)
      assert function_exported?(ExMaude, :load_file, 2)
    end

    test "load_module/1 is defined" do
      assert function_exported?(ExMaude, :load_module, 1)
      assert function_exported?(ExMaude, :load_module, 2)
    end

    test "execute/2 is defined" do
      assert function_exported?(ExMaude, :execute, 2)
    end

    test "version/0 is defined" do
      assert function_exported?(ExMaude, :version, 0)
    end
  end

  describe "public API delegation" do
    setup do
      start_supervised!(
        ExMaude.Pool.child_spec(
          name: @delegate_pool,
          worker_module: ExMaude.Backend.Port,
          maude_path: @fake_maude,
          use_pty: false,
          pool_size: 1,
          pool_max_overflow: 0
        )
      )

      {:ok, pool: @delegate_pool}
    end

    test "delegates command APIs through the configured pool", %{pool: pool} do
      assert {:ok, result} = ExMaude.reduce("NAT", "1 + 1", pool: pool)
      assert result =~ "reduce in NAT : 1 + 1"

      assert {:ok, result} = ExMaude.rewrite("NAT", "1", max_rewrites: 1, pool: pool)
      assert result =~ "rewrite [1] in NAT"

      assert {:ok, result} = ExMaude.execute("show modules .", pool: pool)
      assert result =~ "show modules"

      assert {:ok, result} = ExMaude.parse("NAT", "1 + 1", pool: pool)
      assert result =~ "parse in NAT"

      assert {:ok, result} = ExMaude.show_module("NAT", pool: pool)
      assert result =~ "show module NAT"

      assert {:ok, result} = ExMaude.list_modules(pool: pool)
      assert result =~ "show modules"
    end

    test "delegates search parsing through the configured pool", %{pool: pool} do
      assert {:ok, []} = ExMaude.search("NAT", "0", "N:Nat", pool: pool)
    end

    test "delegates module loading through the configured pool", %{pool: pool} do
      assert :ok = ExMaude.load_module("fmod TEST is sort Foo . endfm", pool: pool)
    end

    test "delegates version lookup" do
      assert {:ok, version} = ExMaude.version()
      assert is_binary(version)
    end
  end
end
