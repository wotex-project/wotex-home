defmodule WotexHome.Rules.ArbitrationBasis do
  @moduledoc "Runtime-bound correspondence for the actual provided proposal set; no active-set completeness or control authority."
  alias WotexHome.RuntimeArtifacts
  alias WotexHome.Rules.{Arbitration, ArbitrationReference}

  @profile "whole-thing-arbitration-v1"
  @domain "wotex-home.whole-thing-arbitration-runtime.v1"
  @fields ~w(result profile scope limit input_digest outcome_digest runtime_digest obligations basis_digest)a
  @obligations ~w(closed_bounded_input whole_thing_conflicts equivalent_originals_preserved arbitration_before_cutoff deterministic_independent_capacity no_control_authority)a
  @hash ~r/\A[0-9a-f]{64}\z/

  def qualify(candidates, limit \\ 16) do
    with {:ok, expected} <- ArbitrationReference.batch(candidates, limit),
         {:ok, runtime} <- RuntimeArtifacts.digest([:wotex_home], @domain),
         {:ok, actual} <- Arbitration.batch(candidates, limit),
         true <- actual == expected,
         {:ok, repeated} <- RuntimeArtifacts.digest([:wotex_home], @domain),
         true <- runtime == repeated do
      basis = %{
        result: :basis_complete,
        profile: @profile,
        scope: :provided_proposal_set_only,
        limit: limit,
        input_digest: digest({@profile, :input, limit, Enum.sort_by(candidates, & &1.rule_id)}),
        outcome_digest: digest({@profile, :outcome, actual}),
        runtime_digest: runtime,
        obligations: @obligations
      }

      {:ok, Map.put(basis, :basis_digest, digest(basis))}
    else
      false -> {:error, :arbitration_correspondence_failed}
      error -> error
    end
  end

  @doc "Receipt syntax and commitment only; no current input/runtime correspondence."
  def valid?(basis) when is_map(basis) do
    Enum.sort(Map.keys(basis)) == Enum.sort(@fields) and
      basis.result == :basis_complete and basis.profile == @profile and
      basis.scope == :provided_proposal_set_only and is_integer(basis.limit) and
      basis.limit in 1..16 and basis.obligations == @obligations and
      Enum.all?(~w(input_digest outcome_digest runtime_digest basis_digest)a, fn key ->
        value = basis[key]
        is_binary(value) and byte_size(value) == 64 and value =~ @hash
      end) and digest(Map.delete(basis, :basis_digest)) == basis.basis_digest
  end

  def valid?(_), do: false

  def current(basis, candidates, limit \\ 16) do
    if valid?(basis) do
      case qualify(candidates, limit) do
        {:ok, ^basis} -> :ok
        {:ok, _} -> {:error, :stale_arbitration_basis}
        error -> error
      end
    else
      {:error, :invalid_arbitration_basis}
    end
  end

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
