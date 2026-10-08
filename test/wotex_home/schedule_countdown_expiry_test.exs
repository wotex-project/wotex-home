defmodule WotexHome.ScheduleCountdownExpiryTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Codec, CountdownExpiry}
  @format "wotex-home.schedule-countdown-expiry.v1"

  test "expiry is a canonical original activation/cause record without a time sample" do
    original =
      ~s(["wotex-home.schedule-countdown-expiry.v1",6,1,9,"countdown_missed:old_boot","boot:new",1])

    assert {:ok, ^original} =
             CountdownExpiry.build(%{revision: 6, epoch: 1}, 9, :old_boot, "boot:new", 1)

    assert {:ok, record} = CountdownExpiry.decode(original)

    assert record == %{
             activation_revision: 6,
             authority_epoch: 1,
             expected_revision: 9,
             reason: "countdown_missed:old_boot",
             boot_epoch: "boot:new",
             clock_generation: 1
           }

    assert CountdownExpiry.for_source?(record, source())
    refute CountdownExpiry.for_source?(%{record | boot_epoch: "boot:original"}, source())

    refute CountdownExpiry.for_source?(record, %{
             source()
             | "trigger" => ["interval", 0, 60_000, 0, nil]
           })
  end

  test "generation loss and unavailable custody have distinct closed identities" do
    for {reason, generation, valid} <- [
          {:clock_changed, 2, true},
          {:clock_changed, 0, true},
          {:clock_changed, 1, false},
          {:clock_unavailable, nil, true},
          {:clock_unavailable, 1, true},
          {:clock_unavailable, 2, false}
        ] do
      assert {:ok, document} =
               CountdownExpiry.build(
                 %{revision: 6, epoch: 1},
                 6,
                 reason,
                 "boot:original",
                 generation
               )

      assert {:ok, record} = CountdownExpiry.decode(document)
      assert CountdownExpiry.for_source?(record, source()) == valid
      refute CountdownExpiry.for_source?(Map.put(record, :clock_sample, %{}), source())
    end
  end

  test "expanded, noncanonical, invalid bounds and unknown causes cannot become expiry history" do
    valid = [@format, 6, 1, 9, "countdown_missed:old_boot", "boot:new", 1]

    for changed <- [
          valid ++ [0],
          List.replace_at(valid, 0, "wotex-home.schedule-withdrawal.v1"),
          List.replace_at(valid, 1, 0),
          List.replace_at(valid, 2, 0),
          List.replace_at(valid, 3, 5),
          List.replace_at(valid, 4, "countdown_missed:guessed_time"),
          List.replace_at(valid, 5, ""),
          List.replace_at(valid, 6, nil),
          List.replace_at(valid, 6, -1),
          List.replace_at(valid, 6, 9_223_372_036_854_775_808)
        ] do
      assert {:error, :invalid_countdown_expiry} = CountdownExpiry.decode(JSON.encode!(changed))
    end

    assert {:error, :invalid_countdown_expiry} =
             CountdownExpiry.decode(" " <> JSON.encode!(valid))

    assert {:error, :invalid_countdown_expiry} =
             CountdownExpiry.build(%{}, 1, :unknown, "boot:new", 1)

    refute CountdownExpiry.for_source?(nil, source())
  end

  defp source,
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
      "trigger" => ["countdown", "boot:original", 1, 0, 60_000]
    }
end
