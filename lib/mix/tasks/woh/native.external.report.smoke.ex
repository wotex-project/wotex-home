defmodule Woh.Tool.NativeExternalReportSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture

  def run(project) do
    vectors =
      JSON.decode!(
        File.read!(Path.join(project, "test/fixtures/profiles/external-observations.json"))
      )

    valid =
      for family <- ~w(temperature research multi) do
        key = if family == "multi", do: "density", else: "sample"

        one(
          "valid-" <> family,
          preview(Map.put(vectors[family]["value"], "continuity", "baseline"), key),
          key
        )
      end

    value = vectors["temperature"]["value"] |> Map.put("continuity", "baseline")
    base = preview(value)

    unknown =
      for {freshness, reason} <- [
            {"unknown", "synthetic_lab"},
            {"stale", "expired"},
            {"missing", "missing"}
          ] do
        item =
          Map.merge(base, %{
            "freshness" => freshness,
            "reason" => reason,
            "value" => nil,
            "remaining_ms" => 0
          })

        item =
          if freshness == "missing",
            do: Map.merge(item, %{"report_revision" => nil, "age_ms" => nil}),
            else: item

        one(freshness, item)
      end

    metadata =
      for {key, value} <- [
            {"target_id", "sensor:other"},
            {"capability_key", "other"},
            {"authority_epoch", true},
            {"authority_epoch", 1.0},
            {"store_revision", -1},
            {"selection_revision", 43},
            {"resource_revision", 43},
            {"report_revision", nil},
            {"age_ms", nil},
            {"remaining_ms", 0},
            {"remaining_ms", 86_400_001},
            {"remaining_ms", false},
            {"value", nil},
            {"freshness", "known"},
            {"reason", "claimed_fresh"},
            {"extra", 1}
          ],
          do: one("invalid", Map.put(base, key, value))

    values =
      for {key, changed} <- [
            {"channel_id", "bad/id"},
            {"quality", "invalid"},
            {"quality_reason", "sentinel"},
            {"continuity", "gap"},
            {"sequence", nil},
            {"sequence", "18446744073709551616"},
            {"sequence", "07"},
            {"source_epoch", String.duplicate("F", 32)},
            {"source_ref", "bad/id"},
            {"profile_sha256", "bad"},
            {"value_kind", "float"},
            {"normalized_value", %{"type" => "sint", "value" => "9223372036854775808"}},
            {"normalized_value", %{"type" => "sint", "value" => "02500"}},
            {"normalized_value", %{"type" => "sint", "value" => 2500}},
            {"normalized_value", %{"type" => "sint", "value" => "2500", "extra" => true}},
            {"unit", nil},
            {"receipt_time", %{"epoch" => String.duplicate("f", 32), "monotonic_us" => "-0"}},
            {"semantic", Map.put(value["semantic"], "extra", true)},
            {"contract_ref", Map.put(value["contract_ref"], "id", "relative")},
            {"contract_ref", Map.put(value["contract_ref"], "version", "65536.0.0")},
            {"contract_ref", Map.put(value["contract_ref"], "id", "urn:bad:\u200Bname")},
            {"extra", true},
            {"source_time", %{"large" => String.duplicate("x", 4097)}}
          ],
          do: one("invalid", Map.put(base, "value", Map.put(value, key, changed)))

    boolean =
      Map.merge(value, %{
        "value_kind" => "boolean",
        "unit" => nil,
        "normalized_value" => %{"type" => "boolean", "value" => false}
      })

    external = Map.put(value, "value_kind", "external")

    catalogue = catalogue_cases(project)

    cases =
      catalogue ++
        valid ++
        unknown ++
        metadata ++
        values ++
        [
          one("valid-alias", preview(value, "temperature"), "temperature"),
          one("valid-bool", preview(boolean)),
          one("valid-external", preview(external)),
          one("invalid", preview(put_in(boolean, ["normalized_value", "value"], 0))),
          %{
            mode: "refused",
            exchanges: [
              {request("sample"),
               %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}}
            ]
          },
          %{mode: "lost", exchanges: [{request("sample"), :close}]},
          %{
            mode: "invalid",
            exchanges: [
              {request("sample"), {:raw, ~s({"api_version":1,"api_version":1,"outcome":"ok"})}}
            ]
          }
        ]

    case NativeFixture.run(project, "NativeExternalReportClientSmoke.swift", cases, [
           "NativeExternalReportClient"
         ]) do
      :ok -> {:ok, length(cases)}
      error -> error
    end
  end

  defp catalogue_cases(project) do
    vectors =
      JSON.decode!(
        File.read!(Path.join(project, "test/fixtures/profiles/external-target-selections.json"))
      )

    things =
      for family <- ~w(temperature research multi),
          do:
            JSON.decode!(vectors[family]["select"]["outcome"]["thing_document"])
            |> Map.put("resource_revision", 0)

    catalogue_request = %{
      "api_version" => 1,
      "operation" => "catalogue",
      "credential" => NativeFixture.credential(),
      "watermark" => nil,
      "after" => nil,
      "page_size" => 10
    }

    snapshot_request = %{
      "api_version" => 1,
      "operation" => "snapshot",
      "credential" => NativeFixture.credential(),
      "watermark" => 42,
      "after" => nil,
      "page_size" => 100
    }

    snapshot = %{
      "api_version" => 1,
      "outcome" => "ok",
      "snapshot" => %{
        "authority_epoch" => 1,
        "watermark" => 42,
        "items" => [],
        "next_after" => nil
      }
    }

    catalogue = fn thing ->
      %{
        "api_version" => 1,
        "outcome" => "ok",
        "catalogue" => %{
          "authority_epoch" => 1,
          "watermark" => 42,
          "items" => [thing],
          "next_after" => nil
        }
      }
    end

    valid =
      for thing <- things,
          do: %{
            mode: "catalogue-valid",
            exchanges: [{catalogue_request, catalogue.(thing)}, {snapshot_request, snapshot}]
          }

    thing = hd(things)
    [record] = thing["capabilities"]

    bad = [
      Map.put(thing, "resource_revision", true),
      Map.put(thing, "profile_ref", "external:bad"),
      Map.put(thing, "capabilities", [record, record]),
      Map.put(thing, "capabilities", [
        Map.put(record, "declaration_sha256", String.duplicate("0", 64))
      ])
    ]

    data = JSON.decode!(record["declaration_document"])

    bad =
      bad ++
        for {key, changed} <- [
              {"thing_id", "sensor:other"},
              {"operations", ["read", "write"]},
              {"risk_class", "trusted"},
              {"freshness_ms", true},
              {"constraints", %{"min" => true, "max" => 3000}},
              {"extra", true}
            ] do
          bytes = JSON.encode!(Map.put(data, key, changed))

          sha =
            :crypto.hash(:sha256, "wotex-home.external-read-declaration@1\n" <> bytes)
            |> Base.encode16(case: :lower)

          Map.put(thing, "capabilities", [
            Map.merge(record, %{"declaration_document" => bytes, "declaration_sha256" => sha})
          ])
        end

    large_schema =
      Map.put(data, "value_schema", %{
        "type" => "object",
        "properties" => %{String.duplicate("x", 4096) => %{"type" => "integer"}}
      })

    large_document = JSON.encode!(large_schema)

    large_sha =
      :crypto.hash(:sha256, "wotex-home.external-read-declaration@1\n" <> large_document)
      |> Base.encode16(case: :lower)

    large =
      Map.put(thing, "capabilities", [
        Map.merge(record, %{
          "declaration_document" => large_document,
          "declaration_sha256" => large_sha
        })
      ])

    duplicate_document =
      String.replace(record["declaration_document"], "{", "{\"capability_key\":\"duplicate\",",
        global: false
      )

    duplicate_sha =
      :crypto.hash(:sha256, "wotex-home.external-read-declaration@1\n" <> duplicate_document)
      |> Base.encode16(case: :lower)

    bad =
      bad ++
        [
          Map.put(thing, "capabilities", [
            Map.merge(record, %{
              "declaration_document" => duplicate_document,
              "declaration_sha256" => duplicate_sha
            })
          ])
        ]

    valid =
      valid ++
        [
          %{
            mode: "catalogue-valid",
            exchanges: [{catalogue_request, catalogue.(large)}, {snapshot_request, snapshot}]
          }
        ]

    valid ++
      for thing <- bad,
          do: %{mode: "catalogue-invalid", exchanges: [{catalogue_request, catalogue.(thing)}]}
  end

  def session(project) do
    value =
      JSON.decode!(
        File.read!(Path.join(project, "test/fixtures/profiles/external-observations.json"))
      )["temperature"]["value"]
      |> Map.put("continuity", "baseline")

    identity = %{
      "deployment_id" => String.duplicate("a", 64),
      "owner_id" => String.duplicate("b", 64),
      "authority_epoch" => 1,
      "store_revision" => 42,
      "principal_id" => "reader:fixture"
    }

    identity_request = %{
      "api_version" => 1,
      "operation" => "controller_identity",
      "credential" => NativeFixture.credential()
    }

    envelope = fn identity ->
      %{"api_version" => 1, "outcome" => "ok", "controller_identity" => identity}
    end

    response = %{
      "api_version" => 1,
      "outcome" => "ok",
      "external_report_preview" => preview(value)
    }

    cases =
      for mode <- ~w(valid owner-changed epoch-changed revision-changed refused lost) do
        report =
          case mode do
            "refused" ->
              %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}

            "lost" ->
              :close

            _ ->
              response
          end

        after_identity =
          case mode do
            "owner-changed" -> Map.put(identity, "owner_id", String.duplicate("c", 64))
            "epoch-changed" -> Map.put(identity, "authority_epoch", 2)
            "revision-changed" -> Map.put(identity, "store_revision", 41)
            _ -> identity
          end

        exchanges = [{identity_request, envelope.(identity)}, {request("sample"), report}]

        exchanges =
          if mode in ~w(refused lost),
            do: exchanges,
            else: exchanges ++ [{identity_request, envelope.(after_identity)}]

        %{mode: mode, exchanges: exchanges, diagnostic: true}
      end

    sources =
      Path.wildcard(Path.join(project, "native/macos/Sources/*.swift"))
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(WotexHomeApp LocalHealthClient)))

    NativeFixture.run(project, "NativeExternalReportSessionSmoke.swift", cases, sources)
  end

  defp preview(value, key \\ "sample"),
    do: %{
      "format" => "home-external-reported-value-v1",
      "target_id" => "sensor:external",
      "capability_key" => key,
      "store_revision" => 42,
      "authority_epoch" => 1,
      "selection_revision" => 7,
      "resource_revision" => 0,
      "report_revision" => 8,
      "value" => value,
      "freshness" => "fresh",
      "reason" => nil,
      "age_ms" => 5,
      "remaining_ms" => 1000
    }

  defp request(key),
    do: %{
      "api_version" => 1,
      "operation" => "external_report_current",
      "credential" => NativeFixture.credential(),
      "target_id" => "sensor:external",
      "capability_key" => key
    }

  defp one(mode, preview, key \\ "sample"),
    do: %{
      mode: mode,
      exchanges: [
        {request(key),
         %{"api_version" => 1, "outcome" => "ok", "external_report_preview" => preview}}
      ]
    }
end

defmodule Mix.Tasks.Woh.Native.External.Report.Smoke do
  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Check native external report reads against independent socket fixtures"
  def run([]) do
    case Woh.Tool.NativeExternalReportSmoke.run(File.cwd!()) do
      {:ok, count} ->
        case Woh.Tool.NativeExternalReportSmoke.session(File.cwd!()) do
          :ok ->
            Mix.shell().info(
              "native external report #{count} socket and six selected-session cases passed"
            )

          {:error, reason} ->
            Mix.raise("native external report session failed: #{reason}")
        end

      {:error, reason} ->
        Mix.raise("native external report smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.report.smoke")
end
