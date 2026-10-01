defmodule WotexHome.Lifx.PowerClaim do
  @moduledoc """
  Immutable Store-issued context for one claimed direct-power operation.

  The random token is useful only from the process that owns the Store claim;
  copying this value to another process does not transfer authority. The
  command remains unsendable until that owner persists the handoff marker.
  """

  alias WotexHome.Durable.Receipt
  alias WotexHome.Mutation
  alias WotexHome.Semantics.Thing

  @enforce_keys [
    :receipt,
    :token,
    :stable_id,
    :thing,
    :mutation,
    :boot_epoch
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          receipt: Receipt.t(),
          token: binary(),
          stable_id: String.t(),
          thing: Thing.t(),
          mutation: Mutation.t(),
          boot_epoch: String.t()
        }
end
