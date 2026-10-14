defmodule Mix.Tasks.Woh.Native.Authoring.Mutation.Smoke do
  use Mix.Task
  alias Woh.Tool.Command
  alias WotexHome.Profiles.{AuthoringImport, AuthoringReview}
  @requirements ["loadpaths"]
  @shortdoc "Check closed native authoring transfer and receipt recovery peers"
  def run([]) do
    root =
      Path.join(
        "/private/tmp",
        "authoring-mutation-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "mutation")
    fixture = Path.join(root, "cases.json")
    cases = cases()

    try do
      File.write!(fixture, JSON.encode!(cases))
      File.chmod!(fixture, 0o600)

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-target",
          "arm64-apple-macos15.0",
          "-module-cache-path",
          Path.join(root, "cache")
        ] ++
          Enum.map(
            ~w(LocalHealthClient NativeSetupWire NativeTargetWire NativeRuleOperationWire NativeRuleClient NativeScheduleWire NativeScheduleClient NativeAuthoringReadClient NativeAuthoringOriginalWire NativePendingCodec NativePendingAuthoring NativeAuthoringMutationClient),
            &Path.expand("native/macos/Sources/#{&1}.swift")
          ) ++
          [Path.expand("native/macos/Tests/NativeAuthoringMutationSmoke.swift"), "-o", executable]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <- Command.run_diagnostic(executable, [fixture], 16_384, 30_000),
           true <-
             String.trim(output) ==
               "native authoring #{length(cases)} mutation transfer and original-recovery peer cases passed",
           do: Mix.shell().info(String.trim(output)),
           else: (
             {:error, reason} -> Mix.raise("native authoring mutation smoke failed: #{reason}")
             _ -> Mix.raise("native authoring mutation fixture did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.authoring.mutation.smoke")

  defp cases do
    bytes = :binary.copy(<<255>>, 262_144)
    raw = :crypto.hash(:sha256, bytes)
    frame = <<"WOHA", 1, 1, 262_144::32, raw::binary, bytes::binary>>

    summary = %{
      "kind" => "source",
      "object_digest" => sha(frame),
      "payload_sha256" => sha(bytes),
      "payload_bytes" => byte_size(bytes)
    }

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "import:1",
      "expected_revision" => 1,
      "object" => summary
    }

    {:ok, document} = AuthoringImport.encode(input)

    imported = %{
      "authority_epoch" => 1,
      "operation_id" => "import:1",
      "revision" => 2,
      "first_revision" => 2,
      "object" => summary
    }

    imports = cases_for("import", document, bytes, imported)
    candidate = vector("authoring-candidate")

    candidates =
      for mode <- ~w(valid missing lost-final malformed-final wrong-receipt refused-final),
          do: entry("candidate", mode, candidate["input_document"], nil, candidate["receipt"])

    review = vector("authoring-review")

    evidence =
      for n <- 0..255,
          do: %{
            "instance_path" => "/profile/binding",
            "source_ref" => String.duplicate("a", 64),
            "locator" =>
              String.pad_leading(Integer.to_string(n), 3, "0") <> String.duplicate("x", 250)
          }

    large = put_in(review["input"], ["review", "evidence"], evidence)
    {:ok, large_document} = AuthoringReview.encode(large)
    unless byte_size(large_document) > 65_536, do: Mix.raise("large review fixture is too small")
    receipt = Map.put(review["receipt"], "input_sha256", sha(large_document))
    imports ++ candidates ++ cases_for("review", large_document, nil, receipt)
  end

  defp cases_for(kind, document, payload, receipt),
    do:
      for(
        mode <-
          ~w(valid missing replay lost-begin lost-before lost-after changed-owner stale-success lost-final malformed-final wrong-receipt refused-final cleanup-failed),
        do: entry(kind, mode, document, payload, receipt)
      )

  defp entry(kind, mode, document, payload, receipt),
    do: %{
      "kind" => kind,
      "mode" => mode,
      "canonical" => Base.encode64(document),
      "payload" => if(payload, do: Base.encode64(payload), else: nil),
      "receipt" => receipt
    }

  defp vector(name), do: JSON.decode!(File.read!("test/fixtures/profiles/" <> name <> ".json"))
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
