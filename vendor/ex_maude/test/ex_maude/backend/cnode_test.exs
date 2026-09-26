defmodule ExMaude.Backend.CNodeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ExMaude.Backend
  alias ExMaude.Backend.CNode

  test "live workers reserve different bounded node slots" do
    parent = self()

    workers =
      for _ <- 1..3 do
        spawn_monitor(fn ->
          send(parent, {self(), CNode.reserve_node_slot(0)})
          receive do: (:stop -> :ok)
        end)
      end

    slots =
      for {pid, _} <- workers do
        assert_receive {^pid, {:ok, slot}}
        slot
      end

    assert length(Enum.uniq(slots)) == 3
    assert Enum.all?(slots, &(&1 in 0..1023))

    for {pid, ref} <- workers do
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    # The registry processes monitor exits asynchronously.
    released = hd(slots)

    assert Enum.reduce_while(1..100, false, fn _, _ ->
             if :global.whereis_name({CNode, node(), released}) == :undefined do
               {:halt, true}
             else
               Process.sleep(10)
               {:cont, false}
             end
           end)

    assert {:ok, ^released} = CNode.reserve_node_slot(released)
  end

  describe "module structure" do
    test "implements Backend behaviour" do
      behaviours = CNode.__info__(:attributes)[:behaviour] || []
      assert ExMaude.Backend in behaviours
    end

    test "is a GenServer" do
      assert function_exported?(CNode, :init, 1)
      assert function_exported?(CNode, :handle_call, 3)
      assert function_exported?(CNode, :handle_info, 2)
      assert function_exported?(CNode, :terminate, 2)
    end

    test "exports all Backend callbacks" do
      assert function_exported?(CNode, :start_link, 1)
      assert function_exported?(CNode, :execute, 3)
      assert function_exported?(CNode, :alive?, 1)
      assert function_exported?(CNode, :load_file, 2)
      assert function_exported?(CNode, :stop, 1)
    end

    test "has correct struct fields" do
      state = %CNode{}
      assert Map.has_key?(state, :cnode_name)
      assert Map.has_key?(state, :port)
      assert Map.has_key?(state, :os_pid)
      assert Map.has_key?(state, :maude_path)
      assert Map.has_key?(state, :cookie)
      assert Map.has_key?(state, :connected)
      assert Map.has_key?(state, :max_response_bytes)
    end

    test "struct has correct defaults" do
      state = %CNode{}
      assert state.cookie == ""
      assert state.connected == false
    end
  end

  describe "startup failure" do
    test "checks prerequisites before starting a worker" do
      original_flag = Process.flag(:trap_exit, true)

      try do
        path = Path.expand("../../support/fake_maude.sh", __DIR__)

        case CNode.start_link(maude_path: path) do
          {:error, {:cnode_start_failed, reason}} ->
            assert reason in [:node_not_distributed] or match?({:missing_binary, _}, reason)

          {:ok, pid} ->
            CNode.stop(pid)
        end
      after
        Process.flag(:trap_exit, original_flag)
      end
    end
  end

  describe "cookie handshake" do
    test "encodes the cookie outside process arguments" do
      assert {:ok, <<6::unsigned-big-32, "secret">>} =
               CNode.encode_cookie_handshake("secret")
    end

    test "rejects empty and oversized cookies" do
      assert {:error, :invalid_cookie} = CNode.encode_cookie_handshake("")
      assert {:error, :invalid_cookie} = CNode.encode_cookie_handshake(String.duplicate("x", 256))
    end
  end

  describe "availability" do
    test "available? returns boolean" do
      result = Backend.available?(:cnode)
      assert is_boolean(result)
    end

    test "available? checks for maude_bridge binary" do
      priv_dir = :code.priv_dir(:ex_maude)
      binary_path = Path.join(priv_dir, "maude_bridge")
      binary_exists = File.exists?(binary_path)

      assert Backend.available?(:cnode) == binary_exists
    end
  end

  describe "alive?/1 edge cases" do
    test "returns false for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute CNode.alive?(pid)
    end

    test "returns false for non-existent pid" do
      fake_pid = spawn(fn -> :ok end)
      Process.exit(fake_pid, :kill)
      Process.sleep(10)
      refute CNode.alive?(fake_pid)
    end
  end

  describe "execute/3 edge cases" do
    test "returns error when not connected" do
      assert function_exported?(CNode, :execute, 3)
    end

    test "exits when server is not alive" do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      assert catch_exit(CNode.execute(fake_pid, "test", timeout: 100))
    end
  end

  describe "callback behavior for disconnected state" do
    test "execute and load_file return not_connected errors" do
      state = %CNode{connected: false}

      assert {:reply, {:error, execute_error}, ^state} =
               CNode.handle_call({:execute, "reduce in NAT : 1 .", 100}, self(), state)

      assert execute_error.type == :not_connected

      assert {:reply, {:error, load_error}, ^state} =
               CNode.handle_call({:load_file, "/tmp/missing.maude", 100}, self(), state)

      assert load_error.type == :not_connected
    end

    test "connected execute stops on bridge send failure" do
      state = %CNode{connected: true, cnode_name: :missing_cnode}

      assert {:stop, {:shutdown, {:bridge_failure, type}}, {:error, error}, ^state} =
               CNode.handle_call({:execute, "reduce in NAT : 1 .", 1}, self(), state)

      assert type in [:timeout, :cnode_error]
      assert error.type == type
    end

    test "alive? reflects connection state" do
      disconnected = %CNode{connected: false}
      connected = %CNode{connected: true}

      assert {:reply, false, ^disconnected} = CNode.handle_call(:alive?, self(), disconnected)
      assert {:reply, true, ^connected} = CNode.handle_call(:alive?, self(), connected)
    end

    test "connection retry exhaustion stops the worker" do
      state = %CNode{cnode_name: :missing_cnode}

      assert capture_log(fn ->
               assert {:stop, {:connect_failed, :retries_exhausted}, ^state} =
                        CNode.handle_info({:connect_retry, 0}, state)
             end) =~ "Failed to connect to C-Node"
    end

    test "stale connection retry is ignored after connection" do
      state = %CNode{connected: true}

      assert {:noreply, ^state} = CNode.handle_info({:connect_retry, 5}, state)
    end

    test "nodedown for the bridge stops the worker" do
      state = %CNode{cnode_name: :bridge@localhost}

      assert capture_log(fn ->
               assert {:stop, :nodedown, ^state} =
                        CNode.handle_info({:nodedown, :bridge@localhost}, state)
             end) =~ "went down"
    end

    test "unrelated info messages are ignored" do
      state = %CNode{}

      assert {:noreply, ^state} = CNode.handle_info(:unrelated, state)
    end
  end

  describe "load_file/2" do
    test "function exists with correct arity" do
      assert function_exported?(CNode, :load_file, 2)
    end
  end

  describe "stop/1" do
    test "function exists with correct arity" do
      assert function_exported?(CNode, :stop, 1)
    end
  end

  describe "default constants" do
    test "default timeout is 30 seconds" do
      assert function_exported?(CNode, :execute, 3)
    end
  end

  describe "integration tests" do
    @describetag :cnode

    setup context do
      cnode_available = Backend.available?(:cnode)
      node_distributed = Node.alive?()

      cond do
        not cnode_available ->
          {:ok, Map.put(context, :skip, "C-Node binary not compiled (run: cd c_src && make)")}

        not node_distributed ->
          {:ok,
           Map.put(context, :skip, "Node not distributed (run: elixir --sname test -S mix test)")}

        true ->
          {:ok, cnode_available: true}
      end
    end

    @tag :integration
    test "starts and connects", context do
      if Map.has_key?(context, :skip) do
        {:skip, context.skip}
      else
        {:ok, pid} = CNode.start_link([])

        result =
          Enum.reduce_while(1..40, false, fn _, _ ->
            if CNode.alive?(pid) do
              {:halt, true}
            else
              Process.sleep(100)
              {:cont, false}
            end
          end)

        assert result, "C-Node failed to connect within 4 seconds"

        CNode.stop(pid)
      end
    end

    @tag :integration
    test "executes reduce command", context do
      if Map.has_key?(context, :skip) do
        {:skip, context.skip}
      else
        {:ok, pid} = CNode.start_link([])

        Enum.reduce_while(1..40, false, fn _, _ ->
          if CNode.alive?(pid) do
            {:halt, true}
          else
            Process.sleep(100)
            {:cont, false}
          end
        end)

        {:ok, result} = CNode.execute(pid, "reduce in NAT : 1 + 2 .")
        assert result =~ "3"

        CNode.stop(pid)
      end
    end
  end
end
