defmodule WotexHome.Recovery.TransferAcceptanceRecord do
  @moduledoc "Read-only exact retained acceptance-row audit; no current trust or authority."
  alias WotexHome.Profiles.Artifact

  alias WotexHome.Recovery.{
    DomainCodec,
    IsolationDecision,
    TransferAcceptanceCodec,
    TransferReviewCodec
  }

  @review_links ~w(principal_id source_epoch retirement_revision source_maintenance_revision source_rule_generation deployment_id source_owner_id destination_owner_id domain_digest domain_count counter_state counter_state_digest)

  def audit([
        principal,
        epoch,
        operation,
        input_bytes,
        receipt_bytes,
        review_bytes,
        package,
        isolation_document,
        policy_document,
        domain_document,
        revision
      ]) do
    with {:ok, input} <- TransferAcceptanceCodec.decode("operation", input_bytes),
         {:ok, receipt} <- TransferAcceptanceCodec.decode("acceptance", receipt_bytes),
         {:ok, review} <- TransferReviewCodec.decode(review_bytes),
         true <- Map.take(receipt, Map.keys(input)) == input,
         true <-
           receipt["principal_id"] == principal and receipt["source_epoch"] == epoch and
             receipt["operation_id"] == operation and receipt["revision"] == revision,
         true <- Map.take(receipt, @review_links) == Map.take(review, @review_links),
         true <- receipt["review_digest"] == Artifact.digest(review_bytes),
         {:ok, scope} <- TransferReviewCodec.isolation_scope(review),
         {:ok, isolation} <- IsolationDecision.audit(package, scope, policy_document),
         true <-
           isolation.document == isolation_document and
             isolation.package_digest == receipt["isolation_package_digest"] and
             isolation.decision_digest == receipt["isolation_decision_digest"],
         true <-
           isolation.decision["issued_at_utc_ms"] >= review["issued_at_utc_ms"] and
             isolation.decision["expires_at_utc_ms"] <= review["expires_at_utc_ms"],
         {:ok, domains} <-
           DomainCodec.acceptance_basis(domain_document, isolation.decision["method"]),
         true <-
           Enum.all?(
             [:domain_digest, :domain_count, :counter_state, :counter_state_digest],
             fn field -> domains[field] == review[Atom.to_string(field)] end
           ),
         :ok <- TransferAcceptanceCodec.match_source_counts(receipt, domains.source_counts) do
      {:ok,
       %{input: input, receipt: receipt, review: review, domains: domains, isolation: isolation}}
    else
      _ -> {:error, :corrupt_controller_acceptance}
    end
  end

  def audit(_), do: {:error, :corrupt_controller_acceptance}
end
