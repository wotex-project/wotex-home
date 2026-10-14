defmodule WotexHome.Profiles.AuthoringReview do
  @moduledoc "Closed original review and producer-independent historical result encodings."
  alias WotexHome.Id
  alias WotexHome.Profiles.{AuthoringWire, EnvelopeCodec}
  @max 9_223_372_036_854_775_807
  @input "wotex-home.authoring-review.v1"
  @result "wotex-home.authoring-review-result@1"
  @source ~w(format basis_sha256 draft_sha256 sources_sha256 evidence_sha256 status required_paths covered_paths missing_paths ambiguous_paths unresolved_paths)
  @envelope ~w(format envelope_sha256 document_identities projection_sha256 consumption_sha256 home_contracts exclusions producer)
  @fixture ~w(format consumption_sha256 fixtures_sha256 status cases uncovered_channels)
  @receipt ~w(authority_epoch operation_id revision input_sha256 candidate_revision basis_sha256 result_sha256 source_review home_consumption fixture_status proposal_status)
  @candidate ~w(authority_epoch operation_id revision input_sha256 assessment_sha256)
  @producer ~w(core_archive_sha256 runtime_archive_sha256 profiles_archive_sha256)
  @roots ~r/\A\/(?:profile\/(?:binding|fingerprint\/(?:[0-9]|[12][0-9]|3[01])|channels\/(?:[0-9]|[12][0-9]|3[01])\/(?:selector|semantic|invalid_values|conversion))|definitions\/(?:[0-9]|[12][0-9]|3[01])\/(?:unit|value_schema))\z/

  def encode(d) do
    with true <- EnvelopeCodec.keys?(d, ~w(authority_epoch expected_revision operation_id review)),
         true <-
           integer?(d["authority_epoch"], 1) and integer?(d["expected_revision"], 0) and
             Id.valid?(d["operation_id"]),
         r = d["review"],
         true <-
           EnvelopeCodec.keys?(r, ~w(candidate_ref envelope_ref evidence mode unresolved_paths)),
         true <- candidate?(r["candidate_ref"]),
         :ok <- evidence(r["evidence"]),
         :ok <- paths(r["unresolved_paths"], 64),
         true <-
           (r["mode"] == "source" and r["envelope_ref"] == nil) or
             (r["mode"] == "complete" and handle?(r["envelope_ref"])),
         values = [
           r["mode"],
           Enum.map(@candidate, &r["candidate_ref"][&1]),
           Enum.map(
             r["evidence"],
             &Enum.map(~w(instance_path source_ref locator), fn k -> &1[k] end)
           ),
           r["unresolved_paths"],
           handle_values(r["envelope_ref"])
         ],
         do:
           sized(
             JSON.encode!([
               @input,
               [d["authority_epoch"], d["operation_id"], d["expected_revision"], values]
             ]),
             131_072
           ),
         else: (
           false -> invalid()
           error -> error
         )
  end

  def decode(bytes) do
    with {:ok, [@input, [epoch, op, revision, [mode, candidate, evidence, unresolved, envelope]]]} <-
           AuthoringWire.decode(bytes, 131_072),
         true <- is_list(candidate) and length(candidate) == 5,
         :ok <- bounded(evidence, 256),
         true <- Enum.all?(evidence, &(is_list(&1) and length(&1) == 3)),
         {:ok, envelope} <- native_handle(envelope),
         d = %{
           "authority_epoch" => epoch,
           "operation_id" => op,
           "expected_revision" => revision,
           "review" => %{
             "mode" => mode,
             "candidate_ref" => Map.new(Enum.zip(@candidate, candidate)),
             "evidence" =>
               Enum.map(evidence, &Map.new(Enum.zip(~w(instance_path source_ref locator), &1))),
             "unresolved_paths" => unresolved,
             "envelope_ref" => envelope
           }
         },
         {:ok, ^bytes} <- encode(d),
         do: {:ok, d},
         else: (
           {:error, :authoring_limit} = e -> e
           _ -> invalid()
         )
  end

  def encode_result(d) do
    with true <-
           EnvelopeCodec.keys?(d, ~w(envelope fixtures format source)) and d["format"] == @result,
         true <- source?(d["source"]) and pair?(d["envelope"], d["fixtures"]),
         do:
           sized(
             JSON.encode!([
               @result,
               Enum.map(@source, &d["source"][&1]),
               envelope_values(d["envelope"]),
               fixture_values(d["fixtures"])
             ]),
             65536
           ),
         else: (_ -> invalid())
  end

  def decode_result(bytes) do
    with {:ok, [@result, source, envelope, fixtures]} <- AuthoringWire.decode(bytes, 65536),
         true <- is_list(source) and length(source) == 11,
         {:ok, envelope} <- native_envelope(envelope),
         {:ok, fixtures} <- native_fixtures(fixtures),
         d = %{
           "format" => @result,
           "source" => Map.new(Enum.zip(@source, source)),
           "envelope" => envelope,
           "fixtures" => fixtures
         },
         {:ok, ^bytes} <- encode_result(d),
         do: {:ok, d},
         else: (_ -> invalid())
  end

  def encode_receipt(d) do
    valid =
      EnvelopeCodec.keys?(d, Enum.sort(@receipt)) and integer?(d["authority_epoch"], 1) and
        Id.valid?(d["operation_id"]) and
        integer?(d["revision"], 1) and integer?(d["candidate_revision"], 1) and
        d["candidate_revision"] < d["revision"] and
        Enum.all?(~w(input_sha256 basis_sha256 result_sha256), &EnvelopeCodec.digest?(d[&1])) and
        d["source_review"] in ~w(attributed incomplete ambiguous) and
        d["home_consumption"] in ~w(not_assessed matched) and
        d["fixture_status"] in ~w(not_supplied not_assessed passed failed incomplete) and
        d["proposal_status"] ==
          proposal_status(d["source_review"], d["home_consumption"], d["fixture_status"])

    if valid, do: {:ok, JSON.encode!(Enum.map(@receipt, &d[&1]))}, else: invalid()
  end

  def decode_receipt(bytes) do
    with {:ok, values} when length(values) == 11 <- AuthoringWire.decode(bytes, 4096),
         d = Map.new(Enum.zip(@receipt, values)),
         {:ok, ^bytes} <- encode_receipt(d),
         do: {:ok, d},
         else: (_ -> invalid())
  end

  def proposal_status("attributed", "matched", "passed"), do: "complete"
  def proposal_status(_, _, _), do: "incomplete"
  @doc false
  def sources_digest(rows),
    do:
      sha(
        "wotex-home.authoring-sources@1\n" <>
          JSON.encode!(
            Enum.map(rows, fn r ->
              Enum.map(~w(kind object_digest payload_sha256 payload_bytes), &r["object"][&1]) ++
                [r["first_revision"]]
            end)
          )
      )

  @doc false
  def evidence_digest(evidence, unresolved),
    do:
      sha(
        "wotex-home.authoring-evidence@1\n" <>
          JSON.encode!([
            Enum.map(
              evidence,
              &Enum.map(~w(instance_path source_ref locator), fn k -> &1[k] end)
            ),
            unresolved
          ])
      )

  defp source?(s) do
    EnvelopeCodec.keys?(s, Enum.sort(@source)) and s["format"] == "wotex-home.authoring-source@1" and
      Enum.all?(
        ~w(basis_sha256 draft_sha256 sources_sha256 evidence_sha256),
        &EnvelopeCodec.digest?(s[&1])
      ) and
      Enum.all?(
        ~w(required_paths covered_paths missing_paths ambiguous_paths),
        &(paths(s[&1], 225) == :ok)
      ) and paths(s["unresolved_paths"], 64) == :ok and
      "/profile/binding" in s["required_paths"] and
      Enum.all?(
        ~w(covered_paths missing_paths ambiguous_paths unresolved_paths),
        &Enum.all?(s[&1], fn p -> p in s["required_paths"] end)
      ) and
      Enum.sort(
        Enum.uniq(
          s["covered_paths"] ++
            s["missing_paths"] ++ s["ambiguous_paths"] ++ s["unresolved_paths"]
        )
      ) == s["required_paths"] and
      disjoint?(
        s["covered_paths"],
        s["missing_paths"] ++ s["ambiguous_paths"] ++ s["unresolved_paths"]
      ) and
      disjoint?(s["missing_paths"], s["ambiguous_paths"] ++ s["unresolved_paths"]) and
      s["status"] == source_status(s)
  end

  defp source_status(%{"ambiguous_paths" => [_ | _]}), do: "ambiguous"
  defp source_status(%{"missing_paths" => [], "unresolved_paths" => []}), do: "attributed"
  defp source_status(_), do: "incomplete"
  defp pair?(nil, nil), do: true

  defp pair?(e, f),
    do: envelope?(e) and fixture?(f) and f["consumption_sha256"] == e["consumption_sha256"]

  defp envelope?(e) do
    EnvelopeCodec.keys?(e, Enum.sort(@envelope)) and
      e["format"] == "wotex-home.external-profile-inspection@1" and
      Enum.all?(
        ~w(envelope_sha256 projection_sha256 consumption_sha256),
        &EnvelopeCodec.digest?(e[&1])
      ) and
      bounded(e["document_identities"], 33) == :ok and e["document_identities"] != [] and
      Enum.all?(
        e["document_identities"],
        &(EnvelopeCodec.keys?(&1, ~w(raw_sha256 reference)) and
            EnvelopeCodec.reference?(&1["reference"]) and EnvelopeCodec.digest?(&1["raw_sha256"]))
      ) and
      bounded(e["home_contracts"], 32) == :ok and e["home_contracts"] != [] and
      Enum.all?(
        e["home_contracts"],
        &(EnvelopeCodec.keys?(&1, ~w(channel_id contract_ref)) and
            EnvelopeCodec.key?(&1["channel_id"]) and EnvelopeCodec.reference?(&1["contract_ref"]))
      ) and
      sorted_by?(e["home_contracts"], & &1["channel_id"]) and bounded(e["exclusions"], 32) == :ok and
      Enum.all?(
        e["exclusions"],
        &(EnvelopeCodec.keys?(&1, ~w(channel_id reason)) and EnvelopeCodec.key?(&1["channel_id"]) and
            &1["reason"] in ~w(producer_unsupported operation_unsupported consumption_unavailable))
      ) and
      sorted_by?(e["exclusions"], & &1["channel_id"]) and
      EnvelopeCodec.keys?(e["producer"], Enum.sort(@producer)) and
      Enum.all?(@producer, &EnvelopeCodec.digest?(e["producer"][&1]))
  end

  defp fixture?(f) do
    EnvelopeCodec.keys?(f, Enum.sort(@fixture)) and
      f["format"] == "wotex-home.authoring-fixtures@1" and
      EnvelopeCodec.digest?(f["consumption_sha256"]) and
      EnvelopeCodec.digest?(f["fixtures_sha256"]) and
      bounded(f["cases"], 32) == :ok and
      Enum.all?(f["cases"], fn c ->
        EnvelopeCodec.keys?(c, ~w(disposition id reason)) and Id.valid?(c["id"]) and
          ((c["disposition"] == "passed" and c["reason"] == nil) or
             (c["disposition"] == "failed" and
                c["reason"] in ~w(channel_unavailable selector_mismatch interpretation_refused proposal_mismatch)))
      end) and
      sorted_by?(f["cases"], & &1["id"]) and bounded(f["uncovered_channels"], 32) == :ok and
      Enum.all?(f["uncovered_channels"], &EnvelopeCodec.key?/1) and
      sorted?(f["uncovered_channels"]) and f["status"] == fixture_status(f)
  end

  defp fixture_status(%{"cases" => []}), do: "not_supplied"

  defp fixture_status(f) do
    cond do
      Enum.any?(f["cases"], &(&1["disposition"] == "failed")) -> "failed"
      f["uncovered_channels"] != [] -> "incomplete"
      true -> "passed"
    end
  end

  defp envelope_values(nil), do: nil

  defp envelope_values(e),
    do: [
      e["format"],
      e["envelope_sha256"],
      Enum.map(e["document_identities"], &[reference_values(&1["reference"]), &1["raw_sha256"]]),
      e["projection_sha256"],
      e["consumption_sha256"],
      Enum.map(e["home_contracts"], &[&1["channel_id"], reference_values(&1["contract_ref"])]),
      Enum.map(e["exclusions"], &[&1["channel_id"], &1["reason"]]),
      Enum.map(@producer, &e["producer"][&1])
    ]

  defp fixture_values(nil), do: nil

  defp fixture_values(f),
    do: [
      f["format"],
      f["consumption_sha256"],
      f["fixtures_sha256"],
      f["status"],
      Enum.map(f["cases"], &Enum.map(~w(id disposition reason), fn k -> &1[k] end)),
      f["uncovered_channels"]
    ]

  defp native_envelope(nil), do: {:ok, nil}

  defp native_envelope([
         format,
         digest,
         docs,
         projection,
         consumption,
         contracts,
         exclusions,
         producer
       ]) do
    with true <-
           list_entries?(docs, 33, 2) and list_entries?(contracts, 32, 2) and
             list_entries?(exclusions, 32, 2),
         true <- is_list(producer) and length(producer) == 3,
         true <-
           Enum.all?(docs, fn [r, _] -> reference_values?(r) end) and
             Enum.all?(contracts, fn [_, r] -> reference_values?(r) end) do
      {:ok,
       %{
         "format" => format,
         "envelope_sha256" => digest,
         "document_identities" =>
           Enum.map(docs, fn [r, d] ->
             %{"reference" => native_reference(r), "raw_sha256" => d}
           end),
         "projection_sha256" => projection,
         "consumption_sha256" => consumption,
         "home_contracts" =>
           Enum.map(contracts, fn [c, r] ->
             %{"channel_id" => c, "contract_ref" => native_reference(r)}
           end),
         "exclusions" =>
           Enum.map(exclusions, fn [c, r] -> %{"channel_id" => c, "reason" => r} end),
         "producer" => Map.new(Enum.zip(@producer, producer))
       }}
    else
      _ -> invalid()
    end
  end

  defp native_envelope(_), do: invalid()
  defp native_fixtures(nil), do: {:ok, nil}

  defp native_fixtures([format, c, hash, status, cases, uncovered]) do
    if list_entries?(cases, 32, 3),
      do:
        {:ok,
         %{
           "format" => format,
           "consumption_sha256" => c,
           "fixtures_sha256" => hash,
           "status" => status,
           "cases" => Enum.map(cases, &Map.new(Enum.zip(~w(id disposition reason), &1))),
           "uncovered_channels" => uncovered
         }},
      else: invalid()
  end

  defp native_fixtures(_), do: invalid()

  defp evidence(v) do
    with :ok <- bounded(v, 256),
         true <-
           Enum.all?(v, fn e ->
             EnvelopeCodec.keys?(e, ~w(instance_path locator source_ref)) and
               root?(e["instance_path"]) and EnvelopeCodec.digest?(e["source_ref"]) and
               EnvelopeCodec.text?(e["locator"], 256)
           end),
         keys = Enum.map(v, &{&1["instance_path"], &1["source_ref"], &1["locator"]}),
         true <- sorted?(keys),
         do: :ok,
         else: (
           false -> invalid()
           e -> e
         )
  end

  defp paths(v, max) do
    with :ok <- bounded(v, max),
         true <- Enum.all?(v, &root?/1) and sorted?(v),
         do: :ok,
         else: (
           false -> invalid()
           e -> e
         )
  end

  defp root?(s), do: is_binary(s) and byte_size(s) <= 512 and Regex.match?(@roots, s)

  defp candidate?(c),
    do:
      EnvelopeCodec.keys?(c, Enum.sort(@candidate)) and integer?(c["authority_epoch"], 1) and
        integer?(c["revision"], 1) and Id.valid?(c["operation_id"]) and
        Enum.all?(~w(input_sha256 assessment_sha256), &EnvelopeCodec.digest?(c[&1]))

  defp handle?(h),
    do:
      EnvelopeCodec.keys?(h, ~w(first_revision object_digest)) and
        EnvelopeCodec.digest?(h["object_digest"]) and integer?(h["first_revision"], 1)

  defp handle_values(nil), do: nil
  defp handle_values(h), do: [h["object_digest"], h["first_revision"]]
  defp native_handle(nil), do: {:ok, nil}
  defp native_handle([d, r]), do: {:ok, %{"object_digest" => d, "first_revision" => r}}
  defp native_handle(_), do: invalid()
  defp reference_values(r), do: Enum.map(~w(id version sha256), &r[&1])
  defp reference_values?([_, _, _]), do: true
  defp reference_values?(_), do: false
  defp native_reference(v), do: Map.new(Enum.zip(~w(id version sha256), v))

  defp list_entries?(v, max, size),
    do: bounded(v, max) == :ok and Enum.all?(v, &(is_list(&1) and length(&1) == size))

  defp integer?(v, min), do: is_integer(v) and v in min..@max
  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :authoring_limit}
  defp bounded([_ | t], n), do: bounded(t, n - 1)
  defp bounded(_, _), do: invalid()
  defp disjoint?(a, b), do: Enum.all?(a, &(&1 not in b))
  defp sorted?(v), do: v == Enum.sort(Enum.uniq(v))
  defp sorted_by?(v, f), do: sorted?(Enum.map(v, f))

  defp sized(bytes, max),
    do: if(byte_size(bytes) <= max, do: {:ok, bytes}, else: {:error, :authoring_limit})

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp invalid, do: {:error, :invalid_authoring_review}
end
