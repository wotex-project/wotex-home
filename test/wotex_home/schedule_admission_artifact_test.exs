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
    assert decoded.temporal_basis["profile"] == "single-schedule-temporal-v3"
    assert "actual_source_cursor_correspondence" in decoded.temporal_basis["obligations"]
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

  test "legacy temporal bases remain historical and cannot authorize current use" do
    {source, rule, resources, invariant} = inputs()
    {:ok, document} = AdmissionArtifact.build(source, rule, resources, invariant, nil)
    data = JSON.decode!(document)

    for {profile, extra} <- [
          {"single-schedule-temporal-v1", 3},
          {"single-schedule-temporal-v2", 1}
        ] do
      basis =
        data["temporal_basis"]
        |> Map.put("profile", profile)
        |> Map.update!("obligations", &Enum.drop(&1, -extra))
        |> Map.delete("basis_digest")

      basis = Map.put(basis, "basis_digest", Codec.hash(JSON.encode!(basis)))
      assert TemporalBasis.valid?(basis)
      historical = JSON.encode!(%{data | "temporal_basis" => basis})
      assert {:ok, decoded} = AdmissionArtifact.decode(historical)
      assert decoded.temporal_basis == basis
      assert {:error, :stale_schedule_admission} = AdmissionArtifact.current(historical)
    end

    assert {:ok, _} = AdmissionArtifact.current(document)
  end

  test "nonexample interval and countdown parameters receive source-bound current evidence" do
    {source, rule, resources, invariant} = inputs()
    {:ok, decoded} = Codec.decode(source)

    for trigger <- [
          ["interval", 7_777, 60_001, 67_779, 187_781],
          ["countdown", "boot:actual", 41, 7_777, 86_400_000]
        ] do
      {:ok, source} = Codec.encode(%{decoded | "trigger" => trigger})
      assert {:ok, document} = AdmissionArtifact.build(source, rule, resources, invariant, nil)
      assert {:ok, current} = AdmissionArtifact.current(document)
      assert current.source["trigger"] == trigger
      assert current.temporal_basis["source_digest"] == Codec.hash(source)
    end
  end

  test "parameter-dependent runtime defects cannot hide behind fixed-example correspondence" do
    {source, rule, resources, _} = inputs()
    {:ok, decoded} = Codec.decode(source)
    interval = ["interval", 7_777, 60_001, 0, nil]
    countdown = ["countdown", "boot:actual", 41, 7_777, 86_400_000]
    {:ok, things} = WotexHome.Rules.CandidateArtifact.things(resources)
    ebin = TemporalBasis |> :code.which() |> List.to_string() |> Path.dirname()

    replacements = [
      {"lib/wotex_home/schedules/window.ex", ~s(finish = due + source["late_window_ms"]),
       ~s(finish = due + source["late_window_ms"]) <>
         " + if(source[\"trigger\"] == #{inspect(interval)}, do: 1, else: 0)", interval},
      {"lib/wotex_home/schedules/planner.ex",
       "next_watermark = max(watermark, min(lower, @maximum_due))",
       "next_watermark = max(watermark, min(lower, @maximum_due))" <>
         " + if(source[\"trigger\"] == #{inspect(interval)}, do: 1, else: 0)", interval},
      {"lib/wotex_home/schedules/window.ex", "now < due ->",
       "now < due + if(source[\"trigger\"] == #{inspect(countdown)}, do: 1, else: 0) ->",
       countdown},
      {"lib/wotex_home/schedules/recurrence.ex",
       "{:ok, if(Codec.utc?(due) and (finish == nil or due < finish), do: due)}",
       "{:ok, if(anchor == 7777 and period == 60001, do: nil, else: if(Codec.utc?(due) and (finish == nil or due < finish), do: due))}",
       interval}
    ]

    for {path, expression, replacement, trigger} <- replacements do
      {:ok, actual} = Codec.encode(%{decoded | "trigger" => trigger})
      code = File.read!(Path.expand("../..", __DIR__) |> Path.join(path))
      assert length(String.split(code, expression)) == 2
      mutant = String.replace(code, expression, replacement)

      script = """
      alias WotexHome.Schedules.TemporalBasis
      original = #{inspect(ebin)}
      private = Path.join(System.tmp_dir!(), "home-source-proof-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
      File.mkdir!(private)
      File.chmod!(private, 0o700)
      for path <- Path.wildcard(Path.join(original, "*")), File.regular?(path), do: File.cp!(path, Path.join(private, Path.basename(path)))
      true = :code.del_path(String.to_charlist(original))
      true = :code.add_patha(String.to_charlist(private))
      try do
        {:ok, _} = TemporalBasis.qualify(#{inspect(actual)}, #{inspect(rule)}, #{inspect(things)})
        Code.compiler_options(ignore_module_conflict: true)
        [{module, bytes}] = Code.compile_string(#{inspect(mutant, limit: :infinity, printable_limit: :infinity)})
        artifact = Path.join(private, Atom.to_string(module) <> ".beam")
        File.write!(artifact, bytes)
        :code.purge(module)
        # All old fixed examples still pass under this matching new runtime.
        {:ok, _} = TemporalBasis.qualify(#{inspect(source)}, #{inspect(rule)}, #{inspect(things)})
        {:error, :source_correspondence_failed} = TemporalBasis.qualify(#{inspect(actual)}, #{inspect(rule)}, #{inspect(things)})
        IO.puts("source defect rejected")
      after
        File.rm_rf!(private)
      end
      """

      assert {"source defect rejected\n", 0} =
               System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
                 stderr_to_stdout: true
               )
    end
  end

  test "future fold and footer defects refuse independently checked calendar admission" do
    {interval, rule, resources, _} = inputs()
    {:ok, source} = Codec.decode(interval)
    {:ok, things} = WotexHome.Rules.CandidateArtifact.things(resources)
    ebin = TemporalBasis |> :code.which() |> List.to_string() |> Path.dirname()
    records = JSON.decode!(File.read!(@fixture))["zones"]

    mutations = [
      {"Fixture/Stockholm", "02:30:00", "lib/wotex_home/schedules/recurrence.ex",
       "first = List.first(instants)",
       "first = if date == ~D[2026-10-25], do: List.last(instants), else: List.first(instants)"},
      {"Fixture/Julian", "12:00:00", "lib/wotex_home/schedules/tzif_footer.ex",
       "Date.add(Date.new!(year, 1, 1), number - 1 + leap_adjustment)",
       "Date.add(Date.new!(year, 1, 1), number - 1 + leap_adjustment + if(year == 2026, do: 1, else: 0))"}
    ]

    for {name, time, path, expression, replacement} <- mutations do
      record = Enum.find(records, &(&1["name"] == name))
      {:ok, zone} = Tzif.decode(name, Base.decode64!(record["data_base64"]))

      {:ok, calendar} =
        Codec.encode(%{source | "trigger" => ["daily", name, zone.digest, time, 0, nil]})

      code = File.read!(Path.expand("../..", __DIR__) |> Path.join(path))
      assert length(String.split(code, expression)) == 2
      mutant = String.replace(code, expression, replacement)

      script = """
      alias WotexHome.Schedules.TemporalBasis
      original = #{inspect(ebin)}
      private = Path.join(System.tmp_dir!(), "home-calendar-proof-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
      File.mkdir!(private)
      File.chmod!(private, 0o700)
      for path <- Path.wildcard(Path.join(original, "*")), File.regular?(path), do: File.cp!(path, Path.join(private, Path.basename(path)))
      true = :code.del_path(String.to_charlist(original))
      true = :code.add_patha(String.to_charlist(private))
      try do
        zone = #{inspect(zone, limit: :infinity, printable_limit: :infinity)}
        {:ok, _} = TemporalBasis.qualify(#{inspect(calendar)}, #{inspect(rule)}, #{inspect(things)}, zone)
        Code.compiler_options(ignore_module_conflict: true)
        [{module, bytes}] = Code.compile_string(#{inspect(mutant, limit: :infinity, printable_limit: :infinity)})
        artifact = Path.join(private, Atom.to_string(module) <> ".beam")
        File.write!(artifact, bytes)
        :code.purge(module)
        {:ok, _} = TemporalBasis.qualify(#{inspect(interval)}, #{inspect(rule)}, #{inspect(things)})
        {:error, :calendar_correspondence_failed} = TemporalBasis.qualify(#{inspect(calendar)}, #{inspect(rule)}, #{inspect(things)}, zone)
        IO.puts("calendar defect rejected")
      after
        File.rm_rf!(private)
      end
      """

      assert {"calendar defect rejected\n", 0} =
               System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
                 stderr_to_stdout: true
               )
    end
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

  test "a warm positive proof does not accept a forged proposal commitment" do
    {source, rule, resources, invariant} = inputs()
    {:ok, document} = AdmissionArtifact.build(source, rule, resources, invariant, nil)
    assert {:ok, _} = AdmissionArtifact.current(document)
    data = JSON.decode!(document)

    basis =
      data["temporal_basis"]
      |> Map.put("proposal_basis_digest", String.duplicate("f", 64))
      |> Map.delete("basis_digest")

    basis = Map.put(basis, "basis_digest", Codec.hash(JSON.encode!(basis)))
    forged = JSON.encode!(%{data | "temporal_basis" => basis})
    assert {:ok, _} = AdmissionArtifact.decode(forged)
    assert {:error, :stale_schedule_admission} = AdmissionArtifact.current(forged)
    assert {:ok, _} = AdmissionArtifact.current(document)
  end

  test "a warm proof still rejects an expanded declaration set and binds changed source content" do
    {source, rule, resources, _} = inputs()
    {:ok, things} = WotexHome.Rules.CandidateArtifact.things(resources)
    assert {:ok, original} = TemporalBasis.qualify(source, rule, things)
    extra = %{things["light:desk"] | id: "light:other"}

    assert {:error, :unsupported_restricted_profile} =
             TemporalBasis.qualify(source, rule, Map.put(things, extra.id, extra))

    assert {:ok, ^original} = TemporalBasis.qualify(source, rule, things)
    {:ok, decoded_source} = Codec.decode(source)
    {:ok, changed_source} = Codec.encode(%{decoded_source | "late_window_ms" => 11_000})
    assert {:ok, changed} = TemporalBasis.qualify(changed_source, rule, things)
    refute changed == original
    assert changed["source_digest"] == Codec.hash(changed_source)
    assert {:ok, ^original} = TemporalBasis.qualify(source, rule, things)
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

    # Global selection journals are independent of the target's declaration
    # counter. A selection at revision 40 can bind resource revision 4.
    later = %{pin | "selection_revision" => 40, "trust_revision" => 20}

    assert {:ok, later_document} =
             AdmissionArtifact.build(source, rule, resources, invariant, later)

    assert {:ok, %{profile_pin: ^later}} = AdmissionArtifact.decode(later_document)

    for changed <- [
          Map.put(pin, "owner_revision", 9),
          %{pin | "target_id" => "light:other"},
          %{pin | "resource_revision" => 5},
          %{pin | "selection_revision" => 1},
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

  test "warm proofs reject loaded-code drift and rerun correspondence for matching mutant files" do
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
      original = #{inspect(ebin)}
      private = Path.join(System.tmp_dir!(), "home-temporal-proof-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
      File.mkdir!(private)
      File.chmod!(private, 0o700)
      for path <- Path.wildcard(Path.join(original, "*")), File.regular?(path), do: File.cp!(path, Path.join(private, Path.basename(path)))
      true = :code.del_path(String.to_charlist(original))
      true = :code.add_patha(String.to_charlist(private))
      source = #{inspect(source)}
      rule = #{inspect(rule)}
      things = #{inspect(things)}
      try do
        {:ok, basis} = TemporalBasis.qualify(source, rule, things)
        {:ok, ^basis} = TemporalBasis.qualify(source, rule, things)
        Code.compiler_options(ignore_module_conflict: true)
        [{module, bytes}] = Code.compile_string(#{inspect(mutant)})
        {:error, :runtime_artifact_unavailable} = TemporalBasis.qualify(source, rule, things)
        # A matching new file/loaded checksum is a new runtime, not old proof.
        artifact = Path.join(private, Atom.to_string(module) <> ".beam")
        original_bytes = File.read!(artifact)
        File.write!(artifact, bytes)
        :code.purge(module)
        {:error, :temporal_correspondence_failed} = TemporalBasis.qualify(source, rule, things)
        # Also change a valid runtime directly, leaving its old proof warm.
        File.write!(artifact, original_bytes)
        {:module, ^module} = :code.load_binary(module, String.to_charlist(artifact), original_bytes)
        :code.purge(module)
        {:ok, ^basis} = TemporalBasis.qualify(source, rule, things)
        {:ok, ^basis} = TemporalBasis.qualify(source, rule, things)
        File.write!(artifact, bytes)
        {:module, ^module} = :code.load_binary(module, String.to_charlist(artifact), bytes)
        :code.purge(module)
        {:error, :temporal_correspondence_failed} = TemporalBasis.qualify(source, rule, things)
        IO.puts("mutant rejected")
      after
        File.rm_rf!(private)
      end
      """

      assert {"mutant rejected\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 ["-pa", ebin, "-e", script],
                 stderr_to_stdout: true
               )
    end
  end

  test "a warm proof refuses a missing runtime artifact in an isolated process" do
    {source, rule, resources, _} = inputs()
    {:ok, things} = WotexHome.Rules.CandidateArtifact.things(resources)
    ebin = TemporalBasis |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    alias WotexHome.Schedules.TemporalBasis
    original = #{inspect(ebin)}
    private = Path.join(System.tmp_dir!(), "home-temporal-missing-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(private)
    File.chmod!(private, 0o700)
    for path <- Path.wildcard(Path.join(original, "*")), File.regular?(path), do: File.cp!(path, Path.join(private, Path.basename(path)))
    true = :code.del_path(String.to_charlist(original))
    true = :code.add_patha(String.to_charlist(private))
    source = #{inspect(source)}
    rule = #{inspect(rule)}
    things = #{inspect(things)}
    try do
      {:ok, basis} = TemporalBasis.qualify(source, rule, things)
      {:ok, ^basis} = TemporalBasis.qualify(source, rule, things)
      File.rm!(Path.join(private, "Elixir.WotexHome.Schedules.Guard.beam"))
      {:error, :runtime_artifact_unavailable} = TemporalBasis.qualify(source, rule, things)
      IO.puts("missing rejected")
    after
      File.rm_rf!(private)
    end
    """

    assert {"missing rejected\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
               stderr_to_stdout: true
             )
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
