defmodule WotexHome.Qualification.Programme do
  @moduledoc """
  Fixed LIFX case obligations and a sanitized, non-authorizing gap report.

  Receipt syntax is checked by Evidence, but signatures, reviewer identity and
  raw artifact provenance are not. Even a complete report remains unverified.
  """

  alias WotexHome.Qualification.Evidence

  @schema "wotex-home.qualification-programme.v1"
  @report_schema "wotex-home.qualification-report.v1"
  @programme_id "lifx-old-eu-v1"
  @programme_digest "c8b87806eb765a74a1b91c37e1cbf07bbb4d69b4415dbe173cc994397b27ebd3"
  @requirements ~w(H03-T1 H03-T2 H03-T3 H03-T4 H03-T5 H03-T6)

  @spec lifx_cases() :: {:ok, [map()], String.t()} | {:error, atom()}
  def lifx_cases do
    path = Application.app_dir(:wotex_home, "priv/qualification/lifx-old-eu-v1.json")

    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= 16_384,
         digest <- :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         true <- digest == @programme_digest,
         {:ok, %{"schema" => @schema, "programme_id" => @programme_id, "cases" => cases} = doc} <-
           JSON.decode(bytes),
         true <- Map.keys(doc) |> Enum.sort() == ~w(cases programme_id schema),
         true <- is_list(cases) and length(cases) in 1..64,
         true <- Enum.all?(cases, &match?({:ok, _}, Evidence.case_definition(&1))),
         true <- Enum.uniq_by(cases, & &1["case_id"]) == cases,
         true <- Enum.map(cases, & &1["requirement_id"]) |> Enum.uniq() |> Enum.sort() == @requirements do
      {:ok, cases, digest}
    else
      _ -> {:error, :invalid_qualification_programme}
    end
  end

  @spec lifx_report(map(), [map()]) :: {:ok, map()} | {:error, atom()}
  def lifx_report(cohort, receipts) do
    with {:ok, cases, programme_digest} <- lifx_cases(),
         {:ok, cohort_digest} <- Evidence.cohort_digest(cohort),
         {:ok, results} <- Evidence.summarize(cases, receipts, cohort) do
      counts =
        Map.new(~w(passed failed blocked not_run), fn status ->
          {status, Enum.count(results, &(&1["status"] == status))}
        end)

      {:ok,
       %{
         "schema" => @report_schema,
         "programme_id" => @programme_id,
         "programme_digest" => programme_digest,
         "cohort_digest" => cohort_digest,
         "provenance" => "unverified",
         "status" => if(counts["passed"] == length(results), do: "complete_unverified", else: "incomplete"),
         "counts" => counts,
         "cases" => results
       }}
    end
  end
end
