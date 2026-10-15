defmodule Woh.Tool.NativeExternalGuidance do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    cases = cases()

    with :ok <-
           NativeFixture.run(project, "NativeExternalGuidanceSmoke.swift", cases, [
             "NativeExternalProfileClient",
             "NativeExternalProfileOriginalWire",
             "NativeExternalGuidanceClient"
           ]),
         do: {:ok, length(cases)}
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp reference(family),
    do:
      Map.take(
        fixture("external-inspections")[family]["receipt"],
        ~w(authority_epoch operation_id revision input_sha256 result_sha256)
      )

  defp identity(changes \\ %{}),
    do:
      Map.merge(
        %{
          "deployment_id" => String.duplicate("a", 64),
          "owner_id" => String.duplicate("b", 64),
          "authority_epoch" => 2,
          "store_revision" => 100,
          "principal_id" => "operator:read"
        },
        changes
      )

  defp request(operation, fields \\ %{}),
    do:
      Map.merge(
        %{
          "api_version" => 1,
          "credential" => NativeFixture.credential(),
          "operation" => operation
        },
        fields
      )

  defp envelope(member, body), do: %{"api_version" => 1, "outcome" => "ok", member => body}
  defp operation("context"), do: "external_profile_context"
  defp operation("sources"), do: "external_source_catalogue"
  defp operation("target"), do: "external_target_basis"
  defp operation("artifact"), do: "external_inspection_artifact"
  defp fields("target", _), do: %{"target_id" => "sensor:external"}
  defp fields("artifact", family), do: %{"inspection_ref" => reference(family)}
  defp fields(_, _), do: %{}

  defp body(kind, extra),
    do:
      Map.merge(
        %{
          "format" => "wotex-home." <> String.replace(operation(kind), "_", "-") <> "@1",
          "principal_id" => "operator:read",
          "authority_epoch" => 2,
          "store_revision" => 100,
          "policy_generation" => 1
        },
        extra
      )

  defp context,
    do:
      body("context", %{
        "maintenance" => "normal",
        "maintenance_revision" => 0,
        "reader" => %{
          "state" => "available",
          "basis_sha256" => String.duplicate("c", 64),
          "reason" => nil
        }
      })

  defp sources(family) do
    data = fixture("external-source-selections")[family]

    row =
      Map.take(
        data["data"],
        ~w(source_ref reader_basis_sha256 source_epoch source_generation method trust policy_sha256)
      )
      |> Map.put("source_selection_sha256", data["sha256"])

    body("sources", %{
      "state" => "available",
      "owner_epoch" => String.duplicate("d", 32),
      "sources" => [row],
      "reason" => nil
    })
  end

  defp target(state) do
    absent = state == "absent"

    body("target", %{
      "target_id" => "sensor:external",
      "state" => state,
      "selection_revision" => if(absent, do: 0, else: 80),
      "selection_generation" => if(absent, do: 0, else: 2),
      "resource_revision" => if(absent, do: 0, else: 1),
      "binding_revision" => if(absent, do: 0, else: if(state == "selected", do: 80, else: 70)),
      "artifact_digest" => if(absent, do: nil, else: String.duplicate("e", 64)),
      "trust_revision" => if(absent, do: 0, else: 90)
    })
  end

  defp artifact(family) do
    value = fixture("external-trust")[family]

    body("artifact", %{
      "inspection_ref" => reference(family),
      "artifact_digest" => value["artifact_digest"],
      "artifact" => value["artifact"]
    })
  end

  defp one(kind, result, expected, options \\ []) do
    family = Keyword.get(options, :family, "temperature")
    before = Keyword.get(options, :before, identity())
    after_identity = Keyword.get(options, :after, before)
    response = Keyword.get(options, :response, envelope(operation(kind), result))

    exchanges = [
      {request("controller_identity"), envelope("controller_identity", before)},
      {request(operation(kind), fields(kind, family)), response}
    ]

    exchanges =
      if expected in ~w(valid missing guard),
        do:
          exchanges ++
            [{request("controller_identity"), envelope("controller_identity", after_identity)}],
        else: exchanges

    %{
      mode:
        Enum.join(
          [
            kind,
            expected,
            family,
            Keyword.get(options, :variant, if(kind == "target", do: result["state"], else: ""))
          ],
          "|"
        ),
      exchanges: exchanges,
      diagnostic: true
    }
  end

  defp invalid(kind, result, options \\ []), do: one(kind, result, "invalid", options)

  # Independent manifest array/hash construction: never calls the Elixir or Swift owner.
  defp rehash(body) do
    arrays =
      Enum.map(body["artifact"]["objects"], fn row ->
        ref =
          if row["reference"],
            do: Enum.map(~w(id version sha256), &row["reference"][&1]),
            else: nil

        [row["kind"], ref, row["object_digest"], row["payload_sha256"], row["payload_bytes"]]
      end)

    Map.put(
      body,
      "artifact_digest",
      Base.encode16(
        :crypto.hash(:sha256, "wotex-home.external-artifact@1\n" <> JSON.encode!(arrays)),
        case: :lower
      )
    )
  end

  defp cases do
    context = context()
    sources = sources("temperature")
    target = target("selected")
    artifact = artifact("temperature")

    bodies = [
      {"context", context},
      {"sources", sources},
      {"target", target},
      {"artifact", artifact}
    ]

    valid =
      for family <- ~w(temperature research) do
        [
          one("context", context, "valid", family: family),
          one(
            "context",
            %{context | "maintenance" => "maintenance", "maintenance_revision" => 90},
            "valid",
            family: family,
            variant: "maintenance"
          ),
          one(
            "context",
            put_in(context, ["reader"], %{
              "state" => "unavailable",
              "basis_sha256" => nil,
              "reason" => "external_reader_unavailable"
            }),
            "valid",
            family: family,
            variant: "unavailable"
          ),
          one("sources", sources(family), "valid", family: family, variant: "one"),
          one("sources", %{sources | "sources" => []}, "valid", family: family),
          one(
            "sources",
            %{
              sources
              | "state" => "unavailable",
                "owner_epoch" => nil,
                "sources" => [],
                "reason" => "external_source_unavailable"
            },
            "valid",
            family: family,
            variant: "unavailable"
          ),
          one("artifact", artifact(family), "valid", family: family),
          one("artifact", nil, "missing",
            family: family,
            response: %{"api_version" => 1, "outcome" => "not_found"}
          )
        ] ++
          Enum.map(
            ~w(absent selected revoked),
            &one("target", target(&1), "valid", family: family)
          )
      end
      |> List.flatten()

    closed =
      for {kind, value} <- bodies do
        missing = for key <- Map.keys(value), do: invalid(kind, Map.delete(value, key))

        wrong =
          for {key, bad} <- [
                {"format", "future@2"},
                {"extra", true},
                {"principal_id", "bad/id"},
                {"authority_epoch", 0},
                {"authority_epoch", true},
                {"authority_epoch", 1.0},
                {"store_revision", -1},
                {"store_revision", "100"},
                {"policy_generation", 1025},
                {"policy_generation", 101},
                {"policy_generation", nil},
                {"store_revision", 9_223_372_036_854_775_808}
              ],
              do: invalid(kind, Map.put(value, key, bad))

        guards =
          for {key, bad} <- [
                {"principal_id", "other:actor"},
                {"authority_epoch", 3},
                {"store_revision", 101}
              ],
              do: one(kind, Map.put(value, key, bad), "guard")

        changed =
          for {key, bad} <- [
                {"principal_id", "other:actor"},
                {"authority_epoch", 3},
                {"store_revision", 101},
                {"owner_id", String.duplicate("f", 64)}
              ],
              do: one(kind, value, "guard", after: identity(%{key => bad}))

        wrappers = [
          invalid(kind, value, response: Map.put(envelope(operation(kind), value), "extra", nil)),
          one(kind, value, "refused",
            response: %{"api_version" => 1, "outcome" => "error", "reason" => "permission_denied"}
          ),
          invalid(kind, value,
            response: %{
              "api_version" => 1,
              "outcome" => "error",
              "reason" => "bad/private reason"
            }
          ),
          one(kind, value, "lost", response: :close),
          invalid(kind, value,
            response: {:raw, ~s({"api_version":1,"outcome":"ok","outcome":"ok"})}
          )
        ]

        missing ++ wrong ++ guards ++ changed ++ wrappers
      end
      |> List.flatten()

    bad_context =
      for {path, bad} <- [
            {["maintenance"], "unknown"},
            {["maintenance_revision"], 1},
            {["reader", "reason"], "external_reader_unavailable"},
            {["reader", "basis_sha256"], nil},
            {["reader", "extra"], nil},
            {["reader", "state"], "unknown"}
          ],
          do: invalid("context", put_in(context, path, bad))

    [row] = sources["sources"]

    bad_sources =
      Enum.map(
        [
          %{sources | "owner_epoch" => String.duplicate("D", 32)},
          %{sources | "sources" => [row, row]},
          %{sources | "sources" => List.duplicate(row, 33)},
          %{sources | "state" => "unavailable"},
          %{sources | "reason" => "external_source_unavailable"}
        ],
        &invalid("sources", &1)
      ) ++
        for {key, value} <- [
              {"stable_id_sha256", String.duplicate("0", 64)},
              {"source_generation", true},
              {"source_generation", 0},
              {"source_epoch", "bad"},
              {"trust", "trusted"},
              {"method", "automatic"},
              {"source_ref", "bad/id"},
              {"policy_sha256", "bad"}
            ],
            do: invalid("sources", %{sources | "sources" => [Map.put(row, key, value)]})

    bad_targets =
      for {key, bad} <- [
            {"target_id", "sensor:other"},
            {"state", "unknown"},
            {"selection_revision", 101},
            {"selection_generation", 0},
            {"resource_revision", 0},
            {"binding_revision", 79},
            {"artifact_digest", nil},
            {"trust_revision", 0},
            {"trust_revision", 101}
          ],
          do: invalid("target", Map.put(target, key, bad))

    absent = target("absent")

    bad_absent =
      for key <-
            ~w(selection_revision selection_generation resource_revision binding_revision trust_revision),
          do: invalid("target", Map.put(absent, key, 1))

    objects = artifact["artifact"]["objects"]

    mutate_object = fn row ->
      put_in(artifact, ["artifact", "objects"], List.replace_at(objects, 0, row)) |> rehash()
    end

    bad_artifact =
      [
        invalid("artifact", Map.put(artifact, "artifact_digest", String.duplicate("0", 64))),
        invalid(
          "artifact",
          put_in(artifact, ["inspection_ref", "operation_id"], "other:inspection")
        ),
        invalid("artifact", put_in(artifact, ["artifact", "extra"], nil)),
        invalid("artifact", put_in(artifact, ["artifact", "id"], "bad/id")),
        invalid("artifact", put_in(artifact, ["artifact", "version"], "01.0.0")),
        invalid("artifact", put_in(artifact, ["artifact", "objects"], [hd(objects)])),
        invalid(
          "artifact",
          put_in(artifact, ["artifact", "objects"], [hd(objects), hd(objects)]) |> rehash()
        )
      ] ++
        for {key, value} <- [
              {"extra", nil},
              {"kind", "profile"},
              {"object_digest", "bad"},
              {"payload_sha256", "bad"},
              {"payload_bytes", 0},
              {"payload_bytes", 65537},
              {"payload_bytes", true},
              {"reference", %{}}
            ],
            do: invalid("artifact", mutate_object.(Map.put(hd(objects), key, value)))

    no_io =
      for {kind, variant} <- [
            {"context", "bad-credential"},
            {"target", "bad-id"},
            {"artifact", "bad-ref"}
          ],
          do: %{mode: Enum.join([kind, "input", "temperature", variant], "|"), exchanges: []}

    boundary_sources =
      Enum.map(0..31, fn index ->
        Map.put(
          row,
          "source_ref",
          "source:" <> String.pad_leading(Integer.to_string(index), 2, "0")
        )
      end)

    boundaries = [
      one("sources", %{sources | "sources" => boundary_sources}, "valid", variant: "32"),
      invalid("sources", %{sources | "sources" => Enum.reverse(boundary_sources)}),
      invalid("target", %{target | "selection_generation" => 81, "resource_revision" => 80}),
      one("artifact", nil, "guard",
        response: %{"api_version" => 1, "outcome" => "not_found"},
        after: identity(%{"store_revision" => 101})
      )
    ]

    valid ++
      boundaries ++
      closed ++ bad_context ++ bad_sources ++ bad_targets ++ bad_absent ++ bad_artifact ++ no_io
  end
