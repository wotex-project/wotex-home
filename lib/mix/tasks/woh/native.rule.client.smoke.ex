defmodule Woh.Tool.NativeRuleClientSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture
  alias WotexHome.Rules.OperationInput

  def run(project) do
    base = %{"api_version" => 1, "credential" => NativeFixture.credential()}

    source = %{
      "version" => 1,
      "id" => "rule:one",
      "source_revision" => 2,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => "light:one",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      },
      "authority_class" => "automation",
      "unknown_policy" => "block",
      "ownership_ms" => 1,
      "cooldown_ms" => 0,
      "causal_budget" => 1
    }

    identity = %{"principal_id" => "operator:fixture", "authority_epoch" => 7}

    review =
      Map.merge(identity, %{
        "operation_id" => "rule:review",
        "expected_revision" => 9,
        "revision" => 10,
        "artifact_digest" => hex("a"),
        "decision" => "pending_positive_basis",
        "reason" => "positive_basis_missing",
        "profile" => "home-draft-review-v1",
        "rule_digest" => hex("b"),
        "registry_digest" => hex("c"),
        "checker_receipt_digest" => nil,
        "proposal_basis_digest" => hex("d")
      })

    admission =
      Map.merge(identity, %{
        "operation_id" => "rule:admit",
        "revision" => 10,
        "artifact_digest" => hex("a"),
        "profile" => "home-explicit-light-admission-v1",
        "state" => "admitted"
      })

    activation = %{
      "admission_revision" => 4,
      "previous_generation" => 2,
      "rule_generation" => 3,
      "revision" => 10,
      "store_revision" => 12,
      "affected_requests" => 2,
      "unknown_outcomes" => 1,
      "state" => "active"
    }

    invocation =
      Map.merge(identity, %{
        "operation_id" => "rule:invoke",
        "disposition" => "held",
        "reason" => nil,
        "revision" => 10
      })

    basis = %{
      "profile" => "explicit-boolean-light-v3",
      "scope" => "proposal_generation_only",
      "target_id" => "light:one",
      "rule_digest" => hex("b"),
      "registry_digest" => hex("c"),
      "runtime_digest" => hex("d"),
      "compiler_profile" => "home-rule-ir-v1",
      "source_digest" => hex("e"),
      "ir_digest" => hex("f"),
      "obligations" =>
        ~w(closed_rule closed_source_bound_ir compiler_correspondence ordinary_light_power single_explicit_trigger literal_predicate one_writer no_feedback one_effect_per_root runtime_correspondence pure_gate_precedence blocked_root_preservation)
    }

    preview = %{
      "decision" => "pending_positive_basis",
      "reason" => "positive_basis_missing",
      "profile" => "home-draft-review-v1",
      "rule_digest" => hex("b"),
      "registry_digest" => hex("c"),
      "watermark" => 9,
      "proposal_basis" => basis
    }

    preview_request = Map.merge(base, %{"operation" => "review_rules", "rules" => [source]})

    previews = [
      {"preview-valid", preview},
      {"preview-no-basis", %{preview | "proposal_basis" => nil}},
      {"preview-rejected", %{preview | "decision" => "rejected", "proposal_basis" => nil}},
      {"preview-invalid-watermark", %{preview | "watermark" => true}},
      {"preview-invalid-basis",
       %{preview | "proposal_basis" => %{basis | "scope" => "execution"}}},
      {"preview-invalid-target",
       %{preview | "proposal_basis" => %{basis | "target_id" => "light:other"}}}
    ]

    cases =
      Enum.map(previews, fn {mode, result} ->
        %{mode: mode, exchanges: [{preview_request, ok("review", result)}]}
      end)

    cases =
      cases ++
        Enum.flat_map(
          [
            {"review", "record_rule_review", "rule_review_receipt", review},
            {"admit", "admit_rule", "rule_receipt", admission},
            {"activate", "activate_rule", "rule_receipt", activation},
            {"invoke", "invoke_rule", "receipt", invocation}
          ],
          fn {kind, operation, key, receipt} ->
            original =
              ["wotex-home.explicit-rule-operation.v1", kind, 7, "rule:" <> kind] ++
                case kind do
                  k when k in ["review", "admit"] -> [9, "rule:one", 2, "light:one", true]
                  "activate" -> [9, 4]
                  "invoke" -> [3, "rule:one"]
                end

            {:ok, ^kind, input} = OperationInput.from_record(original)
            {:ok, digest} = OperationInput.digest(kind, input)

            if kind == "admit" and
                 digest != "fc52e2c35a08d3c9dedd9fd58c22135913bd528be565bc0163ea1ae638f8a13a",
               do: raise("independent admit input differs")

            fields =
              case kind do
                k when k in ["review", "admit"] ->
                  %{
                    "authority_epoch" => 7,
                    "operation_id" => "rule:" <> kind,
                    "expected_revision" => 9,
                    "rules" => [source]
                  }

                "activate" ->
                  %{
                    "authority_epoch" => 7,
                    "operation_id" => "rule:activate",
                    "expected_revision" => 9,
                    "admission_revision" => 4
                  }

                "invoke" ->
                  %{
                    "authority_epoch" => 7,
                    "operation_id" => "rule:invoke",
                    "rule_generation" => 3,
                    "rule_id" => "rule:one"
                  }
              end

            mutate = Map.merge(base, Map.put(fields, "operation", operation))

            lookup =
              Map.merge(base, %{"operation" => "rule_original_status", "original" => original})

            status =
              case kind do
                "admit" -> Map.put(receipt, "kind", "admission")
                "activate" -> Map.put(receipt, "kind", "activation")
                _ -> receipt
              end

            wrapper = %{"kind" => kind, "input_digest" => digest, "result" => status}

            defects =
              [
                {"revision", Map.put(receipt, "revision", true)},
                {"extra", Map.put(receipt, "execute", true)}
              ] ++
                if kind == "activate",
                  do: [
                    {"counts", %{receipt | "store_revision" => 13}},
                    {"admission", %{receipt | "admission_revision" => 0}}
                  ],
                  else: [
                    {"principal", Map.put(receipt, "principal_id", "operator:other")},
                    {"operation", Map.put(receipt, "operation_id", "rule:other")}
                  ]

            [
              %{mode: kind <> "-valid", exchanges: [{mutate, ok(key, receipt)}]},
              %{
                mode: kind <> "-lookup-valid",
                exchanges: [{lookup, ok("rule_original", wrapper)}]
              },
              %{
                mode: kind <> "-lookup-missing",
                exchanges: [{lookup, %{"api_version" => 1, "outcome" => "not_found"}}]
              },
              %{
                mode: kind <> "-lookup-invalid-digest",
                exchanges: [
                  {lookup, ok("rule_original", %{wrapper | "input_digest" => hex("0")})}
                ]
              },
              %{
                mode: kind <> "-lookup-invalid-kind",
                exchanges: [{lookup, ok("rule_original", %{wrapper | "kind" => "other"})}]
              },
              %{
                mode: kind <> "-refused",
                exchanges: [
                  {mutate,
                   %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}}
                ]
              }
            ] ++
              Enum.map(defects, fn {name, invalid} ->
                %{mode: kind <> "-invalid-" <> name, exchanges: [{mutate, ok(key, invalid)}]}
              end)
          end
        )

    NativeFixture.run(
      project,
      "NativeRuleClientSmoke.swift",
      cases,
      ~w(NativeRuleOperationWire NativeRuleClient)
    )
  end

  defp hex(value), do: String.duplicate(value, 64)
  defp ok(key, value), do: %{"api_version" => 1, "outcome" => "ok", key => value}
end

defmodule Mix.Tasks.Woh.Native.Rule.Client.Smoke do
  @moduledoc "Independent native explicit-rule SDK framing and original result correspondence."
  @shortdoc "Check native explicit rule SDK"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeRuleClientSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native explicit rule SDK 46 independent route and original-result cases passed"
        )

      {:error, reason} ->
        Mix.raise("native explicit rule SDK smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.rule.client.smoke")
end
