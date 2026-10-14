defmodule Mix.Tasks.Woh.Native.Authoring.Original.Smoke do
  use Mix.Task
  alias Woh.Tool.Command
  alias WotexHome.Profiles.{AuthoringImport, AuthoringCandidate, AuthoringReview}
  @requirements ["loadpaths"]
  @shortdoc "Check complete native authoring originals against owning vectors and adversarial bounds"

  def run([]) do
    cases = cases()

    root =
      Path.join(
        "/private/tmp",
        "authoring-original-codec-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
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
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(root, "cache")
      ] ++
        Enum.map(
          ~w(LocalHealthClient NativeAuthoringReadClient NativeAuthoringOriginalWire),
          &Path.expand("native/macos/Sources/#{&1}.swift")
        ) ++
        [Path.expand("native/macos/Tests/NativeAuthoringOriginalSmoke.swift"), "-o", executable]

    try do
      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <- Command.run_diagnostic(executable, [fixture], 16_384, 20_000),
           true <-
             String.trim(output) ==
               "native authoring #{length(cases)} complete-original cases passed",
           do: Mix.shell().info(String.trim(output)),
           else: (
             {:error, reason} -> Mix.raise("native authoring original smoke failed: #{reason}")
             _ -> Mix.raise("native authoring original fixture did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.authoring.original.smoke")

  defp cases do
    for {kind, file, codec} <- [
          {"import", "authoring-import", AuthoringImport},
          {"candidate", "authoring-candidate", AuthoringCandidate},
          {"review", "authoring-review", AuthoringReview}
        ] do
      vector = JSON.decode!(File.read!("test/fixtures/profiles/" <> file <> ".json"))
      input = vector["input"]
      assert_document = codec.encode(input)

      unless assert_document == {:ok, vector["input_document"]},
        do: Mix.raise("owning vector drift")

      document = vector["input_document"]

      valid = [
        valid(kind, "canonical", document, document),
        valid(kind, "native", JSON.encode!(input), document)
      ]

      bad = [
        Map.put(input, "authority_epoch", true),
        Map.put(input, "authority_epoch", 0),
        Map.put(input, "expected_revision", -1),
        Map.put(input, "expected_revision", 1.5),
        Map.put(input, "expected_revision", 1.0),
        Map.put(input, "authority_epoch", 1.0),
        Map.put(input, "expected_revision", 9_223_372_036_854_775_808),
        Map.put(input, "operation_id", "bad\n"),
        Map.put(input, "operation_id", String.duplicate("x", 129)),
        Map.put(input, "extra", true),
        Map.delete(input, "operation_id")
      ]

      scalar_max =
        input
        |> Map.put("authority_epoch", 9_223_372_036_854_775_807)
        |> Map.put("expected_revision", 9_223_372_036_854_775_807)

      {:ok, max_document} = codec.encode(scalar_max)
      valid = valid ++ [valid(kind, "native", JSON.encode!(scalar_max), max_document)]

      malformed = [
        invalid(kind, "canonical", " " <> document),
        invalid(kind, "canonical", document <> " "),
        invalid(kind, "canonical", String.replace(document, "[", "[null,", global: false)),
        invalid(kind, "native", ~s({"authority_epoch":1,"authority_epoch":1})),
        invalid(kind, "native", <<255>>)
      ]

      {more_valid, more_bad} = domain(kind, input, codec)

      budget =
        if kind == "import", do: 4096, else: if(kind == "candidate", do: 65536, else: 262_144)

      canonical_budget =
        if kind == "import", do: 4096, else: if(kind == "candidate", do: 32768, else: 131_072)

      encoded = JSON.encode!(input)

      boundary = [
        valid(
          kind,
          "native",
          encoded <> String.duplicate(" ", budget - byte_size(encoded)),
          document
        ),
        invalid(
          kind,
          "native",
          encoded <> String.duplicate(" ", budget + 1 - byte_size(encoded))
        ),
        invalid(
          kind,
          "canonical",
          document <> String.duplicate(" ", canonical_budget + 1 - byte_size(document))
        )
      ]

      valid ++
        more_valid ++
        Enum.map(bad ++ more_bad, &invalid(kind, "native", JSON.encode!(&1))) ++
        malformed ++ boundary
    end
    |> List.flatten()
  end

  defp valid(kind, mode, bytes, document),
    do: %{
      "kind" => kind,
      "mode" => mode,
      "bytes" => Base.encode64(bytes),
      "valid" => true,
      "canonical" => Base.encode64(document),
      "sha" => :crypto.hash(:sha256, document) |> Base.encode16(case: :lower)
    }

  defp invalid(kind, mode, bytes),
    do: %{"kind" => kind, "mode" => mode, "bytes" => Base.encode64(bytes), "valid" => false}

  defp examples(kind, inputs, codec) do
    Enum.flat_map(inputs, fn input ->
      {:ok, document} = codec.encode(input)

      [
        valid(kind, "native", JSON.encode!(input), document),
        valid(kind, "canonical", document, document)
      ]
    end)
  end

  defp domain("import", input, codec) do
    kinds =
      for kind <- ~w(source draft bundle fixture contract envelope profile definition),
          size <- [1, if(kind in ~w(source draft bundle contract), do: 262_144, else: 65536)],
          do: put_in(input, ["object", "kind"], kind) |> put_in(["object", "payload_bytes"], size)

    bad =
      for {key, value} <- [
            {"kind", "unknown"},
            {"payload_bytes", false},
            {"payload_bytes", 0},
            {"payload_bytes", 262_145},
            {"object_digest", "bad"},
            {"payload_sha256", String.duplicate("A", 64)}
          ],
          do: put_in(input, ["object", key], value)

    {examples("import", kinds, codec), bad}
  end

  defp domain("candidate", input, codec) do
    reader = %{
      "max_bytes" => 262_144,
      "max_depth" => 8,
      "max_nodes" => 4096,
      "max_channels" => 32,
      "max_definitions" => 32,
      "max_bindings" => 32,
      "max_dependencies" => 32,
      "max_numeric_digits" => 64
    }

    limits = %{
      "max_bundle_bytes" => 262_144,
      "max_diagnostics" => 64,
      "max_report_bytes" => 24576,
      "max_check_steps" => 1_000_000
    }

    handles =
      for n <- 0..31,
          do: %{
            "object_digest" =>
              Integer.to_string(n, 16) |> String.downcase() |> String.pad_leading(64, "0"),
            "first_revision" => 1
          }

    full =
      input
      |> put_in(["request", "limits"], Map.put(limits, "reader", reader))
      |> put_in(["request", "source_refs"], handles)
      |> put_in(["request", "fixture_refs"], handles)

    inputs =
      for instruction <- [
            "private-canary α/β\t\n\"\\",
            String.duplicate("x", 4096),
            "",
            "é é \u2028 \u2029"
          ],
          do: put_in(full, ["request", "instruction"], instruction)

    bad = [
      put_in(full, ["request", "instruction"], String.duplicate("x", 4097)),
      put_in(full, ["request", "instruction"], "bad\r"),
      put_in(full, ["request", "mode"], "generated"),
      put_in(full, ["request", "source_refs"], Enum.reverse(handles)),
      put_in(full, ["request", "source_refs"], [hd(handles), hd(handles)]),
      put_in(full, ["request", "fixture_refs"], handles ++ [hd(handles)]),
      put_in(full, ["request", "base_draft_ref", "first_revision"], true)
    ]

    bad =
      bad ++
        for {key, value} <- reader,
            changed <- [0, true, value + 1],
            do: put_in(full, ["request", "limits", "reader", key], changed)

    bad =
      bad ++
        for {key, value} <- limits,
            changed <- [0, true, value + 1],
            do: put_in(full, ["request", "limits", key], changed)

    {examples("candidate", inputs, codec), bad}
  end

  defp domain("review", input, codec) do
    root = "/profile/binding"

    evidence =
      for n <- 0..255,
          do: %{
            "instance_path" => root,
            "source_ref" => String.duplicate("a", 64),
            "locator" =>
              "private-canary:" <>
                String.pad_leading(Integer.to_string(n), 3, "0") <> String.duplicate("x", 238)
          }

    full = put_in(input, ["review", "evidence"], evidence)

    complete =
      full
      |> put_in(["review", "mode"], "complete")
      |> put_in(["review", "envelope_ref"], %{
        "object_digest" => String.duplicate("b", 64),
        "first_revision" => 1
      })

    inputs = [
      full,
      complete,
      put_in(input, ["review", "evidence"], [
        %{
          "instance_path" => root,
          "source_ref" => String.duplicate("a", 64),
          "locator" => "α/β\"\\"
        }
      ])
    ]

    paths = for n <- 0..31, suffix <- ~w(unit value_schema), do: "/definitions/#{n}/#{suffix}"
    inputs = inputs ++ [put_in(full, ["review", "unresolved_paths"], Enum.sort(paths))]

    unicode =
      for locator <- ["é", "é"],
          do: %{
            "instance_path" => root,
            "source_ref" => String.duplicate("a", 64),
            "locator" => locator
          }

    inputs = inputs ++ [put_in(input, ["review", "evidence"], unicode)]

    bad = [
      put_in(full, ["review", "evidence"], evidence ++ [hd(evidence)]),
      put_in(full, ["review", "evidence"], Enum.reverse(evidence)),
      put_in(full, ["review", "evidence"], [hd(evidence), hd(evidence)]),
      put_in(complete, ["review", "envelope_ref"], nil),
      put_in(full, ["review", "envelope_ref"], %{
        "object_digest" => String.duplicate("b", 64),
        "first_revision" => 1
      }),
      put_in(full, ["review", "candidate_ref", "revision"], false),
      put_in(full, ["review", "unresolved_paths"], [root, root])
    ]

    bad = bad ++ [put_in(full, ["review", "unresolved_paths"], Enum.sort(paths ++ [root]))]

    bad =
      bad ++
        for path <- [
              "/profile/fingerprint/32",
              "/profile/fingerprint/01",
              "/definitions/0/value_schema/extra",
              root <> "\n"
            ],
            do: put_in(full, ["review", "unresolved_paths"], [path])

    bad =
      bad ++
        for locator <- ["", "bad\n", "bad\u200b", String.duplicate("x", 257)],
            do:
              put_in(full, ["review", "evidence"], [
                %{
                  "instance_path" => root,
                  "source_ref" => String.duplicate("a", 64),
                  "locator" => locator
                }
              ])

    {examples("review", inputs, codec), bad}
  end
end