end

defmodule Mix.Tasks.Woh.Native.External.Guidance.Smoke do
  @moduledoc """
  Checks native external-profile guidance decoding and controller identity guards.

  Run from the repository root with an Apple Silicon macOS Swift 6 toolchain:

      mix woh.native.external.guidance.smoke
      mix woh.native.external.guidance.smoke --live

  The default run compiles the Swift client for macOS 15 and checks exact request
  sequences against private fixture peers. Cases cover context, source catalogue,
  target basis and retained inspection manifests, including the 32-source bound,
  malformed metadata, missing results, refusals, lost replies and identity drift.
  Frozen manifests and an independent array/hash builder supply expectations;
  these peers create no source publisher, mutation, signing backend or device
  effect.

  `--live` additionally exercises both fixture families against disposable
  `WotexHome.Durable.Store` instances and private `WotexHome.LocalAPI.Server`
  sockets. The reads follow `WotexHome.Authority.external_profile_context/2`,
  `WotexHome.Authority.external_source_catalogue/2`,
  `WotexHome.Authority.external_target_basis/3` and
  `WotexHome.Authority.external_inspection_artifact/3`; metadata remains a
  snapshot, not approval or target-selection authority.

  Success prints the independent peer case count after all selected checks pass;
  reported check failures raise `Mix.Error`. This is software fixture evidence,
  not installed-app or physical-device qualification.
  """

  use Mix.Task
  @shortdoc "Check bounded native external guidance reads"
  @requirements ["loadpaths"]
  def run(args) when args in [[], ["--live"]] do
    with {:ok, count} <- Woh.Tool.NativeExternalGuidance.run(File.cwd!()),
         :ok <-
           if(args == ["--live"],
             do: Woh.Tool.NativeExternalProfileLive.run(File.cwd!(), true),
             else: :ok
           ),
         do:
           Mix.shell().info(
             "native external guidance passed #{count} independently sequenced cases"
           ),
         else: ({:error, reason} -> Mix.raise("native external guidance failed: #{reason}"))
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.guidance.smoke [--live]")
end
