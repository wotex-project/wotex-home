defmodule Wotex.UDP.Admission do
  @moduledoc """
  Bounded admission before a socket call enters the UDP owner's mailbox.

  One atomic word packs the number of pending calls and their send bytes. A
  compare-and-swap reserves both limits together, so concurrent callers
  cannot each observe the same free capacity. Admission gives up after 64
  competing updates and returns overload. The owner creates the counter;
  the owner releases each reservation when it handles the call or exits.
  """

  alias Wotex.UDP.Error

  @doc "Reserves one pending call and its binary send bytes, or returns overload."
  @spec acquire(:atomics.atomics_ref(), pos_integer(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def acquire(counter, max_calls, max_bytes, bytes)
      when is_integer(max_calls) and max_calls > 0 and
             is_integer(max_bytes) and max_bytes > 0 and is_integer(bytes) and bytes >= 0 do
    reserve(counter, max_calls, max_bytes, bytes, 64)
  catch
    :error, :badarg -> invalid()
  end

  def acquire(_, _, _, _), do: invalid()

  @doc "Releases the exact reservation made for a completed or failed call."
  @spec release(:atomics.atomics_ref(), pos_integer(), non_neg_integer()) :: :ok
  def release(counter, max_bytes, bytes) do
    :atomics.sub(counter, 1, max_bytes + 1 + bytes)
    :ok
  end

  defp reserve(_, _, _, _, 0),
    do: {:error, %Error{kind: :overload, operation: :admission, reason: nil}}

  defp reserve(counter, max_calls, max_bytes, bytes, attempts) do
    radix = max_bytes + 1
    current = :atomics.get(counter, 1)
    calls = div(current, radix)
    queued_bytes = rem(current, radix)

    if calls >= max_calls or queued_bytes + bytes > max_bytes do
      {:error, %Error{kind: :overload, operation: :admission, reason: nil}}
    else
      case :atomics.compare_exchange(counter, 1, current, current + radix + bytes) do
        :ok -> :ok
        _ -> reserve(counter, max_calls, max_bytes, bytes, attempts - 1)
      end
    end
  end

  defp invalid,
    do: {:error, %Error{kind: :invalid_handle, operation: :admission, reason: nil}}
end
