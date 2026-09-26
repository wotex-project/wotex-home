defmodule WotexHome.Durable.Receipt do
  @moduledoc """
  Durable disposition of one scoped operation ID.

  `:held` is a stored request awaiting the future authenticated authority. It
  is not command admission and cannot be claimed by any driver in this build.
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
          disposition: :held | :rejected,
          reason: String.t() | nil,
          revision: non_neg_integer()
        }
end
