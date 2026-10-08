defmodule WotexHome.Schedules.TemporalBasis do
  @moduledoc "Finite single-schedule calculation/guard correspondence; no durable admission, clock trust or effect authority."
  import Bitwise
  alias WotexHome.RuntimeArtifacts
  alias WotexHome.Durable.Registry
  alias WotexHome.Rules.RestrictedBasis
  alias WotexHome.Schedules.{Codec, Guard, Occurrence, OperationInput, Planner, Window}

  @profile "single-schedule-temporal-v1"
  @scope "calculation_and_guard_correspondence"
  @domain "wotex-home.single-schedule-runtime.v1"
  @fields ~w(profile scope source_digest rule_document_digest declaration_digest proposal_basis_digest timezone_digest runtime_digest obligations basis_digest)
  @obligations ~w(exact_source_effect single_absolute_effect one_candidate_per_window zero_early_half_open_window whole_interval_tolerance original_boot_generation monotonic_considered_cursor bounded_missed_range no_uncertain_retry finite_guard_precedence original_author_required no_composed_activation)
  @flags ~w(maintenance active_generation current_admission current_author current_target current_profile capacity_available considered)a
  @hash ~r/\A[0-9a-f]{64}\z/
  @cache_key {__MODULE__, :positive_correspondence}

  def qualify(source_document, rule_document, things, zone \\ nil) do
    input = %{
      "authority_epoch" => 1,
      "operation_id" => "schedule:basis",
      "expected_revision" => 0,
      "source_document" => source_document,
      "rule_document" => rule_document
    }

    with true <- is_map(things) and map_size(things) == 1,
         {:ok, source, rule} <- OperationInput.source("review", input),
         :ok <- Planner.cadence(source, zone),
         {:ok, declaration} <- Registry.encode_thing(things[source["target_id"]]),
         {:ok, runtime} <- RuntimeArtifacts.digest([:wotex_home], @domain) do
      bindings = %{
        "profile" => @profile,
        "scope" => @scope,
        "source_digest" => Codec.hash(source_document),
        "rule_document_digest" => Codec.hash(rule_document),
        "declaration_digest" => Codec.hash(declaration),
        "timezone_digest" => timezone_digest(source),
        "runtime_digest" => runtime,
        "obligations" => @obligations
      }

      positive_correspondence(bindings, source, rule, things)
    else
      false ->
        Process.delete(@cache_key)
        {:error, :unsupported_restricted_profile}

      error ->
        Process.delete(@cache_key)
        error
    end
  end

  # One bounded positive result per caller process. Neither retained receipts
  # nor current authority/freshness/custody facts enter this cache. Every lookup
  # follows a complete fresh loaded/file-code inventory, including this verifier.
  # A cold proof also repeats that inventory after running the full verifier.
  defp positive_correspondence(bindings, source, rule, things) do
    case Process.get(@cache_key) do
      {^bindings, basis} ->
        {:ok, basis}

      _ ->
        Process.delete(@cache_key)

        with :ok <- correspondence(source),
             {:ok, proposal} <- RestrictedBasis.qualify([rule], things),
             {:ok, runtime} <- RuntimeArtifacts.digest([:wotex_home], @domain),
             true <- runtime == bindings["runtime_digest"] do
          basis =
            Map.put(
              bindings,
              "proposal_basis_digest",
              Codec.hash(:erlang.term_to_binary(proposal, [:deterministic]))
            )

          basis = Map.put(basis, "basis_digest", Codec.hash(JSON.encode!(basis)))
          Process.put(@cache_key, {bindings, basis})
          {:ok, basis}
        else
          false -> {:error, :temporal_runtime_changed}
          error -> error
        end
    end
  end

  def valid?(basis) do
    Codec.exact?(basis, @fields) and basis["profile"] == @profile and
      basis["scope"] == @scope and basis["obligations"] == @obligations and
      Enum.all?(
        ~w(source_digest rule_document_digest declaration_digest proposal_basis_digest runtime_digest basis_digest),
        &hash?(basis[&1])
      ) and
      (basis["timezone_digest"] == nil or hash?(basis["timezone_digest"])) and
      Codec.hash(JSON.encode!(Map.delete(basis, "basis_digest"))) == basis["basis_digest"]
  end

  def current(basis, source, rule, things, zone \\ nil) do
    with true <- valid?(basis),
         {:ok, current} <- qualify(source, rule, things, zone),
         true <- current == basis,
         do: :ok,
         else: (_ -> {:error, :stale_temporal_basis})
  end

  def timezone_digest(%{"trigger" => [kind, _, digest | _]})
      when kind in ["once", "daily", "weekdays"], do: digest

  def timezone_digest(_), do: nil

  defp hash?(value), do: is_binary(value) and byte_size(value) == 64 and value =~ @hash

  defp correspondence(source) do
    with :ok <- windows(source), :ok <- cursors(source), :ok <- countdown(source), do: guards()
  end

  defp windows(source) do
    source = %{source | "trigger" => ["interval", 100_000, 60_000, 0, nil]}
    {:ok, occurrence} = Occurrence.build(source, 1, 1, ["utc", 100_000])
    finish = 100_000 + source["late_window_ms"]
    tolerance = source["uncertainty_tolerance_ms"]
    points = [99_999, 100_000, 100_001, finish - 1, finish, finish + 1]

    widths =
      Enum.uniq([
        0,
        1,
        2 * tolerance,
        2 * tolerance + 1,
        source["late_window_ms"] - 1,
        source["late_window_ms"],
        source["late_window_ms"] + 1
      ])

    for lower <- points, width <- widths, reduce: :ok do
      :ok ->
        upper = lower + width
        expected = reference_window(lower, upper, 100_000, finish, tolerance)

        if Window.check(source, occurrence, sample(lower, upper), "boot:temporal", 1, 0) ==
             {:ok, expected}, do: :ok, else: {:error, :temporal_correspondence_failed}

      error ->
        error
    end
  end

  defp reference_window(lower, upper, due, finish, tolerance) do
    # Separate interval containment formulation, preserving uncertainty priority.
    precise = upper - lower <= tolerance * 2
    before = upper < due
    after_window = lower >= finish
    inside = lower >= due and upper <= finish - 1

    case {precise, before, after_window, inside} do
      {false, _, _, _} -> :uncertain
      {true, true, _, _} -> :early
      {true, _, true, _} -> :expired
      {true, _, _, true} -> :eligible
      _ -> :uncertain
    end
  end

  defp cursors(source) do
    source = %{source | "trigger" => ["interval", 100_000, 60_000, 0, nil]}
    late = source["late_window_ms"]
    {:ok, first} = Planner.plan(source, 99_999, sample(100_000, 100_000), "boot:temporal", 1, 0)

    {:ok, duplicate} =
      Planner.plan(source, first.watermark, sample(100_000, 100_000), "boot:temporal", 1, 0)

    {:ok, backward} =
      Planner.plan(source, first.watermark, sample(99_999, 99_999), "boot:temporal", 1, 0)

    jump = 100_000 + 16_000_000 * 60_000

    {:ok, forward} =
      Planner.plan(source, first.watermark, sample(jump, jump), "boot:temporal", 1, 0)

    uncertain_sample =
      sample(jump + 60_000, jump + 60_000 + 2 * source["uncertainty_tolerance_ms"] + 1)

    {:ok, uncertain} =
      Planner.plan(source, forward.watermark, uncertain_sample, "boot:temporal", 1, 0)

    {:ok, precise_later} =
      Planner.plan(
        source,
        uncertain.watermark,
        sample(jump + 60_000, jump + 60_000),
        "boot:temporal",
        1,
        0
      )

    if first.coordinate == ["utc", 100_000] and first.decision == :eligible and
         duplicate.coordinate == nil and backward.coordinate == nil and
         backward.watermark == first.watermark and forward.coordinate == ["utc", jump] and
         forward.missed_range == [100_000, jump - late] and
         uncertain.decision == :uncertain and precise_later.coordinate == nil,
       do: :ok,
       else: {:error, :temporal_correspondence_failed}
  end

  defp countdown(source) do
    source = %{source | "trigger" => ["countdown", "boot:temporal", 1, 0, 1_000]}
    {:ok, occurrence} = Occurrence.build(source, 1, 1, ["countdown", "boot:temporal", 1, 1_000])

    clock = %{
      sample(0, 0)
      | "wall_confidence" => "unqualified",
        "utc_lower_ms" => nil,
        "utc_upper_ms" => nil
    }

    checks = [
      {"boot:temporal", 1, 999, {:ok, :early}},
      {"boot:temporal", 1, 1_000, {:ok, :eligible}},
      {"boot:temporal", 1, 1_000 + source["late_window_ms"] - 1, {:ok, :eligible}},
      {"boot:temporal", 1, 1_000 + source["late_window_ms"], {:ok, :expired}},
      {"boot:other", 1, 1_000, {:error, :old_boot}},
      {"boot:temporal", 2, 1_000, {:error, :clock_changed}}
    ]

    if Enum.all?(checks, fn {boot, generation, now, expected} ->
         Window.check(source, occurrence, clock, boot, generation, now) == expected
       end), do: :ok, else: {:error, :temporal_correspondence_failed}
  end

  defp guards do
    for bits <- 0..255,
        invariant <- [:allow, :deny, :unknown],
        override <- [:none, :live],
        window <- [:early, :eligible, :uncertain, :expired],
        active_count <- [0, 1, 2],
        reduce: :ok do
      :ok ->
        input =
          Map.new(Enum.with_index(@flags), fn {flag, index} ->
            {flag, (bits &&& 1 <<< index) != 0}
          end)
          |> Map.merge(%{
            invariant: invariant,
            override: override,
            window: window,
            active_count: active_count
          })

        if Guard.decision(input) == {:ok, reference_guard(input)},
          do: :ok,
          else: {:error, :temporal_correspondence_failed}

      error ->
        error
    end
  end

  defp reference_guard(input) do
    failures = [
      {input.maintenance, :maintenance_active},
      {input.active_count != 1, :composed_temporal_unsupported},
      {!input.active_generation, :stale_rule_generation},
      {!input.current_admission, :schedule_basis_changed},
      {!input.current_author, :author_unavailable},
      {!input.current_target, :permission_denied},
      {!input.current_profile, :profile_unavailable},
      {input.invariant in [:deny, :unknown], :invariant_unresolved},
      {input.override != :none, :operator_override_active},
      {input.considered, :occurrence_already_considered},
      {input.window != :eligible,
       %{early: :occurrence_early, uncertain: :clock_uncertain, expired: :occurrence_expired}[
         input.window
       ]},
      {!input.capacity_available, :scheduler_capacity}
    ]

    case Enum.find(failures, fn {failed, _} -> failed end) do
      nil -> :allow
      {true, reason} -> reason
    end
  end

  defp sample(lower, upper),
    do: %{
      "source_id" => "clock:temporal",
      "qualification_digest" => String.duplicate("a", 64),
      "boot_epoch" => "boot:temporal",
      "generation" => 1,
      "sampled_monotonic_ms" => 0,
      "utc_lower_ms" => lower,
      "utc_upper_ms" => upper,
      "maximum_age_ms" => 600_000,
      "drift_ppm" => 0,
      "wall_confidence" => "qualified",
      "monotonic_continuous" => true
    }
end
