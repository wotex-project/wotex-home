defmodule WotexHome.ScheduleTimezoneCustodyTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Codec, Timezone, Tzif}
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "woh-zone-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(Path.join(root, "Fixture"))
    File.chmod!(Path.join(root, "Fixture"), 0o700)
    zones = JSON.decode!(File.read!(@fixture))["zones"]

    for record <- zones do
      path = Path.join(root, record["name"])
      File.write!(path, Base.decode64!(record["data_base64"]))
      File.chmod!(path, 0o600)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, zones: zones, options: [root: root, owner_uid: File.stat!(root).uid]}
  end

  test "actual descriptor reads retain all original TZif bytes and independent resolution vectors",
       c do
    for record <- c.zones do
      assert {:ok, %Tzif{} = zone} = Timezone.read(record["name"], c.options)
      assert zone.bytes == Base.decode64!(record["data_base64"])
      assert zone.digest == record["sha256"]

      for vector <- record["vectors"] do
        assert {:ok, result} = Timezone.resolve(record["name"], vector["local"], c.options)
        assert result.name == zone.name && result.digest == zone.digest
        assert result.basis_scope == "calendar_calculation_only"
        assert result.instant_count == length(vector["utc_ms"])
        assert result.first_utc_ms == Enum.at(vector["utc_ms"], 0)
        assert result.second_utc_ms == Enum.at(vector["utc_ms"], 1)
      end
    end
  end

  test "source pins must match installed host bytes and noncalendar sources need no timezone",
       c do
    {:ok, zone} = Timezone.read("Fixture/Stockholm", c.options)
    source = source(["daily", zone.name, zone.digest, "02:30:00", 0, nil])
    assert {:ok, ^zone} = Timezone.source(source, c.options)
    File.write!(Path.join(c.root, zone.name), Base.decode64!(Enum.at(c.zones, 1)["data_base64"]))
    assert {:error, :timezone_basis_changed} = Timezone.source(source, c.options)
    File.rm!(Path.join(c.root, zone.name))
    assert {:error, :timezone_basis_changed} = Timezone.source(source, c.options)
    assert {:ok, nil} = Timezone.source(source(["interval", 0, 60_000, 0, nil]), root: "/absent")
  end

  test "traversal, endpoints, noncanonical labels and absent files never select a host file", c do
    for name <- [
          "../UTC",
          "/UTC",
          "Fixture/../UTC",
          "https://zone",
          "Fixture//UTC",
          nil,
          "Missing"
        ] do
      assert {:error, :timezone_unavailable} = Timezone.read(name, c.options)
    end

    for local <- [
          "2026-01-01",
          "2026-01-01T00:00:60",
          "2026-01-01T00:00:00Z",
          "1969-01-01T00:00:00",
          nil
        ] do
      assert {:error, _} = Timezone.resolve("Fixture/UTC", local, c.options)
    end
  end

  test "mutable root, nested directory and wrong ownership refuse even valid TZif bytes", c do
    assert {:error, :timezone_unavailable} =
             Timezone.read(
               "Fixture/UTC",
               Keyword.put(c.options, :owner_uid, File.stat!(c.root).uid + 1)
             )

    File.chmod!(c.root, 0o770)
    assert {:error, :timezone_unavailable} = Timezone.read("Fixture/UTC", c.options)
    File.chmod!(c.root, 0o700)
    File.chmod!(Path.join(c.root, "Fixture"), 0o777)
    assert {:error, :timezone_unavailable} = Timezone.read("Fixture/UTC", c.options)
  end

  test "world-writable, oversized, directory and malformed data refuse; installed aliases preserve names",
       c do
    path = Path.join(c.root, "Fixture/UTC")
    File.chmod!(path, 0o622)
    assert {:error, :timezone_unavailable} = Timezone.read("Fixture/UTC", c.options)
    File.chmod!(path, 0o600)
    File.ln_s!(path, Path.join(c.root, "Fixture/Alias"))
    assert {:ok, %Tzif{name: "Fixture/Alias"}} = Timezone.read("Fixture/Alias", c.options)
    File.write!(path, :binary.copy("x", 65_537))
    assert {:error, :timezone_unavailable} = Timezone.read("Fixture/UTC", c.options)
    File.write!(path, "invalid")
    assert {:error, :timezone_unavailable} = Timezone.read("Fixture/UTC", c.options)
    assert {:error, :timezone_unavailable} = Timezone.read("Fixture", c.options)
  end

  defp source(trigger) do
    %{
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
end
