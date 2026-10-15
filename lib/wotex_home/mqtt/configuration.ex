defmodule WotexHome.MQTT.Configuration do
  @moduledoc """
  Validates the native inputs for one explicitly configured MQTT publisher.

  Trusted host composition supplies exactly the native keys `:reader`,
  `:projection`, `:source`, `:channels` and `:connection`. `check/2` rebuilds the
  `WotexHome.Profiles.ReaderSelection`, capture-bound `Wotex.Profiles.Projection`
  and `WotexHome.Profiles.ExternalSourceSelection` using the publisher's new
  source epoch. The installed binding must expose the exact
  `Wotex.Binding.MQTT.JSONProjection.selector_schema/0` and `observeproperty`.
  The 1 to 32 selected channels require supported observable plans and valid
  selectors.
  Source trust is limited to `unauthenticated_local` or `synthetic_lab`.

  Success is `{:ok, checked}` with the selection, exported projection, selected
  plans and sorted unique Topic Names. Refusals are
  `{:error, :invalid_mqtt_publisher}` or `{:error, :invalid_mqtt_connection}`.
  Construction performs no broker I/O and invokes no credential provider.

  `connection/1` accepts exactly `:address`, `:local_address`, `:port`, `:tls`
  and a zero-arity `:credentials` provider. Addresses must be literal private,
  loopback or link-local IPv4 tuples; the selected local address must currently
  belong to a host interface. Ports range from 1 to 65,535. `local_present?/1`
  repeats the interface-presence check and returns a boolean. Connection
  validation returns `:ok` or `{:error, :invalid_mqtt_connection}`.

  TLS is explicit: `nil` selects plaintext, otherwise `:server_name` and
  `:cacerts` provide a 1 to 253-byte hostname and 1 to 8 DER certificates, each
  at most 16,384 bytes and at most 65,536 bytes together. This checks configuration
  and certificate syntax; `WotexHome.MQTT.Connection` performs peer/hostname
  verification. Password credentials are accepted there only over TLS.

  Native configuration and credential providers belong to trusted host
  composition, never a profile or remote authoring request. Validation grants
  no target selection, observation freshness or physical qualification.
  """

  alias Wotex.Binding.MQTT.JSONProjection
  alias Wotex.Profiles.Projection
  alias WotexHome.Profiles.{ExternalSourceSelection, ReaderSelection}

  @doc "Revalidates a closed native configuration using the publisher's new source epoch."
  def check(config, epoch) do
    with true <- keys?(config, [:reader, :projection, :source, :channels, :connection]),
         {:ok, reader} <- ReaderSelection.to_map(config.reader),
         {:ok, projection} <- Projection.to_map(config.projection, reader["reader_limits"]),
         true <- config.projection.inputs["capture"] == config.reader.inputs["capture"],
         true <- projection["capture_digest"] == reader["capture_digest"],
         true <- projection["capture_epoch"] == reader["capture_epoch"],
         binding when is_map(binding) <-
           Enum.find(config.reader.inputs["installed"]["bindings"], fn b ->
             Map.take(b, ~w(id version sha256)) == projection["binding"]
           end),
         true <- binding["selector_schema"] == JSONProjection.selector_schema(),
         true <- "observeproperty" in binding["operations"],
         true <- keys?(config.source, ~w(source_ref stable_id source_generation method trust)),
         true <- config.source["trust"] in ~w(unauthenticated_local synthetic_lab),
         {:ok, selection} <-
           ExternalSourceSelection.new(
             Map.put(config.source, "source_epoch", epoch),
             config.reader,
             config.channels
           ),
         {:ok, plans} <- plans(config.channels, projection["channel_plans"]),
         :ok <- connection(config.connection) do
      {:ok,
       %{
         selection: selection,
         projection: projection,
         plans: plans,
         topics: plans |> Enum.map(& &1["selector"]["topic"]) |> Enum.uniq() |> Enum.sort()
       }}
    else
      {:error, :invalid_mqtt_connection} = error -> error
      _ -> {:error, :invalid_mqtt_publisher}
    end
  rescue
    _ -> {:error, :invalid_mqtt_publisher}
  catch
    _, _ -> {:error, :invalid_mqtt_publisher}
  end

  @doc "Checks endpoint, TLS and provider shape, including current interface presence."
  def connection(c) do
    if keys?(c, [:address, :local_address, :port, :tls, :credentials]) and
         local?(c.address) and local?(c.local_address) and local_present?(c.local_address) and
         is_integer(c.port) and c.port in 1..65_535 and tls?(c.tls) and
         is_function(c.credentials, 0), do: :ok, else: {:error, :invalid_mqtt_connection}
  end

  @doc "Rechecks that the explicitly bound address still belongs to a host interface."
  def local_present?(address) do
    case :inet.getifaddrs() do
      {:ok, interfaces} -> Enum.any?(interfaces, fn {_, opts} -> {:addr, address} in opts end)
      _ -> false
    end
  end

  defp plans(channels, plans) do
    Enum.reduce_while(channels, {:ok, []}, fn c, {:ok, acc} ->
      plan = Enum.find(plans, &(&1["channel_id"] == c["channel_id"]))

      if is_map(plan) and plan["disposition"] == "supported" and
           "observeproperty" in plan["operations"] and
           JSONProjection.validate_selector(plan["selector"]) == :ok,
         do: {:cont, {:ok, acc ++ [plan]}},
         else: {:halt, :invalid}
    end)
  end

  defp local?({a, b, c, d}) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do:
      a == 127 or a == 10 or (a == 172 and b in 16..31) or
        (a == 192 and b == 168) or (a == 169 and b == 254)

  defp local?(_), do: false
  defp tls?(nil), do: true

  defp tls?(tls) do
    keys?(tls, [:server_name, :cacerts]) and is_binary(tls.server_name) and
      byte_size(tls.server_name) in 1..253 and
      Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/, tls.server_name) and
      Enum.all?(String.split(tls.server_name, "."), fn label ->
        byte_size(label) in 1..63 and not String.starts_with?(label, "-") and
          not String.ends_with?(label, "-")
      end) and certs?(tls.cacerts)
  end

  defp certs?(certs) when is_list(certs) and length(certs) in 1..8 do
    Enum.all?(certs, &(is_binary(&1) and byte_size(&1) in 1..16_384)) and
      Enum.reduce(certs, 0, &(byte_size(&1) + &2)) <= 65_536 and
      Enum.all?(certs, fn der ->
        try do
          :public_key.pkix_decode_cert(der, :otp)
          true
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      end)
  end

  defp certs?(_), do: false

  defp keys?(value, keys),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
