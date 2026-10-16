defmodule WotexHome.RoutineClockTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Schedules.{ClockSample, RoutineClockCodec, RoutineClockMath}

  @v "test/fixtures/routines/clock-bases.json" |> File.read!() |> JSON.decode!()
  @maximum 9_223_372_036_854_775_807
  @minimum -9_223_372_036_854_775_808
  @binding ~w(deployment_id owner_id authority_epoch store_boot_epoch elapsed_generation runtime_digest monotonic_origin_ms)

  test "full independent private documents and original elapsed/UTC tokens agree" do
    assert {:ok, @v["policy_document"]} == RoutineClockCodec.policy_document(@v["policy"])
    assert {:ok, @v["policy"]} == RoutineClockCodec.decode_policy(@v["policy_document"])
    assert {:ok, @v["request_document"]} == RoutineClockCodec.request_document(@v["request"])
    assert {:ok, @v["request"]} == RoutineClockCodec.decode_request(@v["request_document"])
    assert {:ok, @v["elapsed_token"]} == RoutineClockCodec.elapsed_token(@v["request"])
    assert sha(@v["policy_document"]) == @v["policy_sha256"]
    assert sha(@v["request_document"]) == @v["request_sha256"]
    utc = @v["utc"]

    assert {:ok, utc["token"]} ==
             RoutineClockCodec.utc_token(
               utc["scope"],
               utc["sample"],
               utc["started_ms"],
               utc["observation"]
             )
  end

  for vector <- @v["pairs"] do
    @vector vector
    test "independent interval relation #{@vector["name"]}" do
      result =
        RoutineClockMath.continuity(
          @vector["policy"],
          @vector["old"],
          @vector["old"],
          @vector["new"]
        )

      assert_outcome(result, @vector["expected"]["outcome"])
    end
  end

  for vector <- @v["coordinates"] do
    @vector vector
    test "exact raw coordinate #{@vector["raw"]} minus #{@vector["origin"]}" do
      result = RoutineClockMath.coordinate(@vector["raw"], @vector["origin"])

      if @vector["outcome"] == "ok",
        do: assert(result == {:ok, @vector["expected"]}),
        else: assert_outcome(result, @vector["outcome"])
    end
  end

  test "rolling checks cannot replace the original anchor or forgive cumulative drift" do
    policy = @v["policy"]
    anchor = hd(@v["pairs"])["old"]

    previous =
      Enum.reduce(1..10, anchor, fn index, previous ->
        current = %{
          anchor
          | "primary_lower_ms" => 1001 * index,
            "primary_upper_ms" => 1001 * index,
            "continuous_ms" => 1000 * index
        }

        assert :ok = RoutineClockMath.continuity(policy, anchor, previous, current)
        current
      end)

    current = %{
      anchor
      | "primary_lower_ms" => 11_011,
        "primary_upper_ms" => 11_011,
        "continuous_ms" => 11_000
    }

    assert :ok = RoutineClockMath.continuity(policy, previous, previous, current)

    assert {:error, :routine_clock_unavailable} =
             RoutineClockMath.continuity(policy, anchor, previous, current)
  end

  test "every source and lifecycle identity remains immutable across an accepted incarnation" do
    vector = hd(@v["pairs"])

    for {key, value} <- [
          {"source_id", "fixture:other"},
          {"reference_id", "fixture:other"},
          {"source_digest", String.duplicate("e", 64)},
          {"reference_epoch", String.duplicate("e", 32)},
          {"reference_started_ms", -10001},
          {"lifecycle_generation", 2},
          {"lifecycle_started_ms", -9999}
        ] do
      changed = Map.put(vector["new"], key, value)

      assert {:error, :routine_clock_unavailable} =
               RoutineClockMath.continuity(
                 vector["policy"],
                 vector["old"],
                 vector["old"],
                 changed
               )
    end
  end

  test "freshness uses the original pair and exclusive expiry without renewing it at processing time" do
    binding = @v["request"] |> Map.take(@binding) |> Map.put("monotonic_origin_ms", "-10000")
    observation = hd(@v["pairs"])["old"]

    for now <- [10000, 10001, 10999] do
      assert {:ok, %{"sampled_ms" => 10000, "expires_ms" => 11000}} =
               RoutineClockMath.freshness(binding, @v["policy"], observation, now)
    end

    assert {:error, :routine_clock_unavailable} =
             RoutineClockMath.freshness(binding, @v["policy"], observation, 9999)

    assert {:error, :routine_clock_snapshot_stale} =
             RoutineClockMath.freshness(binding, @v["policy"], observation, 11000)

    fresh = %{
      observation
      | "primary_lower_ms" => 1,
        "primary_upper_ms" => 1,
        "continuous_ms" => 1
    }

    assert {:ok, %{"sampled_ms" => 10001, "expires_ms" => 11001}} =
             RoutineClockMath.freshness(binding, @v["policy"], fresh, 11000)

    extreme = %{
      observation
      | "reference_started_ms" => @minimum,
        "lifecycle_started_ms" => @minimum,
        "primary_lower_ms" => -1,
        "primary_upper_ms" => -1
    }

    binding = Map.put(binding, "monotonic_origin_ms", Integer.to_string(@minimum))

    assert {:error, :routine_clock_limit} =
             RoutineClockMath.freshness(binding, @v["policy"], extreme, @maximum)
  end

  test "independent UTC intervals preserve original expiry and legacy endpoint behavior" do
    u = @v["utc"]

    for vector <- u["projections"] do
      result =
        RoutineClockMath.utc_interval(
          u["sample"],
          u["scope"],
          u["started_ms"],
          u["observation"]["lifecycle_started_ms"],
          u["origin"],
          vector["now"]
        )

      if vector["outcome"] == "ok",
        do: assert(result == {:ok, {vector["lower"], vector["upper"]}}),
        else: assert_outcome(result, vector["outcome"])
    end

    assert {:ok, _} =
             ClockSample.advance(
               u["sample"],
               u["scope"]["store_boot_epoch"],
               u["scope"]["clock_generation"],
               1100
             )

    assert {:error, :routine_clock_snapshot_stale} =
             RoutineClockMath.utc_interval(u["sample"], u["scope"], 10, -10000, -10000, 1100)

    assert {:error, :routine_clock_unavailable} =
             RoutineClockMath.utc_interval(u["sample"], u["scope"], 0, -10000, -10000, 100)

    assert {:ok, _} =
             RoutineClockMath.utc_interval(u["sample"], u["scope"], 1, -10000, -10000, 100)

    assert {:error, :routine_clock_limit} =
             RoutineClockMath.utc_interval(u["sample"], u["scope"], 10, @minimum, @maximum, 100)
  end

  test "equal current UTC intervals from different originals have different UTC tokens" do
    u = @v["utc"]
    first = %{u["sample"] | "drift_ppm" => 0}

    second = %{
      first
      | "sampled_monotonic_ms" => 101,
        "utc_lower_ms" => first["utc_lower_ms"] + 1,
        "utc_upper_ms" => first["utc_upper_ms"] + 1
    }

    assert {:ok, same} = RoutineClockMath.utc_interval(first, u["scope"], 10, -10000, -10000, 200)

    assert {:ok, ^same} =
             RoutineClockMath.utc_interval(second, u["scope"], 10, -10000, -10000, 200)

    assert {:ok, first_token} =
             RoutineClockCodec.utc_token(u["scope"], first, 10, u["observation"])

    assert {:ok, second_token} =
             RoutineClockCodec.utc_token(u["scope"], second, 10, u["observation"])

    refute first_token == second_token
    assert {:ok, @v["elapsed_token"]} == RoutineClockCodec.elapsed_token(@v["request"])
  end

  test "every complete approval identity contributes to the elapsed token" do
    request = %{
      @v["request"]
      | "monotonic_origin_ms" => "-10000",
        "reference_started_ms" => "-10000",
        "lifecycle_started_ms" => "-9999"
    }

    assert {:ok, token} = RoutineClockCodec.elapsed_token(request)

    for {key, value} <- [
          {"deployment_id", String.duplicate("e", 64)},
          {"owner_id", String.duplicate("e", 64)},
          {"authority_epoch", 2},
          {"store_boot_epoch", "fixture:other-boot"},
          {"elapsed_generation", 3},
          {"runtime_digest", String.duplicate("e", 64)},
          {"monotonic_origin_ms", "-9999"},
          {"policy_sha256", String.duplicate("e", 64)},
          {"source_digest", String.duplicate("e", 64)},
          {"reference_epoch", String.duplicate("e", 32)},
          {"reference_started_ms", "-10001"},
          {"lifecycle_generation", 2},
          {"lifecycle_started_ms", "-9998"},
          {"challenge_nonce", Base.url_encode64(:binary.copy(<<42>>, 32), padding: false)}
        ] do
      assert {:ok, changed} = RoutineClockCodec.elapsed_token(Map.put(request, key, value))
      refute token == changed

      assert {:error, :invalid_routine_clock} =
               RoutineClockCodec.elapsed_token(Map.delete(request, key))
    end

    for key <- ~w(authority_epoch elapsed_generation lifecycle_generation) do
      assert {:ok, document} = RoutineClockCodec.request_document(Map.put(request, key, @maximum))
      assert {:ok, _} = RoutineClockCodec.decode_request(document)
    end
  end

  test "closed native inputs and canonical private byte bounds refuse whole payloads" do
    for value <- [
          nil,
          self(),
          [nil | false],
          %URI{},
          Map.put(@v["policy"], :extra, true),
          Map.delete(@v["policy"], "source_id")
        ] do
      assert {:error, :invalid_routine_clock} = RoutineClockCodec.policy_document(value)
    end

    for {key, value} <- [
          {"approval_timeout_ms", 1.0},
          {"maximum_sample_ms", 0},
          {"drift_ppm", 1001},
          {"qualified_run_ms", 1000},
          {"source_id", "not a Home ID"}
        ] do
      assert {:error, :invalid_routine_clock} =
               RoutineClockCodec.policy_document(Map.put(@v["policy"], key, value))
    end

    assert {:error, :routine_clock_limit} =
             RoutineClockCodec.policy_document(
               Map.put(@v["policy"], "approval_timeout_ms", @maximum + 1)
             )

    assert {:error, :routine_clock_limit} =
             RoutineClockCodec.policy_document(
               Map.put(@v["policy"], "source_id", String.duplicate("a", 129))
             )

    assert {:ok, max_id} =
             RoutineClockCodec.policy_document(
               Map.put(@v["policy"], "source_id", String.duplicate("a", 128))
             )

    assert {:ok, _} = RoutineClockCodec.decode_policy(max_id)

    for bytes <- [
          @v["policy_document"] <> " ",
          " " <> @v["policy_document"],
          "{}",
          String.duplicate(" ", 4096),
          <<255>>,
          "[]",
          String.replace(@v["policy_document"], "routine-elapsed-policy", "schedule-clock-policy")
        ] do
      assert {:error, :invalid_routine_clock} = RoutineClockCodec.decode_policy(bytes)
    end

    for bytes <- [
          String.duplicate(" ", 4097),
          JSON.encode!(List.duplicate(0, 17)),
          "[[[[0]]]]",
          JSON.encode!([String.duplicate("a", 129)]),
          "[9223372036854775808]"
        ] do
      assert {:error, :routine_clock_limit} = RoutineClockCodec.decode_policy(bytes)
    end

    for text <- ["-0", "+1", "00", "-01", "1e3", " 1"] do
      assert {:error, :invalid_routine_clock} =
               RoutineClockCodec.request_document(
                 Map.put(@v["request"], "monotonic_origin_ms", text)
               )
    end

    assert {:error, :routine_clock_limit} =
             RoutineClockCodec.request_document(
               Map.put(@v["request"], "monotonic_origin_ms", Integer.to_string(@maximum + 1))
             )

    assert {:error, :invalid_routine_clock} =
             RoutineClockCodec.request_document(
               Map.update!(@v["request"], "challenge_nonce", &(&1 <> "="))
             )
  end

  test "malformed or unavailable native source and UTC claims never yield partial time" do
    observation = hd(@v["pairs"])["old"]

    for bad <- [
          nil,
          self(),
          Map.put(observation, "extra", true),
          Map.put(observation, "primary_lower_ms", 0.0)
        ] do
      assert {:error, :invalid_routine_clock} = RoutineClockCodec.observation(bad, @v["policy"])
    end

    assert {:error, :routine_clock_limit} =
             RoutineClockCodec.observation(
               Map.put(observation, "primary_upper_ms", @maximum + 1),
               @v["policy"]
             )

    assert {:error, :routine_clock_unavailable} =
             RoutineClockCodec.observation(
               Map.put(observation, "primary_upper_ms", 1001),
               @v["policy"]
             )

    assert {:error, :invalid_routine_clock} = RoutineClockMath.coordinate(1.0, 0)

    u = @v["utc"]

    for sample <- [
          Map.put(u["sample"], "generation", 6),
          Map.put(u["sample"], "boot_epoch", "old:boot"),
          Map.put(u["sample"], "monotonic_continuous", false),
          %{
            u["sample"]
            | "wall_confidence" => "unqualified",
              "utc_lower_ms" => nil,
              "utc_upper_ms" => nil
          }
        ] do
      assert {:error, :routine_clock_unavailable} =
               RoutineClockCodec.utc_sample(sample, u["scope"])

      assert {:error, :routine_clock_unavailable} =
               RoutineClockMath.utc_interval(sample, u["scope"], 10, -10000, -10000, 100)
    end
  end

  defp assert_outcome(:ok, "ok"), do: :ok

  defp assert_outcome(result, outcome),
    do: assert(result == {:error, String.to_existing_atom(outcome)})

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
