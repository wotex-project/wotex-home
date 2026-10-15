Code.require_file(Path.expand("../support/routine_external_fact_fixture.exs", __DIR__))

defmodule WotexHome.ExternalInputMathTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Durable.Store.ExternalInputMath, as: M
  alias WotexHome.RoutineExternalFactFixture, as: F
  alias WotexHome.Rules.ExternalFact

  @vectors JSON.decode!(File.read!("test/fixtures/profiles/external-input-collection.json"))

  for row <- @vectors["clock_cases"] do
    @row row
    test "independent clock: #{row["id"]}" do
      row = @row

      result =
        M.bounds(
          row["origin_ms"],
          row["receipt_us"],
          row["deadline_us"],
          row["declaration_freshness_ms"],
          row["mapping_freshness_ms"]
        )

      case {row["expected"], result} do
        {%{"error" => "external_input_limit"}, _} ->
          assert result == {:error, :external_input_limit}

        {%{"error" => "invalid"}, {:error, :invalid_external_input}} ->
          :ok

        {%{"error" => "invalid"}, {:ok, bounds}} ->
          assert {:ok, "invalid"} =
                   M.classify(bounds, row["sampled_ms"], "usable", "7", "continuous")

        {expected, {:ok, bounds}} ->
          assert {:ok, reason} =
                   M.classify(bounds, row["sampled_ms"], "usable", "7", "continuous")

          actual = Map.new(bounds, fn {key, value} -> {Atom.to_string(key), value} end)
          assert Map.put(actual, "reason", reason) == expected

        unexpected ->
          flunk("clock refusal differs from the frozen oracle: #{inspect(unexpected)}")
      end
    end
  end

  for row <- @vectors["report_cases"] do
    @row row
    test "independent report priority: #{row["id"]}" do
      row = @row
      sampled = if row["clock_valid"], do: 1, else: 0
      expiry = if row["expired"], do: 1, else: 100
      # Preboot/future correspondence is represented by a future receipt here;
      # bounds/5 separately rejects negative elapsed coordinates above.
      bounds = %{received_store_ms: 1, owner_expires_ms: 101, expires_ms: max(2, expiry)}
      sampled = if row["expired"] and row["clock_valid"], do: 100, else: sampled

      assert {:ok, reason} =
               M.classify(bounds, sampled, row["quality"], row["sequence"], row["continuity"])

      assert reason == row["expected"]
    end
  end

  test "independent uncertainty ceiling retains null and every frozen integer witness" do
    assert {:ok, nil} = M.uncertainty_ms(nil)

    for row <- @vectors["uncertainty_cases"] do
      assert M.uncertainty_ms(row["uncertainty_us"]) == {:ok, row["expected_ms"]}
    end
  end

  test "original Fact identity and receipt arithmetic match the public reader/routine projection" do
    entry = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    item = hd(entry["snapshot"]["items"])
    ref = item["report_ref"]

    assert {:ok, id} =
             M.fact_id(
               item["target_id"],
               item["capability_key"],
               item["install_revision"],
               ref["owner_epoch"],
               ref["report_id"],
               ref["report_sha256"]
             )

    assert id == item["projection"]["fact"]["id"]
    assert {:ok, bounds} = M.bounds(-10_000, "-1001", "59998999", 5000, 1000)
    assert {:ok, uncertainty} = M.uncertainty_ms("3")
    original = F.new()
    d = entry["definition"]

    metadata =
      item["projection"]["fact"]
      |> Map.drop(~w(quality unit value))
      |> Map.put("id", id)
      |> Map.put("receipt_ms", bounds.received_store_ms)
      |> Map.put("expires_ms", bounds.expires_ms)
      |> Map.put("source_uncertainty_ms", uncertainty)

    context = Map.merge(original.context, Map.take(d, ~w(limits registry)))
    assert {:ok, result} = ExternalFact.project(original.value, d["mapping"], metadata, context)

    # The earlier inert fixture uses its three-archive producer assertion;
    # the input entry fixture changes that assertion and consumption SHA.
    # Compare each value SHA to its own independent oracle, then require all
    # seven unchanged projection fields (including the complete Fact/binding).
    assert result["external_value_sha256"] ==
             original.vector["expected_result"]["external_value_sha256"]

    refute result["external_value_sha256"] == item["projection"]["external_value_sha256"]

    assert Map.delete(result, "external_value_sha256") ==
             Map.delete(item["projection"], "external_value_sha256")

    assert {:ok, nil} = M.classify(bounds, 10_000, "usable", "7", "continuous")
    assert {:ok, "expired"} = M.classify(bounds, 10_998, "usable", "7", "continuous")
  end

  test "Fact identity distinguishes every original component and refuses malformed scope" do
    fields = [
      "sensor:external",
      "sample",
      21,
      String.duplicate("f", 32),
      "report:7",
      String.duplicate("a", 64)
    ]

    {:ok, original} = apply(M, :fact_id, fields)

    for {replacement, index} <-
          Enum.with_index([
            "sensor:other",
            "other",
            22,
            String.duplicate("e", 32),
            "report:8",
            String.duplicate("b", 64)
          ]) do
      assert {:ok, changed} = apply(M, :fact_id, List.replace_at(fields, index, replacement))
      refute changed == original
    end

    for {replacement, index} <- [
          {%{}, 0},
          {"with space", 1},
          {0, 2},
          {String.duplicate("F", 32), 3},
          {nil, 4},
          {String.duplicate("A", 64), 5}
        ] do
      assert {:error, :invalid_external_input} =
               apply(M, :fact_id, List.replace_at(fields, index, replacement))
    end
  end

  test "malformed coordinates, lifetimes and canonical integer strings never wrap or coerce" do
    for origin <- [nil, 0.0, "0"],
        do:
          assert({:error, :invalid_external_input} = M.bounds(origin, "0", "100000", 1000, 1000))

    for {receipt, deadline} <- [
          {"0", "99999"},
          {"0", "100001"},
          {"0", "60001000"},
          {"100000", "0"},
          {"-0", "100000"},
          {"+0", "100000"},
          {"00", "100000"}
        ] do
      assert {:error, :invalid_external_input} = M.bounds(0, receipt, deadline, 1000, 1000)
    end

    for value <- ["-1", "+1", "01", "1.0", 1, %{}],
        do: assert({:error, :invalid_external_input} = M.uncertainty_ms(value))

    assert {:error, :external_input_limit} = M.uncertainty_ms("18446744073709551616")

    assert {:error, :external_input_limit} =
             M.bounds(0, String.duplicate("9", 21), "0", 1000, 1000)

    assert {:error, :external_input_limit} = M.bounds(0, "9223372036854775808", "0", 1000, 1000)
    {:ok, bounds} = M.bounds(0, "0", "100000", 1000, 1000)

    for forged <- [
          Map.put(bounds, :extra, true),
          %{bounds | expires_ms: 0},
          Map.put(bounds, :expires_ms, 1.0)
        ] do
      assert {:error, :invalid_external_input} = M.classify(forged, 0, "usable", "7", "baseline")
    end

    assert {:error, :invalid_external_input} = M.classify(bounds, -1, "usable", "7", "baseline")
    assert {:error, :invalid_external_input} = M.classify(bounds, 0, "usable", "01", "baseline")
  end
end
