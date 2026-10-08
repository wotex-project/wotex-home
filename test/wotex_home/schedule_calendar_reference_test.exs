defmodule WotexHome.ScheduleCalendarReferenceTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{CalendarReference, Codec}
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)
  @source %{
    "id" => "schedule:reference",
    "source_revision" => 1,
    "author_id" => "operator:one",
    "rule_id" => "rule:one",
    "rule_source_digest" => String.duplicate("a", 64),
    "target_id" => "light:one",
    "resource_revision" => 0,
    "late_window_ms" => 10_000,
    "uncertainty_tolerance_ms" => 100,
    "trigger" => ["interval", 100_000, 60_000, 0, nil]
  }

  test "independent byte parsing and phase intersection agree with all frozen local resolution vectors" do
    corpus = JSON.decode!(File.read!(@fixture))
    assert Enum.sum(Enum.map(corpus["zones"], &length(&1["vectors"]))) == 230

    for record <- corpus["zones"] do
      assert {:ok, reference} =
               CalendarReference.decode(record["name"], Base.decode64!(record["data_base64"]))

      assert reference.digest == record["sha256"]

      for vector <- record["vectors"] do
        assert {:ok, instants} =
                 CalendarReference.resolve(
                   reference,
                   NaiveDateTime.from_iso8601!(vector["local"])
                 )

        assert instants == vector["utc_ms"], "#{record["name"]} #{vector["local"]}"
      end
    end
  end

  test "independent Gregorian recurrence agrees with the frozen gap, fold and source-bound vectors" do
    corpus = JSON.decode!(File.read!(@fixture))

    references =
      Map.new(corpus["zones"], fn record ->
        {:ok, reference} =
          CalendarReference.decode(record["name"], Base.decode64!(record["data_base64"]))

        {record["name"], reference}
      end)

    assert length(corpus["next_cases"]) == 112

    for vector <- corpus["next_cases"] do
      reference = references[vector["zone"]]

      trigger =
        if vector["days"] == Enum.to_list(1..7),
          do: [
            "daily",
            reference.name,
            reference.digest,
            vector["time"],
            vector["start_ms"],
            vector["end_ms"]
          ],
          else: [
            "weekdays",
            reference.name,
            reference.digest,
            vector["time"],
            vector["days"],
            vector["start_ms"],
            vector["end_ms"]
          ]

      assert {:ok, actual} =
               CalendarReference.next(
                 %{@source | "trigger" => trigger},
                 vector["after_ms"],
                 reference
               )

      assert actual == vector["next_ms"], inspect(vector)
    end
  end

  test "one-shot selection and recurring first-fold policy remain distinct" do
    reference = reference("Fixture/Stockholm")
    assert {:ok, [first, second]} = CalendarReference.resolve(reference, ~N[2026-10-25 02:30:00])

    for selected <- [first, second] do
      source = %{
        @source
        | "trigger" => [
            "once",
            reference.name,
            reference.digest,
            "2026-10-25",
            "02:30:00",
            selected
          ]
      }

      assert {:ok, ^selected} = CalendarReference.next(source, selected - 1, reference)
      assert {:ok, nil} = CalendarReference.next(source, selected, reference)
    end

    source = %{
      @source
      | "trigger" => [
          "daily",
          reference.name,
          reference.digest,
          "02:30:00",
          first + 1,
          second + 1
        ]
    }

    assert {:ok, nil} = CalendarReference.next(source, first, reference)

    source = %{
      @source
      | "trigger" => [
          "once",
          reference.name,
          reference.digest,
          "2026-10-25",
          "02:30:00",
          first + 1
        ]
    }

    assert {:error, :invalid_calendar_reference} = CalendarReference.next(source, -1, reference)
  end

  test "finite phase boundaries and unspecified data never become extrapolated offsets" do
    assert {:ok, reference} =
             CalendarReference.decode("Fixture/Finite", data([{1_000, 1}, {2_000, 0}], ""))

    assert {:ok, 0} = CalendarReference.offset(reference, 999_999)
    assert {:ok, 3_600} = CalendarReference.offset(reference, 1_000_000)
    assert {:ok, 3_600} = CalendarReference.offset(reference, 1_999_999)
    assert {:error, :timezone_undefined} = CalendarReference.offset(reference, 2_000_000)
    assert {:ok, constant} = CalendarReference.decode("Fixture/Constant", data([], ""))
    assert {:ok, 0} = CalendarReference.offset(constant, Codec.utc_maximum() - 60_000)

    assert {:ok, unknown} =
             CalendarReference.decode(
               "Fixture/Unknown",
               String.replace(data([], ""), "STD", "-00")
             )

    assert {:error, :timezone_undefined} =
             CalendarReference.resolve(unknown, ~N[2026-01-01 12:00:00])
  end

  test "closed raw-data and source boundaries reject malformed or substituted inputs" do
    bytes = data([{1_000, 1}, {2_000, 0}], "")

    bad = [
      binary_part(bytes, 0, 43),
      bytes <> "ignored",
      binary_part(bytes, 0, byte_size(bytes) - 1),
      data([{1_000, 1}, {1_000, 0}], ""),
      data([{2_000, 1}, {1_000, 0}], ""),
      data([{1_000, 2}], ""),
      data([{1_000, 1}], "UTC0"),
      data([], "EST5EDT"),
      data([], "UTC0\nUTC0"),
      data([], "UTC0DST,M0.1.0,M10.5.0"),
      data([], "UTC0DST,J0,J365"),
      data([], "UTC0DST,M3.5.0/-2,M10.5.0"),
      data([], "UTC0DST,M3.5.0/25,M10.5.0"),
      replace(bytes, 32, <<4_097::unsigned-big-32>>),
      replace(bytes, 28, <<1::unsigned-big-32>>),
      String.replace(bytes, "TZif2", "TZif1"),
      String.duplicate("x", 65_537)
    ]

    for bytes <- bad,
        do:
          assert(
            {:error, :invalid_calendar_reference} ==
              CalendarReference.decode("Fixture/Broken", bytes)
          )

    assert {:error, :invalid_calendar_reference} = CalendarReference.decode("/UTC", bytes)
    reference = reference("Fixture/UTC")

    source = %{
      @source
      | "trigger" => ["daily", reference.name, reference.digest, "12:00:00", 0, nil]
    }

    assert {:error, :invalid_calendar_reference} =
             CalendarReference.next(Map.put(source, "timer", true), -1, reference)

    assert {:error, :invalid_calendar_reference} = CalendarReference.next(source, -2, reference)

    assert {:error, :invalid_calendar_reference} =
             CalendarReference.next(source, 0, %{reference | digest: String.duplicate("f", 64)})

    assert {:error, :invalid_calendar_reference} =
             CalendarReference.resolve(reference, ~N[2026-01-01 12:00:00.001])
  end

  test "replacing all production calendar calculators cannot change the reference in an isolated VM" do
    ebin = CalendarReference |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    alias WotexHome.Schedules.CalendarReference
    Code.compiler_options(ignore_module_conflict: true)
    Code.compile_string(~S|defmodule WotexHome.Schedules.Tzif do; def decode(_, _), do: raise("production called"); def resolve(_, _), do: raise("production called"); end|)
    Code.compile_string(~S|defmodule WotexHome.Schedules.TzifFooter do; def decode(_, _), do: raise("production called"); def at(_, _), do: raise("production called"); end|)
    Code.compile_string(~S|defmodule WotexHome.Schedules.Recurrence do; def next(_, _, _), do: raise("production called"); end|)
    corpus = JSON.decode!(File.read!(#{inspect(@fixture)}))
    for record <- corpus["zones"] do
      {:ok, reference} = CalendarReference.decode(record["name"], Base.decode64!(record["data_base64"]))
      for vector <- record["vectors"] do
        {:ok, instants} = CalendarReference.resolve(reference, NaiveDateTime.from_iso8601!(vector["local"]))
        true = instants == vector["utc_ms"]
      end
    end
    IO.puts("reference independent")
    """

    assert {"reference independent\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
               stderr_to_stdout: true
             )
  end

  defp reference(name) do
    record = JSON.decode!(File.read!(@fixture))["zones"] |> Enum.find(&(&1["name"] == name))
    {:ok, reference} = CalendarReference.decode(name, Base.decode64!(record["data_base64"]))
    reference
  end

  defp data(transitions, footer) do
    legacy = header(0, 1, 4) <> <<0::signed-big-32, 0, 0, "STD", 0>>
    current = header(length(transitions), 2, 8)
    times = for {time, _} <- transitions, into: "", do: <<time::signed-big-64>>
    indexes = for {_, index} <- transitions, into: "", do: <<index>>

    legacy <>
      current <>
      times <>
      indexes <>
      <<0::signed-big-32, 0, 0, 3_600::signed-big-32, 1, 4, "STD", 0, "DST", 0>> <>
      "\n" <> footer <> "\n"
  end

  defp header(times, types, chars),
    do:
      <<"TZif2", 0::120, 0::unsigned-big-32, 0::unsigned-big-32, 0::unsigned-big-32,
        times::unsigned-big-32, types::unsigned-big-32, chars::unsigned-big-32>>

  defp replace(bytes, offset, value),
    do:
      binary_part(bytes, 0, offset) <>
        value <>
        binary_part(
          bytes,
          offset + byte_size(value),
          byte_size(bytes) - offset - byte_size(value)
        )
end
