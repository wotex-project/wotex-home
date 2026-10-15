defmodule Mix.Tasks.Woh.Native.External.Mutation.Smoke do
  @moduledoc """
  Checks fixed external-profile delivery against complete originals and framed peers.

  Run `mix woh.native.external.mutation.smoke` on the supported macOS toolchain.
  Independent receipts exercise every original-derived join; private framed peers
  check status-first retry, exact wrappers, identity races and uncertainty after
  a possible mutation. Credentials are public synthetic fixture bytes.

  Add `--live` to exercise both quantity families against real SQLite and Unix
  sockets, including dropped commit replies, separate-process pending recovery,
  source withdrawal, explicit missing acknowledgement and failed publication.
  Live credentials travel on stdin and fixtures use disposable private directories.

  These checks establish the typed client boundary, not installed signing, current
  source presence, physical qualification or a current target grant.
  """

  use Mix.Task
  alias Woh.Tool.NativeFixture
  @requirements ["loadpaths"]
  @shortdoc "Check fixed native external-profile mutations and receipt joins"

  def run([]) do
    vectors =
      JSON.decode!(File.read!("test/fixtures/profiles/native-external-profile-sdk.json"))["cases"]

    accepted = Enum.filter(vectors, & &1["accepted"])

    cases =
      [%{mode: "corpus", exchanges: []}] ++
        Enum.flat_map(accepted, &normal/1) ++
        adverse(hd(accepted)) ++ watermark(List.last(accepted))

    sources =
      ~w(NativeExternalProfileClient NativeExternalProfileOriginalWire NativeExternalProfileMutationClient)

    case NativeFixture.run(
           File.cwd!(),
           "NativeExternalProfileMutationSmoke.swift",
           cases,
           sources
         ) do
      :ok ->
        Mix.shell().info(
          "native external SDK passed 176 independent joins and #{length(cases) - 1} framed delivery cases"
        )

      {:error, reason} ->
        Mix.raise("native external mutation smoke failed: #{reason}")
    end
  end

  def run(["--live"]) do
    case Woh.Tool.NativeExternalMutationLive.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native external SDK both-family Store, lost reply, pending restart, retry, absence and refusal workflows passed"
        )

      {:error, reason} ->
        Mix.raise("native external SDK live failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.mutation.smoke [--live]")

  defp request(operation, fields \\ %{}),
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
          "authority_epoch" => 1,
          "store_revision" => 100,
          "principal_id" => "operator:sdk"
        },
        changes
      )

  defp ok(member, value), do: %{"api_version" => 1, "outcome" => "ok", member => value}
  defp missing, do: %{"api_version" => 1, "outcome" => "not_found"}
  defp error(reason), do: %{"api_version" => 1, "outcome" => "error", "reason" => reason}

  defp identity_exchange(value \\ identity()),
    do: {request("controller_identity"), ok("controller_identity", value)}

  defp receipt(row), do: ok("external_#{row["kind"]}_receipt", row["receipt"])

  defp status(row, reply) do
    [_, [epoch, operation | _]] = JSON.decode!(row["document"])

    {request("external_#{row["kind"]}_status", %{
       "authority_epoch" => epoch,
       "operation_id" => operation
     }), reply}
  end

  defp mutation(row, reply) do
    codec =
      case row["kind"] do
        "inspection" -> WotexHome.Profiles.ExternalInspection
        "trust" -> WotexHome.Profiles.ExternalTrust
        "target" -> WotexHome.Profiles.ExternalTarget
      end

    {:ok, fields} = codec.decode(row["document"])

    operation =
      if row["kind"] == "inspection",
        do: "external_profile_inspect",
        else: "external_#{row["kind"]}_change"

    wrapper = if row["kind"] == "inspection", do: "inspection", else: "change"
    {request(operation, %{wrapper => fields}), reply}
  end

  defp one(row, action, expected, exchanges),
    do: %{mode: Enum.join([row["name"], action, expected], "|"), exchanges: exchanges}

  defp normal(row) do
    final =
      identity_exchange(identity(%{"store_revision" => max(100, row["receipt"]["revision"])}))

    [
      one(row, "lookup", "valid", [
        identity_exchange(),
        status(row, receipt(row)),
        final
      ]),
      one(row, "retry", "valid", [
        identity_exchange(),
        status(row, receipt(row)),
        final
      ]),
      one(row, "lookup", "missing", [
        identity_exchange(),
        status(row, missing()),
        final
      ]),
      one(row, "retry", "valid", [
        identity_exchange(),
        status(row, missing()),
        mutation(row, receipt(row)),
        final
      ])
    ]
  end

  defp watermark(row) do
    [
      one(row, "lookup", "guard", [
        identity_exchange(),
        status(row, receipt(row)),
        identity_exchange()
      ]),
      one(row, "retry", "unknown", [
        identity_exchange(),
        status(row, missing()),
        mutation(row, receipt(row)),
        identity_exchange()
      ])
    ]
  end

  defp adverse(row) do
    initial = identity_exchange()
    found = status(row, receipt(row))
    absent = status(row, missing())
    sent = mutation(row, receipt(row))

    identity_changes = [
      %{"owner_id" => String.duplicate("e", 64)},
      %{"deployment_id" => String.duplicate("e", 64)},
      %{"principal_id" => "operator:other"},
      %{"authority_epoch" => 2},
      %{"store_revision" => 89}
    ]

    before =
      for change <- identity_changes,
          do: one(row, "retry", "guard", [identity_exchange(identity(change))])

    after_read =
      for change <- identity_changes,
          do: one(row, "lookup", "guard", [initial, found, identity_exchange(identity(change))])

    after_send =
      for change <- identity_changes,
          do:
            one(row, "retry", "unknown", [
              initial,
              absent,
              sent,
              identity_exchange(identity(change))
            ])

    after_read ++
      before ++
      after_send ++
      [
        one(row, "lookup", "valid", [
          initial,
          found,
          identity_exchange(identity(%{"store_revision" => 101}))
        ]),
        one(row, "retry", "valid", [
          initial,
          absent,
          sent,
          identity_exchange(identity(%{"store_revision" => 101}))
        ]),
        one(row, "lookup", "refused", [initial, status(row, error("permission_denied"))]),
        one(row, "retry", "refused", [initial, absent, mutation(row, error("permission_denied"))]),
        one(row, "retry", "unknown", [initial, absent, mutation(row, error("outcome_unknown"))]),
        one(row, "retry", "unknown", [initial, absent, mutation(row, :close)]),
        one(row, "retry", "unknown", [initial, absent, mutation(row, missing())]),
        one(row, "retry", "unknown", [
          initial,
          absent,
          mutation(row, %{"api_version" => 1, "outcome" => "ok"})
        ]),
        one(row, "retry", "unknown", [
          initial,
          absent,
          sent,
          {request("controller_identity"), :close}
        ]),
        one(row, "retry", "unknown", [
          initial,
          absent,
          sent,
          {request("controller_identity"), error("unauthorized")}
        ]),
        one(row, "retry", "unknown", [
          initial,
          absent,
          sent,
          {request("controller_identity"), error("permission_denied")}
        ]),
        one(row, "retry-old", "guard", [
          identity_exchange(identity(%{"authority_epoch" => 2})),
          absent
        ]),
        one(row, "retry-old", "valid", [
          identity_exchange(identity(%{"authority_epoch" => 2})),
          found,
          identity_exchange(identity(%{"authority_epoch" => 2}))
        ]),
        one(row, "lookup", "lost", [initial, status(row, :close)]),
        one(row, "lookup", "invalid", [initial, status(row, error("private:malformed reason"))]),
        one(row, "retry", "unknown", [
          initial,
          absent,
          mutation(row, error("private:malformed reason"))
        ]),
        one(row, "lookup", "invalid", [
          initial,
          status(
            row,
            receipt(
              Map.update!(
                row,
                "receipt",
                &Map.put(&1, "reader_basis_sha256", String.duplicate("0", 64))
              )
            )
          )
        ]),
        one(row, "retry", "unknown", [
          initial,
          absent,
          mutation(
            row,
            receipt(
              Map.update!(
                row,
                "receipt",
                &Map.put(&1, "reader_basis_sha256", String.duplicate("0", 64))
              )
            )
          )
        ]),
        one(row, "lookup", "input", [])
      ]
  end
end
