defmodule Mix.Tasks.Woh.Native.Generation.Sdk.Smoke do
  @moduledoc """
  Checks native generation metadata, complete result codecs and original delivery.

  Run `mix woh.native.generation.sdk.smoke` on the supported macOS toolchain.
  Frozen independent Python responses are cross-checked against
  `WotexHome.Profiles.GenerationOperator` and the owning preparation/attempt
  codecs before Swift validates normal, malformed and original-correspondence
  cases. An in-process JSON transport checks exact unchanged requests, typed
  refusals and lost replies.

  Pass `--wire-only` to run those representation/JSON-transport cases without
  starting the actual Store/socket/process cohorts. The default additionally
  uses the two frozen quantity fixtures through real private Store/socket
  operations, original publication, queued settlement, lost replies and restart.
  Compilation and fixture execution have finite deadlines; failed compilation,
  codec drift or a failed assertion refuses the task rather than reporting success.

  Synthetic credentials stay in process/private fixture custody. No external
  model or Keychain is used. The result establishes the tested software boundary,
  not installed signing, provider quality, source review, profile approval or
  physical qualification.
  """

  use Mix.Task
  alias Woh.Tool.Command

  alias WotexHome.Profiles.{
    AuthoringCandidate,
    GenerationAttempt,
    GenerationOperator,
    GenerationPreparation
  }

  @requirements ["loadpaths"]
  @shortdoc "Check native generation options, complete results and original delivery"

  def run(arguments) when arguments in [[], ["--wire-only"]] do
    wire_only = arguments == ["--wire-only"]
    cases = cases()

    root =
      Path.join(
        "/private/tmp",
        "generation-sdk-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "sdk")
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
          if(wire_only,
            do: ~w(LocalHealthClient NativeGenerationOriginalWire NativeGenerationClient),
            else:
              ~w(LocalHealthClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativePrivateDocuments NativeNetworkPreferences NativeRuleOperationWire NativeRuleClient NativeScheduleWire NativeScheduleClient NativeAuthoringReadClient NativeAuthoringOriginalWire NativePendingAuthoring NativeGenerationOriginalWire NativeGenerationClient NativePendingCodec NativePendingStorage NativeAuthoringMutationClient NativePendingRecoveryOperations)
          ),
          &Path.expand("native/macos/Sources/#{&1}.swift")
        ) ++
        [
          Path.expand("native/macos/Tests/NativeGenerationSDKSmoke.swift"),
          "-o",
          executable
        ]

    args =
      if wire_only,
        do: args ++ ["-D", "WOH_NATIVE_SDK_WIRE_ONLY"],
        else: args ++ [Path.expand("native/macos/Tests/NativeGenerationStoreSmoke.swift")]

    try do
      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <- Command.run_diagnostic(executable, [fixture], 16_384, 30_000),
           :ok <- store_checks(executable, root, wire_only),
           true <-
             String.trim(output) ==
               "native generation #{length(cases)} SDK codec and original-delivery cases passed",
           do: Mix.shell().info(String.trim(output)),
           else: (
             {:error, reason} -> Mix.raise("native generation SDK smoke failed: #{reason}")
             _ -> Mix.raise("native generation SDK fixture did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.generation.sdk.smoke [--wire-only]")

  defp store_checks(_, _, true), do: :ok

  defp store_checks(executable, root, false),
    do: Woh.Tool.NativeGenerationStoreSmoke.run(executable, root)

  defp cases do
    vectors =
      JSON.decode!(File.read!("test/fixtures/profiles/native-generation-sdk.json"))["cases"]

    Enum.flat_map(vectors, fn v ->
      request = request(v)

      unless GenerationOperator.validate_response(request, v["response"]) == :ok,
        do: Mix.raise("frozen generation SDK response drifted from its owner")

      if v["result_document"] do
        result = v["response"]["authoring_generation_attempt"]["result"]

        unless GenerationAttempt.encode_result(result) == {:ok, v["result_document"]},
          do: Mix.raise("frozen generation result bytes drifted")

        if v["assessment_document"] &&
             AuthoringCandidate.encode_assessment(result["assessment"]) !=
               {:ok, v["assessment_document"]},
           do: Mix.raise("frozen generation assessment bytes drifted")
      end

      [
        entry(v, v["response"], true),
        Map.put(entry(v, v["response"], true), "mode", "native_integer")
      ] ++
        [
          entry(v, Map.put(v["response"], "extra", nil), false),
          entry(v, Map.put(v["response"], "api_version", true), false)
        ] ++
        Enum.map(paths(v["response"]), fn path ->
          entry(v, put_path(v["response"], path ++ ["extra"], nil), false)
        end) ++
        scalar_cases(v) ++
        canonical_cases(v) ++ collection_cases(v) ++ constraints(v) ++ peer_cases(v)
    end)
  end

  defp request(v) do
    input =
      if v["original"] do
        codec = if v["kind"] == "preparation", do: GenerationPreparation, else: GenerationAttempt
        {:ok, input} = codec.decode(v["original"])
        input
      else
        %{}
      end

    Map.merge(Map.take(input, ~w(authority_epoch operation_id)), %{
      "operation" => v["operation"],
      "input" => input
    })
  end

  defp entry(v, response, valid),
    do:
      Map.merge(
        Map.take(
          v,
          if(valid,
            do: ~w(operation original kind result_document assessment_document),
            else: ~w(operation original kind)
          )
        ),
        %{
          "mode" => "response",
          "bytes" => Base.encode64(JSON.encode!(response)),
          "valid" => valid
        }
      )

  defp canonical_cases(v) do
    cases =
      for {field, mode} <- [{"result_document", "result"}, {"assessment_document", "assessment"}],
          bytes = v[field],
          is_binary(bytes),
          {value, valid} <- [
            {bytes, true},
            {" " <> bytes, false},
            {bytes <> " ", false},
            {"{}", false}
          ],
          do:
            Map.merge(Map.take(v, ~w(operation original kind)), %{
              "mode" => mode,
              "bytes" => Base.encode64(value),
              "valid" => valid
            })

    if v["oversized_assessment_document"],
      do:
        cases ++
          [
            Map.merge(Map.take(v, ~w(operation original kind)), %{
              "mode" => "assessment",
              "bytes" => Base.encode64(v["oversized_assessment_document"]),
              "valid" => false
            })
          ],
      else: cases
  end

  defp collection_cases(v) do
    fields = v["response"]["authoring_generation_options"]
    result = v["response"]["authoring_generation_attempt"]["result"]

    cond do
      is_map(fields) and length(fields["policies"]) == 32 ->
        policies = fields["policies"]

        for altered <- [
              policies ++ [hd(policies)],
              Enum.reverse(policies),
              List.replace_at(policies, 31, hd(policies))
            ],
            do:
              entry(
                v,
                put_path(v["response"], ["authoring_generation_options", "policies"], altered),
                false
              )

      is_map(result) and is_map(result["assessment"]) ->
        path = ["authoring_generation_attempt", "result", "assessment", "report", "diagnostics"]
        diagnostics = result["assessment"]["report"]["diagnostics"]

        if diagnostics == [],
          do: [],
          else: [
            entry(v, put_path(v["response"], path, List.duplicate(hd(diagnostics), 65)), false)
          ]

      true ->
        []
    end
  end

  defp samples(list) do
    positions = [0, div(length(list), 2), length(list) - 1]
    Enum.filter(Enum.with_index(list), fn {_, i} -> i in positions end)
  end

  defp constraints(v) do
    status = v["response"]["authoring_generation_attempt"]
    result = if is_map(status), do: status["result"]

    cond do
      is_map(result) and is_map(result["assessment"]) ->
        base = ["authoring_generation_attempt", "result", "assessment"]
        a = result["assessment"]

        changes = [
          {base ++ ["source_review"], "assessed"},
          {base ++ ["report", "candidate_sha256"], String.duplicate("0", 64)},
          {["authoring_generation_attempt", "result_revision"], status["original"]["revision"]},
          {["authoring_generation_attempt", "state"], "running"},
          {["authoring_generation_attempt", "result", "draft_ref"], nil}
        ]

        changes =
          if a["disposition"] == "compatible",
            do: changes ++ [{base ++ ["report", "truncated"], true}],
            else: changes ++ [{base ++ ["report", "diagnostics"], []}]

        changes =
          if a["report"]["diagnostics"] == [],
            do: changes,
            else:
              changes ++
                [
                  {base ++ ["report", "diagnostics", 0, "repair"], "control\n"},
                  {base ++ ["report", "diagnostics", 0, "code"], "format\u200b"},
                  {base ++ ["report", "diagnostics", 0, "instance_path"],
                   String.duplicate("x", 513)},
                  {base ++ ["report", "diagnostics", 0, "rule_id"], String.duplicate("x", 129)}
                ]

        Enum.map(changes, fn {path, value} ->
          entry(v, put_path(v["response"], path, value), false)
        end)

      true ->
        []
    end
  end

  defp scalar_cases(v) do
    for {path, value} <- scalars(v["response"]),
        invalid <-
          if(is_integer(value),
            do: [true, 1.0, -1, 9_223_372_036_854_775_808, "1"],
            else:
              if(is_boolean(value),
                do: [0, 1, "true", nil],
                else: if(is_binary(value), do: [true], else: [])
              )
          ),
        do: entry(v, put_path(v["response"], path, invalid), false)
  end

  defp peer_cases(v) do
    case v["operation"] do
      operation when operation in ~w(authoring_generation_prepare authoring_generation_start) ->
        for mode <-
              ~w(submit lost_submit malformed_submit wrong_receipt refused invalid_reason not_found_submit outcome_unknown),
            do:
              Map.merge(entry(v, v["response"], true), %{
                "mode" => "peer",
                "peer" => mode,
                "response" => v["response"]
              })

      operation
      when operation in ~w(authoring_generation_status authoring_generation_attempt_status) ->
        for mode <- ~w(lookup missing_lookup replay retry_missing retry_lost retry_status_lost),
            do:
              Map.merge(entry(v, v["response"], true), %{
                "mode" => "peer",
                "peer" => mode,
                "response" => v["response"]
              })

      "authoring_generation_cancel" ->
        for mode <- ~w(cancel lost_cancel malformed_cancel missing_cancel refused_cancel),
            do:
              Map.merge(entry(v, v["response"], true), %{
                "mode" => "peer",
                "peer" => mode,
                "response" => v["response"]
              })

      _ ->
        []
    end
  end

  defp scalars(map) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> Enum.map(scalars(v), fn {p, s} -> {[k | p], s} end) end)

  defp scalars(list) when is_list(list),
    do:
      Enum.flat_map(samples(list), fn {v, i} ->
        Enum.map(scalars(v), fn {p, s} -> {[i | p], s} end)
      end)

  defp scalars(value), do: [{[], value}]

  defp paths(map) when is_map(map),
    do: [[]] ++ Enum.flat_map(map, fn {k, v} -> Enum.map(paths(v), &[k | &1]) end)

  defp paths(list) when is_list(list),
    do: Enum.flat_map(samples(list), fn {v, i} -> Enum.map(paths(v), &[i | &1]) end)

  defp paths(_), do: []
  defp put_path(_, [], value), do: value

  defp put_path(map, [k | rest], value) when is_map(map),
    do: Map.put(map, k, put_path(Map.get(map, k), rest, value))

  defp put_path(list, [i | rest], value) when is_list(list),
    do: List.update_at(list, i, &put_path(&1, rest, value))
end
