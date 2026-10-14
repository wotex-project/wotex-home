defmodule Woh.Tool.NativeAuthoringReadSmoke do
  @moduledoc false
  alias Woh.Tool.NativeFixture

  def run(project) do
    objects = object_cases()
    originals = original_cases(project)
    cases = objects ++ originals

    with :ok <-
           NativeFixture.run(project, "NativeAuthoringReadClientSmoke.swift", cases, [
             "NativeAuthoringReadClient"
           ]),
         do: {:ok, length(cases)}
  end

  defp base(operation),
    do: %{
      "api_version" => 1,
      "operation" => operation,
      "credential" => NativeFixture.credential()
    }

  def session(project) do
    identity = %{
      "deployment_id" => String.duplicate("a", 64),
      "owner_id" => String.duplicate("b", 64),
      "authority_epoch" => 2,
      "store_revision" => 10,
      "principal_id" => "author:fixture"
    }

    identity_request = base("controller_identity")

    request =
      Map.merge(base("authoring_review_status"), %{
        "authority_epoch" => 1,
        "operation_id" => "operation:1"
      })

    receipt =
      JSON.decode!(File.read!(Path.join(project, "test/fixtures/profiles/authoring-review.json")))[
        "receipt"
      ]
      |> Map.put("operation_id", "operation:1")

    cases =
      for mode <-
            ~w(valid old-epoch missing owner-changed principal-changed epoch-changed revision-changed receipt-future refused lost) do
        before = if mode == "valid", do: Map.put(identity, "authority_epoch", 1), else: identity

        after_identity =
          case mode do
            "owner-changed" -> Map.put(before, "owner_id", String.duplicate("c", 64))
            "principal-changed" -> Map.put(before, "principal_id", "author:other")
            "epoch-changed" -> Map.put(before, "authority_epoch", 3)
            "revision-changed" -> Map.put(before, "store_revision", 9)
            _ -> before
          end

        response =
          case mode do
            "missing" ->
              %{"api_version" => 1, "outcome" => "not_found"}

            "refused" ->
              %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}

            "lost" ->
              :close

            "receipt-future" ->
              envelope("authoring_review_receipt", Map.put(receipt, "revision", 11))

            _ ->
              envelope("authoring_review_receipt", receipt)
          end

        exchanges = [
          {identity_request, envelope("controller_identity", before)},
          {request, response}
        ]

        exchanges =
          if mode in ~w(refused lost),
            do: exchanges,
            else:
              exchanges ++ [{identity_request, envelope("controller_identity", after_identity)}]

        %{mode: mode, exchanges: exchanges, diagnostic: true}
      end

    contract =
      JSON.decode!(
        File.read!(Path.join(project, "test/fixtures/profiles/authoring-contract-exports.json"))
      )["temperature"]

    contract_identity = Map.put(identity, "authority_epoch", 1)

    contract_cases =
      for mode <-
            ~w(valid owner-changed principal-changed epoch-changed revision-changed future old actor epoch refused lost cancel) do
        after_identity =
          case mode do
            "owner-changed" -> Map.put(contract_identity, "owner_id", String.duplicate("c", 64))
            "principal-changed" -> Map.put(contract_identity, "principal_id", "author:other")
            "epoch-changed" -> Map.put(contract_identity, "authority_epoch", 2)
            "revision-changed" -> Map.put(contract_identity, "store_revision", 9)
            _ -> contract_identity
          end

        changed =
          case mode do
            "future" -> Map.put(contract, "store_revision", 11)
            "old" -> Map.put(contract, "store_revision", 9)
            "actor" -> Map.put(contract, "principal_id", "author:other")
            "epoch" -> Map.put(contract, "authority_epoch", 2)
            _ -> contract
          end

        response =
          case mode do
            "lost" ->
              :close

            "cancel" ->
              {:delay, 150, envelope("authoring_contract", changed)}

            "refused" ->
              %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}

            _ ->
              envelope("authoring_contract", changed)
          end

        exchanges = [
          {identity_request, envelope("controller_identity", contract_identity)},
          {base("authoring_contract_export"), response}
        ]

        exchanges =
          if mode in ~w(lost refused),
            do: exchanges,
            else:
              exchanges ++ [{identity_request, envelope("controller_identity", after_identity)}]

        %{mode: "contract-" <> mode, exchanges: exchanges, diagnostic: true}
      end

    cases = cases ++ contract_cases

    sources =
      Path.wildcard(Path.join(project, "native/macos/Sources/*.swift"))
      |> Enum.map(&Path.basename(&1, ".swift"))
      |> Enum.reject(&(&1 in ~w(WotexHomeApp LocalHealthClient)))

    with :ok <-
           NativeFixture.run(project, "NativeAuthoringReadSessionSmoke.swift", cases, sources),
         do: {:ok, length(cases)}
  end

  defp envelope(member, value), do: %{"api_version" => 1, "outcome" => "ok", member => value}

  defp one(mode, request, response),
    do: %{mode: mode, exchanges: [{request, response}], diagnostic: true}

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp object_cases do
    for {kind, tag, ceiling} <- [
          {"source", 1, 262_144},
          {"draft", 2, 262_144},
          {"bundle", 3, 262_144},
          {"fixture", 4, 65536},
          {"contract", 5, 262_144},
          {"envelope", 6, 65536},
          {"profile", 7, 65536},
          {"definition", 8, 65536}
        ],
        size <- [1, ceiling] do
      bytes = :binary.copy(<<255>>, size)
      raw_sha = :crypto.hash(:sha256, bytes)
      digest = sha(<<"WOHA", 1, tag, size::32, raw_sha::binary, bytes::binary>>)

      object = %{
        "kind" => kind,
        "object_digest" => digest,
        "payload_sha256" => sha(bytes),
        "payload_bytes" => size
      }

      raw = %{
        "object" => object,
        "first_revision" => 3,
        "payload_base64" => Base.url_encode64(bytes, padding: false)
      }

      request = Map.put(base("authoring_object_read"), "object_digest", digest)
      mode = "|" <> kind <> "|" <> digest
      valid = one("object" <> mode, request, envelope("authoring_object", raw))

      bad = [
        Map.put(raw, "first_revision", true),
        Map.put(raw, "first_revision", 0),
        Map.put(raw, "payload_base64", raw["payload_base64"] <> "="),
        Map.put(raw, "payload_base64", "AB"),
        Map.put(raw, "extra", true),
        put_in(raw, ["object", "payload_bytes"], size + 1),
        put_in(raw, ["object", "payload_sha256"], String.duplicate("0", 64)),
        put_in(raw, ["object", "object_digest"], String.duplicate("0", 64)),
        put_in(raw, ["object", "kind"], "unknown")
      ]

      [
        valid
        | Enum.map(bad, &one("invalid-object" <> mode, request, envelope("authoring_object", &1)))
      ]
    end
    |> List.flatten()
  end

  defp original_cases(project) do
    for {kind, file, member} <- [
          {"import", "authoring-import", "authoring_object_receipt"},
          {"candidate", "authoring-candidate", "authoring_candidate_receipt"},
          {"review", "authoring-review", "authoring_review_receipt"}
        ] do
      vector =
        JSON.decode!(File.read!(Path.join(project, "test/fixtures/profiles/" <> file <> ".json")))

      receipt = Map.put(vector["receipt"], "operation_id", "operation:1")
      operation = "authoring_" <> if(kind == "import", do: "object", else: kind) <> "_status"

      request =
        Map.merge(base(operation), %{"authority_epoch" => 1, "operation_id" => "operation:1"})

      bad = [
        Map.put(receipt, "authority_epoch", 2),
        Map.put(receipt, "operation_id", "other:1"),
        Map.put(receipt, "revision", true),
        Map.put(receipt, "revision", 0),
        Map.put(receipt, "revision", 1.5),
        Map.put(receipt, "revision", 9_223_372_036_854_775_808),
        Map.put(receipt, "extra", true),
        Map.delete(receipt, "operation_id")
      ]

      bad =
        bad ++
          case kind do
            "import" ->
              [
                Map.put(receipt, "first_revision", receipt["revision"] + 1),
                put_in(receipt, ["object", "payload_bytes"], false)
              ]

            "candidate" ->
              [
                Map.put(receipt, "capture_status", "supplied"),
                Map.put(receipt, "source_review", "attributed"),
                Map.put(receipt, "bundle", %{
                  "object_digest" => String.duplicate("a", 64),
                  "first_revision" => 1
                }),
                Map.put(receipt, "assessment_sha256", "bad")
              ]

            "review" ->
              [
                Map.put(receipt, "candidate_revision", receipt["revision"]),
                Map.put(receipt, "proposal_status", "approved"),
                Map.put(receipt, "source_review", "not_assessed"),
                Map.put(receipt, "result_sha256", "bad")
              ]
          end

      combinatorial =
        if kind == "review" do
          for source <- ~w(attributed incomplete ambiguous),
              consumption <- ~w(not_assessed matched),
              fixture <- ~w(not_supplied not_assessed passed failed incomplete) do
            proposal =
              if source == "attributed" and consumption == "matched" and fixture == "passed",
                do: "complete",
                else: "incomplete"

            changed =
              Map.merge(receipt, %{
                "source_review" => source,
                "home_consumption" => consumption,
                "fixture_status" => fixture,
                "proposal_status" => proposal
              })

            [
              one("valid|review", request, envelope(member, changed)),
              one(
                "invalid|review",
                request,
                envelope(
                  member,
                  Map.put(
                    changed,
                    "proposal_status",
                    if(proposal == "complete", do: "incomplete", else: "complete")
                  )
                )
              )
            ]
          end
          |> List.flatten()
        else
          []
        end

      [
        one("valid|" <> kind, request, envelope(member, receipt)),
        one(
          "valid|" <> kind,
          request,
          envelope(member, Map.put(receipt, "revision", 9_223_372_036_854_775_807))
        ),
        one("missing|" <> kind, request, %{"api_version" => 1, "outcome" => "not_found"}),
        one("refused|" <> kind, request, %{
          "api_version" => 1,
          "outcome" => "error",
          "reason" => "permission_denied"
        }),
        one("lost|" <> kind, request, :close),
        one(
          "invalid|" <> kind,
          request,
          {:raw, ~s({"api_version":1,"api_version":1,"outcome":"ok"})}
        )
      ] ++
        Enum.map(bad, &one("invalid|" <> kind, request, envelope(member, &1))) ++ combinatorial
    end
    |> List.flatten()
  end
end

defmodule Mix.Tasks.Woh.Native.Authoring.Read.Smoke do
  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Check native inert authoring reads against independent private peers"
  def run([]) do
    case Woh.Tool.NativeAuthoringReadSmoke.run(File.cwd!()) do
      {:ok, count} ->
        case Woh.Tool.NativeAuthoringReadSmoke.session(File.cwd!()) do
          {:ok, sessions} ->
            Mix.shell().info(
              "native authoring #{count} typed private peer and #{sessions} selected-session cases passed"
            )

          {:error, reason} ->
            Mix.raise("native authoring selected-session smoke failed: #{reason}")
        end

      {:error, reason} ->
        Mix.raise("native authoring read smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.authoring.read.smoke")
end
