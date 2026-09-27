defmodule WotexHome.Durable.Receipt do
  @moduledoc """
  Durable disposition of one scoped operation ID.

  `:held` is a stored request awaiting authenticated authority. It is not
  command admission. Execution states require a separately qualified transition;
  this structure reports them without granting a driver capability.
  """

  @enforce_keys [
    :principal_id,
    :authority_epoch,
    :operation_id,
    :disposition,
    :reason,
    :revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          principal_id: String.t(),
          authority_epoch: non_neg_integer(),
          operation_id: String.t(),
          disposition:
            :held
            | :rejected
            | :queued
            | :claimed
            | :dispatching
            | :protocol_accepted
            | :observed
            | :contradicted
            | :failed
            | :outcome_unknown,
          reason: String.t() | nil,
          revision: non_neg_integer()
        }
end
