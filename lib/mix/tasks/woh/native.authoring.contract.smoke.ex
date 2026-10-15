defmodule Woh.Tool.NativeAuthoringContractSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    vectors =
      JSON.decode!(
        File.read!(Path.join(project, "test/fixtures/profiles/authoring-contract-exports.json"))
      )

    request = %{
      "api_version" => 1,
      "operation" => "authoring_contract_export",
      "credential" => NativeFixture.credential()
    }

    wrap = fn value -> %{"api_version" => 1, "outcome" => "ok", "authoring_contract" => value} end

    one = fn mode, response ->
      %{mode: mode, exchanges: [{request, response}], diagnostic: true}
    end

    base = vectors["temperature"]
    valid = for {family, value} <- vectors, do: one.("valid-" <> family, wrap.(value))

    runtime = %{
      "format" => "wotex-home.profile-producer-runtime@1",
      "source_revision" => "ba8ea373244ce57987f47a731b8eca3ccae9b45f",
      "core_runtime_sha256" => String.duplicate("0", 64),
      "runtime_runtime_sha256" => String.duplicate("1", 64),
      "profiles_runtime_sha256" => String.duplicate("2", 64)
    }

    valid =
      valid ++
        for {name, revision} <- [
              {"valid-runtime-predecessor", runtime["source_revision"]},
              {"valid-runtime-current", WotexHome.MixProject.source_pins()[:wotex]},
              {"valid-runtime-other", String.duplicate("f", 40)}
            ] do
          one.(
            name,
            wrap.(
              put_in(base, ["summary", "producer"], Map.put(runtime, "source_revision", revision))
            )
          )
        end

    bad = [
      Map.put(base, "extra", true),
      Map.put(base, "format", "wrong"),
      Map.put(base, "authority_epoch", true),
      Map.put(base, "authority_epoch", 1.0),
      Map.put(base, "store_revision", -1),
      Map.put(base, "principal_id", "bad/id"),
      Map.put(base, "contract_base64", base["contract_base64"] <> "="),
      Map.put(base, "contract_base64", "_w"),
      Map.put(base, "contract_base64", ""),
      Map.put(base, "contract_base64", String.duplicate("A", 349_527)),
      put_in(base, ["summary", "extra"], true),
      put_in(base, ["summary", "format"], "wrong"),
      put_in(base, ["summary", "contract_sha256"], String.duplicate("0", 64)),
      put_in(base, ["summary", "contract_raw_sha256"], String.duplicate("0", 64)),
      put_in(base, ["summary", "basis_sha256"], "bad"),
      put_in(base, ["summary", "consumption_policy"], "wrong"),
      put_in(base, ["summary", "limits", "max_diagnostics"], false),
      put_in(base, ["summary", "limits", "max_diagnostics"], 1.0),
      put_in(base, ["summary", "limits", "max_diagnostics"], 65),
      put_in(base, ["summary", "limits", "reader", "max_bytes"], 1),
      put_in(base, ["summary", "producer"], Map.put(runtime, "extra", true)),
      put_in(
        base,
        ["summary", "producer"],
        Map.put(runtime, "source_revision", String.duplicate("A", 40))
      ),
      put_in(
        base,
        ["summary", "producer"],
        Map.put(runtime, "source_revision", String.duplicate("0", 41))
      ),
      put_in(
        base,
        ["summary", "producer"],
        Map.put(runtime, "source_revision", String.duplicate("0", 39))
      )
    ]

    {:ok, bytes} = Base.url_decode64(base["contract_base64"], padding: false)
    document = JSON.decode!(bytes)

    deep = Enum.reduce(1..33, 0, fn _, inner -> [inner] end)
    dense = List.duplicate(List.duplicate(0, 3000), 17)

    bound_document =
      Map.put(document, "schemas", %{
        "node_limit" => dense,
        "string_limit" => String.duplicate("x", 16385)
      })

    changed_documents = [
      JSON.encode!(Map.put(document, "extra", true)),
      JSON.encode!(Map.put(document, "format", "wrong")),
      JSON.encode!(put_in(document, ["limits", "max_diagnostics"], 1.0)),
      JSON.encode!(put_in(document, ["limits", "max_diagnostics"], 63)),
      JSON.encode!(Map.put(document, "schemas", List.duplicate(1, 4097))),
      JSON.encode!(Map.put(document, "schemas", deep)),
      JSON.encode!(Map.put(document, "schemas", dense)),
      JSON.encode!(bound_document),
      JSON.encode!(Map.put(document, "schemas", String.duplicate("x", 16385))),
      JSON.encode!(Map.put(document, "schemas", %{String.duplicate("k", 16385) => 1})),
      String.replace(bytes, "{", "{\"format\":\"duplicate\",", global: false),
      <<255>>
    ]

    bad =
      bad ++
        Enum.map(changed_documents, fn bytes ->
          base
          |> Map.put("contract_base64", Base.url_encode64(bytes, padding: false))
          |> put_in(["summary", "contract_raw_sha256"], sha(bytes))
          |> put_in(
            ["summary", "contract_sha256"],
            sha("wotex.profile.authoring-contract@1\n" <> bytes)
          )
        end)

    cases =
      valid ++
        Enum.map(bad, &one.("invalid", wrap.(&1))) ++
        [
          one.("invalid-missing", %{"api_version" => 1, "outcome" => "not_found"}),
          one.("refused", %{
            "api_version" => 1,
            "outcome" => "error",
            "reason" => "permission_denied"
          }),
          one.("lost", :close)
        ]

    with :ok <-
           NativeFixture.run(project, "NativeAuthoringContractSmoke.swift", cases, [
             "NativeAuthoringReadClient"
           ]),
         do: {:ok, length(cases)}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

defmodule Mix.Tasks.Woh.Native.Authoring.Contract.Smoke do
  @moduledoc """
  Checks native installed-contract reads against independent private peers.

  Run `mix woh.native.authoring.contract.smoke` on the supported macOS toolchain. The task
  compiles and runs the owning Swift fixture under bounded deadlines and reports
  a refusal when compilation, peer exchange or fixture assertions fail.

  The fixture establishes bounded software behavior only. It neither qualifies
  physical devices nor installs or changes the operator's controller policy.
  """

  use Mix.Task
  @shortdoc "Check native installed contract reads against independent private peers"
  def run([]) do
    case Woh.Tool.NativeAuthoringContractSmoke.run(File.cwd!()) do
      {:ok, count} ->
        Mix.shell().info("native authoring contract #{count} private peer cases passed")

      {:error, reason} ->
        Mix.raise("native authoring contract smoke failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.authoring.contract.smoke")
end
