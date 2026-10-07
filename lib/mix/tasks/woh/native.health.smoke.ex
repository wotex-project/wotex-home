defmodule Woh.Tool.NativeHealthSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    request = %{
      "api_version" => 1,
      "operation" => "health",
      "credential" => NativeFixture.credential()
    }

    valid = %{
      "api_version" => 1,
      "outcome" => "ok",
      "health" => %{
        "store_revision" => 12,
        "authority_epoch" => 1,
        "held_requests" => 2,
        "rule_generation" => 4,
        "queued_requests" => 1,
        "claimed_requests" => 1,
        "unknown_outcomes" => 1,
        "active_things" => 3,
        "active_principals" => 1,
        "writable" => true,
        "dispatch_enabled" => false
      }
    }

    cases = [
      %{mode: "valid", exchanges: [{request, valid}]},
      %{
        mode: "invalid",
        exchanges: [{request, %{"api_version" => 2, "outcome" => "ok", "health" => %{}}}]
      },
      %{
        mode: "slow",
        exchanges: [{request, {:drip, <<20::unsigned-big-32, "partial-response">>}}]
      }
    ]

    NativeFixture.run(project, "LocalHealthSmoke.swift", cases ++ identity_cases())
  end

  defp identity_cases do
    request = %{
      "api_version" => 1,
      "operation" => "controller_identity",
      "credential" => NativeFixture.credential()
    }

    identity = %{
      "deployment_id" => String.duplicate("a", 64),
      "owner_id" => String.duplicate("b", 64),
      "authority_epoch" => 2,
      "store_revision" => 19,
      "principal_id" => "fixture:reader"
    }

    envelope = %{"api_version" => 1, "outcome" => "ok", "controller_identity" => identity}

    invalid =
      for {key, value} <- [
            {"deployment_id", String.duplicate("A", 64)},
            {"owner_id", String.duplicate("b", 63)},
            {"owner_id", String.duplicate("g", 64)},
            {"authority_epoch", 0},
            {"authority_epoch", true},
            {"authority_epoch", 2.0},
            {"authority_epoch", 9_223_372_036_854_775_808},
            {"store_revision", -1},
            {"store_revision", false},
            {"store_revision", 19.0},
            {"principal_id", "invalid principal"},
            {"principal_id", String.duplicate("a", 129)},
            {"credential", NativeFixture.credential()}
          ] do
        %{
          mode: "identity-invalid",
          exchanges: [
            {request, %{envelope | "controller_identity" => Map.put(identity, key, value)}}
          ]
        }
      end

    invalid ++
      [
        %{mode: "identity-valid", exchanges: [{request, envelope}]},
        %{
          mode: "identity-invalid",
          exchanges: [
            {request, %{envelope | "controller_identity" => Map.delete(identity, "principal_id")}}
          ]
        },
        %{
          mode: "identity-invalid",
          exchanges: [{request, Map.put(envelope, "role", "operator")}]
        },
        %{
          mode: "identity-refused",
          exchanges: [
            {request, %{"api_version" => 1, "outcome" => "error", "reason" => "unauthorized"}}
          ]
        }
      ]
  end
end

defmodule Mix.Tasks.Woh.Native.Health.Smoke do
  @moduledoc """
  Exercises the Swift health client against a same-user Unix socket peer.

  Run `mix woh.native.health.smoke` to compile the native health fixture and
  check exact request framing, a valid response, an invalid API version and an
  absolute deadline against a slow byte-by-byte response. The socket and
  credential are local test data; no installed agent or live bulb is used.
  """

  @shortdoc "Smoke-test Swift health framing and deadline"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeHealthSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native health/identity framing, closed response validation, principal binding, and drip deadline passed"
        )

      {:error, reason} ->
        Mix.raise("native health smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.health.smoke")
end
