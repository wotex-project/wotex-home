defmodule WotexHome.Profiles.AuthoringFixtures do
  @moduledoc "Pure comparison against explicit independently reviewed selector and decoded-report expectations."
  alias WotexHome.Id
  alias WotexHome.Profiles.{AuthoringProducer, EnvelopeCodec, ExternalEnvelope}

  @expected ~w(channel_id affordance semantic unit normalized_value quality quality_reason continuity source_ref source_epoch sequence source_time receipt_time interpretation)
  @report ~w(channel_id profile_sha256 binding capture_epoch source_ref source_epoch sequence source_time receipt_time continuity quality quality_reason value)
  @identity ~w(profile_sha256 closure_sha256 capture_digest compiler_ref)
  @enforce_keys [:envelope, :fixtures, :reader_limits, :data]
  defstruct @enforce_keys

  def check(envelope, fixtures, limits) do
    with {:ok, summary} <- ExternalEnvelope.to_map(envelope, limits),
         {:ok, projection} <-
           producer(Wotex.Profiles.Projection, :to_map, [envelope.projection, limits]),
         :ok <- fixtures(fixtures),
         {:ok, encoded} <- encode(fixtures),
         :ok <- expectations(fixtures, projection, limits),
         included = Enum.map(summary["home_contracts"], & &1["channel_id"]),
         {:ok, cases, covered} <-
           cases(fixtures, envelope.projection, projection, included, limits) do
      uncovered = Enum.sort(included -- covered)

      data = %{
        "format" => "wotex-home.authoring-fixtures@1",
        "consumption_sha256" => summary["consumption_sha256"],
        "fixtures_sha256" =>
          AuthoringProducer.sha("wotex-home.authoring-fixture-set@1\n" <> encoded),
        "status" => status(cases, uncovered),
        "cases" => cases,
        "uncovered_channels" => uncovered
      }

      {:ok,
       %__MODULE__{envelope: envelope, fixtures: fixtures, reader_limits: limits, data: data}}
    end
  end

  def to_map(%__MODULE__{} = value, current, limits) when map_size(value) == 5 do
    with true <- value.reader_limits == limits,
         {:ok, old} <- ExternalEnvelope.to_map(value.envelope, limits),
         {:ok, now} <- ExternalEnvelope.to_map(current, limits),
         :ok <- same_basis(old, now),
         {:ok, rebuilt} <- check(current, value.fixtures, limits),
         true <- rebuilt == value,
         do: {:ok, rebuilt.data},
         else: (
           false -> {:error, :invalid_authoring_fixture}
           error -> error
         )
  end

  def to_map(_, _, _), do: {:error, :invalid_authoring_fixture}

  defp same_basis(%{"consumption_sha256" => basis}, %{"consumption_sha256" => basis}), do: :ok
  defp same_basis(_, _), do: {:error, :stale_authoring_basis}

  defp fixtures(fixtures) do
    with :ok <- bounded(fixtures, 32),
         true <-
           Enum.all?(fixtures, fn f ->
             EnvelopeCodec.keys?(f, ~w(expected id report selector)) and Id.valid?(f["id"]) and
               EnvelopeCodec.keys?(f["report"], Enum.sort(@report)) and
               EnvelopeCodec.keys?(f["expected"], Enum.sort(@expected))
           end),
         ids = Enum.map(fixtures, & &1["id"]),
         true <- ids == Enum.sort(Enum.uniq(ids)),
         :ok <- sizes(fixtures),
         do: :ok,
         else: (
           false -> {:error, :invalid_authoring_fixture}
           error -> error
         )
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :authoring_limit}
  defp bounded([_ | tail], remaining), do: bounded(tail, remaining - 1)
  defp bounded(_, _), do: {:error, :invalid_authoring_fixture}

  defp sizes(fixtures) do
    opts = [
      max_bytes: 65_536,
      max_depth: 8,
      max_nodes: 4096,
      max_collection_size: 256,
      max_string_bytes: 256
    ]

    Enum.reduce_while(fixtures, {:ok, 0}, fn fixture, {:ok, total} ->
      case producer(Wotex.JSON, :encode, [fixture, opts]) do
        {:ok, bytes} when byte_size(bytes) <= 65_536 and total + byte_size(bytes) <= 262_144 ->
          {:cont, {:ok, total + byte_size(bytes)}}

        {:ok, _} ->
          {:halt, {:error, :authoring_limit}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp expectations(fixtures, projection, limits) do
    Enum.reduce_while(fixtures, :ok, fn fixture, :ok ->
      data = Map.merge(fixture["expected"], Map.take(projection, @identity))

      case producer(Wotex.Profiles.Proposal, :new, [data, limits]) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp cases(fixtures, native, projection, included, limits) do
    Enum.reduce_while(fixtures, {:ok, [], []}, fn fixture, {:ok, cases, covered} ->
      case evaluate(fixture, native, projection, included, limits) do
        {:ok, reason} ->
          disposition = if reason == nil, do: "passed", else: "failed"
          result = %{"id" => fixture["id"], "disposition" => disposition, "reason" => reason}

          covered =
            if reason == nil, do: [fixture["report"]["channel_id"] | covered], else: covered

          {:cont, {:ok, [result | cases], covered}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, cases, covered} -> {:ok, Enum.reverse(cases), Enum.uniq(covered)}
      error -> error
    end
  end

  defp evaluate(fixture, native, projection, included, limits) do
    channel = fixture["report"]["channel_id"]
    plan = Enum.find(projection["channel_plans"], &(&1["channel_id"] == channel))

    cond do
      channel not in included or plan == nil or plan["disposition"] != "supported" ->
        {:ok, "channel_unavailable"}

      plan["selector"] != fixture["selector"] ->
        {:ok, "selector_mismatch"}

      true ->
        interpret(fixture, native, limits)
    end
  end

  defp interpret(fixture, native, limits) do
    with {:ok, value} <-
           producer(Wotex.Profiles.Interpreter, :project, [native, fixture["report"], limits]),
         {:ok, value} <- producer(Wotex.Profiles.Proposal, :to_map, [value, limits]) do
      {:ok,
       if(Map.take(value, @expected) == fixture["expected"], do: nil, else: "proposal_mismatch")}
    else
      {:error, reason} = error
      when reason in [:authoring_limit, :profiles_producer_unavailable] ->
        error

      _ ->
        {:ok, "interpretation_refused"}
    end
  end

  defp status([], _), do: "not_supplied"

  defp status(cases, uncovered) do
    cond do
      Enum.any?(cases, &(&1["disposition"] == "failed")) -> "failed"
      uncovered != [] -> "incomplete"
      true -> "passed"
    end
  end

  defp encode(fixtures), do: producer(Wotex.JSON, :encode, [fixtures])

  defp producer(module, function, args),
    do: AuthoringProducer.call(module, function, args, :invalid_authoring_fixture)
end
