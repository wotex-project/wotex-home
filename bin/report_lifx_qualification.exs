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

  def public_keys(document) when is_map(document) and map_size(document) <= 32 do
    Enum.reduce_while(document, {:ok, %{}}, fn {key_id, encoded}, {:ok, keys} ->
      with true <- WotexHome.Id.valid?(key_id),
           true <- is_binary(encoded) and byte_size(encoded) == 43,
           {:ok, key} <- Base.url_decode64(encoded, padding: false),
           true <- byte_size(key) == 32 and
                     Base.url_encode64(key, padding: false) == encoded do
        {:cont, {:ok, Map.put(keys, key_id, key)}}
      else
        _ -> {:halt, {:error, :invalid_trust_keys}}
      end
    end)
  end

  def public_keys(_), do: {:error, :invalid_trust_keys}
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

  [cohort_path, attestations_path, trust_keys_path] ->
    with {:ok, cohort} <- QualificationReportInput.read_json(cohort_path),
         {:ok, attestations} <- QualificationReportInput.read_json(attestations_path),
         {:ok, key_document} <- QualificationReportInput.read_json(trust_keys_path),
         {:ok, keys} <- QualificationReportInput.public_keys(key_document),
         {:ok, report} <- Programme.lifx_attested_report(cohort, attestations, keys) do
      IO.puts(JSON.encode!(report))
    else
      {:error, reason} ->
        IO.puts(:stderr, "qualification report error: #{inspect(reason)}")
        System.halt(1)
    end

  _ ->
    IO.puts(:stderr, "usage: mix run --no-compile bin/report_lifx_qualification.exs COHORT.json RECEIPTS.json [TRUST_KEYS.json for signed receipts]")
    System.halt(2)
end
