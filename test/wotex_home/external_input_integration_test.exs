Code.require_file(Path.expand("../support/external_input_store_fixture.exs", __DIR__))
Code.require_file(Path.expand("../support/external_input_review_fixture.exs", __DIR__))

defmodule WotexHome.ExternalInputIntegrationTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.ExternalInputStoreFixture, as: F
  alias WotexHome.ExternalInputReviewFixture, as: R
  alias WotexHome.RoutineExternalFactFixture, as: P
  alias WotexHome.Profiles.ExternalReportOwner

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

  setup do
    F.setup() |> Map.merge(R.keys())
  end

  for {type, samples} <- [
        {"integer", [{25, 250}]},
        {"boolean", [{false, false}, {true, true}]},
        {"enum", [{"0", "closed"}, {"1", "open"}]},
        {"unfamiliar", [{25, 250}]}
      ] do
    @variant_type type
    @samples samples
    test "#{type} current private input retains its original coordinate through public evaluation",
         c do
      variant = variant(@variant_type)
      c = prepare(c, variant)

      review =
        R.review(c, @variant_type, "sample",
          mapping: variant.mapping,
          registry: variant.context["registry"],
          freshness_ms: 30_000
        )

      assert {:ok, _} =
               Authority.change_external_routine_input(
                 c.authority,
                 c.credential,
                 R.install(review)
               )

      for {{raw, expected}, n} <- Enum.with_index(@samples, 1) do
        report =
          put_in(
            variant.report,
            ["value", "value"],
            if(is_integer(raw), do: Integer.to_string(raw), else: raw)
          )

        receipt = publish(c, report, n)
        before = tables(c)
        assert {:ok, snapshot} = collect(c, [scope("sample")])
        assert [item] = snapshot["items"]
        assert item["reason"] == nil
        fact = item["projection"]["fact"]
        assert fact["value"] === expected
        assert fact["receipt_ms"] == receipt["received_store_ms"]
        assert fact["received_at"] == nil
        assert fact["expires_ms"] == receipt["received_store_ms"] + 30_000
        assert item["projection"]["binding_basis"] == item["binding_basis"]
        assert item["binding_basis"]["input_mapping"] == review.definition.data["mapping"]

        assert {:ok, true} =
                 evaluate(review.definition.data, item, snapshot["sampled_ms"], expected)

        assert {:ok, "unknown"} =
                 evaluate(review.definition.data, item, fact["expires_ms"], expected)

        assert tables(c) == before
      end

      assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
    end
  end

  test "multi-channel selection keeps unsupported density readable and the mixed scope complete",
       c do
    c =
      F.prepare(c,
        family: "multi",
        case_keys: c.case_keys,
        decision_keys: c.decision_keys,
        policy: %{"freshness_ms" => 30_000}
      )

    review = R.review(c, "multi", "sample", freshness_ms: 30_000)

    assert {:ok, _} =
             Authority.change_external_routine_input(c.authority, c.credential, R.install(review))

    report = F.fixture("external-transport-reports")["multi"]["report"]
    publish(c, Map.put(report, "channel_id", "sample"), 1)
    density = publish(c, report, 2)

    assert {:ok, read} =
             Authority.external_report_current(
               c.authority,
               c.credential,
               "sensor:external",
               "density"
             )

    assert read["reason"] == nil
    assert read["value"]["normalized_value"] == %{"type" => "sint", "value" => "2500"}
    assert read["report_revision"] == density["revision"]

    assert {:ok, context} =
             Authority.external_routine_input_context(
               c.authority,
               c.credential,
               "sensor:external",
               "density"
             )

    candidate =
      review.definition.data["mapping"]
      |> Map.delete("sha256")
      |> Map.merge(
        Map.take(
          context["reader"],
          ~w(profile_sha256 closure_sha256 capture_digest compiler_ref reader_contract_ref channel_id affordance semantic_ref external_unit)
        )
      )

    {candidate, registry} =
      candidate_basis(
        candidate,
        review.definition.data["registry"],
        review.definition.data["limits"]
      )

    assert {:error, %{code: :incompatible_dimension}} =
             Wotex.Routines.InputMapping.digest(
               candidate,
               registry,
               review.definition.data["limits"]
             )

    before = tables(c)

    requested =
      [scope("density")] ++
        Enum.map(1..30, &scope("missing:" <> String.pad_leading(Integer.to_string(&1), 2, "0"))) ++
        [scope("sample")]

    assert {:ok, snapshot} = collect(c, requested)
    assert Enum.map(snapshot["items"], &Map.take(&1, ~w(target_id capability_key))) == requested
    assert length(snapshot["items"]) == 32

    assert Enum.all?(
             Enum.take(snapshot["items"], 31),
             &(&1["reason"] == "input_not_installed" and &1["projection"] == nil)
           )

    assert List.last(snapshot["items"])["projection"]["fact"]["value"] == 250
    assert List.last(snapshot["items"])["reason"] == nil
    assert tables(c) == before
  end

  test "a changed current review signature refuses without publishing a Fact", c do
    variant = variant("integer")
    c = prepare(c, variant)
    review = R.review(c, "review-loss", "sample", freshness_ms: 5000)

    assert {:ok, _} =
             Authority.change_external_routine_input(c.authority, c.credential, R.install(review))

    publish(c, variant.report, 1)

    :sys.replace_state(
      c.store,
      &%{&1 | qualification_decision_keys: %{"decision-entry" => <<0::256>>}}
    )

    before = tables(c)
    assert {:ok, %{"items" => [item]}} = collect(c, [scope("sample")])
    assert item["reason"] == "input_unqualified"
    assert item["projection"] == nil and item["binding_basis"] == nil
    assert tables(c) == before
    assert :sys.get_state(c.store).writable
  end

  defp prepare(c, v) do
    source = F.fixture("external-source-selections")["temperature"]["inputs"]

    reader = %{
      "installed" => Map.take(v.source, ~w(bindings contracts home_contracts)),
      "capture" => v.source["capture"],
      "reader_limits" => v.source["reader_limits"]
    }

    source =
      source
      |> Map.put("reader", reader)
      |> update_in(["channels", Access.at!(0), "consumer"], fn _ -> v.consumer end)

    F.prepare(c,
      policy: %{"freshness_ms" => 30_000},
      fixture: v.source,
      source_inputs: source,
      case_keys: c.case_keys,
      decision_keys: c.decision_keys
    )
  end

  defp variant("integer"), do: P.new()
  defp variant("boolean"), do: P.typed(P.new(), "boolean", false)
  defp variant("enum"), do: P.typed(P.new(), "enum", "0")

  defp variant("unfamiliar") do
    v = P.new()
    quantity = "urn:example:quantity:unfamiliar-thermometric-scale"

    definition =
      hd(v.source["definitions"])
      |> Map.put("id", "urn:example:semantic:unfamiliar-thermometric-scale")
      |> put_in(["unit", "quantity_kind"], quantity)

    {:ok, semantic} = Wotex.Profiles.Definition.reference(definition, v.source["reader_limits"])
    profile = put_in(v.source["profile"], ["channels", Access.at!(0), "semantic"], semantic)
    {:ok, reference} = Wotex.Profiles.Profile.reference(profile, v.source["reader_limits"])

    source =
      v.source
      |> Map.put("definitions", [definition])
      |> Map.put("profile", profile)
      |> put_in(["envelope", "profile"], reference)
      |> put_in(["envelope", "definitions"], [semantic])

    consumer =
      v.consumer
      |> Map.put("semantic_ref", semantic)
      |> put_in(["unit", "quantity_kind"], quantity)

    %{
      v
      | source: source,
        consumer: consumer,
        report: Map.put(v.report, "profile_sha256", reference["sha256"])
    }
  end

  defp publish(c, report, sequence) do
    {:ok, clock} = ExternalReportOwner.receipt_clock(c.reports)

    report =
      Map.merge(report, %{
        "receipt_time" => clock,
        "sequence" => Integer.to_string(sequence),
        "continuity" => "continuous",
        "source_ref" => c.selection.data["source_ref"],
        "source_epoch" => c.selection.data["source_epoch"]
      })

    id = "integration:#{sequence}"

    assert {:ok, published} =
             ExternalReportOwner.publish(
               c.reports,
               id,
               c.selection.data["source_ref"],
               c.selection.sha256,
               report
             )

    assert {:ok, receipt} =
             Authority.accept_external_report(c.authority, %{
               "report_owner_epoch" => published["owner_epoch"],
               "report_id" => id
             })

    receipt
  end

  defp evaluate(d, item, elapsed, expected) do
    m = d["mapping"]
    fact = item["projection"]["fact"]

    source = %{
      "format" => "wotex.routines.source@1",
      "profile" => "bounded-composition@1",
      "id" => "current-input-probe",
      "revision" => "1",
      "parameters" => %{},
      "bindings" => ["sensor"],
      "trigger" => %{"kind" => "manual"},
      "condition" => %{"op" => "eq", "binding" => "sensor", "value" => expected},
      "steps" => %{"id" => "end", "kind" => "noop"},
      "overlap" => "reject",
      "run_ms" => 1000
    }

    context = %{
      "registry" => d["registry"],
      "bases" => [m["basis"]],
      "bindings" => %{
        "sensor" => %{
          "basis" => m["legacy_basis_ref"],
          "thing_id" => fact["thing_id"],
          "resource_roles" => %{}
        }
      },
      "definitions" => [],
      "arguments" => %{},
      "compiler_basis" => "sha256:" <> String.duplicate("7", 64)
    }

    assert {:ok, program} =
             Wotex.Routines.Compiler.compile(source, context, @profile, d["limits"])

    snapshot = %{
      "id" => "snapshot:current-input",
      "membership_generation" => "membership:current-input",
      "active_programs" => [program.data["ir_digest"]],
      "resource_revisions" => %{fact["thing_id"] => 1},
      "binding_bases" => %{"sensor" => item["binding_basis"]},
      "facts" => %{"sensor" => fact}
    }

    {:ok, utc, _} = DateTime.from_iso8601(fact["source_time"])
    instant = DateTime.to_unix(utc, :millisecond) + 10

    time = %{
      "epoch" => fact["receipt_epoch"],
      "elapsed_ms" => elapsed,
      "clock_generation" => "clock:current-input",
      "utc_low_ms" => instant,
      "utc_high_ms" => instant
    }

    Wotex.Routines.Evaluation.evaluate(program, snapshot, time, @profile, d["limits"])
  end

  defp collect(c, scope), do: Authority.external_routine_facts(c.authority, c.credential, scope)

  defp candidate_basis(mapping, registry, limits) do
    basis = put_in(mapping["basis"], ["affordance", "name"], mapping["affordance"]["name"])
    body = Map.drop(basis, ~w(byte_digest semantic_digest implementation_digest compiler_digest))

    basis =
      Map.put(
        basis,
        "byte_digest",
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, P.encode(body)), case: :lower)
      )

    {:ok, digest} = Wotex.Routines.Basis.semantic_digest(basis, limits)
    basis = Map.put(basis, "semantic_digest", digest)
    ref = Map.take(basis, ~w(id version semantic_digest))

    registry =
      Enum.map(registry, fn row ->
        row = if row["id"] == basis["id"], do: Map.put(row, "semantic_digest", digest), else: row

        Map.update!(
          row,
          "requires",
          &Enum.map(&1, fn old -> if old["id"] == basis["id"], do: ref, else: old end)
        )
      end)

    {Map.merge(mapping, %{"basis" => basis, "legacy_basis_ref" => ref}), registry}
  end

  defp scope(key), do: %{"target_id" => "sensor:external", "capability_key" => key}

  defp tables(c) do
    for table <-
          ~w(meta routine_external_input_operations routine_external_input_history routine_external_input_current profile_external_observations profile_external_observation_current authority_journal),
        into: %{} do
      {:ok, rows} =
        SQL.query(:sys.get_state(c.store).db, "SELECT * FROM " <> table <> " ORDER BY rowid")

      {table, rows}
    end
  end
end
