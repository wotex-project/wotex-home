defmodule WotexHome.Discovery.Candidate do
  @moduledoc """
  Bounded, untrusted introduction from a local discovery window.

  Endpoint and claimed IDs are evidence strings. Constructing a candidate
  performs no fetch, enrollment, credential lookup or driver operation.
  """

  alias WotexHome.Id

  @keys ~w(interface_id transport source_endpoint receive_epoch received_monotonic_ms raw_ref claimed_identifiers trust_class)
  @transports ~w(udp mdns zigbee configured)
  @trust_classes ~w(untrusted_network operator_configured)
  @enforce_keys [
    :interface_id,
    :transport,
    :source_endpoint,
    :receive_epoch,
    :received_monotonic_ms,
    :raw_ref,
    :claimed_identifiers,
    :trust_class
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(input) when is_map(input) do
    with :ok <- closed(input),
         :ok <- metadata(input),
         :ok <- claims(input) do
      {:ok,
       struct!(__MODULE__,
         interface_id: input["interface_id"],
         transport: input["transport"],
         source_endpoint: input["source_endpoint"],
         receive_epoch: input["receive_epoch"],
         received_monotonic_ms: input["received_monotonic_ms"],
         raw_ref: input["raw_ref"],
         claimed_identifiers: input["claimed_identifiers"],
         trust_class: input["trust_class"]
       )}
    end
  end

  def new(_input), do: {:error, :invalid_candidate}

  defp closed(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp metadata(input) do
    endpoint = input["source_endpoint"]

    if Id.valid?(input["interface_id"]) and Id.valid?(input["receive_epoch"]) and
         Id.valid?(input["raw_ref"]) and input["transport"] in @transports and
         input["trust_class"] in @trust_classes and is_binary(endpoint) and
         byte_size(endpoint) > 0 and byte_size(endpoint) <= 256 and
         is_integer(input["received_monotonic_ms"]) and input["received_monotonic_ms"] >= 0,
       do: :ok,
       else: {:error, :invalid_metadata}
  end

  defp claims(%{"claimed_identifiers" => claims}) when is_map(claims) and map_size(claims) <= 8 do
    if Enum.all?(claims, fn {key, value} ->
         key in ~w(manufacturer model firmware stable_id) and Id.valid?(value)
       end),
       do: :ok,
       else: {:error, :invalid_claims}
  end

  defp claims(_input), do: {:error, :invalid_claims}
end
