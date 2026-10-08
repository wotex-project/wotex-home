defmodule WotexHome.Schedules.CalendarCorrespondence do
  @moduledoc "Finite source-bound recurring-calendar correspondence against independent raw-byte/Gregorian calculations; no autonomous or clock authority."
  alias WotexHome.Schedules.{CalendarReference, Codec, Recurrence, Tzif}

  def coordinates(source, %Tzif{} = zone) do
    with {:ok, reference} <- CalendarReference.decode(zone.name, zone.bytes),
         true <- reference.digest == zone.digest,
         {:ok, coordinates} <- prefix(source, reference, -1, [], 4),
         :ok <- compare_probes(source, zone, reference),
         do: {:ok, coordinates},
         else: (_ -> {:error, :calendar_correspondence_failed})
  end

  def coordinates(_, _), do: {:error, :calendar_correspondence_failed}

  defp prefix(_, _, _, coordinates, 0), do: {:ok, Enum.reverse(coordinates)}

  defp prefix(source, reference, after_ms, coordinates, remaining) do
    with {:ok, due} <- CalendarReference.next(source, after_ms, reference) do
      cond do
        due == nil -> {:ok, Enum.reverse(coordinates)}
        not Codec.utc?(due) or due <= after_ms -> {:error, :calendar_correspondence_failed}
        true -> prefix(source, reference, due, [["utc", due] | coordinates], remaining - 1)
      end
    end
  end

  defp compare_probes(source, zone, reference) do
    probes =
      case source["trigger"] do
        ["once", _, _, _, _, due] ->
          [-1, due - 1, due, due + 1]

        ["daily", _, _, _, start, finish] ->
          CalendarReference.probes(reference, start, finish)

        ["weekdays", _, _, _, _, start, finish] ->
          CalendarReference.probes(reference, start, finish)
      end

    Enum.reduce_while(probes, :ok, fn after_ms, :ok ->
      if Recurrence.next(source, after_ms, zone) ==
           CalendarReference.next(source, after_ms, reference),
         do: {:cont, :ok},
         else: {:halt, {:error, :calendar_correspondence_failed}}
    end)
  end
end
