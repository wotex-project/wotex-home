defmodule WotexHome.DurableClockContextTest do
  use ExUnit.Case, async: true
  alias WotexHome.Durable.Store.ClockContext
  alias WotexHome.Schedules.{ClockCodec, ClockLease, Codec, Tzif}
  @clock_fixture Path.expand("../fixtures/schedules/clock_vectors.json", __DIR__)
  @zone_fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  setup do
    fixture = JSON.decode!(File.read!(@clock_fixture))
    record = hd(fixture["records"])
    {:ok, request} = ClockCodec.decode_request(fixture["request_document"])

    scope =
      Map.take(
        request,
        ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest)
      )

    {:ok, lease} =
      ClockLease.establish(
        fixture["request_document"],
        fixture["policy_document"],
        record["package_document"],
        record["started_ms"],
        record["received_ms"]
      )

    {:ok, sample, interval} = ClockLease.current(lease, scope, 123)
    snapshot = %{scope: scope, sample: sample, now_ms: 123, interval: interval, reason: nil}
    %{snapshot: snapshot, boot: scope["store_boot_epoch"]}
  end

  test "ordinary receipt reads remain lazy and never acquire temporal or timezone confidence",
       c do
    parent = self()

    {:ok, context} =
      ClockContext.new(
        fn ->
          send(parent, :receipt_read)
          {c.boot, 123}
        end,
        fn ->
          send(parent, :temporal_read)
          {:ok, c.snapshot}
        end,
        fn _ ->
          send(parent, :timezone_read)
          {:ok, nil}
        end
      )

    refute_received :receipt_read
    assert ClockContext.receipt(context) == {c.boot, 123}
    assert_received :receipt_read
    refute_received :temporal_read
    refute_received :timezone_read
    assert {:ok, snapshot} = ClockContext.temporal(context)
    assert snapshot == c.snapshot
    assert_received :temporal_read
    refute_received :timezone_read
    assert {:error, :temporal_clock_unavailable} = ClockContext.temporal(fn -> {c.boot, 123} end)
    assert ClockContext.receipt(fn -> {c.boot, 123} end) == {c.boot, 123}
  end

  test "independent signed interval is bounded by actual receipt samples surrounding the read",
       c do
    reads = start_supervised!({Agent, fn -> [100, 125] end})

    {:ok, context} =
      ClockContext.new(
        fn -> {c.boot, Agent.get_and_update(reads, fn [next | rest] -> {next, rest} end)} end,
        fn -> {:ok, c.snapshot} end,
        fn _ -> {:ok, nil} end
      )

    assert {:ok, snapshot} = ClockContext.temporal(context)
    assert snapshot == c.snapshot
    assert Agent.get(reads, & &1) == []
  end

  test "future samples, substituted boot/generation, mismatched uncertainty and expanded scope refuse",
       c do
    for changed <- [
          %{c.snapshot | now_ms: 124},
          %{c.snapshot | now_ms: 122},
          %{c.snapshot | interval: {0, 1}},
          %{c.snapshot | sample: Map.put(c.snapshot.sample, "boot_epoch", "boot:other")},
          %{c.snapshot | sample: Map.put(c.snapshot.sample, "generation", 3)},
          %{c.snapshot | sample: Map.put(c.snapshot.sample, "sampled_monotonic_ms", 124)},
          %{c.snapshot | scope: Map.put(c.snapshot.scope, "store_boot_epoch", "boot:other")},
          %{c.snapshot | scope: Map.put(c.snapshot.scope, "authority_epoch", 0)},
          %{c.snapshot | scope: Map.put(c.snapshot.scope, "owner_id", "unbound")},
          %{c.snapshot | scope: Map.put(c.snapshot.scope, "caller", "unbound")},
          %{c.snapshot | reason: :temporal_clock_unavailable},
          Map.put(c.snapshot, :caller_clock, true)
        ] do
      {:ok, context} =
        ClockContext.new(fn -> {c.boot, 123} end, fn -> {:ok, changed} end, fn _ -> {:ok, nil} end)

      assert {:error, :temporal_clock_unavailable} = ClockContext.temporal(context)
    end
  end

  test "explicit unqualified snapshot retains null UTC and never invents a qualified sample", c do
    sample = %{
      c.snapshot.sample
      | "wall_confidence" => "unqualified",
        "qualification_digest" => nil,
        "monotonic_continuous" => false,
        "utc_lower_ms" => nil,
        "utc_upper_ms" => nil
    }

    snapshot = %{c.snapshot | sample: sample, interval: nil, reason: :temporal_clock_unavailable}

    {:ok, context} =
      ClockContext.new(fn -> {c.boot, 123} end, fn -> {:ok, snapshot} end, fn _ -> {:ok, nil} end)

    assert {:ok, ^snapshot} = ClockContext.temporal(context)

    {:ok, forged} =
      ClockContext.new(
        fn -> {c.boot, 123} end,
        fn -> {:ok, %{snapshot | interval: {0, 1}}} end,
        fn _ -> {:ok, nil} end
      )

    assert {:error, :temporal_clock_unavailable} = ClockContext.temporal(forged)
  end

  test "rollback or failing callbacks refuse temporal confidence; corruption reasons remain typed",
       c do
    reads = start_supervised!({Agent, fn -> [124, 123] end})

    {:ok, context} =
      ClockContext.new(
        fn -> {c.boot, Agent.get_and_update(reads, fn [head | rest] -> {head, rest} end)} end,
        fn -> {:ok, c.snapshot} end,
        fn _ -> {:ok, nil} end
      )

    assert {:error, :temporal_clock_unavailable} = ClockContext.temporal(context)

    {:ok, failing} =
      ClockContext.new(
        fn -> {c.boot, 123} end,
        fn -> raise "synthetic source failure" end,
        fn _ -> {:ok, nil} end
      )

    assert {:error, :temporal_clock_unavailable} = ClockContext.temporal(failing)

    {:ok, corrupt} =
      ClockContext.new(
        fn -> {c.boot, 123} end,
        fn -> {:error, :corrupt_schedule_admission} end,
        fn _ -> {:ok, nil} end
      )

    assert {:error, :corrupt_schedule_admission} = ClockContext.temporal(corrupt)
    assert {:error, :invalid_clock_context} = ClockContext.new(nil, nil, nil)
  end

  test "timezone callback must retain complete source name/digest/bytes and cannot add an interval zone",
       c do
    record = JSON.decode!(File.read!(@zone_fixture))["zones"] |> hd()
    {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))
    calendar = source(["daily", zone.name, zone.digest, "02:30:00", 0, nil])
    interval = source(["interval", 0, 60_000, 0, nil])

    {:ok, context} =
      ClockContext.new(fn -> {c.boot, 123} end, fn -> {:ok, c.snapshot} end, fn _ ->
        {:ok, zone}
      end)

    assert {:ok, ^zone} = ClockContext.timezone(context, calendar)
    assert {:error, :timezone_basis_changed} = ClockContext.timezone(context, interval)

    assert {:error, :timezone_basis_changed} =
             ClockContext.timezone(
               context,
               source(["daily", zone.name, Codec.hash("different"), "02:30:00", 0, nil])
             )

    {:ok, empty} =
      ClockContext.new(fn -> {c.boot, 123} end, fn -> {:ok, c.snapshot} end, fn _ ->
        {:ok, nil}
      end)

    assert {:ok, nil} = ClockContext.timezone(empty, interval)
    assert {:error, :timezone_basis_changed} = ClockContext.timezone(empty, calendar)

    assert {:error, :timezone_basis_changed} =
             ClockContext.timezone(fn -> {c.boot, 123} end, calendar)

    {:ok, changed} =
      ClockContext.new(fn -> {c.boot, 123} end, fn -> {:ok, c.snapshot} end, fn _ ->
        {:ok, %{zone | offsets: [0]}}
      end)

    assert {:error, :timezone_basis_changed} = ClockContext.timezone(changed, calendar)
  end

  defp source(trigger),
    do: %{
      "id" => "schedule:one",
      "source_revision" => 1,
      "author_id" => "manager:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => Codec.hash("inert"),
      "target_id" => "light:one",
      "resource_revision" => 0,
      "late_window_ms" => 10_000,
      "uncertainty_tolerance_ms" => 100,
      "trigger" => trigger
    }
end
