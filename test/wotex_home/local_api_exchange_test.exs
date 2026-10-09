defmodule WotexHome.LocalAPIExchangeTest do
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Exchange
  import ExUnit.CaptureLog

  setup do
    root = Path.join(System.tmp_dir!(), "woh-exchange-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, path: Path.join(root, "home.sqlite")})
    {:ok, credential, _} = Store.provision_principal(store, "reader:exchange", ["read"], [])

    request = %{
      "api_version" => 1,
      "operation" => "health",
      "credential" => Base.url_encode64(credential, padding: false)
    }

    %{store: store, authority: Authority.new(store: store), request: request}
  end

  test "expired ordinary budgets refuse before creating an execution process", c do
    assert %{"outcome" => "error", "reason" => "request_timeout"} =
             Exchange.perform(c.authority, c.request, System.monotonic_time(:millisecond) - 1)

    assert %{"outcome" => "error", "reason" => "outcome_unknown"} =
             Exchange.perform(
               c.authority,
               %{c.request | "operation" => "submit"},
               System.monotonic_time(:millisecond) - 1
             )

    assert {:ok, 1} = Store.revision(c.store)
  end

  test "Store-call failure emits closed read/mutation outcomes without logging the credential",
       c do
    :ok = stop_supervised(Store)

    log =
      capture_log(fn ->
        assert %{"outcome" => "error", "reason" => "operation_unavailable"} =
                 Exchange.perform(
                   c.authority,
                   c.request,
                   System.monotonic_time(:millisecond) + 1_000
                 )

        request =
          Map.put(c.request, "operation", "begin_maintenance")
          |> Map.merge(%{
            "authority_epoch" => 1,
            "operation_id" => "maint:failed",
            "expected_revision" => 1
          })

        assert %{"outcome" => "error", "reason" => "outcome_unknown"} =
                 Exchange.perform(
                   c.authority,
                   request,
                   System.monotonic_time(:millisecond) + 1_000
                 )
      end)

    assert log == ""
  end

  for event <- [:caller_loss, :deadline] do
    test "#{event} kills the actual guarded route worker even while Store is suspended", c do
      :ok = :sys.suspend(c.store)
      parent = self()

      caller =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          result =
            Exchange.perform(
              c.authority,
              c.request,
              System.monotonic_time(:millisecond) +
                unquote(if event == :deadline, do: 150, else: 5_000)
            )

          send(parent, {:result, result})
        end)

      :erlang.trace(caller, true, [:procs, :set_on_spawn])
      send(caller, :go)
      assert_receive {:trace, ^caller, :spawn, guard, _}, 1_000
      assert_receive {:trace, ^guard, :spawn, worker, _}, 1_000
      guard_ref = Process.monitor(guard)
      worker_ref = Process.monitor(worker)

      try do
        if unquote(event) == :caller_loss do
          Process.exit(caller, :kill)
        else
          assert_receive {:result, %{"outcome" => "error", "reason" => "request_timeout"}}, 1_000
        end

        assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
        assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
        refute Process.alive?(worker)
      after
        :sys.resume(c.store)
        Process.exit(caller, :kill)
      end

      assert {:ok, 1} = Store.revision(c.store)
    end
  end
end
