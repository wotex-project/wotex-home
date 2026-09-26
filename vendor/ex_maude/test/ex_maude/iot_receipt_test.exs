defmodule ExMaude.IoTReceiptTest do
  use ExMaude.MaudeCase

  alias ExMaude.IoT

  @moduletag :integration

  defp rule(id, trigger, actions, priority \\ 1) do
    %{id: id, thing_id: "d", trigger: trigger, actions: actions, priority: priority}
  end

  test "semantic identity is stable across runs and changes with bounds or assumptions", %{
    maude_available: true
  } do
    rules = [rule("r", {:always}, [{:set_prop, "d", "state", "bad"}])]
    bad = {:thing_state, "d", "state", "bad"}
    {:ok, first} = IoT.verify_safety_with_receipt(rules, bad, max_depth: 2)
    {:ok, second} = IoT.verify_safety_with_receipt(rules, bad, max_depth: 2)
    {:ok, deeper} = IoT.verify_safety_with_receipt(rules, bad, max_depth: 3)

    {:ok, assumed} =
      IoT.verify_safety_with_receipt(rules, bad,
        max_depth: 2,
        assumptions: ["observations are current"]
      )

    assert first.semantic.digest == second.semantic.digest
    refute first.execution.run_id == second.execution.run_id
    refute first.semantic.digest == deeper.semantic.digest
    refute first.semantic.digest == assumed.semantic.digest
    assert first.execution.observed_model_digest != nil
    assert first.execution.completion == :bounded_complete
    assert first.execution.native_disposition == :completed
    assert first.execution.parse_disposition == :completed
    assert [%{kind: :reachable_bad_state}] = first.execution.findings
    assert first.execution.witness.scope == :returned_solution
    assert first.execution.witness.semantic_digest == first.semantic.digest
    assert first.execution.witness.model_closure_digest == first.semantic.model_closure_digest
  end

  test "concurrent isolated runs keep their own worker epochs", %{maude_available: true} do
    rules = [rule("r", {:always}, [{:set_prop, "d", "state", "bad"}])]
    bad = {:thing_state, "d", "state", "bad"}

    receipts =
      1..6
      |> Task.async_stream(
        fn _ -> IoT.verify_safety_with_receipt(rules, bad) end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert length(Enum.uniq_by(receipts, & &1.semantic.digest)) == 1
    assert length(Enum.uniq_by(receipts, & &1.execution.run_id)) == 6
    assert length(Enum.uniq_by(receipts, & &1.execution.worker_epoch)) == 6
    assert Enum.all?(receipts, &(&1.execution.completion == :bounded_complete))
  end

  test "priority is not an execution arbiter", %{maude_available: true} do
    rules = [
      rule("high", {:prop_eq, "state", "off"}, [{:set_prop, "d", "state", "good"}], 10),
      rule("low", {:prop_eq, "state", "off"}, [{:set_prop, "d", "state", "bad"}], 0)
    ]

    assert {:ok, receipt} =
             IoT.verify_safety_with_receipt(rules, {:thing_state, "d", "state", "bad"},
               initial_state: [{:thing_state, "d", "state", "off"}]
             )

    assert [%{kind: :reachable_bad_state}] = receipt.execution.findings
  end

  test "missing values use two-valued negation and invoke has no modeled state effect", %{
    maude_available: true
  } do
    negated = [
      rule("negative", {:not, {:prop_eq, "observed", "yes"}}, [{:set_prop, "d", "state", "bad"}])
    ]

    assert {:ok, negative_receipt} =
             IoT.verify_safety_with_receipt(negated, {:thing_state, "d", "state", "bad"})

    assert negative_receipt.execution.findings != []

    invoked = [rule("invoke", {:always}, [{:invoke, "d", "notify"}])]

    assert {:ok, deadlock} =
             IoT.verify_liveness_with_receipt(invoked, {:thing_state, "d", "state", "notified"})

    assert [%{kind: :terminal_state_missing_goal}] = deadlock.execution.findings
    assert deadlock.execution.witness.scope == :returned_solution
  end

  test "pairwise cascade does not imply a reachable bad state", %{maude_available: true} do
    rules = [
      rule("source", {:prop_eq, "state", "off"}, [{:set_prop, "d", "state", "on"}]),
      rule("sink", {:prop_eq, "state", "on"}, [{:set_prop, "d", "state", "bad"}])
    ]

    assert {:ok, conflicts} = IoT.detect_conflicts_with_receipt(rules)
    assert Enum.any?(conflicts.execution.findings, &(&1.type == :state_cascade))

    assert {:ok, reachability} =
             IoT.verify_safety_with_receipt(rules, {:thing_state, "d", "state", "bad"},
               initial_state: [{:thing_state, "d", "state", "else"}],
               max_depth: 2
             )

    assert reachability.execution.findings == []
    assert reachability.execution.completion == :bounded_complete
  end

  test "witness cap omits state data but retains digest", %{maude_available: true} do
    rules = [rule("r", {:always}, [{:set_prop, "d", "state", "private-state-canary"}])]

    assert {:ok, receipt} =
             IoT.verify_safety_with_receipt(
               rules,
               {:thing_state, "d", "state", "private-state-canary"},
               max_witness_bytes: 1
             )

    assert receipt.execution.witness.value == nil
    assert receipt.execution.witness.complete == false
    assert byte_size(receipt.execution.witness.digest) == 64
    refute inspect(receipt.execution.findings) =~ "private-state-canary"
  end

  test "output ceiling and deadline do not become completed evidence", %{maude_available: true} do
    rules = [rule("r", {:always}, [{:set_prop, "d", "state", "bad"}])]
    bad = {:thing_state, "d", "state", "bad"}

    assert {:ok, overflow} =
             IoT.verify_safety_with_receipt(rules, bad, max_response_bytes: 80)

    assert overflow.execution.completion == :output_overflow
    assert overflow.semantic.budgets.max_witness_bytes == 80
    assert overflow.execution.native_disposition == :response_too_large
    assert overflow.execution.parse_disposition == :not_run
    assert overflow.execution.findings == []

    assert {:ok, timed_out} = IoT.verify_safety_with_receipt(rules, bad, timeout: 1)
    assert timed_out.execution.completion == :timeout
    assert timed_out.execution.findings == []
  end

  test "unsupported consumer semantics fail explicitly", %{maude_available: true} do
    rules = [rule("r", {:always}, [{:invoke, "d", "notify"}])]

    assert {:error, %ExMaude.Error{type: :validation}} =
             IoT.verify_liveness_with_receipt(
               rules,
               {:thing_state, "d", "state", "notified"},
               semantics: :effectful_invoke
             )
  end

  test "default telemetry does not carry private state", %{maude_available: true} do
    handler = "iot-receipt-private-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        ExMaude.Telemetry.events(),
        fn event, measurements, metadata, recipient ->
          send(recipient, {:receipt_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    canary = "private-state-canary-987654"
    rules = [rule("r", {:always}, [{:set_prop, "d", "state", canary}])]

    assert {:ok, _} =
             IoT.verify_safety_with_receipt(rules, {:thing_state, "d", "state", canary})

    events =
      Stream.repeatedly(fn ->
        receive do
          {:receipt_telemetry, event, measurements, metadata} ->
            {event, measurements, metadata}
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    assert events != []
    refute inspect(events) =~ canary
  end
end
