defmodule Woh.Tool.NativeRuleSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture

  def run(project) do
    base = %{"api_version" => 1, "credential" => NativeFixture.credential()}
    status_request = Map.put(base, "operation", "rule_status")

    status = %{
      "authority_epoch" => 3,
      "rule_generation" => 2,
      "admission_revision" => 4,
      "state" => "active",
      "reason" => nil
    }

    activation = %{
      "admission_revision" => 0,
      "previous_generation" => 1,
      "rule_generation" => 2,
      "revision" => 6,
      "store_revision" => 8,
      "affected_requests" => 2,
      "unknown_outcomes" => 1,
      "state" => "inactive"
    }

    operation_request =
      Map.merge(base, %{
        "operation" => "rule_operation_status",
        "authority_epoch" => 3,
        "operation_id" => "rule:17"
      })

    suspend =
      Map.merge(base, %{
        "operation" => "activate_rule",
        "authority_epoch" => 3,
        "operation_id" => "rule:17",
        "expected_revision" => 5,
        "admission_revision" => 0
      })

    admission = %{
      "kind" => "admission",
      "principal_id" => "operator:1",
      "authority_epoch" => 3,
      "operation_id" => "rule:17",
      "revision" => 4,
      "artifact_digest" => String.duplicate("a", 64),
      "profile" => "home-explicit-light-admission-v1",
      "state" => "admitted"
    }

    data = [
      {"status-active", status_request, "rule_status", status},
      {"status-inactive", status_request, "rule_status",
       %{status | "state" => "inactive", "admission_revision" => 0}},
      {"status-suspended", status_request, "rule_status",
       %{status | "state" => "suspended", "reason" => "rule_basis_changed"}},
      {"status-invalid-boolean", status_request, "rule_status",
       %{status | "rule_generation" => true}},
      {"status-invalid-float", status_request, "rule_status",
       %{status | "rule_generation" => 2.5}},
      {"status-invalid-state", status_request, "rule_status",
       %{status | "admission_revision" => 0}},
      {"suspend-valid", suspend, "rule_receipt", activation},
      {"suspend-invalid-count", suspend, "rule_receipt", %{activation | "unknown_outcomes" => 3}},
      {"suspend-invalid-state", suspend, "rule_receipt", %{activation | "state" => "active"}},
      {"operation-activation", operation_request, "rule_receipt",
       Map.put(activation, "kind", "activation")},
      {"operation-admission", operation_request, "rule_receipt", admission},
      {"operation-invalid-id", operation_request, "rule_receipt",
       %{admission | "operation_id" => "other:17"}}
    ]

    cases =
      [
        %{mode: "invalid-input", exchanges: []},
        %{
          mode: "operation-missing",
          exchanges: [{operation_request, %{"api_version" => 1, "outcome" => "not_found"}}]
        }
      ] ++
        Enum.map(data, fn {mode, request, key, value} ->
          %{
            mode: mode,
            exchanges: [{request, %{"api_version" => 1, "outcome" => "ok", key => value}}]
          }
        end)

    NativeFixture.run(project, "LocalRulePolicySmoke.swift", cases)
  end
end

defmodule Mix.Tasks.Woh.Native.Rule.Smoke do
  @moduledoc "Checks the native rule status/suspension and immutable operation lookup against an independent peer."
  @shortdoc "Smoke-test Swift rule policy control"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeRuleSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native rule policy status/suspension/uncertainty checks passed")
      {:error, reason} -> Mix.raise("native rule policy smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.rule.smoke")
end
