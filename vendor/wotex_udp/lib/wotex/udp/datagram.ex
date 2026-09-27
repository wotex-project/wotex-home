defmodule Wotex.UDP.Datagram do
  @moduledoc """
  One received datagram and its source address.

  `data` is the original binary, not parsed or decoded. The source is a
  physical network endpoint; callers decide whether to accept or interpret it.
  """

  alias Wotex.UDP.Endpoint

  @enforce_keys [:data, :source]
  defstruct [:data, :source]

  @type t :: %__MODULE__{data: binary(), source: Endpoint.t()}
end
