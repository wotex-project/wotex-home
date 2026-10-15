Code.require_file(Path.expand("support/routine_external_fact_fixture.exs", __DIR__))

defmodule HomeRoutineExternalFactArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.RoutineExternalFactFixture, as: F
  alias WotexHome.Rules.ExternalFact

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
    historical = F.new()
    archive = historical.vector["archive"]
    vector = Map.put(historical.vector, "producer_assertion", archive["producer_assertion"])
    c = F.build(vector, historical.source, historical.consumer, historical.report)

    expected =
      Map.put(
        vector["expected_result"],
        "external_value_sha256",
        archive["external_value_sha256"]
      )

    %{fixture: c, archive: archive, expected: expected}
  end

  test "all five producers load solely from the extracted archive cohort", c do
    for module <- [
          Wotex.JSON,
          Wotex.Runtime,
          Wotex.Profiles.Interpreter,
          Wotex.Profiles.Proposal,
          Wotex.Routines.Input,
          Wotex.Routines.Kernel,
          WotexContinuum
        ] do
      Code.ensure_loaded!(module)

      assert module
             |> :code.which()
             |> List.to_string()
             |> String.starts_with?(Path.join(File.cwd!(), "_build"))
    end

    assert c.archive["producer_assertion"] == %{
             "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
             "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
             "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
           }

    assert c.archive["continuum_archive_sha256"] == System.fetch_env!("HOME_SHADOW_CONTINUUM_SHA")

    assert "sha256:" <> c.archive["routines_archive_sha256"] ==
             System.fetch_env!("HOME_SHADOW_COMPILER_BASIS")

    refute Code.ensure_loaded?(WotexHome.Authority)
    refute Code.ensure_loaded?(WotexHome.Durable.Store)

    for app <- [:wotex, :wotex_runtime, :wotex_profiles, :wotex_continuum, :wotex_routines],
        do: assert(Application.spec(app, :mod) in [nil, []])
  end

  test "original reader coordinates and the entire independent result reach the actual kernel",
       c do
    f = c.fixture
    assert f.value.data["normalized_value"] == %{"type" => "sint", "value" => "2500"}
    assert f.context["envelope"].consumption_sha256 == c.archive["consumption_sha256"]
    assert {:ok, result} = project(f)
    assert result == c.expected
    assert result["fact"]["profile_digest"] != f.mapping["basis"]["semantic_digest"]
    assert result["binding_basis"]["input_mapping"] == f.mapping
    assert {:ok, true, %{"outcome" => "completed", "proposals" => []}} = execute(f, result, 250)
    assert {:ok, ^result} = project(f)
  end

  test "actual Boolean and enum Home values reach known predicates", %{fixture: c} do
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

      assert {:ok, true, %{"outcome" => "completed", "proposals" => []}} =
               execute(changed, result, expected)
    end
  end

  test "all original signed clocks retain floor and exclusive expiry", %{fixture: c} do
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

      if row["expected_error"] do
        assert {:error, :external_fact_limit} = project(%{changed | metadata: metadata})
      else
        assert {:ok, result} = project(%{changed | metadata: metadata})
        assert result["fact"]["receipt_ms"] == row["expected_receipt_ms"]
        assert result["fact"]["expires_ms"] == row["maximum_expiry_ms"]
        assert result["fact"]["received_at"] == nil
      end
    end

    assert {:ok, result} = project(c)
    assert {:ok, true, %{"outcome" => "completed"}} = execute(c, result, 250, 10_997)

    assert {:ok, "unknown", %{"outcome" => "blocked", "proposals" => []}} =
             execute(c, result, 250, 10_998)
  end

  test "substituted native values, missing installation and aggregate overflow refuse", %{
    fixture: c
  } do
    bad = %{c.value | sha256: String.duplicate("0", 64)}

    assert {:error, :invalid_external_fact} =
             ExternalFact.project(bad, c.mapping, c.metadata, c.context)

    missing = Enum.reject(c.context["registry"], &(&1["id"] == c.mapping["id"]))

    assert {:error, :unsupported_external_fact} =
             project(%{c | context: Map.put(c.context, "registry", missing)})

    assert {:error, :invalid_external_fact} =
             project(%{c | metadata: Map.put(c.metadata, "received_at", "2026-10-15T00:00:00Z")})

    assert {:ok, result} = project(c)
    limits = Map.put(c.context["limits"], "max_bytes", byte_size(F.encode(result)) - 1)
    assert {:ok, _} = Wotex.Routines.InputMapping.new(c.mapping, c.context["registry"], limits)

    assert {:error, :external_fact_limit} =
             project(%{c | context: Map.put(c.context, "limits", limits)})
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
