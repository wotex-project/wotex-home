defmodule WotexHome.LifxReadLab do
  @moduledoc false

  alias WotexHome.Lifx.CaptureSession

  def run([interface_name]), do: run_probe(interface_name, nil)
  def run([interface_name, candidate_ref]), do: run_probe(interface_name, candidate_ref)

  def run(_args) do
    IO.puts(:stderr, "usage: mix run bin/lifx_read_lab.exs INTERFACE [CANDIDATE_REF]")
    System.halt(2)
  end

  defp run_probe(interface_name, selected_ref) do
    case CaptureSession.start_link(interface_name: interface_name) do
      {:ok, owner} ->
        code =
          try do
            case CaptureSession.scope(owner) do
              {:ok, scope} ->
                probe(interface_name, scope, owner, selected_ref)

              {:error, reason} ->
                IO.puts(:stderr, "LIFX read-only interface changed: #{reason}")
                2
            end
          after
            GenServer.stop(owner)
          end

        System.halt(code)

      {:error, reason} ->
        IO.puts(:stderr, "LIFX read-only lab: #{reason}")
        System.halt(2)
    end
  end

  defp probe(interface_name, scope, owner, selected_ref) do
    case CaptureSession.discover(owner, 2, 7, 2_000) do
      {:ok, ref, candidates} ->
        IO.puts(
          "selected #{interface_name} #{:inet.ntoa(scope.local)}/#{scope.prefix}; #{length(candidates)} LIFX candidates"
        )

        case select(candidates, selected_ref) do
          {:ok, candidate} ->
            interview(owner, ref, candidate)

          {:error, reason} ->
            Enum.each(candidates, &IO.puts(&1.raw_ref))
            IO.puts(:stderr, "LIFX read-only selection unresolved: #{reason}")
            4
        end

      {:error, :no_candidates} ->
        IO.puts(
          "selected #{interface_name} #{:inet.ntoa(scope.local)}/#{scope.prefix}; 0 LIFX candidates"
        )

        3

      {:error, reason} ->
        IO.puts(:stderr, "LIFX read-only discovery failed: #{reason}")
        2
    end
  end

  defp select([candidate], nil), do: {:ok, candidate}

  defp select(candidates, ref) when is_binary(ref) do
    case Enum.filter(candidates, &(&1.raw_ref == ref)) do
      [candidate] -> {:ok, candidate}
      _ -> {:error, :candidate_not_in_capture}
    end
  end

  defp select(_candidates, nil), do: {:error, :candidate_selection_required}

  defp interview(owner, ref, candidate) do
    with {:ok, result} <- CaptureSession.interview(owner, ref, candidate.raw_ref, 2, 2_000),
         {:ok, evidence} <- CaptureSession.checkout(owner, ref) do
      digest =
        evidence.transcript
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      IO.puts(
        JSON.encode!(%{
          "candidate_ref" => candidate.raw_ref,
          "endpoint" => candidate.source_endpoint,
          "capture_epoch" => evidence.epoch,
          "transcript_sha256" => digest,
          "stable_id_claim" => result.stable_id,
          "manufacturer_reported" => result.manufacturer,
          "model_reported" => result.model,
          "firmware_reported" => result.firmware
        })
      )

      0
    else
      {:error, reason} ->
        IO.puts("#{candidate.raw_ref} interview unresolved: #{reason}")
        4
    end
  end
end

WotexHome.LifxReadLab.run(System.argv())
