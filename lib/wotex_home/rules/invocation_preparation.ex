defmodule WotexHome.Rules.InvocationPreparation do
  @moduledoc """
  Closed inert input for one admitted explicit-rule kernel calculation.

  Store prepares this native atom-keyed map after authenticating the principal
  and checking the scoped original. It binds principal/epoch/operation, active
  rule generation, admission revision, rule identity, exact admission document
  and artifact/runtime digests through a reproducible commitment. Preparing a
  new invocation writes no receipt, causal root or lease. The value contains no
  credential, Store handle, clock callback or grant.

  `identity/1` returns `:ok` or `{:error, :invalid_rule_operation_input}` after
  checking the closed shape, coordinate/hash bounds and commitment. Admission
  bytes are limited to 4 MiB. This check neither decodes history nor proves that
  those bytes match the supplied artifact digest.

  `decode/1` additionally verifies the document digest, decodes the complete
  admission and requires its exact rule and v4 runtime binding. Success is
  `{:ok, artifact}`; any mismatch returns
  `{:error, :invalid_rule_operation_input}`. A valid embedded v4 record does not
  establish that Store still has that admission active or that its code and
  grants remain current.

  `proposal/1` returns `{:ok, projection}` from the actual initial generic kernel
  calculation, or `{:error, reason}` from validation or the closed kernel adapter.
  `WotexHome.Authority` calls it outside the Store writer. Its fixed logical
  initial time supplies no current clock confidence or extended execution lease.
  Failures produce no partial or fallback effect, and no run is persisted here.

  At commit, Store authenticates again, recovers an exact existing original first,
  and otherwise repeats the complete current bindings and final publication guards.
  Possession of this preparation or its projection grants no physical authority.
  """

  alias WotexHome.Id
  alias WotexHome.Rules.{AdmissionArtifact, KernelProposal}

  @format "wotex-home.rule-invocation-preparation.v1"
  @keys ~w(format principal_id authority_epoch operation_id rule_generation admission_revision rule_id artifact_document artifact_digest runtime_digest preparation_digest)a
  @max_i64 9_223_372_036_854_775_807
  @hash ~r/\A[0-9a-f]{64}\z/

  @doc false
  def build(principal, epoch, operation, generation, admission, document) do
    with {:ok, artifact} <- AdmissionArtifact.decode(document) do
      preparation = %{
        format: @format,
        principal_id: principal,
        authority_epoch: epoch,
        operation_id: operation,
        rule_generation: generation,
        admission_revision: admission,
        rule_id: artifact.rule.id,
        artifact_document: document,
        artifact_digest: AdmissionArtifact.digest(document),
        runtime_digest: artifact.proposal_basis.runtime_digest
      }

      preparation = Map.put(preparation, :preparation_digest, digest(preparation))
      with {:ok, _} <- decode(preparation), do: {:ok, preparation}
    end
  end

  @spec identity(term()) :: :ok | {:error, :invalid_rule_operation_input}
  def identity(preparation) when is_map(preparation) and not is_struct(preparation) do
    if map_size(preparation) == length(@keys) and
         Enum.sort(Map.keys(preparation)) == Enum.sort(@keys) and
         preparation.format == @format and Id.valid?(preparation.principal_id) and
         Id.valid?(preparation.operation_id) and Id.valid?(preparation.rule_id) and
         integer?(preparation.authority_epoch, 1, @max_i64) and
         integer?(preparation.rule_generation, 0, @max_i64 - 1) and
         integer?(preparation.admission_revision, 1, @max_i64) and
         is_binary(preparation.artifact_document) and
         byte_size(preparation.artifact_document) <= 4_194_304 and
         Enum.all?(
           [
             preparation.artifact_digest,
             preparation.runtime_digest,
             preparation.preparation_digest
           ],
           &hash?/1
         ) and digest(preparation) == preparation.preparation_digest,
       do: :ok,
       else: invalid()
  end

  def identity(_preparation), do: invalid()

  @spec decode(term()) :: {:ok, map()} | {:error, atom()}
  def decode(preparation) do
    with :ok <- identity(preparation),
         true <-
           AdmissionArtifact.digest(preparation.artifact_document) == preparation.artifact_digest,
         {:ok, artifact} <- AdmissionArtifact.decode(preparation.artifact_document),
         true <- artifact.rule.id == preparation.rule_id,
         true <- artifact.proposal_basis.profile == "explicit-boolean-light-v4",
         true <- artifact.proposal_basis.runtime_digest == preparation.runtime_digest do
      {:ok, artifact}
    else
      _ -> invalid()
    end
  end

  @spec proposal(term()) :: {:ok, map()} | {:error, atom()}
  def proposal(preparation) do
    with {:ok, artifact} <- decode(preparation) do
      [resource] = artifact.resources

      KernelProposal.propose(
        artifact.rule,
        Map.fetch!(artifact.things, resource["thing_id"]),
        resource["resource_revision"],
        Map.take(preparation, [
          :principal_id,
          :authority_epoch,
          :operation_id,
          :rule_generation,
          :preparation_digest
        ]),
        preparation.runtime_digest
      )
    end
  end

  defp digest(preparation) do
    {@format, preparation.principal_id, preparation.authority_epoch, preparation.operation_id,
     preparation.rule_generation, preparation.admission_revision, preparation.rule_id,
     preparation.artifact_digest, preparation.runtime_digest}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp hash?(value), do: is_binary(value) and byte_size(value) == 64 and value =~ @hash

  defp integer?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp invalid, do: {:error, :invalid_rule_operation_input}
end
