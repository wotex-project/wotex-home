defmodule WotexHome.Profiles.InspectionPreparation do
  @moduledoc """
  Builds an inert profile inspection from an exact typed object closure.

  `build/3` receives the closed inspection original, explicit typed read records
  and a checked `WotexHome.Profiles.ReaderSelection`. It verifies exact handles,
  kinds, first revisions and original payload digests, rejects extra or missing
  records, and compiles the supplied envelope/profile/definition closure against
  the selected capture and limits. The result retains the reader/capture basis
  and checked envelope summary.

  At most 34 records are accepted, each payload at most 65,536 bytes and the
  complete framed set at most 329,108 bytes. These checks cannot establish actor
  ownership: `WotexHome.Durable.Store` must select every record from the current
  principal's retained imports before this call. Preparation grants no local
  trust, target selection or physical qualification.
  """

  alias WotexHome.Profiles.{
    AuthoringObject,
    EnvelopeCodec,
    ExternalEnvelope,
    ExternalInspection,
    ReaderSelection
  }

  @maximum 9_223_372_036_854_775_807

  @doc "Checks the complete supplied byte closure and produces an inert inspection result."
  @spec build(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def build(input, records, reader) do
    with {:ok, _} <- ExternalInspection.encode(input),
         {:ok, selection} <- ReaderSelection.to_map(reader),
         :ok <-
           same(
             selection["basis_sha256"],
             input["inspection"]["reader_basis_sha256"],
             :stale_external_basis
           ),
         :ok <- bounded(records, 34),
         true <- Enum.all?(records, &record?/1),
         digests = Enum.map(records, & &1["object"]["object_digest"]),
         true <- digests == Enum.sort(Enum.uniq(digests)),
         :ok <- bytes(records),
         required = requirements(input["inspection"]),
         true <-
           digests ==
             Enum.sort(Enum.uniq(Enum.map(required, fn {h, _} -> h["object_digest"] end))),
         indexed = Map.new(records, &{&1["object"]["object_digest"], &1}),
         :ok <- references(required, indexed, input["expected_revision"]),
         :ok <- verify(records),
         i = input["inspection"],
         documents = %{
           "profile" => document(i["profile"], indexed),
           "definitions" => Enum.map(i["definitions"], &document(&1, indexed))
         },
         {:ok, envelope} <-
           ExternalEnvelope.compile(
             indexed[i["envelope_ref"]["object_digest"]]["payload"],
             documents,
             reader.inputs["installed"],
             reader.inputs["capture"],
             reader.inputs["reader_limits"]
           ),
         {:ok, summary} <- ExternalEnvelope.to_map(envelope, reader.inputs["reader_limits"]) do
      {:ok,
       %{
         "format" => "wotex-home.external-inspection-result@1",
         "reader_basis_sha256" => selection["basis_sha256"],
         "capture_digest" => selection["capture_digest"],
         "envelope" => summary
       }}
    else
      false -> invalid()
      error -> error
    end
  end

  defp record?(r) do
    EnvelopeCodec.keys?(r, ~w(first_revision object payload)) and
      is_integer(r["first_revision"]) and r["first_revision"] in 1..@maximum and
      is_binary(r["payload"]) and
      EnvelopeCodec.keys?(r["object"], ~w(kind object_digest payload_bytes payload_sha256)) and
      r["object"]["kind"] in ~w(envelope profile definition) and
      Enum.all?(~w(object_digest payload_sha256), &EnvelopeCodec.digest?(r["object"][&1])) and
      is_integer(r["object"]["payload_bytes"]) and r["object"]["payload_bytes"] > 0
  end

  defp bytes(records) do
    if Enum.all?(records, &(byte_size(&1["payload"]) <= 65536)) and
         Enum.sum(Enum.map(records, &(byte_size(&1["payload"]) + 42))) <= 329_108,
       do: :ok,
       else: {:error, :external_profile_limit}
  end

  defp requirements(i),
    do:
      [{i["envelope_ref"], "envelope"}, {i["profile"]["object_ref"], "profile"}] ++
        Enum.map(i["definitions"], &{&1["object_ref"], "definition"})

  defp references(required, records, revision) do
    Enum.reduce_while(required, :ok, fn {handle, kind}, :ok ->
      record = records[handle["object_digest"]]

      cond do
        record["object"]["kind"] != kind ->
          {:halt, invalid()}

        record["first_revision"] != handle["first_revision"] or
            record["first_revision"] > revision ->
          {:halt, {:error, :stale_external_reference}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp verify(records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      with {:ok, object} <- AuthoringObject.new(record["object"]["kind"], record["payload"]),
           {:ok, summary} <- AuthoringObject.summary(object),
           true <- summary == record["object"],
           do: {:cont, :ok},
           else: (_ -> {:halt, invalid()})
    end)
  end

  defp document(d, records) do
    record = records[d["object_ref"]["object_digest"]]

    %{
      "reference" => d["reference"],
      "raw_sha256" => record["object"]["payload_sha256"],
      "bytes" => record["payload"]
    }
  end

  defp same(v, v, _), do: :ok
  defp same(_, _, reason), do: {:error, reason}
  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :external_profile_limit}
  defp bounded([_ | tail], n), do: bounded(tail, n - 1)
  defp bounded(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_external_inspection}
end
