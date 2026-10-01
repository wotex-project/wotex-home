defmodule Woh.Tool.NativeMaintenanceSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture

  def run(project) do
    base = %{"api_version" => 1, "credential" => NativeFixture.credential()}
    status_request = Map.put(base, "operation", "maintenance_status")

    operation =
      Map.merge(base, %{
        "operation" => "maintenance_operation_status",
        "authority_epoch" => 3,
        "operation_id" => "maintenance:18"
      })

    begin_request =
      Map.merge(operation, %{"operation" => "begin_maintenance", "expected_revision" => 5})

    end_request =
      Map.merge(operation, %{
        "operation" => "end_maintenance",
        "expected_revision" => 10,
        "begin_revision" => 9
      })

    status = %{
      "authority_epoch" => 3,
      "store_revision" => 10,
      "rule_generation" => 2,
      "begin_revision" => 9,
      "state" => "maintenance"
    }

    begin_receipt = %{
      "principal_id" => "maintenance:local",
      "authority_epoch" => 3,
      "operation_id" => "maintenance:18",
      "action" => "begin",
      "begin_revision" => 9,
      "revision" => 9,
      "rule_generation" => 2,
      "affected_requests" => 2,
      "unknown_outcomes" => 1,
      "state" => "maintenance"
    }

    end_receipt = %{
      begin_receipt
      | "action" => "end",
        "revision" => 11,
        "affected_requests" => 0,
        "unknown_outcomes" => 0,
        "state" => "normal"
    }

    data = [
      {"status-maintenance", status_request, "maintenance_status", status},
      {"status-normal", status_request, "maintenance_status",
       %{status | "state" => "normal", "begin_revision" => 0}},
      {"status-invalid-normal", status_request, "maintenance_status",
       %{status | "state" => "normal"}},
      {"status-invalid-begin", status_request, "maintenance_status",
       %{status | "begin_revision" => 0}},
      {"status-invalid-future", status_request, "maintenance_status",
       %{status | "begin_revision" => 11}},
      {"status-invalid-boolean", status_request, "maintenance_status",
       %{status | "rule_generation" => true}},
      {"status-invalid-float", status_request, "maintenance_status",
       %{status | "store_revision" => 10.0}},
      {"status-invalid-extra", status_request, "maintenance_status",
       Map.put(status, "healthy", true)},
      {"begin-valid", begin_request, "maintenance_receipt", begin_receipt},
      {"begin-invalid-revision", begin_request, "maintenance_receipt",
       %{begin_receipt | "revision" => 8, "begin_revision" => 8}},
      {"begin-invalid-count", begin_request, "maintenance_receipt",
       %{begin_receipt | "unknown_outcomes" => 3}},
      {"begin-invalid-epoch", begin_request, "maintenance_receipt",
       %{begin_receipt | "authority_epoch" => 4}},
      {"begin-invalid-id", begin_request, "maintenance_receipt",
       %{begin_receipt | "operation_id" => "other:18"}},
      {"begin-invalid-action", begin_request, "maintenance_receipt", end_receipt},
      {"begin-invalid-boolean", begin_request, "maintenance_receipt",
       %{begin_receipt | "unknown_outcomes" => true}},
      {"end-valid", end_request, "maintenance_receipt", end_receipt},
      {"end-invalid-count", end_request, "maintenance_receipt",
       %{end_receipt | "affected_requests" => 1}},
      {"end-invalid-begin", end_request, "maintenance_receipt",
       %{end_receipt | "begin_revision" => 8}},
      {"end-invalid-revision", end_request, "maintenance_receipt",
       %{end_receipt | "revision" => 12}},
      {"operation-begin", operation, "maintenance_receipt", begin_receipt},
      {"operation-end", operation, "maintenance_receipt", end_receipt},
      {"operation-invalid-id", operation, "maintenance_receipt",
       %{begin_receipt | "operation_id" => "other:18"}},
      {"operation-invalid-state", operation, "maintenance_receipt",
       %{end_receipt | "state" => "maintenance"}},
      {"operation-invalid-principal", operation, "maintenance_receipt",
       %{begin_receipt | "principal_id" => "bad id"}},
      {"operation-invalid-extra", operation, "maintenance_receipt",
       Map.put(begin_receipt, "current", true)}
    ]

    cases =
      [
        %{mode: "invalid-input", exchanges: []},
        %{
          mode: "operation-missing",
          exchanges: [{operation, %{"api_version" => 1, "outcome" => "not_found"}}]
        },
        %{
          mode: "status-invalid-version",
          exchanges: [
            {status_request,
             %{"api_version" => true, "outcome" => "ok", "maintenance_status" => status}}
          ]
        },
        %{
          mode: "begin-rejected",
          exchanges: [
            {begin_request,
             %{"api_version" => 1, "outcome" => "error", "reason" => "resnapshot_required"}}
          ]
        },
        %{
          mode: "begin-unknown",
          exchanges: [
            {begin_request,
             %{"api_version" => 1, "outcome" => "error", "reason" => "outcome_unknown"}}
          ]
        },
        %{
          mode: "begin-invalid-error",
          exchanges: [
            {begin_request,
             %{
               "api_version" => 1,
               "outcome" => "error",
               "reason" => "resnapshot_required",
               "receipt" => begin_receipt
             }}
          ]
        },
        %{
          mode: "begin-retry",
          exchanges: [
            {begin_request, :close},
            {begin_request, ok("maintenance_receipt", begin_receipt)}
          ]
        }
      ] ++
        Enum.map(data, fn {mode, request, key, value} ->
          %{mode: mode, exchanges: [{request, ok(key, value)}]}
        end)

    NativeFixture.run(project, "LocalMaintenanceSmoke.swift", cases)
  end

  defp ok(key, value), do: %{"api_version" => 1, "outcome" => "ok", key => value}
end

defmodule Mix.Tasks.Woh.Native.Maintenance.Smoke do
  @moduledoc "Checks Swift maintenance status, begin/end, immutable receipt recovery and closed fields against an independent peer."
  @shortdoc "Smoke-test native host maintenance control"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeMaintenanceSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native maintenance status/begin/end/uncertain retry checks passed (32 peer cases)"
        )

      {:error, reason} ->
        Mix.raise("native maintenance smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.maintenance.smoke")
end
