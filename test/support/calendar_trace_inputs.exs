defmodule WotexHome.TestSupport.CalendarTraceInputs do
  @moduledoc false
  alias WotexHome.Schedules.{Timezone, Tzif}

  @zones Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)
         |> File.read!()
         |> JSON.decode!()
         |> Map.fetch!("zones")

  def installed(vector, root) do
    record = Enum.find(@zones, &(&1["name"] == vector["zone"]))
    {:ok, frozen} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))
    true = frozen.digest == record["sha256"]
    true = Enum.at(vector["trigger"], 2) == frozen.digest

    name =
      case vector["zone"] do
        "Fixture/Stockholm" -> "Europe/Stockholm"
        "Fixture/New_York" -> "America/New_York"
      end

    {:ok, zone} = Timezone.read(name)

    trigger =
      vector["trigger"] |> List.replace_at(1, zone.name) |> List.replace_at(2, zone.digest)

    path = Path.join(root, "calendar-oracle.json")

    File.write!(
      path,
      JSON.encode!(%{"data_base64" => Base.encode64(zone.bytes), "trigger" => trigger})
    )

    File.chmod!(path, 0o400)
    script = Path.expand("../fixtures/schedules/generate_calendar_durable_vectors.py", __DIR__)

    {output, 0} =
      System.cmd("python3", [script, "--verify-installed-input", path], stderr_to_stdout: true)

    true = JSON.decode!(output) == vector["instants"]
    %{zone: zone, trigger: trigger, instants: vector["instants"]}
  end
end
