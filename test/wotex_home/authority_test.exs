defmodule WotexHome.AuthorityTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Authority
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.Ledger
  alias WotexHome.Semantics.Thing

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @mutation %{
    "api_version" => 1,
    "operation_id" => "op:authority:1",
    "authority_epoch" => 1,
    "expected_revision" => 0,
    "target_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => true}
  }

  @rule %{
    "version" => 1,
    "id" => "rule:authority:1",
    "source_revision" => 3,
    "trigger" => %{"kind" => "explicit_request"},
    "predicate" => %{"op" => "literal_true"},
    "effect" => %{
      "target_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    },
    "authority_class" => "automation",
    "unknown_policy" => "block",
    "ownership_ms" => 10_000,
    "cooldown_ms" => 1_000,
    "causal_budget" => 4
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-authority-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))
    assert {:ok, gate} = ReviewGate.start_link()

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, controller, 2} =
             Store.provision_principal(
               store,
               "operator:1",
               ["control:ordinary"],
               ["light:desk"]
             )

    assert {:ok, reviewer, 3} =
             Store.provision_principal(store, "reviewer:1", ["rule:review"], ["light:desk"])

    authority = Authority.new(store: store, capture: nil, review_gate: gate)

    on_exit(fn ->
      if Process.alive?(gate), do: GenServer.stop(gate)
      if Process.alive?(store), do: GenServer.stop(store)
    end)

    {:ok, authority: authority, store: store, controller: controller, reviewer: reviewer}
  end

  test "application operations preserve Store identity and idempotency", context do
    direct_health = Store.authorized_health(context.store, context.controller)
    assert ^direct_health = Authority.health(context.authority, context.controller)

    assert {:ok, receipt} =
             Authority.submit(context.authority, context.controller, @mutation)

    assert {:ok, mutation} = WotexHome.Mutation.new(@mutation)

    assert {:ok, ^receipt} =
             Store.submit_request(context.store, context.controller, mutation)
  end

  test "trusted diagnostic bootstrap is a fixed idempotent application use case", context do
    assert {:ok, credential, 4} = Authority.provision_diagnostic(context.authority)
    assert {:ok, %{store_revision: 4}} = Authority.health(context.authority, credential)
    assert {:error, :principal_exists} = Authority.provision_diagnostic(context.authority)
  end

  test "direct packet execution is an explicit host capability", %{
    authority: authority,
    store: store,
    controller: controller
  } do
    assert {:ok, ledger} = Ledger.new(2)

    assert {:error, :dispatch_disabled, ^ledger} =
             Authority.lifx_execute_power(
               authority,
               "operator:1",
               1,
               "op:authority:1",
               :candidate,
               <<1::48>>,
               ledger,
               ack_timeout_ms: 10,
               read_timeout_ms: 10
             )

    assert {:ok, supervisor} = Task.Supervisor.start_link()

    enabled =
      Authority.new(
        store: store,
        power_supervisor: supervisor,
        power_dispatch: true
      )

    assert {:ok, %{dispatch_enabled: true}} = Authority.health(enabled, controller)
  end

  test "rule review is transport independent and revalidates its watermark", context do
    assert {:ok, review, 3} =
             Authority.review_rules(context.authority, context.reviewer, [@rule])

    assert review.decision == :pending_positive_basis
    assert {:ok, 4} = Store.revoke_thing(context.store, "light:desk")

    assert {:error, :review_scope_unavailable} =
             Authority.review_rules(context.authority, context.reviewer, [@rule])
  end

  test "review capacity is released when a caller dies", %{authority: authority} do
    parent = self()
    gate = authority.review_gate

    holders =
      for _ <- 1..2 do
        spawn(fn ->
          ReviewGate.run(gate, fn ->
            send(parent, {:acquired, self()})

            receive do
              :release -> :ok
            end
          end)
        end)
      end

    assert_receive {:acquired, _}
    assert_receive {:acquired, _}
    assert {:error, :review_capacity} = ReviewGate.run(gate, fn -> :unreachable end)

    [first | _] = holders
    Process.exit(first, :kill)
    assert_eventually(fn -> map_size(:sys.get_state(gate).holders) == 1 end)
    assert :ok = ReviewGate.run(gate, fn -> :ok end)
    Enum.each(holders, &send(&1, :release))
  end

  defp assert_eventually(predicate, attempts \\ 100)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(1)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
