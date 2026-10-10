defmodule Mix.Tasks.Woh.Native.Controller.Scope.Smoke do
  @moduledoc "Checks closed native authenticated scope decoding against independent framed UDS peers."
  @shortdoc "Check current native permission and target scope decoding"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.NativeFixture

  def run([]) do
    request = %{
      "api_version" => 1,
      "operation" => "controller_scope",
      "credential" => NativeFixture.credential()
    }

    scope = %{
      "format" => "wotex-home.controller-scope.v1",
      "deployment_id" => String.duplicate("a", 64),
      "owner_id" => String.duplicate("b", 64),
      "authority_epoch" => 7,
      "store_revision" => 9,
      "principal_id" => "operator:scope",
      "permissions" => ["control:ordinary", "read"],
      "target_ids" => ["light:a", "light:b"]
    }

    valid = %{"api_version" => 1, "outcome" => "ok", "controller_scope" => scope}

    invalid =
      [
        Map.put(valid, "extra", true),
        Map.put(valid, "api_version", true),
        %{"api_version" => 1, "outcome" => "not_found"}
      ] ++
        Enum.map(
          [
            {"format", "wotex-home.controller-scope.v2"},
            {"format", nil},
            {"deployment_id", String.duplicate("A", 64)},
            {"deployment_id", String.duplicate("a", 63)},
            {"owner_id", "bad"},
            {"principal_id", "bad principal"},
            {"principal_id", ""},
            {"authority_epoch", true},
            {"authority_epoch", 7.0},
            {"authority_epoch", 0},
            {"store_revision", false},
            {"store_revision", 9.0},
            {"store_revision", -1},
            {"permissions", []},
            {"permissions", ["read", "control:ordinary"]},
            {"permissions", ["read", "read"]},
            {"permissions", ["read", "unknown:permission"]},
            {"permissions", ["host:transfer", "read"]},
            {"permissions", List.duplicate("read", 11)},
            {"permissions", [true]},
            {"permissions", nil},
            {"permissions", ["host:transfer"]},
            {"target_ids", ["light:b", "light:a"]},
            {"target_ids", ["light:a", "light:a"]},
            {"target_ids", ["bad target"]},
            {"target_ids", Enum.map(0..32, &"light:#{&1}") |> Enum.sort()},
            {"target_ids", [1]},
            {"target_ids", nil},
            {"extra", true}
          ],
          fn {key, value} -> put_in(valid, ["controller_scope", key], value) end
        ) ++
        Enum.map(Map.keys(scope), fn key ->
          put_in(valid, ["controller_scope"], Map.delete(scope, key))
        end)

    cases =
      [%{mode: "valid", exchanges: [{request, valid}]}] ++
        Enum.map(invalid, &%{mode: "invalid", exchanges: [{request, &1}]})

    case NativeFixture.run(File.cwd!(), "LocalControllerScopeSmoke.swift", cases) do
      :ok ->
        Mix.shell().info(
          "native controller scope one valid and #{length(invalid)} independent refusal cases passed"
        )

      {:error, reason} ->
        Mix.raise("native controller scope smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.controller.scope.smoke")
end
