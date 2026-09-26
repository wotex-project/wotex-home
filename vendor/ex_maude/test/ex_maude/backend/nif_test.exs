defmodule ExMaude.Backend.NIFTest do
  @moduledoc """
  Tests NIF backend structure, availability, and backend selection.

  This suite mutates global application configuration with
  `Application.put_env/3`, so it must not run concurrently with suites that
  read the same configuration.
  """

  use ExUnit.Case, async: false

  alias ExMaude.Backend
  alias ExMaude.Backend.NIF

  describe "module structure" do
    setup do
      Code.ensure_loaded!(NIF)
      :ok
    end

    test "implements Backend behaviour" do
      behaviours = NIF.__info__(:attributes)[:behaviour] || []
      assert ExMaude.Backend in behaviours
    end

    test "is a GenServer" do
      assert function_exported?(NIF, :init, 1)
      assert function_exported?(NIF, :handle_call, 3)
      assert function_exported?(NIF, :handle_info, 2)
      assert function_exported?(NIF, :terminate, 2)
    end

    test "exports all Backend callbacks" do
      assert function_exported?(NIF, :start_link, 1)
      assert function_exported?(NIF, :execute, 3)
      assert function_exported?(NIF, :alive?, 1)
      assert function_exported?(NIF, :load_file, 2)
      assert function_exported?(NIF, :stop, 1)
    end
  end

  describe "availability" do
    @tag :nif
    test "available? returns true when the NIF is loaded" do
      assert Backend.available?(:nif)
    end
  end

  describe "startup failure" do
    test "returns a structured error when the NIF is not loaded" do
      if Backend.available?(:nif) do
        assert true
      else
        original_flag = Process.flag(:trap_exit, true)

        try do
          assert {:error, {:nif_not_loaded, message}} =
                   NIF.start_link(maude_path: "maude", startup_timeout_ms: 10)

          assert message =~ "NIF binary failed to load"
        after
          Process.flag(:trap_exit, original_flag)
        end
      end
    end
  end

  describe "callback behavior" do
    test "execute stops on native errors" do
      state = %NIF{handle: make_ref()}
      expected_type = if Backend.available?(:nif), do: :nif_error, else: :nif_not_loaded

      assert {:stop, {:shutdown, {:native_failure, ^expected_type}}, {:error, error}, ^state} =
               NIF.handle_call({:execute, "reduce in NAT : 1 .", 10}, self(), state)

      assert error.type == expected_type
    end

    test "load_file stops on native errors" do
      state = %NIF{handle: make_ref()}
      expected_type = if Backend.available?(:nif), do: :nif_error, else: :nif_not_loaded

      assert {:stop, {:shutdown, {:native_failure, ^expected_type}}, {:error, error}, ^state} =
               NIF.handle_call({:load_file, "/tmp/missing.maude", 10}, self(), state)

      assert error.type == expected_type
    end

    test "alive? returns false when the native call raises" do
      state = %NIF{handle: make_ref()}

      assert {:reply, false, ^state} = NIF.handle_call(:alive?, self(), state)
    end

    test "unrelated info messages are ignored" do
      state = %NIF{}

      assert {:noreply, ^state} = NIF.handle_info(:unrelated, state)
    end

    test "terminate tolerates a missing native handle" do
      assert :ok = NIF.terminate(:normal, %NIF{handle: nil})
    end
  end

  describe "native stubs" do
    test "raise nif_not_loaded when no native library is available" do
      if Backend.available?(:nif) do
        assert true
      else
        assert catch_error(NIF.Native.nif_loaded()) == :nif_not_loaded
        assert catch_error(NIF.Native.start("maude")) == :nif_not_loaded
        assert catch_error(NIF.Native.start_with_timeout("maude", 10)) == :nif_not_loaded

        assert catch_error(NIF.Native.execute_with_timeout(make_ref(), "cmd", 10)) ==
                 :nif_not_loaded

        assert catch_error(NIF.Native.execute_with_limit(make_ref(), "cmd", 10, 1024)) ==
                 :nif_not_loaded

        assert catch_error(NIF.Native.stop(make_ref())) == :nif_not_loaded
        assert catch_error(NIF.Native.alive(make_ref())) == :nif_not_loaded
        assert catch_error(NIF.Native.child_pid(make_ref())) == :nif_not_loaded
        assert catch_error(NIF.Native.last_spawned_pid()) == :nif_not_loaded
      end
    end
  end

  describe "configuration" do
    test "impl returns NIF when configured" do
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
end
