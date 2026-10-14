defmodule WotexHome.Profiles.EnvelopeSummary do
  @moduledoc false
  alias WotexHome.Profiles.EnvelopeCodec

  @envelope ~w(format envelope_sha256 document_identities projection_sha256 consumption_sha256 home_contracts exclusions producer)
  def valid?(e) do
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
      WotexHome.Profiles.ProducerIdentity.valid?(e["producer"])
  end

  def values(nil), do: nil

  def values(e),
    do: [
      e["format"],
      e["envelope_sha256"],
      Enum.map(e["document_identities"], &[reference_values(&1["reference"]), &1["raw_sha256"]]),
      e["projection_sha256"],
      e["consumption_sha256"],
      Enum.map(e["home_contracts"], &[&1["channel_id"], reference_values(&1["contract_ref"])]),
      Enum.map(e["exclusions"], &[&1["channel_id"], &1["reason"]]),
      WotexHome.Profiles.ProducerIdentity.values(e["producer"])
    ]

  def from_wire(nil), do: {:ok, nil}

  def from_wire([
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
         {:ok, producer} <- WotexHome.Profiles.ProducerIdentity.from_wire(producer),
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
         "producer" => producer
       }}
    else
      _ -> invalid()
    end
  end

  def from_wire(_), do: invalid()
  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: :error
  defp bounded([_ | t], n), do: bounded(t, n - 1)
  defp bounded(_, _), do: :error

  defp sorted_by?(values, fun) do
    keys = Enum.map(values, fun)
    keys == Enum.sort(Enum.uniq(keys))
  end

  defp reference_values(r), do: Enum.map(~w(id version sha256), &r[&1])
  defp reference_values?([_, _, _]), do: true
  defp reference_values?(_), do: false
  defp native_reference(v), do: Map.new(Enum.zip(~w(id version sha256), v))

  defp list_entries?(values, max, size),
    do: bounded(values, max) == :ok and Enum.all?(values, &exact_list?(&1, size))

  defp exact_list?([], 0), do: true
  defp exact_list?([_ | t], n) when n > 0, do: exact_list?(t, n - 1)
  defp exact_list?(_, _), do: false
  defp invalid, do: {:error, :invalid_external_inspection}
end
