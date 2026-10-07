defmodule WotexHome.ScheduleAdmissionArtifactTest do
  use ExUnit.Case, async: true
  alias WotexHome.Durable.Registry
  alias WotexHome.Rules.OperationInput, as: RuleInput
  alias WotexHome.RuntimeArtifacts
  alias WotexHome.Schedules.{AdmissionArtifact, Codec, Guard, TemporalBasis, Tzif}
  alias WotexHome.Semantics.Thing

  @hash String.duplicate("a", 64)
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  test "a separate temporal package binds complete input and runtime while granting no physical qualification" do
    {source, rule, resources, invariant} = inputs()
    assert {:ok, document} = AdmissionArtifact.build(source, rule, resources, invariant, nil)
    assert {:ok, decoded} = AdmissionArtifact.decode(document)
    assert decoded.source["author_id"] == "operator:one"
    assert decoded.source["resource_revision"] == 4
    assert decoded.rule.ownership_ms == 1
    assert decoded.temporal_basis["scope"] == "calculation_and_guard_correspondence"
    assert decoded.temporal_basis["declaration_digest"] == Codec.hash(hd(resources)["document"])

    assert {:ok, runtime} =
             RuntimeArtifacts.digest([:wotex_home], "wotex-home.single-schedule-runtime.v1")

    assert decoded.temporal_basis["runtime_digest"] == runtime
    assert {:ok, ^decoded} = AdmissionArtifact.current(document)
    assert {:ok, ^document} = AdmissionArtifact.build(source, rule, resources, invariant, nil)
    data = JSON.decode!(document)
    assert data["profile"] == "home-single-schedule-light-admission-v1"
    assert data["physical_qualification"] == "required_at_dispatch"
    assert "current_original_author" in data["mandatory_guards"]
    assert "final_temporal_handoff" in data["mandatory_guards"]
    assert "considered_watermark" in data["mandatory_guards"]
    refute match?({:ok, _}, WotexHome.Rules.AdmissionArtifact.decode(document))
  end

  test "historical runtime commitments decode but cannot become current evidence" do
    {source, rule, resources, invariant} = inputs()
    {:ok, document} = AdmissionArtifact.build(source, rule, resources, invariant, nil)
    data = JSON.decode!(document)

    basis =
      put_in(data["temporal_basis"]["runtime_digest"], String.duplicate("f", 64))[
        "temporal_basis"
      ]

    basis =
      Map.put(basis, "basis_digest", Codec.hash(JSON.encode!(Map.delete(basis, "basis_digest"))))

    assert TemporalBasis.valid?(basis)
    stale = JSON.encode!(%{data | "temporal_basis" => basis})
    assert {:ok, _} = AdmissionArtifact.decode(stale)
    assert {:error, :stale_schedule_admission} = AdmissionArtifact.current(stale)
  end

  test "calendar packages retain original full TZif and reject replacement, malformed bytes and unused zones" do
    {source, rule, resources, invariant} = inputs()
    record = JSON.decode!(File.read!(@fixture))["zones"] |> hd()
    {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))
    {:ok, decoded_source} = Codec.decode(source)

    {:ok, source} =
      Codec.encode(%{
        decoded_source
        | "trigger" => ["daily", zone.name, zone.digest, "02:30:00", 0, nil]
      })

    assert {:ok, document} =
             AdmissionArtifact.build(source, rule, resources, invariant, nil, zone)

    assert {:ok, %{timezone: ^zone}} = AdmissionArtifact.current(document)
    data = JSON.decode!(document)
    assert data["timezone"]["data_base64"] == record["data_base64"]

    for changed <- [
          put_in(data["timezone"]["data_base64"], Base.encode64(zone.bytes <> "\n")),
          put_in(data["timezone"]["digest"], @hash),
          put_in(data["timezone"]["name"], "Fixture/Other"),
          put_in(data["timezone"]["extra"], true),
          %{data | "timezone" => nil}
        ] do
      assert {:error, :corrupt_schedule_admission} =
               AdmissionArtifact.decode(JSON.encode!(changed))
    end

    assert {:error, :unsupported_schedule_admission} =
             AdmissionArtifact.build(source, rule, resources, invariant, nil)

    {interval, _, _, _} = inputs()

    assert {:error, :unsupported_schedule_admission} =
             AdmissionArtifact.build(interval, rule, resources, invariant, nil, zone)
  end

  test "expanded or altered source, declaration, temporal proof and guard lists refuse" do
    {source, rule, resources, invariant} = inputs()
    {:ok, document} = AdmissionArtifact.build(source, rule, resources, invariant, nil)
    data = JSON.decode!(document)
    changed_source = String.replace(source, "operator:one", "operator:two")

    changed_thing =
      String.replace(hd(resources)["document"], "fixture:power:one", "fixture:power:two")

    for changed <- [
          Map.put(data, "timer", true),
          %{data | "profile" => "home-explicit-light-admission-v1"},
          %{data | "scope" => "physically_qualified"},
          %{data | "source_document" => changed_source},
          %{data | "resources" => [%{hd(resources) | "document" => changed_thing}]},
          %{data | "mandatory_guards" => tl(data["mandatory_guards"])},
          put_in(data["temporal_basis"]["obligations"], []),
          put_in(data["invariant"]["target_id"], "light:other"),
          %{data | "physical_qualification" => "not_required"}
        ] do
      assert {:error, :corrupt_schedule_admission} =
               AdmissionArtifact.decode(JSON.encode!(changed))
    end

    for bytes <- [
          " " <> document,
          document <> "\n",
          document <> "{}",
          "{}",
          String.duplicate(" ", 262_145)
        ] do
      assert {:error, :corrupt_schedule_admission} = AdmissionArtifact.decode(bytes)
    end
  end

  test "exact portable pins and invariant commitments require valid ordered identities" do
    {source, rule, resources, _} = inputs()
    invariant = %{"target_id" => "light:desk", "revision" => 3, "digest" => @hash}

    pin = %{
      "target_id" => "light:desk",
      "artifact_digest" => @hash,
      "projection_digest" => @hash,
      "selection_revision" => 4,
      "selection_generation" => 2,
      "trust_revision" => 2,
      "resource_revision" => 4
    }

    assert {:ok, document} = AdmissionArtifact.build(source, rule, resources, invariant, pin)
    assert {:ok, %{profile_pin: ^pin, invariant: ^invariant}} = AdmissionArtifact.decode(document)

    for changed <- [
          Map.put(pin, "owner_revision", 9),
          %{pin | "target_id" => "light:other"},
          %{pin | "resource_revision" => 5},
          %{pin | "selection_revision" => 5},
          %{pin | "selection_generation" => 0},
          %{pin | "trust_revision" => true}
        ] do
      assert {:error, :unsupported_schedule_admission} =
               AdmissionArtifact.build(source, rule, resources, invariant, changed)
    end

    assert {:error, :unsupported_schedule_admission} =
             AdmissionArtifact.build(source, rule, resources, %{invariant | "revision" => 0}, pin)
  end

  test "unsupported body, changed resource and safety-sensitive declaration never gain temporal admission" do
    {source, rule, resources, invariant} = inputs()

    for changed <- [
          [%{hd(resources) | "resource_revision" => 5}],
          resources ++ resources,
          [
            %{
              hd(resources)
              | "document" =>
                  String.replace(hd(resources)["document"], ~s("ordinary"), ~s("safety"))
            }
          ]
        ] do
      assert {:error, :unsupported_schedule_admission} =
               AdmissionArtifact.build(source, rule, changed, invariant, nil)
    end

    conditional = String.replace(rule, ~s("ownership_ms":1), ~s("ownership_ms":2))
    {:ok, original} = Codec.decode(source)
    {:ok, source} = Codec.encode(%{original | "rule_source_digest" => Codec.hash(conditional)})

    assert {:error, :unsupported_schedule_admission} =
             AdmissionArtifact.build(source, conditional, resources, invariant, nil)
  end

  test "guard precedence keeps author loss, maintenance, composition and consumed roots closed" do
    input = %{
      maintenance: false,
      active_generation: true,
      current_admission: true,
      current_author: true,
      current_target: true,
      current_profile: true,
      capacity_available: true,
      considered: false,
      invariant: :allow,
      override: :none,
      window: :eligible,
      active_count: 1
    }

    assert {:ok, :allow} = Guard.decision(input)

    for {field, value, reason} <- [
          {:maintenance, true, :maintenance_active},
          {:active_count, 2, :composed_temporal_unsupported},
          {:active_generation, false, :stale_rule_generation},
          {:current_admission, false, :schedule_basis_changed},
          {:current_author, false, :author_unavailable},
          {:current_target, false, :permission_denied},
          {:current_profile, false, :profile_unavailable},
          {:invariant, :unknown, :invariant_unresolved},
          {:override, :live, :operator_override_active},
          {:considered, true, :occurrence_already_considered},
          {:window, :early, :occurrence_early},
          {:window, :uncertain, :clock_uncertain},
          {:window, :expired, :occurrence_expired},
          {:capacity_available, false, :scheduler_capacity}
        ] do
      assert {:ok, ^reason} = Guard.decision(Map.put(input, field, value))
    end

    assert {:ok, :maintenance_active} =
             Guard.decision(%{input | maintenance: true, current_author: false, considered: true})

    assert {:ok, :author_unavailable} =
             Guard.decision(%{
               input
               | current_author: false,
                 window: :eligible,
                 capacity_available: true
             })

    assert {:ok, :occurrence_already_considered} =
             Guard.decision(%{input | considered: true, capacity_available: false})

    assert {:error, :invalid_schedule_guards} =
             Guard.decision(Map.put(input, :privileged_runner, true))

    assert {:error, :invalid_schedule_guards} = Guard.decision(%{input | current_author: "true"})
  end

  test "separate processes reject omitted guards, always-open windows and replaying cursors" do
    {source, rule, resources, _} = inputs()
    {:ok, things} = WotexHome.Rules.CandidateArtifact.things(resources)
    ebin = TemporalBasis |> :code.which() |> List.to_string() |> Path.dirname()

    mutants = [
      "defmodule WotexHome.Schedules.Guard do; def decision(_), do: {:ok, :allow}; end",
      "defmodule WotexHome.Schedules.Window do; def check(_, _, _, _, _, _, _ \\\\ nil), do: {:ok, :eligible}; end",
      "defmodule WotexHome.Schedules.Planner do; def cadence(_, _ \\\\ nil), do: :ok; " <>
        "def plan(_, _, _, _, _, _, _ \\\\ nil), do: {:ok, %{decision: :eligible, coordinate: [\"utc\", 100000], watermark: 100000, missed_range: nil}}; end"
    ]

    for mutant <- mutants do
      script = """
      alias WotexHome.Schedules.TemporalBasis
      source = #{inspect(source)}
      rule = #{inspect(rule)}
      things = #{inspect(things)}
      {:ok, _} = TemporalBasis.qualify(source, rule, things)
      Code.compiler_options(ignore_module_conflict: true)
      Code.compile_string(#{inspect(mutant)})
      {:error, :temporal_correspondence_failed} = TemporalBasis.qualify(source, rule, things)
      IO.puts("mutant rejected")
      """

      assert {"mutant rejected\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 ["-pa", ebin, "-e", script],
                 stderr_to_stdout: true
               )
    end
  end

  defp inputs do
    {:ok, rule} =
      RuleInput.source("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "rule:body",
        "expected_revision" => 4,
        "rule_id" => "rule:one",
        "source_revision" => 2,
        "target_id" => "light:desk",
        "on" => true
      })

    source = %{
      "id" => "schedule:one",
      "source_revision" => 2,
      "author_id" => "operator:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => Codec.hash(rule),
      "target_id" => "light:desk",
      "resource_revision" => 4,
      "late_window_ms" => 10_000,
      "uncertainty_tolerance_ms" => 100,
      "trigger" => ["interval", 100_000, 60_000, 0, nil]
    }

    {:ok, source} = Codec.encode(source)

    power = %{
      "thing_id" => "light:desk",
      "role" => "Light",
      "key" => "power",
      "value_kind" => "boolean",
      "unit" => "none",
      "operations" => ["read", "write"],
      "risk_class" => "ordinary",
      "profile_ref" => "lifx.old:1",
      "evidence_ref" => "fixture:power:one",
      "freshness_ms" => 5_000,
      "constraints" => %{},
      "extensions" => %{}
    }

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:desk",
        "role" => "Light",
        "profile_ref" => "lifx.old:1",
        "capabilities" => [power]
      })

    {:ok, document} = Registry.encode_thing(thing)
    resources = [%{"thing_id" => thing.id, "resource_revision" => 4, "document" => document}]
    invariant = %{"target_id" => thing.id, "revision" => 0, "digest" => nil}
    {source, rule, resources, invariant}
  end
end
