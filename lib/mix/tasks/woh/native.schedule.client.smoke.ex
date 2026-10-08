defmodule Woh.Tool.NativeScheduleClientSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture

  def run(project) do
    corpus = "test/fixtures/schedules/native_wire_vectors.json" |> File.read!() |> JSON.decode!()
    vectors = Map.new(corpus["vectors"], &{&1["id"], &1})
    base = %{"api_version" => 1, "credential" => NativeFixture.credential()}

    cases =
      Enum.flat_map(~w(review admit activate suspend), fn kind ->
        vector = vectors[if(kind == "admit", do: "interval_true", else: kind)]

        receipt = %{
          "kind" => kind,
          "state" => if(kind == "review", do: "reviewed", else: "admitted"),
          "principal_id" => "operator:one",
          "authority_epoch" => 7,
          "operation_id" => "schedule:" <> kind,
          "input_digest" => vector["digest"],
          "artifact_digest" => hex("a"),
          "revision" => 10
        }

        receipt =
          if kind in ~w(activate suspend), do: lifecycle(kind, vector["digest"]), else: receipt

        mutate =
          Map.merge(base, %{
            "operation" => "schedule_" <> kind,
            "original_document" => vector["document"]
          })

        lookup = %{mutate | "operation" => "schedule_original_status"}

        defects =
          [
            {"principal", Map.put(receipt, "principal_id", "operator:other")},
            {"epoch", Map.put(receipt, "authority_epoch", 8)},
            {"operation", Map.put(receipt, "operation_id", "schedule:other")},
            {"digest", Map.put(receipt, "input_digest", hex("0"))},
            {"kind", Map.put(receipt, "kind", "other")},
            {"state", Map.put(receipt, "state", "active")},
            {"integer", Map.put(receipt, "revision", true)},
            {"extra", Map.put(receipt, "execute", true)}
          ] ++
            if(kind in ~w(activate suspend),
              do: [
                {"counts", %{receipt | "revision" => 14}},
                {"unknown", %{receipt | "unknown_outcomes" => 3}},
                {"generation", %{receipt | "rule_generation" => 4}},
                {"watermark", %{receipt | "initial_watermark" => 1.0}},
                {"admission", %{receipt | "admission_revision" => 4}},
                {"barrier", %{receipt | "barrier_revision" => 11}}
              ],
              else: [
                {"artifact", Map.put(receipt, "artifact_digest", "bad")},
                {"revision", Map.put(receipt, "revision", 11)}
              ]
            )

        [
          %{mode: kind <> "-valid", exchanges: [{mutate, ok("schedule_receipt", receipt)}]},
          %{
            mode: kind <> "-lookup-valid",
            exchanges: [{lookup, ok("schedule_receipt", receipt)}]
          },
          %{
            mode: kind <> "-lookup-missing",
            exchanges: [{lookup, %{"api_version" => 1, "outcome" => "not_found"}}]
          },
          %{
            mode: kind <> "-lost-then-lookup",
            exchanges: [{mutate, :close}, {lookup, ok("schedule_receipt", receipt)}]
          },
          %{
            mode: kind <> "-refused",
            exchanges: [
              {mutate,
               %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}}
            ]
          }
        ] ++
          Enum.map(defects, fn {name, item} ->
            %{
              mode: kind <> "-invalid-" <> name,
              exchanges: [{mutate, ok("schedule_receipt", item)}]
            }
          end)
      end)

    activation = lifecycle("activate", vectors["activate"]["digest"])
    current = %{activation | "state" => "active"}

    withdraw = %{
      current
      | "kind" => "withdraw",
        "state" => "suspended",
        "reason" => "permission_denied",
        "initial_watermark" => -1,
        "operation_id" => "schedule-withdraw:" <> hex("f")
    }

    statuses = [
      {"inactive", %{"state" => "inactive", "activation_revision" => 0, "reason" => nil}},
      {"active", current},
      {"suspended",
       %{current | "state" => "suspended", "reason" => "temporal_clock_unavailable"}},
      {"withdrawn", withdraw},
      {"invalid-principal", %{current | "principal_id" => "operator:other"}},
      {"invalid-state", %{current | "state" => "activated"}},
      {"invalid-reason", %{current | "reason" => "permission_denied"}},
      {"invalid-count", %{current | "unknown_outcomes" => 3}},
      {"invalid-generation", %{current | "rule_generation" => 99, "previous_generation" => 98}},
      {"invalid-withdrawal", %{withdraw | "operation_id" => "schedule:manual"}},
      {"invalid-unsigned", %{withdraw | "initial_watermark" => 18_446_744_073_709_551_615}},
      {"invalid-inactive",
       %{"state" => "inactive", "activation_revision" => true, "reason" => nil}},
      {"invalid-extra", Map.put(current, "clock", true)}
    ]

    cases =
      cases ++
        Enum.map(statuses, fn {mode, item} ->
          %{
            mode: "current-" <> mode,
            exchanges: [
              {Map.put(base, "operation", "schedule_status"), ok("schedule_status", item)}
            ]
          }
        end)

    timezone = %{
      "name" => "Europe/Stockholm",
      "digest" => hex("a"),
      "local_datetime" => "2026-10-25T02:30:00",
      "instant_count" => 1,
      "first_utc_ms" => 1_792_888_200_000,
      "second_utc_ms" => nil,
      "basis_scope" => "calendar_calculation_only"
    }

    zones = [
      {"valid", timezone},
      {"gap", %{timezone | "instant_count" => 0, "first_utc_ms" => nil}},
      {"fold", %{timezone | "instant_count" => 2, "second_utc_ms" => 1_792_891_800_000}},
      {"invalid-name", %{timezone | "name" => "America/New_York"}},
      {"invalid-local", %{timezone | "local_datetime" => "2026-10-25T03:30:00"}},
      {"invalid-scope", %{timezone | "basis_scope" => "trusted_clock"}},
      {"invalid-count", %{timezone | "instant_count" => true}},
      {"invalid-instant", %{timezone | "first_utc_ms" => 1.0}},
      {"invalid-extra-instant", %{timezone | "second_utc_ms" => 1_792_891_800_000}},
      {"invalid-order", %{timezone | "instant_count" => 2, "second_utc_ms" => 1_792_888_200_000}},
      {"invalid-digest", %{timezone | "digest" => "bad"}},
      {"invalid-extra", Map.put(timezone, "qualified", true)}
    ]

    request =
      Map.merge(base, %{
        "operation" => "schedule_timezone",
        "zone_name" => timezone["name"],
        "local_datetime" => timezone["local_datetime"]
      })

    cases =
      cases ++
        Enum.map(zones, fn {mode, item} ->
          %{mode: "timezone-" <> mode, exchanges: [{request, ok("timezone", item)}]}
        end)

    cases = [%{mode: "admit-invalid-input", exchanges: []} | cases]

    case NativeFixture.run(
           project,
           "NativeScheduleClientSmoke.swift",
           cases,
           ~w(NativeRuleOperationWire NativeScheduleWire NativeScheduleClient)
         ) do
      :ok -> {:ok, length(cases)}
      error -> error
    end
  end

  defp lifecycle(kind, digest) do
    %{
      "kind" => kind,
      "state" => if(kind == "activate", do: "activated", else: "suspended"),
      "principal_id" => "operator:one",
      "authority_epoch" => 7,
      "operation_id" => "schedule:" <> kind,
      "input_digest" => digest,
      "admission_revision" => if(kind == "activate", do: 8, else: 0),
      "previous_generation" => 2,
      "rule_generation" => 3,
      "barrier_revision" => 10,
      "revision" => 13,
      "affected_requests" => 2,
      "unknown_outcomes" => 1,
      "reason" => nil,
      "initial_watermark" => if(kind == "activate", do: 100_000, else: -1)
    }
  end

  defp hex(value), do: String.duplicate(value, 64)
  defp ok(key, value), do: %{"api_version" => 1, "outcome" => "ok", key => value}
end

defmodule Mix.Tasks.Woh.Native.Schedule.Client.Smoke do
  @moduledoc "Native schedule SDK closed framing, current readiness and original receipt recovery."
  @shortdoc "Check native schedule SDK"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeScheduleClientSmoke.run(File.cwd!()) do
      {:ok, count} ->
        Mix.shell().info(
          "native schedule SDK #{count} independent route and original-result cases passed"
        )

      {:error, reason} ->
        Mix.raise("native schedule SDK smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.schedule.client.smoke")
end
