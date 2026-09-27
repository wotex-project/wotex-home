defmodule WotexHome.Durable.Receipt do
  @moduledoc """
  Durable disposition of one scoped operation ID.

  `:held` is a stored request awaiting authenticated authority. It is not
  command admission. Execution states require a separately qualified transition;
  this structure reports them without granting a driver capability.

  Store returns receipts so callers can reconcile a timed-out request by its
  original principal, authority epoch and operation ID. Consumers should use
  the disposition and revision together; a reply alone cannot establish a
  device effect.
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
