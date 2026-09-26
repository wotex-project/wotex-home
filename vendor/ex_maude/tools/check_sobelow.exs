defmodule ExMaude.SobelowReview do
  @moduledoc false

  @review Path.expand("../security/sobelow-reviewed.json", __DIR__)

  def run(args) do
    report =
      case args do
        [] -> scan()
        ["--report", path] -> File.read!(path)
        _ -> Mix.raise("usage: mix run tools/check_sobelow.exs [--report path]")
      end

    with {:ok, actual} <- Jason.decode(report),
         {:ok, reviewed} <- @review |> File.read!() |> Jason.decode() do
      compare(actual, reviewed)
    else
      {:error, error} -> Mix.raise("Sobelow report or review is invalid: #{inspect(error)}")
    end
  end

  defp scan do
    {output, status} =
      System.cmd("mix", ["sobelow", "--config", "--no-router", "--format", "json", "--exit"],
        cd: Path.expand("..", __DIR__)
      )

    if status in [0, 1], do: output, else: Mix.raise("Sobelow execution failed: #{status}")
  end

  defp compare(actual, reviewed) do
    findings = Map.fetch!(actual, "findings")
    high = Map.fetch!(findings, "high_confidence")
    medium = Map.fetch!(findings, "medium_confidence")
    low = Map.fetch!(findings, "low_confidence")
    expected = Map.fetch!(reviewed, "findings")
    version = Map.fetch!(actual, "sobelow_version")

    cond do
      high != [] or medium != [] ->
        Mix.raise("Sobelow has unreviewed medium or high confidence findings")

      actual["total_findings"] != length(low) ->
        Mix.raise("Sobelow finding count does not match its report")

      version != reviewed["sobelow_version"] ->
        Mix.raise("Sobelow version changed; review its findings again")

      sort(low) != sort(expected) ->
        Mix.raise("Sobelow findings differ from the exact reviewed set")

      true ->
        Mix.shell().info(
          "Sobelow scanned all source: #{length(low)} exact reviewed low-confidence findings; 0 unreviewed"
        )
    end
  end

  defp sort(findings) do
    Enum.sort_by(findings, fn finding ->
      {finding["file"], finding["line"], finding["type"], finding["variable"]}
    end)
  end
end

ExMaude.SobelowReview.run(System.argv())
