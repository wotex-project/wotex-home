defmodule Woh.Tool.NativeOverridesSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    request = %{
      "api_version" => 1,
      "operation" => "overrides",
      "credential" => NativeFixture.credential(),
      "target_ids" => ["light:desk"]
    }

    override = %{
      "target_id" => "light:desk",
      "operator_id" => "operator:1",
      "authority_epoch" => 3,
      "basis_revision" => 5,
      "remaining_ms" => 4_500,
      "operation_id" => "override:17"
    }

    responses = [
      {"valid", override},
      {"unowned", %{override | "operation_id" => nil}},
      {"invalid", %{override | "target_id" => "light:other"}}
    ]

    cases =
      [%{mode: "invalid-input", exchanges: []}] ++
        Enum.map(responses, fn {mode, value} ->
          response = %{"api_version" => 1, "outcome" => "ok", "overrides" => [value]}
          %{mode: mode, exchanges: [{request, response}]}
        end)

    NativeFixture.run(project, "LocalOverridesSmoke.swift", cases)
  end
end

defmodule Woh.Tool.NativeOverrideMutationSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    base = %{
      "api_version" => 1,
      "credential" => NativeFixture.credential(),
      "authority_epoch" => 3,
      "operation_id" => "override:17"
    }

    issued = %{
      "operator_id" => "operator:1",
      "authority_epoch" => 3,
      "operation_id" => "override:17",
      "target_id" => "light:desk",
      "basis_revision" => 5,
      "duration_ms" => 900_000,
      "issue_revision" => 19,
      "revoke_revision" => nil,
      "active" => true,
      "remaining_ms" => 899_000
    }

    issue_request =
      Map.merge(base, %{
        "operation" => "override_issue",
        "target_id" => "light:desk",
        "basis_revision" => 5,
        "duration_ms" => 900_000
      })

    responses = [
      {"issue-valid", issue_request, issued},
      {"issue-invalid", issue_request, %{issued | "operation_id" => "override:other"}},
      {"status-valid", Map.put(base, "operation", "override_status"), issued},
      {"revoke-valid", Map.put(base, "operation", "override_revoke"),
       %{issued | "revoke_revision" => 20, "active" => false, "remaining_ms" => 0}}
    ]

    cases =
      [%{mode: "invalid-input", exchanges: []}] ++
        Enum.map(responses, fn {mode, request, receipt} ->
          response = %{"api_version" => 1, "outcome" => "ok", "override_receipt" => receipt}
          %{mode: mode, exchanges: [{request, response}]}
        end)

    NativeFixture.run(project, "LocalOverrideMutationSmoke.swift", cases)
  end
end

defmodule Mix.Tasks.Woh.Native.Overrides.Smoke do
  @moduledoc """
  Exercises scoped Swift override reads against a local fixture peer.

  Run `mix woh.native.overrides.smoke` to check the exact target scope, an
  owned override, an unowned override and rejection of an unrelated target.
  The fixture checks protocol decoding only; no live override is issued.
  """

  @shortdoc "Smoke-test Swift override reads"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeOverridesSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native scoped override read checks passed")
      {:error, reason} -> Mix.raise("native override read smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.overrides.smoke")
end

defmodule Mix.Tasks.Woh.Native.Override.Mutations.Smoke do
  @moduledoc """
  Exercises Swift override issue, status and revoke frames with a fixture peer.

  Run `mix woh.native.override.mutations.smoke` to check the typed issue frame,
  receipt identity, status lookup and revoked result. A mismatched operation ID
  must be rejected. This does not dispatch to a device.
  """

  @shortdoc "Smoke-test Swift override mutations"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeOverrideMutationSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native override issue/status/revoke checks passed")
      {:error, reason} -> Mix.raise("native override mutation smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.override.mutations.smoke")
end
