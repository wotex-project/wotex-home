Code.require_file(Path.expand("../support/routine_external_fact_fixture.exs", __DIR__))

defmodule WotexHome.RoutineExternalFactTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Rules.ExternalFact
  alias WotexHome.RoutineExternalFactFixture, as: F

  @profile %{
    "source_bytes" => 32_768,
    "source_depth" => 16,
    "expanded_nodes" => 8,
    "predicate_nodes" => 8,
    "invocation_depth" => 1,
    "parallel_width" => 1,
    "effects" => 1,
    "waits" => 1,
    "active_definitions" => 1,
    "active_runs" => 1,
    "pending_work" => 1,
    "run_ms" => 86_400_000
  }

  setup_all do
    %{fixture: F.new()}
  end

  test "the actual Home reader-to-kernel path matches independently frozen values and identities",
       %{fixture: c} do
    assert c.value.data == c.vector["home_value_data"]
    assert c.value.sha256 == c.vector["expected_result"]["external_value_sha256"]
    assert {:ok, result} = project(c)
    assert result == c.vector["expected_result"]
    assert {:ok, ^result} = project(c)
    assert result["fact"]["profile_digest"] != c.mapping["basis"]["semantic_digest"]
    assert result["binding_basis"]["input_mapping"] == c.mapping
    assert {:ok, true, %{"outcome" => "completed", "proposals" => []}} = execute(c, result, 250)

    assert {:ok, native} =
             Wotex.Routines.InputMapping.new(
               c.mapping,
               c.context["registry"],
               c.context["limits"]
             )

    assert ExternalFact.project(c.value, native, c.metadata, c.context) == {:ok, result}
  end

  test "native Home value, current envelope, consumer and reader limit substitutions refuse", %{
    fixture: c
  } do
    for value <- [
          Map.put(c.value, :extra, true),
          %{c.value | sha256: String.duplicate("0", 64)},
          put_in(c.value.data["normalized_value"], %{"type" => "sint", "value" => "0"}),
          put_in(c.value.inputs["report"]["value"], %{"type" => "sint", "value" => "50"}),
          %{}
        ] do
      assert {:error, :invalid_external_fact} =
               ExternalFact.project(value, c.mapping, c.metadata, c.context)
    end

    for context <- [
          put_in(c.context, ["consumer", "constraints", "min"], -273_149),
          put_in(c.context, ["reader_limits", "max_nodes"], 4095),
          put_in(
            c.context,
            ["envelope", Access.key!(:consumption_sha256)],
            String.duplicate("0", 64)
          )
        ] do
      assert {:error, reason} = ExternalFact.project(c.value, c.mapping, c.metadata, context)
      assert reason in [:invalid_external_fact, :stale_external_fact]
    end
  end

  test "closed metadata and context cannot invent receipt UTC or extend the original lifetime", %{
    fixture: c
  } do
    for metadata <- [
          Map.delete(c.metadata, "received_at"),
          Map.put(c.metadata, "received_at", "2026-10-15T00:00:00Z"),
          Map.put(c.metadata, "private-canary", "body")
        ] do
      assert {:error, :invalid_external_fact} = project(%{c | metadata: metadata})
    end

    for context <- [nil, %{}, Map.put(c.context, "private-canary", "body")] do
      assert {:error, :invalid_external_fact} =
               ExternalFact.project(c.value, c.mapping, c.metadata, context)
    end

    for {key, value} <- [
          {"receipt_ms", 9999},
          {"expires_ms", 10_999},
          {"receipt_epoch", "other-clock"}
        ] do
      assert {:error, :stale_external_fact} =
               project(%{c | metadata: Map.put(c.metadata, key, value)})
    end

    assert {:ok, result} = project(%{c | metadata: Map.put(c.metadata, "expires_ms", 10_000)})
    assert result["fact"]["expires_ms"] == 10_000
    assert result["fact"]["received_at"] == nil
  end

  test "mapping installation, complete identity and selected aggregate limits stay mandatory", %{
    fixture: c
  } do
    missing = Enum.reject(c.context["registry"], &(&1["id"] == c.mapping["id"]))

    assert {:error, :unsupported_external_fact} =
             project(%{c | context: Map.put(c.context, "registry", missing)})

    assert {:error, :stale_external_fact} =
             project(%{c | mapping: Map.put(c.mapping, "sha256", String.duplicate("0", 64))})

    assert {:error, :invalid_external_fact} =
             project(%{c | mapping: Map.put(c.mapping, "private-canary", true)})

    for {key, maximum} <- c.vector["limits"] do
      limits = Map.put(c.context["limits"], key, maximum + 1)

      assert {:error, :external_fact_limit} =
               project(%{c | context: Map.put(c.context, "limits", limits)})
    end

    {:ok, result} = project(c)
    bytes = F.encode(result)
    limits = Map.put(c.context["limits"], "max_bytes", byte_size(bytes) - 1)
    assert {:ok, _} = Wotex.Routines.InputMapping.new(c.mapping, c.context["registry"], limits)

    assert {:error, :external_fact_limit} =
             project(%{c | context: Map.put(c.context, "limits", limits)})
  end

  test "actual Boolean and enum Home readers reach known predicates without scalar coercion", %{
    fixture: c
  } do
    for {type, rows} <- [
          {"boolean", [{false, false}, {true, true}]},
          {"enum", [{"0", "closed"}, {"1", "open"}]}
        ],
        {raw, expected} <- rows do
      changed = F.typed(c, type, raw)
      assert {:ok, result} = project(changed)
      assert result["fact"]["value"] == expected
      assert result["fact"]["unit"] == nil
      assert result["fact"]["received_at"] == nil
      assert result["binding_basis"]["input_mapping"] == changed.mapping

      assert {:ok, true, %{"outcome" => "completed", "proposals" => []}} =
               execute(changed, result, expected)

      changed_fact =
        put_in(result, ["fact", "profile_digest"], c.mapping["basis"]["semantic_digest"])

      assert {:ok, "unknown", %{"outcome" => "blocked", "proposals" => []}} =
               execute(changed, changed_fact, expected)
    end
  end

  test "signed original receipt vectors and 65-bit subtraction preserve conservative expiry", %{
    fixture: c
  } do
    for row <- c.vector["clock_cases"] do
      report = put_in(c.report, ["receipt_time", "monotonic_us"], row["source_receipt_us"])
      changed = F.build(c.vector, c.source, c.consumer, report)

      clock =
        Map.merge(
          c.mapping["receipt_clock"],
          Map.take(row, ~w(source_origin_us target_origin_ms))
        )

      changed =
        F.install(changed, c.mapping |> Map.delete("sha256") |> Map.put("receipt_clock", clock))

      metadata =
        Map.merge(c.metadata, %{
          "receipt_ms" => row["expected_receipt_ms"] || 0,
          "expires_ms" => row["maximum_expiry_ms"] || 1000
        })

      changed = %{changed | metadata: metadata}

      if row["expected_error"] do
        assert {:error, :external_fact_limit} = project(changed)
      else
        assert {:ok, result} = project(changed)
        assert result["fact"]["receipt_ms"] == row["expected_receipt_ms"]
        assert result["fact"]["expires_ms"] == row["maximum_expiry_ms"]
        assert result["fact"]["received_at"] == nil
      end
    end
  end

  test "legacy exact receipt precision refuses fractions and freshness remains exclusive", %{
    fixture: c
  } do
    clock = Map.drop(c.mapping["receipt_clock"], ~w(format projection))
    changed = F.install(c, c.mapping |> Map.delete("sha256") |> Map.put("receipt_clock", clock))
    assert {:error, :inexact_external_fact} = project(changed)

    report = put_in(c.report, ["receipt_time", "monotonic_us"], "-1000")
    aligned = F.build(c.vector, c.source, c.consumer, report)
    aligned = F.install(aligned, Map.delete(changed.mapping, "sha256"))
    metadata = Map.merge(aligned.metadata, %{"receipt_ms" => 9999, "expires_ms" => 10_999})
    assert {:ok, result} = project(%{aligned | metadata: metadata})
    assert result["fact"]["receipt_ms"] == 9999

    assert {:ok, fresh} = project(c)
    assert {:ok, true, %{"outcome" => "completed"}} = execute(c, fresh, 250, 10_997)

    assert {:ok, "unknown", %{"outcome" => "blocked", "proposals" => []}} =
             execute(c, fresh, 250, 10_998)

    for {source, replay} <- [{"retained", "retained"}, {"replayed", "replayed"}, {"gap", "fresh"}] do
      report = Map.put(c.report, "continuity", source)
      changed = F.build(c.vector, c.source, c.consumer, report)
      metadata = Map.merge(c.metadata, %{"continuity" => "lost", "replay" => replay})
      changed = %{changed | metadata: metadata}
      assert {:ok, result} = project(changed)
      assert result["fact"]["continuity"] == "lost"
      assert result["fact"]["replay"] == replay

      assert {:ok, "unknown", %{"outcome" => "blocked", "proposals" => []}} =
               execute(changed, result, 250)
    end
  end

  test "missing producer APIs and isolated producer failures have only static refusals" do
    script = """
    Code.require_file("test/support/routine_external_fact_fixture.exs")
    c = WotexHome.RoutineExternalFactFixture.new()
    project = fn -> WotexHome.Rules.ExternalFact.project(c.value, c.mapping, c.metadata, c.context) end
    {:ok, _} = project.()
    Code.compiler_options(ignore_module_conflict: true)
    for action <- [
      "raise(\\\"private fault canary\\\")",
      "throw(\\\"private throw canary\\\")",
      "exit(\\\"private exit canary\\\")",
      "{:error, :private_canary}",
      "{:ok, %{\\\"private-canary\\\" => true}}"
    ] do
      Code.compile_string("defmodule Wotex.Routines.Input do\\n" <>
        "def project(_, _, _, _), do: " <> action <> "\\n" <>
        "def binding_basis(_, _, _), do: raise(\\\"unexpected binding\\\")\\nend")
      {:error, :external_fact_refused} = project.()
      :code.purge(Wotex.Routines.Input)
    end
    Code.compile_string("defmodule Wotex.Routines.Input do\\ndef absent, do: :ok\\nend")
    {:error, :external_fact_unavailable} = project.()
    IO.puts("five producer faults and missing APIs refused")
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    assert {"five producer faults and missing APIs refused\n", 0} =
             System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
               stderr_to_stdout: true
             )
  end

  defp project(c), do: ExternalFact.project(c.value, c.mapping, c.metadata, c.context)

  defp execute(c, result, expected, elapsed \\ nil) do
    source = %{
      "format" => "wotex.routines.source@1",
      "profile" => "bounded-composition@1",
      "id" => "external-fact-probe",
      "revision" => "1",
      "parameters" => %{},
      "bindings" => ["sensor"],
      "trigger" => %{"kind" => "manual"},
      "condition" => %{"op" => "eq", "binding" => "sensor", "value" => expected},
      "steps" => %{"id" => "end", "kind" => "noop"},
      "overlap" => "reject",
      "run_ms" => 1000
    }

    fact = result["fact"]

    context = %{
      "registry" => c.context["registry"],
      "bases" => [c.mapping["basis"]],
      "bindings" => %{
        "sensor" => %{
          "basis" => c.mapping["legacy_basis_ref"],
          "thing_id" => fact["thing_id"],
          "resource_roles" => %{}
        }
      },
      "definitions" => [],
      "arguments" => %{},
      "compiler_basis" => "sha256:" <> String.duplicate("7", 64)
    }

    {:ok, program} =
      Wotex.Routines.Compiler.compile(source, context, @profile, c.context["limits"])

    snapshot = %{
      "id" => "snapshot:external",
      "membership_generation" => "membership:1",
      "active_programs" => [program.data["ir_digest"]],
      "resource_revisions" => %{fact["thing_id"] => 1},
      "binding_bases" => %{"sensor" => result["binding_basis"]},
      "facts" => %{"sensor" => fact}
    }

    {:ok, date, _} = DateTime.from_iso8601(fact["source_time"])
    utc = DateTime.to_unix(date, :millisecond) + 10

    time = %{
      "epoch" => fact["receipt_epoch"],
      "elapsed_ms" => elapsed || fact["receipt_ms"],
      "clock_generation" => "clock:1",
      "utc_low_ms" => utc,
      "utc_high_ms" => utc
    }

    event = %{
      "kind" => "manual",
      "original" => "original:external",
      "program_digest" => program.data["ir_digest"]
    }

    prior = %{"original" => nil, "busy" => nil, "edge" => nil}

    {:ok, truth} =
      Wotex.Routines.Evaluation.evaluate(program, snapshot, time, @profile, c.context["limits"])

    {:ok, transition} =
      Wotex.Routines.Kernel.advance(
        program,
        event,
        snapshot,
        time,
        prior,
        @profile,
        c.context["limits"]
      )

    {:ok, truth, transition}
  end
end
