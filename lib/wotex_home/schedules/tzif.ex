defmodule WotexHome.Schedules.Tzif do
  @moduledoc "Bounded immutable TZif 2/3/4 data and exact local-time resolution; no clock, OS-zone fallback or I/O."
  alias WotexHome.Schedules.{Codec, TzifFooter}
  @enforce_keys [:name, :digest, :bytes, :transitions, :types, :footer, :offsets]
  defstruct @enforce_keys

  def decode(name, bytes) when is_binary(bytes) and byte_size(bytes) in 44..65_536 do
    with true <- Codec.zone?(name),
         {:ok, first, rest} <- header(bytes),
         size = block_size(first, 4),
         true <- byte_size(rest) >= size,
         <<_old::binary-size(size), second::binary>> = rest,
         {:ok, current, rest} <- header(second),
         true <- current.version == first.version,
         {:ok, transitions, types, footer_text} <- block(current, rest),
         {:ok, footer} <- TzifFooter.decode(footer_text, current.version),
         :ok <- footer_correspondence(transitions, types, footer) do
      footer_offsets =
        if footer == nil,
          do: [],
          else:
            [footer.standard.offset] ++
              if(footer.daylight, do: [footer.daylight.offset], else: [])

      offsets = (Enum.map(types, & &1.offset) ++ footer_offsets) |> Enum.uniq() |> Enum.sort()

      {:ok,
       %__MODULE__{
         name: name,
         digest: Codec.hash(bytes),
         bytes: bytes,
         transitions: transitions,
         types: types,
         footer: footer,
         offsets: offsets
       }}
    else
      {:error, :unsupported_timezone_footer} = error -> error
      _ -> invalid()
    end
  end

  def decode(_, _), do: invalid()

  def valid?(%__MODULE__{name: name, bytes: bytes} = zone), do: decode(name, bytes) == {:ok, zone}
  def valid?(_), do: false

  def offset(%__MODULE__{} = zone, utc_ms) do
    if valid?(zone) and Codec.utc?(utc_ms), do: lookup(zone, div(utc_ms, 1_000)), else: invalid()
  end

  def offset(_, _), do: invalid()

  def resolve(%__MODULE__{} = zone, %NaiveDateTime{microsecond: {0, 0}} = local) do
    if valid?(zone) and local.year in 1970..9999 do
      naive_ms = local |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

      result =
        Enum.reduce_while(zone.offsets, {:ok, []}, fn offset, {:ok, candidates} ->
          candidate = naive_ms - offset * 1_000

          if Codec.utc?(candidate) do
            case lookup(zone, div(candidate, 1_000)) do
              {:ok, %{offset: ^offset}} -> {:cont, {:ok, [candidate | candidates]}}
              {:ok, _} -> {:cont, {:ok, candidates}}
              error -> {:halt, error}
            end
          else
            {:cont, {:ok, candidates}}
          end
        end)

      with {:ok, values} <- result, do: {:ok, Enum.sort(Enum.uniq(values))}
    else
      invalid()
    end
  end

  def resolve(_, _), do: invalid()

  defp lookup(zone, seconds) do
    latest =
      Enum.reduce_while(zone.transitions, nil, fn {time, type}, current ->
        if time <= seconds, do: {:cont, {time, type}}, else: {:halt, current}
      end)

    result =
      cond do
        zone.transitions == [] and zone.footer != nil ->
          TzifFooter.at(zone.footer, seconds)

        zone.transitions == [] ->
          {:ok, hd(zone.types)}

        latest == nil ->
          {:ok, hd(zone.types)}

        elem(latest, 0) == elem(List.last(zone.transitions), 0) and zone.footer != nil ->
          TzifFooter.at(zone.footer, seconds)

        elem(latest, 0) == elem(List.last(zone.transitions), 0) ->
          {:error, :timezone_undefined}

        true ->
          {:ok, Enum.at(zone.types, elem(latest, 1))}
      end

    case result do
      {:ok, %{designation: "-00"}} -> {:error, :timezone_undefined}
      other -> other
    end
  end

  defp header(
         <<"TZif", version, reserved::binary-size(15), utc::unsigned-big-32,
           standard::unsigned-big-32, leaps::unsigned-big-32, times::unsigned-big-32,
           types::unsigned-big-32, chars::unsigned-big-32, rest::binary>>
       )
       when version in [?2, ?3, ?4] and times <= 4_096 and types in 1..256 and chars in 1..2_048 and
              leaps == 0 do
    if reserved == <<0::120>> and utc in [0, types] and standard in [0, types],
      do:
        {:ok,
         %{
           version: version,
           utc: utc,
           standard: standard,
           times: times,
           types: types,
           chars: chars
         }, rest},
      else: invalid()
  end

  defp header(_), do: invalid()

  defp block_size(header, size),
    do: header.times * (size + 1) + header.types * 6 + header.chars + header.utc + header.standard

  defp block(header, bytes) do
    times_size = header.times * 8
    type_size = header.types * 6

    case bytes do
      <<times::binary-size(times_size), indexes::binary-size(header.times),
        types::binary-size(type_size), chars::binary-size(header.chars),
        standard::binary-size(header.standard), utc::binary-size(header.utc), "\n",
        footer::binary>>
      when byte_size(footer) in 1..257 ->
        with true <- :binary.last(footer) == 10,
             footer_text = binary_part(footer, 0, byte_size(footer) - 1),
             true <- Enum.all?(:binary.bin_to_list(footer_text), &(&1 in 32..126)),
             transitions = for(<<time::signed-big-64 <- times>>, do: time),
             true <- transitions == Enum.sort(Enum.uniq(transitions)),
             true <- Enum.all?(:binary.bin_to_list(indexes), &(&1 < header.types)),
             {:ok, decoded_types} <- types(types, chars),
             true <- indicators?(standard, utc, header.types) do
          {:ok, Enum.zip(transitions, :binary.bin_to_list(indexes)), decoded_types, footer_text}
        else
          _ -> invalid()
        end

      _ ->
        invalid()
    end
  end

  defp types(bytes, chars) do
    Enum.reduce_while(
      for(<<offset::signed-big-32, dst, index <- bytes>>, do: {offset, dst, index}),
      {:ok, []},
      fn {offset, dst, index}, {:ok, result} ->
        with true <- offset in -89_999..93_599 and dst in [0, 1] and index < byte_size(chars),
             tail = binary_part(chars, index, byte_size(chars) - index),
             {count, 1} <- :binary.match(tail, <<0>>),
             true <- count <= 32,
             designation = binary_part(tail, 0, count),
             true <- Regex.match?(~r/\A[A-Za-z0-9+-]*\z/, designation) do
          {:cont, {:ok, [%{offset: offset, dst: dst, designation: designation} | result]}}
        else
          _ -> {:halt, invalid()}
        end
      end
    )
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp indicators?(standard, utc, count) do
    standards =
      if standard == "", do: List.duplicate(0, count), else: :binary.bin_to_list(standard)

    universal = if utc == "", do: List.duplicate(0, count), else: :binary.bin_to_list(utc)

    Enum.all?(Enum.zip(standards, universal), fn {s, u} ->
      s in [0, 1] and u in [0, 1] and (u == 0 or s == 1)
    end)
  end

  defp footer_correspondence([], _, _), do: :ok
  defp footer_correspondence(_, _, nil), do: :ok

  defp footer_correspondence(transitions, types, footer) do
    {seconds, index} = List.last(transitions)

    with {:ok, type} <- TzifFooter.at(footer, seconds),
         true <- type == Enum.at(types, index),
         do: :ok,
         else: (_ -> invalid())
  end

  defp invalid, do: {:error, :invalid_timezone_data}
end
