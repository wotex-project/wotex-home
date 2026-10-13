defmodule HomeRoutineTimezoneArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Routines.Calendar, as: Adapter
  alias Wotex.Routines.{CalendarRequest, Error, Limits, Schedule}
  alias WotexHome.Schedules.{CalendarReference, Codec, Occurrence, RoutineTimezone, Tzif}

  setup_all do
    corpus = JSON.decode!(File.read!("fixtures/timezone_vectors.json"))

    zones =
      Map.new(corpus["zones"], fn record ->
        bytes = Base.decode64!(record["data_base64"])
        {:ok, zone} = Tzif.decode(record["name"], bytes)
        {:ok, reference} = CalendarReference.decode(record["name"], bytes)
        {record["name"], %{zone: zone, reference: reference, vectors: record["vectors"]}}
      end)

    generic =
      :wotex_routines
      |> :code.priv_dir()
      |> List.to_string()
      |> Path.join("vectors/wro-01.json")
      |> File.read!()
      |> JSON.decode!()

    {:ok, limits} = Limits.new(generic["limits"])

    time = %{
      "epoch" => "boot:one",
      "clock_generation" => "clock:one",
      "elapsed_ms" => 1000,
      "utc_low_ms" => nil,
      "utc_high_ms" => nil
    }

    %{zones: zones, limits: limits, time: time}
  end

  test "the exact Home closure and four passive producers are freshly compiled", _ do
    root = File.cwd!()
    supplied = System.fetch_env!("HOME_SHADOW_CONSUMER_ROOT")

    assert Map.take(File.stat!(root), [:inode, :major_device]) ==
             Map.take(File.stat!(supplied), [:inode, :major_device])

    for module <- [
          RoutineTimezone,
          Tzif,
          CalendarReference,
          Occurrence,
          Adapter,
          ExBooking,
          ExBooking.TimeZoneProvider,
          Wotex.JSON,
          WotexContinuum
        ] do
      Code.ensure_loaded!(module)

      assert module
             |> :code.which()
             |> List.to_string()
             |> String.starts_with?(Path.join(root, "_build"))
    end

    for app <- [:wotex, :wotex_continuum, :wotex_routines, :ex_booking],
        do: assert(Application.spec(app, :mod) in [nil, []])

    refute Code.ensure_loaded?(WotexHome.Authority)
  end

  test "all 230 retained vectors agree through the producer's public provider seam", c do
    count =
      Enum.reduce(c.zones, 0, fn {name, input}, count ->
        assert {:ok, provider} = RoutineTimezone.provider(input.zone)

        for vector <- input.vectors do
          local = NaiveDateTime.from_iso8601!(vector["local"])
          assert CalendarReference.resolve(input.reference, local) == {:ok, vector["utc_ms"]}

          assert instants(ExBooking.TimeZoneProvider.from_naive(local, name, provider)) ==
                   vector["utc_ms"]
        end

        count + length(input.vectors)
      end)

    assert count == 230
    IO.puts("230 independent timezone vectors passed through extracted producer provider")
  end

  test "gap/fold calendar pages retain original Home occurrence bytes across page sizes", c do
    cases = [
      {"Fixture/Stockholm", "2026-03-28T02:30:00+01:00", "2026-03-28T00:00:00Z",
       "2026-04-01T00:00:00Z",
       ["2026-03-28T01:30:00Z", "2026-03-30T00:30:00Z", "2026-03-31T00:30:00Z"]},
      {"Fixture/New_York", "2026-03-07T02:30:00-05:00", "2026-03-07T00:00:00Z",
       "2026-03-11T00:00:00Z",
       ["2026-03-07T07:30:00Z", "2026-03-09T06:30:00Z", "2026-03-10T06:30:00Z"]},
      {"Fixture/Stockholm", "2026-10-24T02:30:00+02:00", "2026-10-24T00:00:00Z",
       "2026-10-28T00:00:00Z",
       ["2026-10-24T00:30:00Z", "2026-10-25T00:30:00Z", "2026-10-26T01:30:00Z"]},
      {"Fixture/New_York", "2026-10-31T01:30:00-04:00", "2026-10-31T00:00:00Z",
       "2026-11-04T00:00:00Z",
       ["2026-10-31T05:30:00Z", "2026-11-01T05:30:00Z", "2026-11-02T06:30:00Z"]}
    ]

    for {name, start, from, until, expected} <- cases do
      zone = c.zones[name].zone
      request = request(c, zone, start, from, until, "FREQ=DAILY;COUNT=3", 1)
      actual = pages(request, c, [], 0)
      assert Enum.map(actual, & &1["starts_at"]) == expected
      assert Enum.map(actual, & &1["ordinal"]) == [1, 2, 3]

      assert {:ok, whole} =
               Adapter.page(
                 %{request | query: %{request.query | "limit" => 10}},
                 c.time,
                 c.limits
               )

      assert whole.occurrences == actual
      source = source(zone, start)

      for occurrence <- actual do
        due = occurrence["due_ms"]
        assert {:ok, legacy} = Occurrence.build(source, 7, 9, ["utc", due])
        {:ok, source_digest} = Codec.digest(source)

        expected_bytes =
          JSON.encode!([
            "wotex-home.schedule-occurrence.v1",
            7,
            "schedule:one",
            2,
            source_digest,
            9,
            ["utc", due]
          ])

        assert {:ok, identity} = Occurrence.identity(legacy)
        assert identity.document == expected_bytes
        assert identity.id == "occ:" <> sha(expected_bytes)
        assert identity.root_id == "cause:schedule:" <> sha(expected_bytes)
      end
    end
  end

  test "selected second-fold DTSTART remains its original and clock generation only fences projection",
       c do
    for {name, start, expected} <- [
          {"Fixture/Stockholm", "2026-10-25T02:30:00+01:00", "2026-10-25T01:30:00Z"},
          {"Fixture/New_York", "2026-11-01T01:30:00-05:00", "2026-11-01T06:30:00Z"}
        ] do
      {:ok, utc, _} = DateTime.from_iso8601(expected)
      from = DateTime.add(utc, -1) |> DateTime.to_iso8601()
      until = DateTime.add(utc, 172_800) |> DateTime.to_iso8601()
      request = request(c, c.zones[name].zone, start, from, until, "FREQ=DAILY;COUNT=2", 1)
      assert {:ok, first} = Adapter.page(request, c.time, c.limits)
      assert [occurrence] = first.occurrences
      assert occurrence["starts_at"] == expected
      assert occurrence["resolution"] == "second_fold"
      changed_time = %{c.time | "clock_generation" => "clock:two"}
      assert {:ok, rebuilt} = Adapter.page(request, changed_time, c.limits)
      assert hd(rebuilt.occurrences)["original"] == occurrence["original"]

      assert {:error, %Error{code: :stale_calendar_cursor}} =
               Adapter.page(%{request | cursor: first.next_cursor}, changed_time, c.limits)
    end
  end

  test "changed contexts, malformed native zones and precise query endpoints are explicit", c do
    zone = c.zones["Fixture/Stockholm"].zone

    request =
      request(
        c,
        zone,
        "2026-10-24T02:30:00+02:00",
        "2026-10-24T00:00:00Z",
        "2026-10-28T00:00:00Z",
        "FREQ=DAILY;COUNT=3",
        1
      )

    {:ok, page} = Adapter.page(request, c.time, c.limits)

    altered = %{
      request
      | database: %{request.database | context: request.database.context <> "tamper"},
        cursor: page.next_cursor
    }

    assert {:error, %Error{code: :stale_calendar_cursor}} =
             Adapter.page(altered, c.time, c.limits)

    assert {:error, :invalid_timezone_data} =
             RoutineTimezone.provider(%{zone | digest: String.duplicate("a", 64)})

    assert {:error, _} =
             RoutineTimezone.resolve(
               ~N[2026-10-24 02:30:00],
               zone.name,
               request.database.context <> "tamper"
             )

    assert {:error, :timezone_basis_mismatch} =
             RoutineTimezone.localize(
               ~U[2026-10-24 00:30:00Z],
               "Other/Zone",
               request.database.context
             )

    utc = ~U[2026-10-24 00:30:00.123456Z]
    assert {:ok, local} = ExBooking.TimeZoneProvider.shift_zone(utc, zone.name, request.database)
    assert local.microsecond == utc.microsecond
    assert DateTime.compare(local, utc) == :eq
    precise = %{request | query: %{request.query | "from" => "2026-10-24T00:30:00.123456Z"}}
    assert {:ok, filtered} = Adapter.page(precise, c.time, c.limits)
    assert hd(filtered.occurrences)["starts_at"] == "2026-10-25T00:30:00Z"
  end

  defp request(c, zone, start, from, until, rule, limit) do
    raw = %{
      "format" => "wotex.routines.schedule@1",
      "kind" => "calendar",
      "schedule_id" => "schedule:one",
      "definition_digest" => "sha256:" <> String.duplicate("0", 64),
      "late_window_ms" => 10_000,
      "rule" => rule,
      "dtstart" => start,
      "time_zone" => zone.name,
      "time_zone_basis" => "sha256:" <> zone.digest,
      "producer_basis" => System.fetch_env!("HOME_SHADOW_PRODUCER_BASIS")
    }

    {:ok, digest} = Schedule.semantic_digest(raw, c.limits)
    {:ok, schedule} = Schedule.new(%{raw | "definition_digest" => digest}, c.limits)
    {:ok, provider} = RoutineTimezone.provider(zone)

    {:ok, request} =
      CalendarRequest.new(
        schedule,
        %{"from" => from, "until" => until, "limit" => limit, "work_limit" => 100},
        provider,
        nil,
        c.limits
      )

    request
  end

  defp source(zone, start) do
    %{
      "id" => "schedule:one",
      "source_revision" => 2,
      "author_id" => "operator:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => String.duplicate("a", 64),
      "target_id" => "light:one",
      "resource_revision" => 4,
      "late_window_ms" => 10_000,
      "uncertainty_tolerance_ms" => 100,
      "trigger" => ["daily", zone.name, zone.digest, binary_part(start, 11, 8), 0, nil]
    }
  end

  defp pages(request, c, accumulated, count) when count < 5 do
    {:ok, page} = Adapter.page(request, c.time, c.limits)
    result = accumulated ++ page.occurrences

    if page.next_cursor,
      do: pages(%{request | cursor: page.next_cursor}, c, result, count + 1),
      else: result
  end

  defp instants(:gap), do: []
  defp instants({:gap, _, _}), do: []
  defp instants({:ok, datetime}), do: [DateTime.to_unix(datetime, :millisecond)]

  defp instants({:ambiguous, first, second}),
    do: Enum.map([first, second], &DateTime.to_unix(&1, :millisecond))

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
