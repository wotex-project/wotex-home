defmodule Woh.Tool.NativeThingClientSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture

  @power %{
    "thing_id" => "light:fixture",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "fixture:profile:1",
    "evidence_ref" => "fixture:evidence",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }
  @report %{
    "thing_id" => "light:fixture",
    "capability_key" => "power",
    "profile_ref" => "fixture:profile:1",
    "evidence_ref" => "fixture:evidence",
    "value" => %{"type" => "boolean", "value" => true},
    "quality" => "reported",
    "trust" => "unauthenticated_local",
    "source_epoch" => "source:fixture",
    "source_sequence" => 3,
    "boot_epoch" => "adapter:fixture",
    "source_time_utc_ms" => nil,
    "received_time_utc_ms" => 1_700_000_000_000,
    "received_monotonic_ms" => 999_999_999,
    "revision" => 8,
    "received_store_boot_epoch" => "store:fixture",
    "received_store_monotonic_ms" => 900
  }
  @entry %{
    "key" => "power",
    "current_value" => %{"type" => "boolean", "value" => true},
    "report" => @report,
    "freshness" => "fresh",
    "remaining_ms" => 4_900,
    "age_ms" => 100,
    "profile_status" => "usable"
  }
  @view %{
    "format" => "wotex-home.thing-current.v1",
    "principal_id" => "reader:fixture",
    "authority_epoch" => 7,
    "store_revision" => 9,
    "store_boot_epoch" => "store:fixture",
    "sampled_monotonic_ms" => 1_000,
    "resource_revision" => 2,
    "declaration" => %{
      "id" => "light:fixture",
      "role" => "Light",
      "profile_ref" => "fixture:profile:1",
      "capabilities" => [@power]
    },
    "capabilities" => [@entry]
  }

  def run(project) do
    valid =
      for state <-
            ~w(fresh missing unknown synthetic untimed old_boot future stale profile_unavailable),
          do: one("view-" <> state, view(state))

    invalid = Enum.map(invalid_views(), &one("view-invalid", &1))

    refresh = %{
      "thing_id" => "light:fixture",
      "disposition" => "ok",
      "capability_keys" => ["power"],
      "revisions" => [9]
    }

    refresh_cases =
      for result <- [refresh, %{refresh | "disposition" => "duplicate"}],
          do: one("refresh-valid", result)

    bad_refresh =
      for {key, value} <- [
            {"thing_id", "light:other"},
            {"disposition", "observed"},
            {"capability_keys", ["power", "power"]},
            {"revisions", [true]},
            {"revisions", [9.0]},
            {"revisions", []},
            {"credential", "extra"}
          ],
          do: one("refresh-invalid", Map.put(refresh, key, value))

    cases =
      value_cases() ++
        valid ++
        invalid ++
        refresh_cases ++
        bad_refresh ++
        [
          %{
            mode: "view-refused",
            exchanges: [
              {request("thing_current"),
               %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}}
            ]
          }
        ]

    case NativeFixture.run(project, "NativeThingClientSmoke.swift", cases, [
           "NativeThingClient"
         ]) do
      :ok -> {:ok, length(cases)}
      error -> error
    end
  end

  defp request(operation),
    do: %{
      "api_version" => 1,
      "operation" => operation,
      "credential" => NativeFixture.credential(),
      "thing_id" => "light:fixture"
    }

  defp one(mode, result) do
    {operation, key} =
      if String.starts_with?(mode, "refresh"),
        do: {"lifx_refresh", "lifx_refresh"},
        else: {"thing_current", "thing_current"}

    %{
      mode: mode,
      exchanges: [{request(operation), %{"api_version" => 1, "outcome" => "ok", key => result}}]
    }
  end

  defp view("fresh"), do: @view

  defp view(state) do
    {report, age, profile} =
      case state do
        "missing" ->
          {nil, nil, "usable"}

        "unknown" ->
          {Map.merge(@report, %{"quality" => "unknown", "value" => nil}), 100, "usable"}

        "synthetic" ->
          {Map.put(@report, "trust", "synthetic_lab"), 100, "usable"}

        "untimed" ->
          {Map.merge(@report, %{
             "received_store_boot_epoch" => nil,
             "received_store_monotonic_ms" => nil
           }), nil, "usable"}

        "old_boot" ->
          {Map.put(@report, "received_store_boot_epoch", "store:old"), nil, "usable"}

        "future" ->
          {Map.put(@report, "received_store_monotonic_ms", 1_001), nil, "usable"}

        "stale" ->
          {@report, 5_001, "usable"}

        "profile_unavailable" ->
          {@report, 100, "profile_artifact_unavailable"}
      end

    entry =
      Map.merge(@entry, %{
        "report" => report,
        "age_ms" => age,
        "profile_status" => profile,
        "freshness" => state,
        "remaining_ms" => 0,
        "current_value" => nil
      })

    Map.merge(@view, %{
      "capabilities" => [entry],
      "sampled_monotonic_ms" => if(state == "stale", do: 5_901, else: 1_000)
    })
  end

  defp invalid_views do
    top =
      for {key, value} <- [
            {"format", "unknown"},
            {"principal_id", "bad id"},
            {"authority_epoch", true},
            {"authority_epoch", 7.0},
            {"resource_revision", 10},
            {"store_revision", -1},
            {"sampled_monotonic_ms", false},
            {"store_boot_epoch", "bad boot"},
            {"credential", "extra"}
          ],
          do: Map.put(@view, key, value)

    entries =
      for {key, value} <- [
            {"key", "fault"},
            {"freshness", "stale"},
            {"age_ms", 101},
            {"remaining_ms", 4_901},
            {"remaining_ms", true},
            {"current_value", nil},
            {"current_value", %{"type" => "boolean", "value" => 1}},
            {"profile_status", "qualified"},
            {"extra", 1}
          ],
          do: Map.put(@view, "capabilities", [Map.put(@entry, key, value)])

    reports =
      for {key, value} <- [
            {"thing_id", "light:other"},
            {"profile_ref", "other:1"},
            {"evidence_ref", "other:1"},
            {"revision", 10},
            {"source_sequence", true},
            {"received_store_boot_epoch", nil},
            {"quality", "unknown"},
            {"trust", "synthetic_lab"},
            {"received_store_monotonic_ms", 1_001},
            {"value", %{"type" => "boolean", "value" => 1}},
            {"value", %{"type" => "boolean", "value" => true, "extra" => 1}},
            {"credential", "extra"}
          ],
          do:
            Map.put(@view, "capabilities", [
              Map.put(@entry, "report", Map.put(@report, key, value))
            ])

    declarations =
      for {key, value} <- [
            {"thing_id", "light:other"},
            {"unit", "K"},
            {"risk_class", "sensitive"},
            {"freshness_ms", true},
            {"operations", ["read", "read"]},
            {"constraints", %{"min" => 1}},
            {"extensions", %{"bad extension" => "value"}}
          ],
          do: put_in(@view, ["declaration", "capabilities"], [Map.put(@power, key, value)])

    top ++
      entries ++
      reports ++
      declarations ++
      [
        Map.put(@view, "capabilities", []),
        put_in(@view, ["declaration", "id"], "light:other"),
        Map.delete(@view, "principal_id")
      ]
  end

  defp value_cases do
    for {role, key, kind, unit, constraints, value, bad} <- [
          {"Light", "brightness", "fraction", "ppm", %{},
           %{"type" => "fraction", "ppm" => 500_000},
           %{"type" => "fraction", "ppm" => 1_000_001}},
          {"Light", "colour_temperature", "kelvin", "K", %{"min" => 2_000, "max" => 6_500},
           %{"type" => "kelvin", "kelvin" => 4_000}, %{"type" => "kelvin", "kelvin" => 1_999}},
          {"Light", "colour_hsv", "hsv", "mdeg+ppm", %{},
           %{"type" => "hsv", "hue_mdeg" => 120_000, "saturation_ppm" => 500_000},
           %{"type" => "hsv", "hue_mdeg" => 360_000, "saturation_ppm" => 500_000}},
          {"Light", "colour_xy", "xy", "ppm", %{},
           %{"type" => "xy", "x_ppm" => 200_000, "y_ppm" => 300_000},
           %{"type" => "xy", "x_ppm" => 800_000, "y_ppm" => 300_000}},
          {"SmokeDetector", "smoke_state", "smoke_state", "none", %{},
           %{"type" => "smoke_state", "state" => "alarm"},
           %{"type" => "smoke_state", "state" => "false"}}
        ],
        payload <- [value, bad] do
      declaration =
        Map.merge(@power, %{
          "role" => role,
          "key" => key,
          "value_kind" => kind,
          "unit" => unit,
          "risk_class" => if(role == "Light", do: "ordinary", else: "sensitive"),
          "operations" => ["read"],
          "constraints" => constraints
        })

      report = Map.merge(@report, %{"capability_key" => key, "value" => payload})
      entry = Map.merge(@entry, %{"key" => key, "report" => report, "current_value" => payload})

      view =
        Map.merge(@view, %{
          "declaration" =>
            Map.merge(@view["declaration"], %{"role" => role, "capabilities" => [declaration]}),
          "capabilities" => [entry]
        })

      one(if(payload == value, do: "view-value", else: "view-invalid"), view)
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Thing.Client.Smoke do
  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Verify native current Thing evidence against an independent socket peer"
  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeThingClientSmoke.run(File.cwd!()) do
      {:ok, count} ->
        Mix.shell().info("native Thing inspection #{count} independent socket cases passed")

      {:error, reason} ->
        Mix.raise("native Thing inspection failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.thing.client.smoke")
end
