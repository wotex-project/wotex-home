defmodule Mix.Tasks.Woh.Native.Generation.Original.Smoke do
  @moduledoc """
  Checks native complete generation originals and immutable reservation receipts.

  Run `mix woh.native.generation.original.smoke` on the supported macOS
  toolchain. The task checks the independent frozen vectors against their
  Elixir owners, then compiles the pure Swift codec and runs normal, malformed,
  byte-boundary and receipt-correspondence cases under finite deadlines.

  This check sends no request and opens no model, credential or pending journal.
  Its evidence does not establish native submission, installed signing, model
  completion, source review or physical qualification.
  """

  use Mix.Task
  alias Woh.Tool.Command
  alias WotexHome.Profiles.{GenerationPreparation, GenerationAttempt}
  @requirements ["loadpaths"]
  @shortdoc "Check native generation originals and original reservation correspondence"

  def run([]) do
    cases = cases()

    root =
      Path.join(
        "/private/tmp",
        "generation-original-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "codec")
    fixture = Path.join(root, "cases.json")
    File.write!(fixture, JSON.encode!(cases))
    File.chmod!(fixture, 0o600)

    args =
      [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-whole-module-optimization",
        "-Onone",
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(root, "cache")
      ] ++
        Enum.map(
          ~w(LocalHealthClient NativeGenerationOriginalWire),
          &Path.expand("native/macos/Sources/#{&1}.swift")
        ) ++
        [Path.expand("native/macos/Tests/NativeGenerationOriginalSmoke.swift"), "-o", executable]

    try do
      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <- Command.run_diagnostic(executable, [fixture], 16_384, 20_000),
           true <-
             String.trim(output) ==
               "native generation #{length(cases)} complete-original and reservation cases passed",
           do: Mix.shell().info(String.trim(output)),
           else: (
             {:error, reason} -> Mix.raise("native generation original smoke failed: #{reason}")
             _ -> Mix.raise("native generation original fixture did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.generation.original.smoke")

  defp cases do
    vectors =
      JSON.decode!(File.read!("test/fixtures/profiles/native-generation-originals.json"))["cases"]

    Enum.flat_map(vectors, fn v ->
      codec = if v["kind"] == "preparation", do: GenerationPreparation, else: GenerationAttempt

      unless codec.encode(v["input"]) == {:ok, v["document"]} and
               codec.encode_receipt(v["receipt"]) == {:ok, v["receipt_document"]},
             do: Mix.raise("independent generation vector drift")

      base = [
        valid(v, "native", JSON.encode!(v["input"])),
        valid(v, "canonical", v["document"]),
        valid(v, "receipt", v["receipt_document"]),
        if(v["match_valid"] == false,
          do: invalid(v, "receipt_match", v["receipt_document"]),
          else: valid(v, "receipt_match", v["receipt_document"])
        ),
        valid(v, "receipt_native", JSON.encode!(v["receipt"]))
      ]

      native_max = if v["kind"] == "preparation", do: 131_072, else: 8192
      canonical_max = if v["kind"] == "preparation", do: 32768, else: 2048
      bytes = JSON.encode!(v["input"])

      common = [
        Map.put(v["input"], "authority_epoch", true),
        Map.put(v["input"], "authority_epoch", 0),
        Map.put(v["input"], "expected_revision", 1.0),
        Map.put(v["input"], "expected_revision", -1),
        Map.put(v["input"], "expected_revision", 9_223_372_036_854_775_808),
        Map.put(v["input"], "operation_id", "x y"),
        Map.put(v["input"], "extra", true),
        Map.delete(v["input"], "operation_id")
      ]

      receipts =
        for {key, value} <- [
              {"authority_epoch", false},
              {"revision", 1.0},
              {"input_sha256", "bad"},
              {"provider_sha256", "BAD"},
              {"disposition", "candidate"},
              {"extra", true}
            ],
            do: Map.put(v["receipt"], key, value)

      receipt_fields =
        if v["kind"] == "preparation",
          do:
            ~w(authority_epoch operation_id revision input_sha256 projection_sha256 basis_sha256 provider_sha256 policy_sha256 disposition),
          else:
            ~w(authority_epoch operation_id revision input_sha256 preparation_sha256 attempt handoff_sha256 provider_sha256 disposition)

      wrong_matches =
        for {key, value} <- [
              {"operation_id", "other:original"},
              {"authority_epoch", 1},
              {"revision", 1},
              {"input_sha256", String.duplicate("f", 64)}
            ],
            changed = Map.put(v["receipt"], key, value),
            changed != v["receipt"],
            do: changed

      mismatches =
        if v["kind"] == "preparation",
          do: [
            Map.put(v["receipt"], "provider_sha256", String.duplicate("f", 64)),
            Map.put(v["receipt"], "policy_sha256", String.duplicate("f", 64))
          ],
          else: [
            Map.put(v["receipt"], "preparation_sha256", String.duplicate("f", 64)),
            Map.put(v["receipt"], "attempt", if(v["receipt"]["attempt"] == 1, do: 2, else: 1))
          ]

      base ++
        Enum.map(receipts, &invalid(v, "receipt_native", JSON.encode!(&1))) ++
        [
          valid(v, "native", bytes <> String.duplicate(" ", native_max - byte_size(bytes))),
          invalid(v, "native", bytes <> String.duplicate(" ", native_max + 1 - byte_size(bytes))),
          invalid(v, "canonical", String.duplicate("x", canonical_max + 1)),
          invalid(v, "canonical", " " <> v["document"]),
          invalid(v, "canonical", v["document"] <> " "),
          invalid(v, "native", "{\"authority_epoch\":1,\"authority_epoch\":1}"),
          invalid(v, "native", <<255>>)
        ] ++
        Enum.map(
          common ++ mutations(v["kind"], v["input"]),
          &invalid(v, "native", JSON.encode!(&1))
        ) ++
        Enum.map(
          receipts,
          &invalid(
            v,
            "receipt",
            JSON.encode!(Enum.map(receipt_fields, fn key -> &1[key] end)) <>
              if(Map.has_key?(&1, "extra"), do: "null", else: "")
          )
        ) ++
        Enum.map(
          wrong_matches ++ mismatches,
          &invalid(
            v,
            "receipt_match",
            JSON.encode!(Enum.map(receipt_fields, fn key -> &1[key] end))
          )
        )
    end)
  end

  defp mutations("attempt", input) do
    [
      Map.put(input, "attempt", false),
      Map.put(input, "attempt", 4),
      Map.put(input, "repair_export", !input["repair_export"]),
      Map.put(input, "preparation_sha256", "bad"),
      Map.put(input, "preparation_operation_id", "bad id"),
      Map.put(
        input,
        "previous_operation_id",
        if(input["attempt"] == 1, do: "previous:bad", else: nil)
      )
    ]
  end

  defp mutations("preparation", input) do
    limits = %{
      "max_passages" => 32,
      "max_passage_bytes" => 4096,
      "max_passages_bytes" => 131_072,
      "max_examples" => 32,
      "max_examples_bytes" => 262_144,
      "max_input_bytes" => 1_048_576
    }

    reference = %{"object_digest" => String.duplicate("f", 64), "first_revision" => 1}
    passage = %{"reference" => reference, "offset" => 0, "length" => 1}
    template = put_in(input, ["projection", "passages"], [passage])

    handles =
      for n <- 0..32,
          do: %{
            "object_digest" =>
              n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"),
            "first_revision" => 1
          }

    passages = Enum.map(handles, &%{"reference" => &1, "offset" => 0, "length" => 1})

    common = [
      Map.put(input, "provider_sha256", "bad"),
      Map.put(input, "policy_sha256", "bad"),
      Map.put(input, "remote_export", 1),
      put_in(input, ["budget", "attempts"], 4),
      put_in(input, ["budget", "attempt_ms"], 30001),
      put_in(input, ["budget", "total_ms"], 120_001),
      put_in(input, ["budget", "total_ms"], 0),
      put_in(input, ["budget"], %{"attempts" => 1, "attempt_ms" => 2, "total_ms" => 1}),
      put_in(input, ["projection", "instruction"], "bad\r"),
      put_in(input, ["projection", "instruction"], String.duplicate("x", 4097)),
      put_in(input, ["projection", "contract_digest"], "bad"),
      put_in(input, ["projection", "passages"], [passage, passage]),
      put_in(input, ["projection", "examples"], [reference, reference]),
      put_in(input, ["projection", "passages"], passages),
      put_in(input, ["projection", "examples"], handles),
      put_in(input, ["projection", "passages"], Enum.reverse(Enum.take(passages, 2))),
      put_in(input, ["projection", "examples"], Enum.reverse(Enum.take(handles, 2))),
      put_in(template, ["projection", "passages", Access.at(0), "offset"], 262_145),
      put_in(template, ["projection", "passages", Access.at(0), "length"], 4097),
      put_in(
        template,
        ["projection", "passages", Access.at(0), "reference", "first_revision"],
        true
      ),
      put_in(template, ["projection", "examples"], [Map.put(reference, "first_revision", 2)])
    ]

    common ++
      for {key, maximum} <- limits,
          bad <- [0, true, maximum + 1],
          do: put_in(input, ["projection", "limits", key], bad)
  end

  defp valid(v, mode, bytes),
    do: %{
      "kind" => v["kind"],
      "mode" => mode,
      "bytes" => Base.encode64(bytes),
      "valid" => true,
      "canonical" => Base.encode64(v["document"]),
      "sha" => v["sha256"],
      "original" => Base.encode64(v["document"])
    }

  defp invalid(v, mode, bytes),
    do: %{
      "kind" => v["kind"],
      "mode" => mode,
      "bytes" => Base.encode64(bytes),
      "valid" => false,
      "original" => Base.encode64(v["document"])
    }
end
