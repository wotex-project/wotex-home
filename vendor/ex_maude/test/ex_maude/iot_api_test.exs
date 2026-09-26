defmodule ExMaude.IoTAPITest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.Error
  alias ExMaude.IoT

  @fake_maude Path.expand("../support/fake_conflicts.sh", __DIR__)
  @fake_pool :iot_api_test_pool
  @invalid_rules [%{}]
  @valid_rules [
    %{
      id: "r1",
      thing_id: "door",
      trigger: {:always},
      actions: [{:set_prop, "door", "state", "closed"}]
    }
  ]

  defp start_fake_pool do
    start_supervised!(
      ExMaude.Pool.child_spec(
        name: @fake_pool,
        worker_module: ExMaude.Backend.Port,
        maude_path: @fake_maude,
        use_pty: false,
        pool_size: 1,
        pool_max_overflow: 0
      )
    )

    @fake_pool
  end

  describe "detect_conflicts/2 validation" do
    test "returns validation errors before loading Maude" do
      assert {:error, %{"rule_0" => errors}} = IoT.detect_conflicts(@invalid_rules)
      assert "missing required field: id" in errors
    end

    test "emits telemetry for validation failures" do
      ref = make_ref()
      test_pid = self()
      handler_id = "iot-api-validation-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ex_maude, :iot, :detect_conflicts, :start],
          [:ex_maude, :iot, :detect_conflicts, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, _} = IoT.detect_conflicts([:bad])

      assert_receive {^ref, [:ex_maude, :iot, :detect_conflicts, :start],
                      %{rule_count: 1, system_time: _}, %{template: :iot_rules}}

      assert_receive {^ref, [:ex_maude, :iot, :detect_conflicts, :stop],
                      %{duration: duration, conflict_count: 0},
                      %{result: :error, template: :iot_rules}}

      assert is_integer(duration)
    end
  end

  describe "detect_conflicts/2 with a fake Maude pool" do
    test "encodes rules, runs detection, and returns parsed conflicts" do
      pool = start_fake_pool()

      assert {:ok, []} = IoT.detect_conflicts(@valid_rules, pool: pool)
    end

    test "applies supported conflict filters after detection" do
      pool = start_fake_pool()

      assert {:ok, []} =
               IoT.detect_conflicts(@valid_rules,
                 pool: pool,
                 conflict_types: [:state_conflict, :env_conflict]
               )
    end

    test "rejects unsupported conflict filters after detection" do
      pool = start_fake_pool()

      assert {:error, %Error{type: :validation, message: message}} =
               IoT.detect_conflicts(@valid_rules, pool: pool, conflict_types: [:made_up])

      assert message =~ "unsupported conflict type"
    end

    test "rejects non-list conflict filters after detection" do
      pool = start_fake_pool()

      assert {:error, %Error{type: :validation, message: message}} =
               IoT.detect_conflicts(@valid_rules, pool: pool, conflict_types: :state_conflict)

      assert message =~ "conflict_types must be a list"
    end
  end

  describe "specialized conflict detectors" do
    test "validate input before loading Maude" do
      assert {:error, %{"rule_0" => _}} = IoT.detect_state_conflicts(@invalid_rules)
      assert {:error, %{"rule_0" => _}} = IoT.detect_env_conflicts(@invalid_rules)
      assert {:error, %{"rule_0" => _}} = IoT.detect_cascade_conflicts(@invalid_rules)
    end

    test "encode and execute through a fake Maude pool" do
      pool = start_fake_pool()

      assert {:ok, []} = IoT.detect_state_conflicts(@valid_rules, pool: pool)
      assert {:ok, []} = IoT.detect_env_conflicts(@valid_rules, pool: pool)
      assert {:ok, []} = IoT.detect_cascade_conflicts(@valid_rules, pool: pool)
    end
  end

  describe "bounded verification input validation" do
    test "rejects nil and operation-specific target shapes before pool access" do
      for target <- [nil, [{:env_state, "x", 1} | :bad]] do
        assert {:error, %Error{type: :validation}} =
                 IoT.verify_safety([], target, pool: :missing_validation_pool)
      end

      for target <- [nil, [], [{:env_state, "x", 1}]] do
        assert {:error, %Error{type: :validation}} =
                 IoT.verify_liveness([], target, pool: :missing_validation_pool)
      end

      assert {:error, %Error{type: :validation}} =
               IoT.verify_safety([], {:env_state, "x", 1},
                 initial_state: [{:env_state, "x", 1} | :bad],
                 pool: :missing_validation_pool
               )
    end

    test "rejects invalid max_depth" do
      assert {:error, %Error{type: :validation, message: message}} =
               IoT.verify_safety(@valid_rules, {:thing_state, "door", "state", "open"},
                 max_depth: 0
               )

      assert message =~ "max_depth"
    end

    test "rejects invalid timeout" do
      assert {:error, %Error{type: :validation, message: message}} =
               IoT.verify_liveness(@valid_rules, {:thing_state, "door", "state", "open"},
                 timeout: 0
               )

      assert message =~ "timeout"
    end

    test "rejects non-list initial_state" do
      assert {:error, %Error{type: :validation, message: message}} =
               IoT.verify_safety(@valid_rules, {:thing_state, "door", "state", "open"},
                 initial_state: {:thing_state, "door", "state", "closed"}
               )

      assert message =~ "initial_state"
    end

    test "rejects invalid initial_state predicate" do
      assert {:error, %Error{type: :validation, message: message}} =
               IoT.verify_liveness(@valid_rules, {:thing_state, "door", "state", "open"},
                 initial_state: [:bad]
               )

      assert message =~ "initial_state"
    end

    test "rejects invalid target predicate" do
      assert {:error, %Error{type: :validation, message: message}} =
               IoT.verify_safety(@valid_rules, {:thing_state, "", "state", "open"})

      assert message =~ "verification target"
    end
  end

  describe "bounded verification without a pool" do
    test "maps unavailable execution to unverified for safety" do
      assert {:ok, :unverified} =
               IoT.verify_safety(@valid_rules, {:thing_state, "door", "state", "open"},
                 pool: :missing_iot_api_pool
               )
    end

    test "maps unavailable execution to unverified for liveness" do
      assert {:ok, :unverified} =
               IoT.verify_liveness(@valid_rules, {:env_state, "temperature", 21},
                 pool: :missing_iot_api_pool
               )
    end
  end

  describe "bounded verification with a fake Maude pool" do
    test "builds and searches a safety query" do
      pool = start_fake_pool()

      assert {:ok, :unverified} =
               IoT.verify_safety(
                 @valid_rules,
                 [
                   {:thing_state, "door", "state", "open"},
                   {:env_state, "temperature", 21}
                 ],
                 pool: pool,
                 initial_state: [
                   {:thing_state, "door", "state", "closed"},
                   {:env_state, "temperature", 18}
                 ]
               )
    end

    test "builds and searches a liveness query for thing state" do
      pool = start_fake_pool()

      assert {:ok, :unverified} =
               IoT.verify_liveness(
                 @valid_rules,
                 {:thing_state, "door", "state", "open"},
                 pool: pool,
                 initial_state: [{:thing_state, "door", "state", "closed"}]
               )
    end

    test "builds and searches a liveness query for environment state" do
      pool = start_fake_pool()

      assert {:ok, :unverified} =
               IoT.verify_liveness(
                 @valid_rules,
                 {:env_state, "temperature", 21},
                 pool: pool,
                 initial_state: [{:env_state, "temperature", 18}]
               )
    end
  end
end
