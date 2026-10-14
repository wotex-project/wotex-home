defmodule WotexHome.Profiles.AuthoringCandidate do
  @moduledoc """
  Encodes manual candidate originals and their retained assessment metadata.

  `encode/1` binds the operation and expected authority revision to an exact
  draft handle, installed contract digest, sorted source/fixture handles and
  selected limits. Only the manual authoring mode is supported. Receipt and
  assessment codecs retain the original result without needing a running producer.

  Canonical decoding checks representation and correspondence; it does not
  authenticate the actor or establish that selected objects are currently usable.
  The Store owns those checks and durable original-operation reuse.
  """

  alias WotexHome.{Id, Profiles.AuthoringContract}
  alias WotexHome.Profiles.{AuthoringObject, AuthoringWire, EnvelopeCodec}
  @maximum 9_223_372_036_854_775_807
  @reader ~w(max_bytes max_depth max_nodes max_channels max_definitions max_bindings max_dependencies max_numeric_digits)
  @limits ~w(max_bundle_bytes max_diagnostics max_report_bytes max_check_steps)
  @receipt ~w(authority_epoch operation_id revision input_sha256 basis_sha256 assessment_sha256 disposition capture_status bundle source_review fixture_status)
  @assessment ~w(format basis_sha256 draft_sha256 bundle_sha256 phase disposition capture_status report home_consumption source_review fixture_status)
  @report ~w(format contract_sha256 candidate_sha256 disposition capture_status diagnostics truncated)
  @diagnostic ~w(phase code instance_path rule_id repair)
  @format "wotex-home.authoring-candidate.v1"

  def encode(data) do
    with true <-
           EnvelopeCodec.keys?(data, ~w(authority_epoch expected_revision operation_id request)),
         true <-
           int?(data["authority_epoch"], 1) and int?(data["expected_revision"], 0) and
             Id.valid?(data["operation_id"]),
         r = data["request"],
         true <-
           EnvelopeCodec.keys?(
             r,
             ~w(base_draft_ref contract_digest fixture_refs instruction limits mode source_refs)
           ),
         :ok <- mode(r["mode"]),
         true <-
           EnvelopeCodec.digest?(r["contract_digest"]) and handle?(r["base_draft_ref"]) and
             instruction?(r["instruction"]),
         :ok <- handles(r["source_refs"]),
         :ok <- handles(r["fixture_refs"]),
         :ok <- selected_limits(r["limits"]),
         bytes =
           JSON.encode!([
             @format,
             [
               data["authority_epoch"],
               data["operation_id"],
               data["expected_revision"],
               [
                 "manual",
                 r["contract_digest"],
                 ref(r["base_draft_ref"]),
                 Enum.map(r["source_refs"], &ref/1),
                 Enum.map(r["fixture_refs"], &ref/1),
                 r["instruction"],
                 limit_values(r["limits"])
               ]
             ]
           ]),
         true <- byte_size(bytes) <= 32768,
         do: {:ok, bytes},
         else: (
           false -> invalid()
           error -> error
         )
  end

  def decode(bytes) do
    with {:ok,
          [
            @format,
            [
              epoch,
              operation,
              revision,
              [mode, contract, draft, sources, fixtures, instruction, limits]
            ]
          ]} <- AuthoringWire.decode(bytes, 32768),
         {:ok, draft} <- native_ref(draft),
         {:ok, sources} <- native_refs(sources),
         {:ok, fixtures} <- native_refs(fixtures),
         {:ok, limits} <- native_limits(limits),
         data = %{
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => revision,
           "request" => %{
             "mode" => mode,
             "contract_digest" => contract,
             "base_draft_ref" => draft,
             "source_refs" => sources,
             "fixture_refs" => fixtures,
             "instruction" => instruction,
             "limits" => limits
           }
         },
         {:ok, ^bytes} <- encode(data),
         do: {:ok, data},
         else: (
           {:error, reason} = error
           when reason in [:authoring_limit, :unsupported_authoring_mode] ->
             error

           _ ->
             invalid()
         )
  end

  def encode_receipt(data) do
    with true <- EnvelopeCodec.keys?(data, Enum.sort(@receipt)),
         true <-
           int?(data["authority_epoch"], 1) and int?(data["revision"], 1) and
             Id.valid?(data["operation_id"]),
         true <-
           Enum.all?(
             ~w(input_sha256 basis_sha256 assessment_sha256),
             &EnvelopeCodec.digest?(data[&1])
           ),
         true <-
           data["disposition"] in ~w(compatible invalid) and
             data["capture_status"] == "not_supplied" and
             data["source_review"] == "not_assessed" and
             data["fixture_status"] in ~w(not_supplied not_assessed),
         true <- bundle?(data["bundle"]),
         values = Enum.map(@receipt, &data[&1]),
         values = List.replace_at(values, 8, bundle_values(data["bundle"])),
         do: {:ok, JSON.encode!(values)},
         else: (_ -> invalid())
  end

  def decode_receipt(bytes) do
    with {:ok, values} when length(values) == 11 <- AuthoringWire.decode(bytes, 4096),
         {:ok, bundle} <- native_bundle(Enum.at(values, 8)),
         data = Map.new(Enum.zip(@receipt, List.replace_at(values, 8, bundle))),
         {:ok, ^bytes} <- encode_receipt(data),
         do: {:ok, data},
         else: (_ -> invalid())
  end

  def encode_assessment(data) do
    with true <- assessment?(data),
         report = data["report"],
         values = Enum.map(@report, &report[&1]),
         values =
           List.replace_at(
             values,
             5,
             Enum.map(report["diagnostics"], fn d -> Enum.map(@diagnostic, &d[&1]) end)
           ),
         data = Enum.map(@assessment, &data[&1]) |> List.replace_at(7, values),
         bytes = JSON.encode!(data),
         true <- byte_size(bytes) <= 65536,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  def decode_assessment(bytes) do
    with {:ok, values} when length(values) == 11 <- AuthoringWire.decode(bytes, 65536),
         report when is_list(report) and length(report) == 7 <- Enum.at(values, 7),
         diagnostics when is_list(diagnostics) and length(diagnostics) <= 64 <- Enum.at(report, 5),
         true <- Enum.all?(diagnostics, &(is_list(&1) and length(&1) == 5)),
         diagnostics = Enum.map(diagnostics, &Map.new(Enum.zip(@diagnostic, &1))),
         report = Map.new(Enum.zip(@report, List.replace_at(report, 5, diagnostics))),
         data = Map.new(Enum.zip(@assessment, List.replace_at(values, 7, report))),
         {:ok, ^bytes} <- encode_assessment(data),
         do: {:ok, data},
         else: (_ -> invalid())
  end

  defp assessment?(d) do
    EnvelopeCodec.keys?(d, Enum.sort(@assessment)) and
      d["format"] == "wotex-home.authoring-mechanics@1" and
      Enum.all?(~w(basis_sha256 draft_sha256), &EnvelopeCodec.digest?(d[&1])) and
      (d["bundle_sha256"] == nil or EnvelopeCodec.digest?(d["bundle_sha256"])) and
      d["disposition"] in ~w(compatible invalid) and d["capture_status"] == "not_supplied" and
      d["home_consumption"] == "not_assessed" and d["source_review"] == "not_assessed" and
      d["fixture_status"] == "not_supplied" and
      ((d["phase"] == "finalize" and d["bundle_sha256"] == nil and d["disposition"] == "invalid") or
         (d["phase"] == "validate" and EnvelopeCodec.digest?(d["bundle_sha256"]))) and
      report?(d["report"], d)
  end

  defp report?(r, d) do
    EnvelopeCodec.keys?(r, Enum.sort(@report)) and
      r["format"] == "wotex.profile.validation-report@1" and
      EnvelopeCodec.digest?(r["contract_sha256"]) and
      r["candidate_sha256"] == (d["bundle_sha256"] || d["draft_sha256"]) and
      r["disposition"] == d["disposition"] and r["capture_status"] == "not_supplied" and
      is_boolean(r["truncated"]) and
      is_list(r["diagnostics"]) and length(r["diagnostics"]) <= 64 and
      Enum.all?(r["diagnostics"], &diagnostic?/1) and
      ((r["disposition"] == "compatible" and r["diagnostics"] == [] and r["truncated"] == false) or
         (r["disposition"] == "invalid" and r["diagnostics"] != []))
  end

  defp diagnostic?(d),
    do:
      EnvelopeCodec.keys?(d, Enum.sort(@diagnostic)) and
        d["phase"] in ~w(syntax shape semantic binding capture) and
        Enum.all?(~w(code rule_id repair), &EnvelopeCodec.text?(d[&1], 128)) and
        (d["instance_path"] == "" or EnvelopeCodec.text?(d["instance_path"], 512))

  defp mode("manual"), do: :ok
  defp mode("generated"), do: {:error, :unsupported_authoring_mode}
  defp mode(_), do: invalid()

  defp selected_limits(l) do
    case AuthoringContract.validate_limits(l) do
      :ok -> :ok
      {:error, :authoring_limit} = e -> e
      _ -> invalid()
    end
  end

  defp int?(v, min), do: is_integer(v) and v in min..@maximum

  defp handle?(v),
    do:
      EnvelopeCodec.keys?(v, ~w(first_revision object_digest)) and
        EnvelopeCodec.digest?(v["object_digest"]) and int?(v["first_revision"], 1)

  defp ref(v), do: [v["object_digest"], v["first_revision"]]

  defp native_ref([digest, first]),
    do: {:ok, %{"object_digest" => digest, "first_revision" => first}}

  defp native_ref(_), do: invalid()

  defp handles(v) do
    with :ok <- bounded(v, 32),
         true <- Enum.all?(v, &handle?/1),
         ids = Enum.map(v, & &1["object_digest"]),
         true <- ids == Enum.sort(Enum.uniq(ids)),
         do: :ok,
         else: (
           false -> invalid()
           e -> e
         )
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :authoring_limit}
  defp bounded([_ | tail], n), do: bounded(tail, n - 1)
  defp bounded(_, _), do: invalid()

  defp native_refs(v) do
    with :ok <- bounded(v, 32),
         true <- Enum.all?(v, &(is_list(&1) and length(&1) == 2)),
         do:
           {:ok,
            Enum.map(v, fn [digest, first] ->
              %{"object_digest" => digest, "first_revision" => first}
            end)},
         else: (
           false -> invalid()
           e -> e
         )
  end

  defp instruction?(s),
    do:
      is_binary(s) and byte_size(s) <= 4096 and String.valid?(s) and
        not Regex.match?(~r/\p{Cc}/u, String.replace(s, ["\n", "\t"], ""))

  defp limit_values(l), do: [Enum.map(@reader, &l["reader"][&1]) | Enum.map(@limits, &l[&1])]

  defp native_limits([r, b, d, p, s]) when is_list(r) and length(r) == 8,
    do:
      {:ok,
       Map.new(Enum.zip(@limits, [b, d, p, s]))
       |> Map.put("reader", Map.new(Enum.zip(@reader, r)))}

  defp native_limits(_), do: invalid()
  defp bundle?(nil), do: true
  defp bundle?(b), do: AuthoringObject.valid_summary?(b) and b["kind"] == "bundle"
  defp bundle_values(nil), do: nil
  defp bundle_values(b), do: Enum.map(~w(kind object_digest payload_sha256 payload_bytes), &b[&1])
  defp native_bundle(nil), do: {:ok, nil}

  defp native_bundle([kind, digest, payload, size]),
    do:
      {:ok,
       %{
         "kind" => kind,
         "object_digest" => digest,
         "payload_sha256" => payload,
         "payload_bytes" => size
       }}

  defp native_bundle(_), do: invalid()
  defp invalid, do: {:error, :invalid_authoring_candidate}
end
