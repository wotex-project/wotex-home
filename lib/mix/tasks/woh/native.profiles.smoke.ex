defmodule Woh.Tool.NativeProfilesSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture
  alias WotexHome.Profiles.{Artifact, Operation}

  def run(project) do
    bytes = File.read!(Path.join(project, "test/support/profiles/lifx-power.json"))
    {:ok, artifact} = Artifact.parse(bytes)
    raw = artifact.digest
    registry = hd(artifact.data["dependencies"])["sha256"]
    base = %{"api_version" => 1, "credential" => NativeFixture.credential()}
    request = fn operation, fields -> Map.merge(Map.put(base, "operation", operation), fields) end

    input = %{
      "action" => "approve",
      "authority_epoch" => 3,
      "operation_id" => "profile:native",
      "expected_revision" => 5,
      "artifact_digest" => raw,
      "expected_trust_revision" => 0
    }

    select =
      Map.merge(input, %{
        "action" => "select",
        "expected_trust_revision" => 4,
        "target_id" => "light:fixture",
        "expected_resource_revision" => 0,
        "expected_binding_revision" => 0,
        "expected_selection_generation" => 0,
        "expected_policy_generation" => 1,
        "expected_rule_generation" => 1,
        "session_ref" => "capture:native",
        "candidate_ref" => "candidate:native",
        "review_ref" => "review:native"
      })

    receipt = fn operation ->
      {:ok, canonical} = Operation.encode(operation)

      %{
        "authority_epoch" => 3,
        "operation_id" => "profile:native",
        "action" => operation["action"],
        "input_digest" => Artifact.digest(canonical),
        "expected_revision" => 5,
        "artifact_digest" => raw,
        "final_revision" => if(operation["action"] == "approve", do: 6, else: 8),
        "changed_targets" => if(operation["action"] == "select", do: 1, else: 0),
        "invalidated_requests" => 0,
        "unknown_outcomes" => 0,
        "previous_trust_revision" => operation["expected_trust_revision"],
        "trust_generation" => 1,
        "policy_generation" => 1
      }
    end

    imported = %{
      "artifact_digest" => raw,
      "projection_digest" => artifact.projection_digest,
      "registry_digest" => registry,
      "id" => "test.portable-light",
      "version" => "1.0.0",
      "profile_ref" => "test.portable-light:1.0.0",
      "binding" => "lifx-direct-power-v1",
      "authority_changed" => false
    }

    item =
      imported
      |> Map.drop(~w(profile_ref authority_changed))
      |> Map.merge(%{
        "trust_revision" => 4,
        "trust_generation" => 1,
        "trust_author" => "operator:fixture",
        "state" => "approved",
        "byte_availability" => "available",
        "qualification_status" => "pending_physical_evidence"
      })

    catalogue = %{
      "store_revision" => 5,
      "authority_epoch" => 3,
      "policy_generation" => 1,
      "items" => [item]
    }

    target = %{
      "target_id" => "light:fixture",
      "store_revision" => 5,
      "authority_epoch" => 3,
      "policy_generation" => 1,
      "rule_generation" => 1,
      "status" => "absent",
      "profile_ref" => nil,
      "declaration" => nil,
      "resource_revision" => 0,
      "binding_revision" => 0,
      "identity" => nil,
      "identity_status" => "absent",
      "selection_revision" => 0,
      "selection_generation" => 0,
      "selection_state" => "absent",
      "artifact_digest" => nil,
      "current_use" => "target_unavailable",
      "qualification_head" => nil
    }

    captured = %{
      "stable_id" => "lifx:d073d5000001",
      "manufacturer" => "lifx.vendor.1",
      "model" => "lifx.product.22",
      "firmware" => "1.22"
    }

    basis = %{
      "principal_id" => "operator:fixture",
      "authority_epoch" => 3,
      "store_revision" => 5,
      "profile_policy_generation" => 1,
      "rule_generation" => 1,
      "maintenance_revision" => 3,
      "target_id" => "light:fixture",
      "resource_revision" => 0,
      "binding_revision" => 0,
      "selection_revision" => 0,
      "selection_generation" => 0,
      "trust_revision" => 4,
      "trust_generation" => 1,
      "artifact_digest" => raw,
      "projection_digest" => artifact.projection_digest,
      "registry_digest" => registry,
      "profile_ref" => "test.portable-light:1.0.0"
    }

    summary = %{
      "status" => "pending_authenticated_selection",
      "identity_method" => "legacy_tofu",
      "qualification_status" => "pending_physical_evidence",
      "current_profile_ref" => nil,
      "proposed_profile_ref" => "test.portable-light:1.0.0",
      "removed_capabilities" => [],
      "capabilities" => [
        %{
          "key" => "power",
          "previous_operations" => [],
          "proposed_operations" => ["read", "write"],
          "previous_freshness_ms" => nil,
          "proposed_freshness_ms" => 5_000,
          "value_kind" => "boolean",
          "unit" => "none",
          "risk_class" => "ordinary"
        }
      ],
      "new_control_grants" => false,
      "invalidation" => [
        "qualification",
        "current_reports",
        "source_grants",
        "unsent_requests",
        "rule_policy"
      ],
      "handed_off_outcomes" => "preserve_uncertainty"
    }

    review = %{
      "review_token" => "review-token:native",
      "review_digest" => String.duplicate("b", 64),
      "state" => "pending",
      "remaining_ms" => 10_000,
      "summary" => summary,
      "identity" => %{
        "prior" => Map.new(captured, fn {key, _} -> {key, nil} end),
        "captured" => captured,
        "method" => "legacy_tofu"
      },
      "basis" => basis
    }

    collection = %{
      "removed_objects" => 1,
      "removed_bytes" => 512,
      "object_count" => 1,
      "total_bytes" => 512,
      "digests" => [raw]
    }

    import_request =
      request.("profile_import", %{"artifact_base64" => Base.url_encode64(bytes, padding: false)})

    profiles_request = request.("profiles", %{})
    target_request = request.("profile_target", %{"thing_id" => "light:fixture"})
    prepare_request = request.("profile_prepare", %{"selection" => select})
    change_request = request.("profile_change", %{"change" => input})
    select_request = request.("profile_change", %{"change" => select})

    status_request =
      request.("profile_operation_status", %{
        "authority_epoch" => 3,
        "operation_id" => "profile:native"
      })

    review_request = request.("profile_review_status", %{"review_token" => "review-token:native"})
    cancel_request = request.("profile_review_cancel", %{"review_token" => "review-token:native"})
    collect_request = request.("profiles_collect", %{})

    declaration = %{
      "id" => "light:fixture",
      "role" => "Light",
      "profile_ref" => imported["profile_ref"],
      "capabilities" => [
        %{
          "thing_id" => "light:fixture",
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => ["read", "write"],
          "risk_class" => "ordinary",
          "profile_ref" => imported["profile_ref"],
          "evidence_ref" => "evidence:native",
          "freshness_ms" => 5_000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    }

    active =
      Map.merge(target, %{
        "store_revision" => 8,
        "status" => "active",
        "profile_ref" => imported["profile_ref"],
        "declaration" => declaration,
        "resource_revision" => 1,
        "binding_revision" => 6,
        "identity" => captured,
        "identity_status" => "reviewed",
        "selection_revision" => 7,
        "selection_generation" => 1,
        "selection_state" => "selected",
        "artifact_digest" => raw,
        "current_use" => "usable"
      })

    head = %{
      "profile_ref" => "lifx.product-22:1.0.0",
      "resource_revision" => 0,
      "identity_digest" => String.duplicate("a", 64),
      "basis_digest" => String.duplicate("b", 64),
      "registry_digest" => registry,
      "runtime_digest" => String.duplicate("c", 64),
      "evidence_ref" => "evidence:prior",
      "status" => "revoked",
      "revision" => 4
    }

    replacement_input = Map.put(select, "expected_binding_revision", 2)

    replacement =
      review
      |> put_in(["identity", "prior"], captured)
      |> put_in(["basis", "binding_revision"], 2)
      |> put_in(["summary", "current_profile_ref"], "lifx.product-22:1.0.0")
      |> put_in(["summary", "capabilities", Access.at(0), "previous_operations"], [
        "read",
        "write"
      ])
      |> put_in(["summary", "capabilities", Access.at(0), "previous_freshness_ms"], 5_000)

    firmware =
      replacement
      |> put_in(["identity", "captured", "firmware"], "1.23")
      |> put_in(["basis", "artifact_digest"], String.duplicate("c", 64))
      |> put_in(["basis", "projection_digest"], String.duplicate("d", 64))
      |> put_in(["basis", "profile_ref"], "test.new-firmware:1.0.0")
      |> put_in(["summary", "proposed_profile_ref"], "test.new-firmware:1.0.0")

    candidate = %{
      "candidate_ref" => "candidate:native",
      "interface_id" => "en0",
      "source_endpoint" => "192.0.2.10:56700",
      "claimed_stable_id" => "lifx:d073d5000001",
      "trust_class" => "untrusted_network"
    }

    discovery = %{"session_ref" => "capture:native", "candidates" => [candidate]}

    packaged = %{
      "profile_ref" => "lifx.product-22:1.0.0",
      "transport" => "udp",
      "manufacturer" => "lifx.vendor.1",
      "model" => "lifx.product.22",
      "firmware_versions" => ["1.22"],
      "qualification_ref" => "pending:compiled",
      "qualification_status" => "pending_physical_evidence",
      "capability_keys" => ["power"]
    }

    interview = %{
      "candidate_ref" => "candidate:native",
      "transport" => "udp",
      "manufacturer_reported" => "lifx.vendor.1",
      "model_reported" => "lifx.product.22",
      "firmware_reported" => "1.22",
      "stable_id_claim" => "lifx:d073d5000001",
      "packaged_profiles" => [packaged]
    }

    discover_request = request.("lifx_discover", %{})

    interview_request =
      request.("lifx_interview", %{
        "session_ref" => "capture:native",
        "candidate_ref" => "candidate:native"
      })

    tuples = [
      {"discover-valid", discover_request, "capture", discovery},
      {"discover-empty-valid", discover_request, "capture", %{discovery | "candidates" => []}},
      {"discover-invalid-duplicate", discover_request, "capture",
       %{discovery | "candidates" => [candidate, candidate]}},
      {"discover-invalid-trust", discover_request, "capture",
       put_in(discovery, ["candidates", Access.at(0), "trust_class"], "authenticated")},
      {"discover-invalid-endpoint", discover_request, "capture",
       put_in(discovery, ["candidates", Access.at(0), "source_endpoint"], "https://example.org")},
      {"interview-valid", interview_request, "interview", interview},
      {"interview-unmapped-valid", interview_request, "interview",
       %{interview | "packaged_profiles" => []}},
      {"interview-invalid-candidate", interview_request, "interview",
       %{interview | "candidate_ref" => "other:candidate"}},
      {"interview-invalid-qualification", interview_request, "interview",
       put_in(interview, ["packaged_profiles", Access.at(0), "qualification_status"], "qualified")},
      {"interview-invalid-duplicate-profile", interview_request, "interview",
       %{interview | "packaged_profiles" => [packaged, packaged]}},
      {"interview-invalid-model", interview_request, "interview",
       put_in(interview, ["packaged_profiles", Access.at(0), "model"], "lifx.product.27")},
      {"import-valid", import_request, "profile_artifact", imported},
      {"import-invalid-digest", import_request, "profile_artifact",
       %{imported | "artifact_digest" => String.duplicate("a", 64)}},
      {"import-invalid-grant", import_request, "profile_artifact",
       %{imported | "authority_changed" => true}},
      {"import-invalid-boolean", import_request, "profile_artifact",
       %{imported | "authority_changed" => 0}},
      {"import-invalid-label", import_request, "profile_artifact",
       %{imported | "profile_ref" => "other:1"}},
      {"import-invalid-extra", import_request, "profile_artifact",
       Map.put(imported, "authority", true)},
      {"catalogue-valid", profiles_request, "profile_catalogue", catalogue},
      {"catalogue-invalid-duplicate", profiles_request, "profile_catalogue",
       %{catalogue | "items" => [item, item]}},
      {"catalogue-invalid-float", profiles_request, "profile_catalogue",
       %{catalogue | "store_revision" => 5.0}},
      {"catalogue-invalid-trust", profiles_request, "profile_catalogue",
       %{catalogue | "items" => [%{item | "trust_revision" => 6}]}},
      {"catalogue-invalid-qualification", profiles_request, "profile_catalogue",
       %{catalogue | "items" => [%{item | "qualification_status" => "qualified"}]}},
      {"target-valid", target_request, "profile_target", target},
      {"target-active-valid", target_request, "profile_target", active},
      {"target-invalid-null-declaration", target_request, "profile_target",
       put_in(%{active | "profile_ref" => nil}, ["declaration", "profile_ref"], nil)},
      {"target-missing-bytes-valid", target_request, "profile_target",
       %{active | "current_use" => "profile_artifact_unavailable"}},
      {"target-retained-head-valid", target_request, "profile_target",
       %{active | "qualification_head" => head}},
      {"target-revoked-valid", target_request, "profile_target",
       %{active | "selection_state" => "revoked", "current_use" => "profile_selection_revoked"}},
      {"target-invalid-revoked-fallback", target_request, "profile_target",
       %{active | "selection_state" => "revoked"}},
      {"target-invalid-declaration", target_request, "profile_target",
       put_in(active, ["declaration", "capabilities", Access.at(0), "unit"], "watts")},
      {"target-invalid-head-float", target_request, "profile_target",
       put_in(%{active | "qualification_head" => head}, ["qualification_head", "revision"], 4.0)},
      {"target-invalid-absent", target_request, "profile_target",
       %{target | "binding_revision" => nil}},
      {"target-invalid-id", target_request, "profile_target",
       %{target | "target_id" => "other:target"}},
      {"target-invalid-fallback", target_request, "profile_target",
       %{target | "current_use" => "usable"}},
      {"prepare-valid", prepare_request, "profile_review", review},
      {"prepare-replacement-valid",
       request.("profile_prepare", %{"selection" => replacement_input}), "profile_review",
       replacement},
      {"review-status-firmware-valid", review_request, "profile_review", firmware},
      {"prepare-committed", prepare_request, "profile_receipt", receipt.(select)},
      {"prepare-invalid-basis", prepare_request, "profile_review",
       put_in(review, ["basis", "store_revision"], 6)},
      {"prepare-invalid-target", prepare_request, "profile_review",
       put_in(review, ["basis", "target_id"], "other:target")},
      {"prepare-invalid-raw", prepare_request, "profile_review",
       put_in(review, ["basis", "artifact_digest"], String.duplicate("a", 64))},
      {"prepare-invalid-identity", prepare_request, "profile_review",
       put_in(review, ["identity", "captured", "stable_id"], "lifx:bad")},
      {"prepare-invalid-initial", prepare_request, "profile_review",
       put_in(review, ["basis", "binding_revision"], 1)},
      {"prepare-invalid-grant", prepare_request, "profile_review",
       put_in(review, ["summary", "new_control_grants"], true)},
      {"prepare-invalid-evidence", prepare_request, "profile_review",
       put_in(review, ["summary", "qualification_status"], "qualified")},
      {"prepare-invalid-expiry", prepare_request, "profile_review",
       %{review | "remaining_ms" => 60_001}},
      {"review-status-valid", review_request, "profile_review", review},
      {"review-status-invalid-token", review_request, "profile_review",
       %{review | "review_token" => "other:token"}},
      {"review-cancel-valid", cancel_request, "profile_review_cancelled", true},
      {"review-cancel-invalid-boolean", cancel_request, "profile_review_cancelled", 1},
      {"change-valid", change_request, "profile_receipt", receipt.(input)},
      {"select-valid", select_request, "profile_receipt", receipt.(select)},
      {"change-invalid-input", change_request, "profile_receipt",
       %{receipt.(input) | "input_digest" => String.duplicate("a", 64)}},
      {"change-invalid-action", change_request, "profile_receipt",
       %{receipt.(input) | "action" => "revoke"}},
      {"change-invalid-count", change_request, "profile_receipt",
       %{receipt.(input) | "unknown_outcomes" => 1}},
      {"change-invalid-epoch", change_request, "profile_receipt",
       %{receipt.(input) | "authority_epoch" => 4}},
      {"change-invalid-id", change_request, "profile_receipt",
       %{receipt.(input) | "operation_id" => "other:operation"}},
      {"change-invalid-boolean", change_request, "profile_receipt",
       %{receipt.(input) | "final_revision" => true}},
      {"change-invalid-extra", change_request, "profile_receipt",
       Map.put(receipt.(input), "current", true)},
      {"operation-valid", status_request, "profile_receipt", receipt.(input)},
      {"operation-invalid-digest", status_request, "profile_receipt",
       %{receipt.(input) | "input_digest" => String.duplicate("a", 64)}},
      {"collect-valid", collect_request, "profile_collection", collection},
      {"collect-invalid-quota", collect_request, "profile_collection",
       %{collection | "object_count" => 129}},
      {"collect-invalid-duplicate", collect_request, "profile_collection",
       %{collection | "digests" => [raw, raw]}}
    ]

    cases =
      Enum.map(tuples, fn {mode, expected, key, value} ->
        %{mode: mode, exchanges: [{expected, ok(key, value)}]}
      end) ++
        [
          %{mode: "invalid-input", exchanges: []},
          %{mode: "operation-missing", exchanges: [{status_request, missing()}]},
          %{mode: "review-status-missing", exchanges: [{review_request, missing()}]},
          %{mode: "review-cancel-missing", exchanges: [{cancel_request, missing()}]},
          %{
            mode: "change-rejected",
            exchanges: [
              {change_request,
               %{"api_version" => 1, "outcome" => "error", "reason" => "resnapshot_required"}}
            ]
          },
          %{
            mode: "change-unknown",
            exchanges: [
              {change_request,
               %{"api_version" => 1, "outcome" => "error", "reason" => "outcome_unknown"}}
            ]
          },
          %{
            mode: "change-retry",
            exchanges: [
              {change_request, :close},
              {status_request, missing()},
              {change_request, ok("profile_receipt", receipt.(input))}
            ]
          },
          %{
            mode: "catalogue-invalid-duplicate-name",
            exchanges: [
              {profiles_request,
               {:raw,
                "{\"api_version\":1,\"api_version\":1,\"outcome\":\"ok\",\"profile_catalogue\":" <>
                  JSON.encode!(catalogue) <> "}"}}
            ]
          }
        ]

    with :ok <- NativeFixture.run(project, "LocalProfilesSmoke.swift", cases),
         do: {:ok, length(cases)}
  end

  defp ok(key, value), do: %{"api_version" => 1, "outcome" => "ok", key => value}
  defp missing, do: %{"api_version" => 1, "outcome" => "not_found"}
end

defmodule Mix.Tasks.Woh.Native.Profiles.Smoke do
  @moduledoc "Check native profile framing, exact operation/receipt correspondence and closed status/review fields against an independent peer."
  @shortdoc "Smoke-test native portable profile routes"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeProfilesSmoke.run(File.cwd!()) do
      {:ok, count} ->
        Mix.shell().info(
          "native profile routes and original-operation recovery passed (#{count} peer cases)"
        )

      {:error, reason} ->
        Mix.raise("native profile smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.profiles.smoke")
end
