defmodule WotexHome.Recovery.DomainCodec do
  @moduledoc "Bounded canonical historical domains and inert method/count correspondence."
  alias WotexHome.{Id, Profiles.Artifact, Profiles.Codec}
  alias WotexHome.Lifx.Packet
  @maximum 9_223_372_036_854_775_807
  @counts ~w(principal_rows active_principal_rows qualified_profile_heads current_observation_rows target_grant_rows source_grant_rows override_lease_rows)a
  @methods ~w(legacy_tofu operator_configured physical_button qr_install_code)
  @capabilities [
    ["power", "ordinary", "boolean", "none"],
    ["brightness", "ordinary", "fraction", "ppm"],
    ["colour_hsv", "ordinary", "hsv", "mdeg+ppm"],
    ["colour_xy", "ordinary", "xy", "ppm"],
    ["colour_temperature", "ordinary", "kelvin", "K"],
    ["smoke_state", "sensitive", "smoke_state", "none"],
    ["fault", "sensitive", "boolean", "none"],
    ["self_test", "sensitive", "boolean", "none"],
    ["battery_fraction", "sensitive", "fraction", "ppm"]
  ]

  def decode(document) when is_binary(document) and byte_size(document) in 1..4_194_304 do
    with {:ok, decoded} <- JSON.decode(document),
         {:ok, version, logical, counts, records} <- header(decoded),
         true <- Codec.digest?(logical) and records?(records),
         true <- JSON.encode!(decoded) == document do
      counter =
        if records != [] and Enum.all?(records, &complete?/1),
          do: "no_radio_state",
          else: "unknown"

      {:ok,
       %{
         version: version,
         document: document,
         logical_snapshot_digest: logical,
         source_counts: counts,
         domain_digest: Artifact.digest(document),
         domain_count: length(records),
         counter_state: counter,
         counter_state_digest: nil
       }}
    else
      _ -> invalid()
    end
  end

  def decode(_), do: invalid()

  @doc "Inert v2 completeness/method check; current trust, time and Store guards remain required."
  def acceptance_basis(document, method) do
    with {:ok, %{version: 2, counter_state: "no_radio_state"} = decoded} <- decode(document),
         true <- method in ["physical_disconnection", "qualified_network_isolation"] do
      {:ok, decoded}
    else
      _ -> {:error, :transfer_domain_isolation_unavailable}
    end
  end

  defp header(["wotex-home.controller-domains.v1", logical, records]),
    do: {:ok, 1, logical, nil, records}

  defp header(["wotex-home.controller-domains.v2", logical, counts, records])
       when is_list(counts) and length(counts) == 7 do
    if Enum.all?(counts, &integer?(&1, 0)) and Enum.all?(counts, &(&1 <= 131_072)) and
         Enum.at(counts, 1) <= hd(counts),
       do: {:ok, 2, logical, Map.new(Enum.zip(@counts, counts)), records},
       else: invalid()
  end

  defp header(_), do: invalid()

  defp records?(records) when is_list(records) and length(records) <= 64 do
    sorted?(records, &List.first/1) and Enum.all?(records, &record?/1) and
      Enum.reduce(records, 0, fn record, total -> total + length(Enum.at(record, 8)) end) <= 2_048
  end

  defp records?(_), do: false

  defp record?([target, "unresolved", nil, nil, nil, [], nil, [], [], ["unknown"]]),
    do: Id.valid?(target)

  defp record?([
         target,
         status,
         profile,
         revision,
         digest,
         caps,
         binding,
         histories,
         selections,
         basis
       ]) do
    Id.valid?(target) and status in ["active", "revoked"] and Id.valid?(profile) and
      integer?(revision, 0) and Codec.digest?(digest) and capabilities?(caps) and
      binding?(binding, target, profile, histories) and histories?(histories, target) and
      selections?(selections, histories) and basis?(basis) and
      basis_link?(basis, head(binding, histories)) and power_basis?(basis, caps)
  end

  defp record?(_), do: false

  defp binding?(nil, _, _, _), do: true

  defp binding?(
         [
           target,
           stable,
           digest,
           candidate,
           review,
           method,
           qualification,
           actor,
           profile,
           revision,
           version
         ],
         target,
         profile,
         histories
       )
       when is_list(histories) do
    Enum.all?([stable, candidate, review, qualification, actor], &Id.valid?/1) and
      Codec.digest?(digest) and method in @methods and integer?(revision, 1) and version in [1, 2] and
      case head(
             [
               target,
               stable,
               digest,
               candidate,
               review,
               method,
               qualification,
               actor,
               profile,
               revision,
               version
             ],
             histories
           ) do
        [values, _] when is_list(values) and length(values) == 14 ->
          Enum.map([1, 2, 3, 5, 6, 7, 8, 9, 10, 0, 4], &Enum.at(values, &1)) ==
            [
              target,
              stable,
              digest,
              candidate,
              review,
              method,
              qualification,
              actor,
              profile,
              revision,
              version
            ]

        _ ->
          false
      end
  end

  defp binding?(_, _, _, _), do: false

  defp histories?(histories, target) when is_list(histories) and length(histories) <= 32 do
    sorted?(histories, fn
      [[revision | _], _] -> revision
      _ -> nil
    end) and Enum.all?(histories, &history?(&1, target))
  end

  defp histories?(_, _), do: false

  defp history?(
         [
           [
             revision,
             target,
             stable,
             digest,
             version,
             candidate,
             review,
             method,
             qualification,
             actor,
             profile,
             manufacturer,
             model,
             firmware
           ] = values,
           basis
         ],
         target
       ) do
    integer?(revision, 1) and
      Enum.all?([stable, candidate, review, qualification, actor, profile], &Id.valid?/1) and
      Codec.digest?(digest) and version in [1, 2] and method in @methods and
      Enum.all?([manufacturer, model, firmware], &(is_nil(&1) or Id.valid?(&1))) and
      basis?(basis) and basis_link?(basis, [values, basis])
  end

  defp history?(_, _), do: false

  defp selections?(selections, histories)
       when is_list(selections) and length(selections) <= 2_048 do
    sorted?(selections, &List.first/1) and
      Enum.all?(selections, fn
        [
          revision,
          generation,
          state,
          artifact,
          projection,
          resource,
          binding,
          runtime,
          declaration,
          caps,
          basis
        ] ->
          identity = Enum.find(histories, fn [[rev | _], _] -> rev == binding end)

          integer?(revision, 1) and integer?(generation, 1) and state in ["selected", "revoked"] and
            Enum.all?([artifact, projection, runtime, declaration], &Codec.digest?/1) and
            integer?(resource, 0) and integer?(binding, 1) and binding < revision and
            not is_nil(identity) and capabilities?(caps) and basis?(basis) and
            basis_link?(basis, identity) and power_basis?(basis, caps) and
            (basis == ["unknown"] or
               (Enum.at(basis, 8) == "portable" and List.last(basis) == projection))

        _ ->
          false
      end)
  end

  defp selections?(_, _), do: false

  defp capabilities?(caps) when is_list(caps) and length(caps) in 1..9 do
    sorted?(caps, &List.first/1) and
      Enum.all?(caps, fn
        [key, operations, risk, kind, unit] ->
          [key, risk, kind, unit] in @capabilities and is_list(operations) and operations != [] and
            operations == Enum.sort(Enum.uniq(operations)) and
            Enum.all?(
              operations,
              &(&1 in if(risk == "sensitive", do: ["read"], else: ["read", "write"]))
            )

        _ ->
          false
      end)
  end

  defp capabilities?(_), do: false
  defp basis?(["unknown"]), do: true

  defp basis?([
         "lifx-direct-power-v1",
         "udp",
         "no_authenticated_radio_state",
         profile,
         "lifx:" <> serial,
         manufacturer,
         model,
         firmware,
         kind,
         dependency
       ]) do
    Enum.all?([profile, manufacturer, model, firmware], &Id.valid?/1) and
      match?({:ok, _}, Packet.target_from_hex(serial)) and kind in ["compiled", "portable"] and
      Codec.digest?(dependency)
  end

  defp basis?(_), do: false
  defp basis_link?(["unknown"], _), do: true

  defp basis_link?(basis, [
         [_, _, stable, _, 2, _, _, "legacy_tofu", _, _, profile, manufacturer, model, firmware],
         _
       ]),
       do: Enum.slice(basis, 3, 5) == [profile, stable, manufacturer, model, firmware]

  defp basis_link?(_, _), do: false
  defp power_basis?(["unknown"], _), do: true
  defp power_basis?(_, [["power", _, "ordinary", "boolean", "none"]]), do: true
  defp power_basis?(_, _), do: false
  defp head(nil, _), do: nil

  defp head(binding, histories) when is_list(histories),
    do:
      Enum.find(histories, fn
        [[revision | _], _] -> revision == Enum.at(binding, 9)
        _ -> false
      end)

  defp head(_, _), do: nil

  defp complete?([_, _, _, _, _, _, binding, histories, selections, basis]),
    do:
      not is_nil(binding) and histories != [] and basis != ["unknown"] and
        Enum.all?(histories, &(List.last(&1) != ["unknown"])) and
        Enum.all?(selections, &(List.last(&1) != ["unknown"]))

  defp sorted?(values, key) do
    keys =
      Enum.map(values, fn value ->
        if is_list(value) and value != [], do: key.(value), else: nil
      end)

    keys == Enum.sort(Enum.uniq(keys))
  end

  defp integer?(value, minimum), do: is_integer(value) and value in minimum..@maximum
  defp invalid, do: {:error, :invalid_transfer_domains}
end
