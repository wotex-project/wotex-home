defmodule Mix.Tasks.Woh.Native.Authoring.Panel.Smoke do
  @moduledoc """
  Checks native authoring confirmation and mounted panel workflows.

  Run `mix woh.native.authoring.panel.smoke` on the supported macOS toolchain. The task
  compiles and runs the owning Swift fixture under bounded deadlines and reports
  a refusal when compilation, peer exchange or fixture assertions fail.

  The fixture establishes bounded software behavior only. It neither qualifies
  physical devices nor installs or changes the operator's controller policy.
  """

  use Mix.Task
  alias Woh.Tool.NativeFixture
  @requirements ["loadpaths"]
  @shortdoc "Check native authoring confirmation, private preparation and mounted layout"
  def run([]) do
    credential = NativeFixture.credential()

    base = fn operation ->
      %{"api_version" => 1, "operation" => operation, "credential" => credential}
    end

    identity = %{
      "deployment_id" => String.duplicate("a", 64),
      "owner_id" => String.duplicate("b", 64),
      "authority_epoch" => 1,
      "store_revision" => 1,
      "principal_id" => "author:fixture"
    }

    identity_response = %{
      "api_version" => 1,
      "outcome" => "ok",
      "controller_identity" => identity
    }

    profiles = %{
      "api_version" => 1,
      "outcome" => "ok",
      "profile_catalogue" => %{
        "authority_epoch" => 1,
        "store_revision" => 1,
        "policy_generation" => 0,
        "items" => []
      }
    }

    cases = [
      %{
        mode: "panel",
        diagnostic: true,
        exchanges: [
          {base.("controller_identity"), identity_response},
          {base.("profiles"), profiles},
          {base.("controller_identity"), identity_response}
        ]
      }
    ]

    cases =
      cases ++
        for {mode, field, changed} <- [
              {"invalid-owner", "owner_id", String.duplicate("c", 64)},
              {"invalid-principal", "principal_id", "author:other"},
              {"invalid-epoch", "authority_epoch", 2},
              {"invalid-watermark", "store_revision", 2}
            ] do
          after_response = put_in(identity_response, ["controller_identity", field], changed)

          %{
            mode: mode,
            diagnostic: true,
            exchanges: [
              {base.("controller_identity"), identity_response},
              {base.("profiles"), profiles},
              {base.("controller_identity"), after_response}
            ]
          }
        end

    cases =
      cases ++
        [
          %{
            mode: "refused",
            diagnostic: true,
            exchanges: [
              {base.("controller_identity"), identity_response},
              {base.("profiles"),
               %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}}
            ]
          }
        ]

    contract =
      JSON.decode!(File.read!("test/fixtures/profiles/authoring-contract-exports.json"))[
        "temperature"
      ]
      |> Map.put("store_revision", 1)

    cases =
      cases ++
        [
          %{
            mode: "manual-panel",
            diagnostic: true,
            exchanges: [
              {base.("controller_identity"), identity_response},
              {base.("authoring_contract_export"),
               %{"api_version" => 1, "outcome" => "ok", "authoring_contract" => contract}},
              {base.("controller_identity"), identity_response}
            ]
          }
        ]

    sources =
      Path.wildcard(Path.expand("native/macos/Sources/*.swift"))
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(WotexHomeApp LocalHealthClient)))

    File.mkdir_p!("_build/native")

    case NativeFixture.run(File.cwd!(), "NativeAuthoringPanelSmoke.swift", cases, sources) do
      :ok ->
        Mix.shell().info(
          "native authoring confirmation, delayed retirement, private review and mounted layout passed"
        )

      {:error, reason} ->
        Mix.raise("native authoring panel smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.authoring.panel.smoke")
end
