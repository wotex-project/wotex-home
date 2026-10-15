defmodule HomeRoutineCivilArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Schedules.{
    CalendarReference,
    CivilTimezone,
    Codec,
    Occurrence,
    Recurrence,
    RoutineCalendar,
    Tzif
  }

  setup_all do
    corpus = JSON.decode!(File.read!("fixtures/timezone_vectors.json"))

    zones =
      Map.new(corpus["zones"], fn record ->
        bytes = Base.decode64!(record["data_base64"])
        {:ok, zone} = Tzif.decode(record["name"], bytes)
        {:ok, reference} = CalendarReference.decode(record["name"], bytes)
        {record["name"], %{zone: zone, reference: reference, vectors: record["vectors"]}}
      end)

    %{zones: zones, corpus: corpus}
  end

  test "actual Home candidate and all public producers load only from the extracted cohort" do
    for module <- [
          CivilTimezone,
          RoutineCalendar,
          Recurrence,
          Tzif,
          CalendarReference,
          ExBooking,
          ExBooking.TimeZoneProvider,
          Wotex.Routines.Civil,
          WotexContinuum,
          Wotex.JSON
        ] do
      Code.ensure_loaded!(module)

      assert module
             |> :code.which()
             |> List.to_string()
             |> String.starts_with?(Path.join(File.cwd!(), "_build"))
    end

    refute Code.ensure_loaded?(WotexHome.Authority)

    for app <- [:wotex, :wotex_continuum, :wotex_routines, :ex_booking],
        do: assert(Application.spec(app, :mod) in [nil, []])
  end

  test "all 230 frozen labels pass through actual complete civil calculation", c do
    count =
      for {_name, input} <- c.zones, reduce: 0 do
        count ->
          for vector <- input.vectors do
            nominal = NaiveDateTime.from_iso8601!(vector["local"])
            source = source(input.zone, Time.to_iso8601(NaiveDateTime.to_time(nominal)))
            assert {:ok, provider} = CivilTimezone.provider(input.zone)
            assert provider.module == CivilTimezone
            assert CalendarReference.resolve(input.reference, nominal) == {:ok, vector["utc_ms"]}
            assert RoutineCalendar.resolve(source, nominal, input.zone) == {:ok, vector["utc_ms"]}
          end

          count + length(input.vectors)
      end

    assert count == 230
    IO.puts("230 independent Home labels passed through the extracted civil cohort")
  end

  test "all 112 recurrence vectors preserve membership and durable original bytes", c do
    assert length(c.corpus["next_cases"]) == 112

    for vector <- c.corpus["next_cases"] do
      input = c.zones[vector["zone"]]

      source =
        source(input.zone, vector["time"], vector["days"], vector["start_ms"], vector["end_ms"])

      expected = {:ok, vector["next_ms"]}
      assert Recurrence.next(source, vector["after_ms"], input.zone) == expected
      assert CalendarReference.next(source, vector["after_ms"], input.reference) == expected
      assert RoutineCalendar.next(source, vector["after_ms"], input.zone) == expected

      if vector["next_ms"] != nil do
        due = vector["next_ms"]
        assert RoutineCalendar.coordinate(source, due, input.zone) == :ok
        {:ok, occurrence} = Occurrence.build(source, 7, 9, ["utc", due])
        {:ok, identity} = Occurrence.identity(occurrence)
        {:ok, digest} = Codec.digest(source)

        literal =
          JSON.encode!([
            "wotex-home.schedule-occurrence.v1",
            7,
            source["id"],
            2,
            digest,
            9,
            ["utc", due]
          ])

        assert identity.document == literal
        assert identity.id == "occ:" <> Codec.hash(literal)
        assert identity.root_id == "cause:schedule:" <> Codec.hash(literal)
      end
    end

    IO.puts("112 independent Home recurrence vectors passed through the extracted civil cohort")
  end

  test "threefold originals retain later one-shot choices but recurring cursors never substitute folds" do
    ten = seconds(~U[2026-07-13 10:00:00Z])

    zone =
      zone("Fixture/Threefold", [7200, 3600, 0], [{ten, 1}, {ten + 3600, 2}, {ten + 3 * 86400, 2}])

    source = source(zone, "11:30:00")

    expected =
      Enum.map(
        [~U[2026-07-13 09:30:00Z], ~U[2026-07-13 10:30:00Z], ~U[2026-07-13 11:30:00Z]],
        &milliseconds/1
      )

    assert RoutineCalendar.resolve(source, ~N[2026-07-13 11:30:00], zone) == {:ok, expected}
    [first, second, third] = expected
    assert RoutineCalendar.next(source, first - 1, zone) == {:ok, first}

    for due <- [second, third] do
      assert {:error, :schedule_coordinate_mismatch} =
               RoutineCalendar.coordinate(source, due, zone)

      once = %{
        source
        | "trigger" => ["once", zone.name, zone.digest, "2026-07-13", "11:30:00", due]
      }

      assert RoutineCalendar.validate_source(once, zone) == :ok
      assert RoutineCalendar.next(once, due - 1, zone) == {:ok, due}
      assert RoutineCalendar.coordinate(once, due, zone) == :ok
      assert RoutineCalendar.next(once, due, zone) == {:ok, nil}
    end

    for cursor <- [first, second - 1, second, third - 1, third] do
      assert RoutineCalendar.next(source, cursor, zone) == Recurrence.next(source, cursor, zone)
      refute elem(RoutineCalendar.next(source, cursor, zone), 1) in [second, third]
    end

    ended = %{source | "trigger" => ["daily", zone.name, zone.digest, "11:30:00", 0, first]}
    assert RoutineCalendar.next(ended, first - 1, zone) == {:ok, nil}
  end

  test "local-date order differs from globally sorting a multi-day producer query" do
    first = seconds(~U[2026-07-13 08:30:00Z])
    last = seconds(~U[2026-07-17 00:00:00Z])

    zone =
      zone("Fixture/DateOrder", [0, 86400, -25200], [{first, 1}, {first + 3600, 2}, {last, 2}])

    source = source(zone, "09:00:00")
    {:ok, reference} = CalendarReference.decode(zone.name, zone.bytes)
    cursor = milliseconds(~U[2026-07-13 08:00:00Z]) - 1
    today = milliseconds(~U[2026-07-13 16:00:00Z])
    tomorrow_first = milliseconds(~U[2026-07-13 09:00:00Z])
    assert {:ok, [^today]} = RoutineCalendar.resolve(source, ~N[2026-07-13 09:00:00], zone)

    assert {:ok, [^tomorrow_first | _]} =
             RoutineCalendar.resolve(source, ~N[2026-07-14 09:00:00], zone)

    assert tomorrow_first < today and tomorrow_first > cursor

    for module <- [Recurrence, RoutineCalendar],
        do: assert(module.next(source, cursor, zone) == {:ok, today})

    assert CalendarReference.next(source, cursor, reference) == {:ok, today}
  end

  test "maximum ambiguity, signed offset and final UTC headroom remain supported" do
    wall = seconds(~U[2026-07-13 12:00:00Z])
    transitions = for(index <- 1..255, do: {wall - 255 + index, index}) ++ [{wall + 1, 255}]
    zone = zone("Fixture/Maximum", Enum.to_list(255..0//-1), transitions)
    source = source(zone, "12:00:00")
    assert {:ok, values} = RoutineCalendar.resolve(source, ~N[2026-07-13 12:00:00], zone)
    assert values == for(index <- 0..255, do: (wall - 255 + index) * 1000)

    for offset <- [-89_999, 93_599] do
      zone = zone("Fixture/Wide", [offset], [])
      source = source(zone, "12:00:00")

      assert RoutineCalendar.resolve(source, ~N[2026-07-13 12:00:00], zone) ==
               {:ok, [(wall - offset) * 1000]}
    end

    zone = zone("Fixture/Final", [0], [])
    source = source(zone, "23:58:59")
    due = milliseconds(~U[9999-12-31 23:58:59Z])
    assert RoutineCalendar.next(source, due - 1, zone) == {:ok, due}
    assert RoutineCalendar.next(source, due, zone) == {:ok, nil}
    positive = zone("Fixture/Positive", [93_599], [])
    source = source(positive, "12:00:00")
    assert RoutineCalendar.next(source, Codec.utc_maximum() - 60_000, positive) == {:ok, nil}
    zone = zone("Fixture/Zero", [0], [])
    source = source(zone, "00:00:00")
    assert RoutineCalendar.next(source, -1, zone) == {:ok, 0}
  end

  test "exact search bound, preflight errors and undefined phases never become partial success" do
    first = seconds(~U[2026-07-13 09:00:00Z])

    transitions =
      for(index <- 1..32, do: {first + (index - 1) * 86400 - (index - 1), index}) ++
        [{first + 33 * 86400, 32}]

    zone = zone("Fixture/GapBound", Enum.to_list(0..32), transitions)
    source = source(zone, "09:00:00", Enum.to_list(1..7), milliseconds(~U[2026-07-13 00:00:00Z]))
    assert RoutineCalendar.next(source, -1, zone) == {:error, :calendar_search_horizon}
    assert Recurrence.next(source, -1, zone) == {:error, :calendar_search_horizon}

    assert RoutineCalendar.resolve(source, ~N[2027-07-13 09:00:00], zone) ==
             {:error, :routine_calendar_refused}

    assert RoutineCalendar.next(source, -2, zone) == {:error, :invalid_schedule_cursor}

    assert RoutineCalendar.resolve(source, ~N[2026-07-13 10:00:00], zone) ==
             {:error, :schedule_coordinate_mismatch}

    assert RoutineCalendar.resolve(source, ~N[2026-07-13 09:00:00], %{
             zone
             | digest: String.duplicate("0", 64)
           }) == {:error, :timezone_basis_mismatch}

    assert RoutineCalendar.resolve(source, ~N[2026-07-13 09:00:00], nil) ==
             {:error, :timezone_basis_required}

    once = %{
      source
      | "trigger" => ["once", zone.name, zone.digest, "2026-07-13", "09:00:00", first * 1000]
    }

    assert RoutineCalendar.validate_source(once, zone) ==
             {:error, :invalid_resolved_schedule_time}
  end

  defp source(zone, time, days \\ Enum.to_list(1..7), start \\ 0, finish \\ nil) do
    %{
      "id" => "schedule:one",
      "source_revision" => 2,
      "author_id" => "operator:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => String.duplicate("a", 64),
      "target_id" => "light:one",
      "resource_revision" => 4,
      "late_window_ms" => 10000,
      "uncertainty_tolerance_ms" => 100,
      "trigger" =>
        if(days == Enum.to_list(1..7),
          do: ["daily", zone.name, zone.digest, time, start, finish],
          else: ["weekdays", zone.name, zone.digest, time, days, start, finish]
        )
    }
  end

  defp zone(name, offsets, transitions) do
    legacy = header(0, 1) <> <<0::signed-big-32, 0, 0, "UTC", 0>>
    current = header(length(transitions), length(offsets))
    times = Enum.map_join(transitions, fn {time, _} -> <<time::signed-big-64>> end)
    indexes = Enum.map_join(transitions, fn {_, index} -> <<index>> end)
    types = Enum.map_join(offsets, &<<&1::signed-big-32, 0, 0>>)

    {:ok, zone} =
      Tzif.decode(name, legacy <> current <> times <> indexes <> types <> <<"UTC", 0, 10, 10>>)

    zone
  end

  defp header(times, types),
    do: <<"TZif2", 0::120, 0::32, 0::32, 0::32, times::32, types::32, 4::32>>

  defp seconds(value), do: DateTime.to_unix(value)
  defp milliseconds(value), do: DateTime.to_unix(value, :millisecond)
end

defmodule HomeRoutineCivilBoundaryTest do
  @moduledoc false

  # Only native-output validation/control flow uses this facade. The concurrent
  # archive cases above execute the actual producer and independent reference.
  use ExUnit.Case, async: false

  alias WotexHome.Schedules.{RoutineCalendar, Tzif}

  setup_all do
    module = Wotex.Routines.Civil
    {^module, original, file} = :code.get_object_code(module)

    {_, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        Code.compile_string(
          """
          defmodule Wotex.Routines.Civil do
            @moduledoc false

            def page(request, time, limits),
              do: HomeRoutineCivilBoundaryTest.producer(request, time, limits)
          end
          """,
          "synthetic-home-civil-boundary.ex"
        )
      end)

    assert [%{severity: :warning, message: message}] = diagnostics
    assert String.contains?(message, "redefining module Wotex.Routines.Civil")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      {:module, ^module} = :code.load_binary(module, file, original)
      :code.purge(module)
    end)

    bytes =
      <<"TZif2", 0::120, 0::32, 0::32, 0::32, 0::32, 1::32, 4::32, 0::signed-big-32, 0, 0, "UTC",
        0>>

    {:ok, zone} = Tzif.decode("Fixture/Boundary", bytes <> bytes <> <<10, 10>>)

    source = %{
      "id" => "schedule:boundary",
      "source_revision" => 1,
      "author_id" => "operator:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => String.duplicate("a", 64),
      "target_id" => "light:one",
      "resource_revision" => 1,
      "late_window_ms" => 10000,
      "uncertainty_tolerance_ms" => 100,
      "trigger" => ["daily", zone.name, zone.digest, "12:00:00", 0, nil]
    }

    %{zone: zone, source: source}
  end

  @spec producer(map(), map(), term()) :: term()
  def producer(request, time, _) do
    Process.put({__MODULE__, :calls}, Process.get({__MODULE__, :calls}, 0) + 1)
    mode = Process.get({__MODULE__, :mode}, :good)
    schedule = request.schedule
    original = "sha256:" <> String.duplicate("7", 64)
    due = DateTime.to_unix(~U[2026-07-13 12:00:00Z], :millisecond)

    point = %{
      "original" => original,
      "due_ms" => due,
      "nominal" => "2026-07-13T12:00:00",
      "starts_at" => "2026-07-13T12:00:00Z",
      "resolution" => "unique",
      "schedule_digest" => schedule["definition_digest"],
      "time_zone_basis" => schedule["time_zone_basis"],
      "producer_basis" => schedule["producer_basis"],
      "database_basis" => "sha256:" <> String.duplicate("8", 64),
      "event" => %{
        "kind" => "due",
        "original" => original,
        "schedule_id" => schedule["schedule_id"],
        "schedule_basis" => schedule["definition_digest"],
        "due_ms" => due,
        "late_window_ms" => 10000,
        "clock_generation" => time["clock_generation"],
        "time_zone_basis" => schedule["time_zone_basis"]
      }
    }

    page = %{
      __struct__: Wotex.Routines.CivilPage,
      request: request,
      time: time,
      occurrences: [point]
    }

    result(mode, page, point)
  end

  defp result(:work, _, _), do: {:error, %Wotex.Routines.Error{code: :civil_work_bound, path: ""}}
  defp result(:refuse, _, _), do: {:error, %Wotex.Routines.Error{code: :civil_refused, path: ""}}

  defp result(:missing, _, _),
    do: {:error, %Wotex.Routines.Error{code: :civil_unavailable, path: ""}}

  defp result(:contract, _, _),
    do: {:error, %Wotex.Routines.Error{code: :producer_contract_error, path: ""}}

  defp result(:raise, _, _), do: raise("PRIVATE_CIVIL_BOUNDARY_CANARY")
  defp result(:private, _, _), do: {:error, "PRIVATE_CIVIL_BOUNDARY_CANARY"}
  defp result(:extra, page, _), do: {:ok, Map.put(page, :extra, nil)}
  defp result(:request, page, _), do: {:ok, %{page | request: %{page.request | query: %{}}}}
  defp result(:time, page, _), do: {:ok, %{page | time: Map.put(page.time, "extra", nil)}}
  defp result(:improper, page, point), do: {:ok, %{page | occurrences: [point | :improper]}}
  defp result(:many, page, point), do: {:ok, %{page | occurrences: List.duplicate(point, 259)}}

  defp result(:duplicate, page, point),
    do:
      {:ok,
       %{
         page
         | occurrences: [
             %{point | "resolution" => "first_fold"},
             %{point | "resolution" => "second_fold"}
           ]
       }}

  defp result({:point, field, value}, page, point),
    do: {:ok, %{page | occurrences: [Map.put(point, field, value)]}}

  defp result(_, page, _), do: {:ok, page}

  test "malformed retained pages and native output refuse without partial coordinates", c do
    assert {:ok, [_]} = RoutineCalendar.resolve(c.source, ~N[2026-07-13 12:00:00], c.zone)

    for mode <- [
          :extra,
          :request,
          :time,
          :improper,
          :many,
          :duplicate,
          {:point, "ordinal", 1},
          {:point, "due_ms", -1},
          {:point, "due_ms", 1},
          {:point, "due_ms", 1.0},
          {:point, "nominal", "2026-07-14T12:00:00"},
          {:point, "starts_at", "2026-07-13T13:00:00+01:00"},
          {:point, "resolution", ["fold", 3]},
          {:point, "producer_basis", "forged"},
          {:point, "schedule_digest", "forged"},
          {:point, "original", "forged"},
          {:point, "event", %{}}
        ] do
      Process.put({__MODULE__, :mode}, mode)

      actual = RoutineCalendar.resolve(c.source, ~N[2026-07-13 12:00:00], c.zone)

      assert match?({:error, :invalid_routine_calendar_projection}, actual),
             "mode #{inspect(mode)} returned #{inspect(actual)}"
    end
  end

  test "work, unavailable, refusal and faulty producers have fixed outcomes without fallback",
       c do
    for {mode, expected} <- [
          work: :routine_calendar_work_bound,
          missing: :routine_calendar_unavailable,
          refuse: :routine_calendar_refused,
          contract: :invalid_routine_calendar_projection,
          raise: :invalid_routine_calendar_projection,
          private: :invalid_routine_calendar_projection
        ] do
      Process.put({__MODULE__, :mode}, mode)

      assert {:error, ^expected} =
               RoutineCalendar.resolve(c.source, ~N[2026-07-13 12:00:00], c.zone)
    end

    assert Process.get({__MODULE__, :calls}) == 6
  end
end
