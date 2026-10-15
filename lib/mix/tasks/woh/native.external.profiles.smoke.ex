defmodule Woh.Tool.NativeExternalProfileReads do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    cases = originals() ++ catalogues() ++ guards() ++ identity_errors()

    with :ok <-
           NativeFixture.run(project, "NativeExternalProfileReadSmoke.swift", cases, [
             "NativeExternalProfileClient"
           ]),
         do: {:ok, length(cases)}
  end

  defp base(operation, fields \\ %{}),
    do:
      Map.merge(
        %{
          "api_version" => 1,
          "operation" => operation,
          "credential" => NativeFixture.credential()
        },
        fields
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

  defp envelope(member, value), do: %{"api_version" => 1, "outcome" => "ok", member => value}
  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp one(kind, expected, response, options \\ []) do
    epoch = Keyword.get(options, :epoch, 1)
    operation = Keyword.get(options, :operation, "original:read")
    sha = Keyword.get(options, :sha, "")
    count = Keyword.get(options, :count, 0)
    before = Keyword.get(options, :before, identity())
    after_identity = Keyword.get(options, :after, before)

    domain =
      if kind == "catalogue",
        do: base("external_profiles"),
        else:
          base("external_#{kind}_status", %{
            "authority_epoch" => epoch,
            "operation_id" => operation
          })

    exchanges = [
      {base("controller_identity"), envelope("controller_identity", before)},
      {domain, response}
    ]

    exchanges =
      if expected in ["valid", "missing", "guard"],
        do:
          exchanges ++
            [{base("controller_identity"), envelope("controller_identity", after_identity)}],
        else: exchanges

    %{
      mode:
        Enum.join(
          [
            kind,
            expected,
            if(kind == "catalogue", do: count, else: epoch),
            if(kind == "catalogue", do: "", else: operation),
            sha
          ],
          "|"
        ),
      exchanges: exchanges
    }
  end

  defp original(kind, expected, receipt, options \\ []) do
    one(
      kind,
      expected,
      envelope("external_#{kind}_receipt", receipt),
      Keyword.put_new(options, :operation, receipt["operation_id"])
    )
  end

  defp originals do
    for family <- ~w(temperature research),
        {kind, receipts} <- [
          {"inspection", [fixture("external-inspections")[family]["receipt"]]},
          {"trust",
           Enum.map(~w(approve revoke), &fixture("external-trust")[family][&1]["receipt"])},
          {"target",
           Enum.map(
             ~w(select revoke),
             &fixture("external-target-selections")[family][&1]["receipt"]
           )}
        ],
        receipt <- receipts,
        reduce: [] do
      acc ->
        positives =
          for {key, value} <- receipt,
              is_integer(value) and value > 0 and
                key not in ~w(previous_trust_revision previous_selection_revision resource_revision withdrawn_grants),
              bad <- [0, -1, true, 1.0, "1", nil, 9_223_372_036_854_775_808],
              do: original(kind, "invalid", Map.put(receipt, key, bad))

        digests =
          for {key, value} <- receipt,
              is_binary(value) and
                (String.ends_with?(key, "sha256") or key in ~w(artifact_digest capture_digest)),
              bad <- ["bad", String.upcase(value), nil],
              bad != value,
              do: original(kind, "invalid", Map.put(receipt, key, bad))

        unknown =
          for key <- Map.keys(receipt),
              do:
                original(kind, "invalid", Map.delete(receipt, key),
                  operation: receipt["operation_id"]
                )

        acc ++
          [
            original(kind, "valid", receipt),
            original(kind, "valid", receipt, sha: receipt["input_sha256"]),
            original(kind, "invalid", receipt, sha: String.duplicate("0", 64)),
            original(kind, "invalid", Map.put(receipt, "extra", true)),
            one(kind, "invalid", envelope("external_wrong_receipt", receipt),
              operation: receipt["operation_id"]
            ),
            original(kind, "invalid", Map.put(receipt, "authority_epoch", 2)),
            original(kind, "invalid", receipt, operation: "other:read")
          ] ++ positives ++ digests ++ unknown
    end
  end

  defp item(index \\ 0),
    do: %{
      "artifact_digest" =>
        index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"),
      "id" => "external:" <> String.pad_leading(Integer.to_string(index), 2, "0"),
      "version" => "1.0.0",
      "trust_revision" => 90,
      "trust_generation" => 1,
      "trust_author" => "operator:read",
      "state" => "approved",
      "reader_basis_sha256" => String.duplicate("d", 64)
    }

  defp catalogue(items, changes \\ %{}),
    do:
      envelope(
        "external_profile_catalogue",
        Map.merge(
          %{
            "authority_epoch" => 2,
            "store_revision" => 100,
            "policy_generation" => 1,
            "items" => items
          },
          changes
        )
      )

  defp catalogues do
    item = item()

    valid = [
      one("catalogue", "valid", catalogue([]), count: 0),
      one("catalogue", "valid", catalogue([item]), count: 1),
      one("catalogue", "valid", catalogue(Enum.map(0..63, &item/1)), count: 64),
      one(
        "catalogue",
        "valid",
        catalogue([%{item | "state" => "revoked", "reader_basis_sha256" => nil}]),
        count: 1
      ),
      one("catalogue", "valid", catalogue([%{item | "state" => "author_unavailable"}]), count: 1),
      one(
        "catalogue",
        "valid",
        catalogue([
          %{item | "version" => "1.10.0"},
          %{item(1) | "id" => item["id"], "version" => "1.2.0"}
        ]),
        count: 2
      )
    ]

    invalid_items =
      for {key, value} <- [
            {"extra", true},
            {"id", "bad/id"},
            {"version", "01.0.0"},
            {"version", "65536.0.0"},
            {"version", "1.0"},
            {"trust_revision", 101},
            {"trust_revision", 0},
            {"trust_revision", true},
            {"trust_generation", 2},
            {"trust_generation", 1.0},
            {"trust_author", "bad/id"},
            {"state", "active"},
            {"state", "revoked"},
            {"reader_basis_sha256", nil},
            {"artifact_digest", "bad"}
          ],
          do: one("catalogue", "invalid", catalogue([Map.put(item, key, value)]))

    invalid_catalogues =
      for {key, value} <- [
            {"extra", true},
            {"authority_epoch", 0},
            {"store_revision", true},
            {"policy_generation", -1},
            {"policy_generation", 101},
            {"policy_generation", 1.0},
            {"items", Enum.map(0..64, &item/1)},
            {"items", [item, item]},
            {"items", [item(1), item]}
          ],
          do: one("catalogue", "invalid", catalogue([item], %{key => value}))

    valid ++
      invalid_items ++
      invalid_catalogues ++
      [
        one("catalogue", "guard", catalogue([item]), after: identity(%{"store_revision" => 101})),
        one("catalogue", "guard", catalogue([item], %{"authority_epoch" => 1})),
        one("catalogue", "invalid", %{"api_version" => 1, "outcome" => "not_found"})
      ]
  end

  defp identity_errors do
    malformed = %{"api_version" => 1, "outcome" => "error", "reason" => "private data\n"}
    mode = "inspection|invalid|1|original:read|"

    [
      %{mode: mode, exchanges: [{base("controller_identity"), malformed}]},
      %{
        mode: mode,
        exchanges: [
          {base("controller_identity"), envelope("controller_identity", identity())},
          {base("external_inspection_status", %{
             "authority_epoch" => 1,
             "operation_id" => "original:read"
           }), %{"api_version" => 1, "outcome" => "not_found"}},
          {base("controller_identity"), malformed}
        ]
      }
    ]
  end

  defp guards do
    receipt = fixture("external-inspections")["temperature"]["receipt"]

    changes = [
      %{"deployment_id" => String.duplicate("c", 64)},
      %{"owner_id" => String.duplicate("c", 64)},
      %{"authority_epoch" => 3},
      %{"principal_id" => "operator:other"},
      %{"store_revision" => 99}
    ]

    for kind <- ~w(inspection trust target), reduce: [] do
      acc ->
        acc ++
          [
            one(kind, "missing", %{"api_version" => 1, "outcome" => "not_found"}),
            one(kind, "invalid", %{"api_version" => 1, "outcome" => "not_found", "extra" => true}),
            one(kind, "refused", %{
              "api_version" => 1,
              "outcome" => "error",
              "reason" => "permission_denied"
            }),
            one(kind, "invalid", %{
              "api_version" => 1,
              "outcome" => "error",
              "reason" => "private data\n"
            }),
            one(kind, "lost", :close)
          ] ++
          Enum.map(
            changes,
            &one(kind, "guard", %{"api_version" => 1, "outcome" => "not_found"},
              after: identity(&1)
            )
          )
    end ++
      [
        original("inspection", "guard", Map.put(receipt, "revision", 101)),
        %{mode: "inspection|input|0|invalid:epoch|", exchanges: []},
        %{mode: "trust|input|1|bad/id|", exchanges: []},
        %{mode: "target|input|1|original:read|bad", exchanges: []}
      ]
  end
end

defmodule Mix.Tasks.Woh.Native.External.Profiles.Smoke do
  @moduledoc """
  Checks typed native v2 profile catalogue and immutable original reads.

  Run `mix woh.native.external.profiles.smoke` on the supported macOS toolchain.
  Independent owning receipts for two quantities and framed peer faults check
  exact shapes, counters, catalogue ordering, identity drift, missing originals,
  malformed responses and read-only request correspondence. Pass `--live` for
  both-family SQLite/private socket history, approval/revocation, absent publishers,
  author withdrawal and current permission checks. No custody or mutation
  is added; installed signing and physical qualification require separate evidence.
  """

  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Check native external-profile catalogue and original metadata"
  def run([]) do
    case Woh.Tool.NativeExternalProfileReads.run(File.cwd!()) do
      {:ok, count} ->
        Mix.shell().info("native external profile reads passed #{count} framed cases")

      {:error, reason} ->
        Mix.raise("native external profile reads failed: #{reason}")
    end
  end

  def run(["--live"]) do
    case Woh.Tool.NativeExternalProfileLive.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native external profile reads passed both-family real Store history, catalogue withdrawal and permission checks"
        )

      {:error, reason} ->
        Mix.raise("native external profile live reads failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.profiles.smoke [--live]")
end
