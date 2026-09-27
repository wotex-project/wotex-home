#!/usr/bin/env elixir
defmodule QualificationReportInput do
  def read_json(path) do
    with {:ok, %{type: :regular, size: size}} when size <= 1_048_576 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= 1_048_576,
         {:ok, value} <- JSON.decode(bytes) do
      {:ok, value}
    else
      _ -> {:error, :invalid_input_file}
    end
  end
end

alias WotexHome.Qualification.Programme

case System.argv() do
  [cohort_path, receipts_path] ->
    with {:ok, cohort} <- QualificationReportInput.read_json(cohort_path),
         {:ok, receipts} <- QualificationReportInput.read_json(receipts_path),
         {:ok, report} <- Programme.lifx_report(cohort, receipts) do
      IO.puts(JSON.encode!(report))
    else
      {:error, reason} ->
        IO.puts(:stderr, "qualification report error: #{inspect(reason)}")
        System.halt(1)
    end

  _ ->
    IO.puts(:stderr, "usage: mix run bin/report_lifx_qualification.exs COHORT.json RECEIPTS.json")
    System.halt(2)
end
