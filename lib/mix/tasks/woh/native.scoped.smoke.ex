defmodule Woh.Tool.NativeReceiptSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    base_request = %{
      "api_version" => 1,
      "credential" => NativeFixture.credential(),
      "authority_epoch" => 3,
      "operation_id" => "op:17"
    }

    receipt = %{
      "principal_id" => "operator:1",
      "authority_epoch" => 3,
      "operation_id" => "op:17",
      "disposition" => "outcome_unknown",
      "reason" => "crash_after_handoff",
      "revision" => 19
    }

    cancelled = %{
      receipt
      | "disposition" => "rejected",
        "reason" => "cancelled_before_claim",
        "revision" => 20
    }

    responses = [
      {"valid", "status", %{"api_version" => 1, "outcome" => "ok", "receipt" => receipt}},
      {"not-found", "status", %{"api_version" => 1, "outcome" => "not_found"}},
      {"invalid", "status",
       %{
         "api_version" => 1,
         "outcome" => "ok",
         "receipt" => %{receipt | "operation_id" => "op:other"}
       }},
      {"cancel-valid", "cancel",
       %{"api_version" => 1, "outcome" => "ok", "receipt" => cancelled}},
      {"cancel-not-found", "cancel", %{"api_version" => 1, "outcome" => "not_found"}},
      {"cancel-invalid", "cancel", %{"api_version" => 1, "outcome" => "ok", "receipt" => receipt}}
    ]

    cases = [
      %{mode: "invalid-input", exchanges: []},
      %{mode: "cancel-invalid-input", exchanges: []}
      | Enum.map(responses, fn {mode, operation, response} ->
          %{mode: mode, exchanges: [{Map.put(base_request, "operation", operation), response}]}
        end)
    ]

    NativeFixture.run(project, "LocalReceiptSmoke.swift", cases)
  end
end

defmodule Woh.Tool.NativeEnrollmentSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    request = %{
      "api_version" => 1,
      "operation" => "enrollment_status",
      "credential" => NativeFixture.credential(),
      "review_ref" => "review:1"
    }

    review = %{
      "review_ref" => "review:1",
      "thing_id" => "light:desk",
      "review_revision" => 3,
      "binding_revision" => 3,
      "digest_version" => 2,
      "state" => "current"
    }

    responses = [
      {"current", %{"api_version" => 1, "outcome" => "ok", "enrollment_review" => review}},
      {"superseded",
       %{
         "api_version" => 1,
         "outcome" => "ok",
         "enrollment_review" => %{review | "state" => "superseded", "binding_revision" => 5}
       }},
      {"not-found", %{"api_version" => 1, "outcome" => "not_found"}},
      {"invalid-ref",
       %{
         "api_version" => 1,
         "outcome" => "ok",
         "enrollment_review" => %{review | "review_ref" => "review:other"}
       }},
      {"invalid-revision",
       %{
         "api_version" => 1,
         "outcome" => "ok",
         "enrollment_review" => %{review | "binding_revision" => 2}
       }},
      {"invalid-state",
       %{
         "api_version" => 1,
         "outcome" => "ok",
         "enrollment_review" => %{review | "state" => "qualified"}
       }}
    ]

    cases =
      [%{mode: "invalid-input", exchanges: []}] ++
        Enum.map(responses, fn {mode, response} ->
          %{mode: mode, exchanges: [{request, response}]}
        end)

    NativeFixture.run(project, "LocalEnrollmentSmoke.swift", cases)
  end
end

defmodule Woh.Tool.NativePowerSubmitSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    request = %{
      "api_version" => 1,
      "operation" => "submit",
      "credential" => NativeFixture.credential(),
      "mutation" => %{
        "api_version" => 1,
        "operation_id" => "op:17",
        "authority_epoch" => 3,
        "expected_revision" => 5,
        "target_id" => "light:desk",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      }
    }

    receipt = %{
      "principal_id" => "operator:1",
      "authority_epoch" => 3,
      "operation_id" => "op:17",
      "disposition" => "held",
      "reason" => nil,
      "revision" => 19
    }

    cases = [
      %{mode: "invalid-input", exchanges: []},
      %{
        mode: "valid",
        exchanges: [{request, %{"api_version" => 1, "outcome" => "ok", "receipt" => receipt}}]
      },
      %{
        mode: "invalid",
        exchanges: [
          {request,
           %{
             "api_version" => 1,
             "outcome" => "ok",
             "receipt" => %{receipt | "operation_id" => "op:other"}
           }}
        ]
      }
    ]

    NativeFixture.run(project, "LocalPowerSubmitSmoke.swift", cases)
  end
end

defmodule Mix.Tasks.Woh.Native.Receipt.Smoke do
  @moduledoc """
  Exercises Swift receipt lookup and cancellation against a fixture peer.

  Run `mix woh.native.receipt.smoke` to check scoped operation IDs, missing
  receipts, uncertain outcomes, cancelled receipts and malformed responses.
  The socket peer checks each request exactly and keeps its test credential
  local to this process.
  """

  @shortdoc "Smoke-test Swift receipt and cancel routes"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeReceiptSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native scoped receipt lookup, cancellation and uncertainty decoding passed"
        )

      {:error, reason} ->
        Mix.raise("native receipt smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.receipt.smoke")
end

defmodule Mix.Tasks.Woh.Native.Enrollment.Smoke do
  @moduledoc """
  Exercises Swift enrollment review lookup against a fixture peer.

  Run `mix woh.native.enrollment.smoke` to check current and superseded review
  states, a missing review and rejection of mismatched references, revisions
  and state values. Each request must match the scoped fixture exactly.
  """

  @shortdoc "Smoke-test Swift enrollment review lookup"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeEnrollmentSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info("native scoped enrollment status and malformed-response checks passed")

      {:error, reason} ->
        Mix.raise("native enrollment smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.enrollment.smoke")
end

defmodule Mix.Tasks.Woh.Native.Power.Submit.Smoke do
  @moduledoc """
  Exercises typed Swift power submission against a fixture peer.

  Run `mix woh.native.power.submit.smoke` to check the exact Boolean mutation
  frame, a held receipt and rejection of a response with another operation ID.
  This is client contract evidence, not device dispatch.
  """

  @shortdoc "Smoke-test Swift typed power submission"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativePowerSubmitSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native typed power submission and receipt checks passed")
      {:error, reason} -> Mix.raise("native power submission smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.power.submit.smoke")
end
