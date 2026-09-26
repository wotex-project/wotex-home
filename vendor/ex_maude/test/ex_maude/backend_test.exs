defmodule ExMaude.BackendTest do
  @moduledoc """
  Tests backend selection and backend availability reporting.

  This suite mutates global application configuration with
  `Application.put_env/3`, so it must not run concurrently with suites that
  read the same configuration.
  """

  use ExUnit.Case, async: false

  alias ExMaude.Backend

  doctest ExMaude.Backend

  describe "impl/0" do
    test "returns Port backend by default" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.delete_env(:ex_maude, :backend)
        assert Backend.impl() == ExMaude.Backend.Port
      after
        if original, do: Application.put_env(:ex_maude, :backend, original)
      end
    end

    test "returns Port backend when configured" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.put_env(:ex_maude, :backend, :port)
        assert Backend.impl() == ExMaude.Backend.Port
      after
        if original do
          Application.put_env(:ex_maude, :backend, original)
        else
          Application.delete_env(:ex_maude, :backend)
        end
      end
    end

    test "returns CNode backend when configured" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.put_env(:ex_maude, :backend, :cnode)
        assert Backend.impl() == ExMaude.Backend.CNode
      after
        if original do
          Application.put_env(:ex_maude, :backend, original)
        else
          Application.delete_env(:ex_maude, :backend)
        end
      end
    end

    test "returns NIF backend when configured" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.put_env(:ex_maude, :backend, :nif)
        assert Backend.impl() == ExMaude.Backend.NIF
      after
        if original do
          Application.put_env(:ex_maude, :backend, original)
        else
          Application.delete_env(:ex_maude, :backend)
        end
      end
    end
  end

  describe "available?/1" do
    test "port backend is always available" do
      assert Backend.available?(:port) == true
    end

    test "cnode availability depends on binary" do
      result = Backend.available?(:cnode)
      assert is_boolean(result)
    end

    test "nif availability depends on loaded module" do
      result = Backend.available?(:nif)
      assert is_boolean(result)
    end
  end

  describe "behaviour callbacks" do
    test "Port backend implements all callbacks" do
      Code.ensure_loaded!(ExMaude.Backend.Port)

      assert function_exported?(ExMaude.Backend.Port, :start_link, 1)
      assert function_exported?(ExMaude.Backend.Port, :execute, 3)
      assert function_exported?(ExMaude.Backend.Port, :alive?, 1)
      assert function_exported?(ExMaude.Backend.Port, :load_file, 2)
      assert function_exported?(ExMaude.Backend.Port, :stop, 1)
    end

    test "CNode backend implements all callbacks" do
      Code.ensure_loaded!(ExMaude.Backend.CNode)

      assert function_exported?(ExMaude.Backend.CNode, :start_link, 1)
      assert function_exported?(ExMaude.Backend.CNode, :execute, 3)
      assert function_exported?(ExMaude.Backend.CNode, :alive?, 1)
      assert function_exported?(ExMaude.Backend.CNode, :load_file, 2)
      assert function_exported?(ExMaude.Backend.CNode, :stop, 1)
    end

    test "NIF backend implements all callbacks" do
      Code.ensure_loaded!(ExMaude.Backend.NIF)

      assert function_exported?(ExMaude.Backend.NIF, :start_link, 1)
      assert function_exported?(ExMaude.Backend.NIF, :execute, 3)
      assert function_exported?(ExMaude.Backend.NIF, :alive?, 1)
      assert function_exported?(ExMaude.Backend.NIF, :load_file, 2)
      assert function_exported?(ExMaude.Backend.NIF, :stop, 1)
    end
  end

  describe "cnode_binary/0" do
    test "returns path in priv directory" do
      path = Backend.cnode_binary()
      assert String.contains?(path, "priv")
      assert String.ends_with?(path, "maude_bridge")
    end
  end

  describe "available_backends/0" do
    test "returns a list of available backends" do
      backends = Backend.available_backends()
      assert is_list(backends)
      assert :port in backends
    end

    test "only includes available backends" do
      backends = Backend.available_backends()

      for backend <- backends do
        assert Backend.available?(backend)
      end
    end
  end

  describe "available?/1 edge cases" do
    test "cnode checks executable permission" do
      result = Backend.available?(:cnode)
      assert is_boolean(result)

      if result do
        path = Backend.cnode_binary()
        assert File.exists?(path)
        stat = File.stat!(path)
        assert Bitwise.band(stat.mode, 0o111) > 0
      end
    end

    test "nif returns a boolean reflecting NIF load state" do
      result = Backend.available?(:nif)
      assert is_boolean(result)
    end
  end
end
