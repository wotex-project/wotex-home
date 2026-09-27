defmodule WotexHome.Rules.OverrideLease do
  @moduledoc """
  A bounded whole-Thing operator override lease.

  `new/1` checks the lease's closed shape and duration. `active?/3` applies
  the current authority epoch and monotonic time, so a lease from an old
  authority cannot suppress a rule. The issuer must authenticate the operator
  and persist the lease before any runtime gate relies on it.
  """

  alias WotexHome.Id

  @max_i64 9_223_372_036_854_775_807
  @keys ~w(target_id operator_id authority_epoch start_ms expires_ms basis_revision)

  @enforce_keys [
    :target_id,
    :operator_id,
    :authority_epoch,
    :start_ms,
    :expires_ms,
    :basis_revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(document) when is_map(document) do
    if Enum.sort(Map.keys(document)) == Enum.sort(@keys) do
      lease = %__MODULE__{
        target_id: document["target_id"],
        operator_id: document["operator_id"],
        authority_epoch: document["authority_epoch"],
        start_ms: document["start_ms"],
        expires_ms: document["expires_ms"],
        basis_revision: document["basis_revision"]
      }

      if valid?(lease), do: {:ok, lease}, else: {:error, :invalid_override_lease}
    else
      {:error, :invalid_override_lease}
    end
  end

  def new(_), do: {:error, :invalid_override_lease}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = lease) do
    Id.valid?(lease.target_id) and Id.valid?(lease.operator_id) and
      valid_i64?(lease.authority_epoch) and valid_i64?(lease.start_ms) and
      valid_i64?(lease.expires_ms) and valid_i64?(lease.basis_revision) and
      lease.expires_ms > lease.start_ms and lease.expires_ms - lease.start_ms <= 86_400_000
  end

  def valid?(_), do: false

  @spec active?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def active?(%__MODULE__{} = lease, authority_epoch, now_ms)
      when is_integer(authority_epoch) and is_integer(now_ms) do
    valid?(lease) and lease.authority_epoch == authority_epoch and
      lease.start_ms <= now_ms and now_ms < lease.expires_ms
  end

  def active?(_, _, _), do: false

  defp valid_i64?(value), do: is_integer(value) and value >= 0 and value <= @max_i64
end
