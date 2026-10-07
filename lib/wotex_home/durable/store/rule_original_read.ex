defmodule WotexHome.Durable.Store.RuleOriginalRead do
  @moduledoc "Existing-only original input joins, synchronously borrowing the sole Store connection."
  alias WotexHome.Durable.Store.{CandidateWriter, RuleWriter}
  alias WotexHome.Rules.OperationInput

  def status(db, credential, record) do
    with {:ok, kind, input} <- OperationInput.from_record(record),
         {:ok, receipt} <- read(db, credential, kind, input),
         {:ok, digest} <- OperationInput.digest(kind, input),
         do: {:ok, %{kind: kind, input_digest: digest, result: receipt}}
  end

  defp read(db, credential, "review", input) do
    with {:ok, source} <- OperationInput.source("review", input),
         do:
           CandidateWriter.original_status(
             db,
             credential,
             input["authority_epoch"],
             input["operation_id"],
             input["expected_revision"],
             source
           )
  end

  defp read(db, credential, "admit", input) do
    with {:ok, source} <- OperationInput.source("admit", input),
         do:
           RuleWriter.original_status(
             db,
             credential,
             "admit",
             input["authority_epoch"],
             input["operation_id"],
             input["expected_revision"],
             source
           )
  end

  defp read(db, credential, "activate", input),
    do:
      RuleWriter.original_status(
        db,
        credential,
        "activate",
        input["authority_epoch"],
        input["operation_id"],
        input["expected_revision"],
        input["admission_revision"]
      )

  defp read(db, credential, "invoke", input),
    do:
      RuleWriter.original_invocation_status(
        db,
        credential,
        input["authority_epoch"],
        input["operation_id"],
        input["rule_generation"],
        input["rule_id"]
      )
end
