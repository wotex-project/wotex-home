defmodule WotexHome.Durable.Store.ExternalInputMath do
  @moduledoc """
  Pure clock arithmetic and report classification for external input collection.

  `WotexHome.Durable.Store.ExternalInputMath.bounds/5` takes Store's boot origin
  in milliseconds, the original report owner's canonical signed microsecond
  receipt/deadline strings, and positive declaration and Mapping freshness
  bounds in milliseconds. It returns `{:ok, bounds}` with atom keys
  `:received_store_ms`, `:owner_expires_ms` and `:expires_ms`. Expiry is capped
  by the original owner deadline and both freshness bounds; processing time
  never renews that lifetime.

      {:ok, bounds} =
        WotexHome.Durable.Store.ExternalInputMath.bounds(
          -10_000, "-1001", "59998999", 5_000, 1_000
        )

      # bounds == %{received_store_ms: 9998, owner_expires_ms: 69998, expires_ms: 10998}
      WotexHome.Durable.Store.ExternalInputMath.classify(
        bounds, 10_998, "usable", "1", "baseline"
      )
      # => {:ok, "expired"}

  Negative source coordinates use mathematical floor. Each published coordinate
  and each freshness sum must fit signed 64-bit bounds; projected coordinates
  must be nonnegative. The original receipt/deadline pair must preserve an
  integral lifetime of 100 through 60,000 milliseconds.

  `WotexHome.Durable.Store.ExternalInputMath.classify/5` takes those bounds, one
  final Store elapsed sample in milliseconds, original quality, a canonical
  unsigned 64-bit decimal sequence string or `nil`, and original continuity.
  It returns `{:ok, reason}` for the contract's first report refusal, or
  `{:ok, nil}` for a usable snapshot. Equality at expiry is expired. A baseline
  may supply a snapshot; this module retains no edge memory.

  `WotexHome.Durable.Store.ExternalInputMath.uncertainty_ms/1` rounds canonical
  unsigned microsecond strings upward to milliseconds and preserves `nil`.
  `WotexHome.Durable.Store.ExternalInputMath.fact_id/6` returns `{:ok, id}` by
  hashing the exact target, capability key, installation revision, report-owner
  epoch, report ID and report digest in the contract's canonical order.

  Malformed inputs return `{:error, :invalid_external_input}`; arithmetic and
  numeric-range overflow return `{:error, :external_input_limit}`. These helpers
  contact no owner, read no database and sample no clock. `WotexHome.Durable.Store`
  remains responsible for matching original rows, owner witnesses, clocks,
  current authorization, custody, runtime and signed review. This module alone
  establishes neither a current Fact nor physical qualification.
  """

  alias WotexHome.{Id, Profiles.EnvelopeCodec}

  @maximum 9_223_372_036_854_775_807
  @minimum -9_223_372_036_854_775_808
  @uint_max 18_446_744_073_709_551_615
  @bounds ~w(expires_ms owner_expires_ms received_store_ms)a

  @doc "Projects the original receipt/deadline and caps expiry at both declared freshness bounds."
  def bounds(origin_ms, receipt_us, deadline_us, declaration_ms, mapping_ms) do
    with :ok <- signed_integer(origin_ms),
         :ok <- signed_integer(origin_ms * 1000),
         {:ok, received} <- signed(receipt_us),
         {:ok, deadline} <- signed(deadline_us),
         true <-
           (deadline - received) in 100_000..60_000_000 and rem(deadline - received, 1000) == 0,
         :ok <- positive(declaration_ms),
         :ok <- positive(mapping_ms),
         receipt = Integer.floor_div(received, 1000) - origin_ms,
         owner = Integer.floor_div(deadline, 1000) - origin_ms,
         declaration = receipt + declaration_ms,
         mapping = receipt + mapping_ms,
         :ok <- signed_integer(receipt),
         :ok <- signed_integer(owner),
         :ok <- signed_integer(declaration),
         :ok <- signed_integer(mapping),
         true <- receipt >= 0 and owner >= 0 do
      {:ok,
       %{
         received_store_ms: receipt,
         owner_expires_ms: owner,
         expires_ms: min(owner, min(declaration, mapping))
       }}
    else
      false -> invalid()
      error -> error
    end
  end

  @doc "Classifies original report data at the single final sample, preserving first-refusal order."
  def classify(bounds, sampled_ms, quality, sequence, continuity) do
    with true <- valid_bounds?(bounds),
         :ok <- nonnegative(sampled_ms),
         true <- quality in ~w(usable invalid unknown stale),
         {:ok, number} <- sequence(sequence),
         true <- continuity in ~w(continuous baseline gap retained replayed unknown) do
      reason =
        cond do
          bounds.received_store_ms > sampled_ms -> "invalid"
          sampled_ms >= bounds.expires_ms -> "expired"
          quality != "usable" -> quality
          number == nil -> "missing_sequence"
          number > @maximum -> "unsupported_external_input"
          continuity in ~w(retained replayed gap) -> continuity
          continuity == "unknown" -> "baseline_required"
          true -> nil
        end

      {:ok, reason}
    else
      false -> invalid()
      error -> error
    end
  end

  @doc "Rounds original nonnegative microsecond uncertainty upward without floating-point arithmetic."
  def uncertainty_ms(nil), do: {:ok, nil}

  def uncertainty_ms(value) do
    with {:ok, micros} <- unsigned(value) do
      {:ok, div(micros, 1000) + if(rem(micros, 1000) == 0, do: 0, else: 1)}
    end
  end

  @doc "Hashes the exact slot, installation revision and original report identity into a stable Fact ID."
  def fact_id(target, key, install, owner_epoch, report_id, report_sha) do
    with true <- Id.valid?(target) and Id.valid?(key) and Id.valid?(report_id),
         :ok <- positive(install),
         true <- is_binary(owner_epoch) and Regex.match?(~r/\A[0-9a-f]{32}\z/, owner_epoch),
         true <- EnvelopeCodec.digest?(report_sha) do
      bytes = JSON.encode!([target, key, install, owner_epoch, report_id, report_sha])

      {:ok,
       "home:external-input:" <>
         Base.encode16(:crypto.hash(:sha256, "wotex-home.external-input-fact@1\n" <> bytes),
           case: :lower
         )}
    else
      false -> invalid()
      error -> error
    end
  end

  defp valid_bounds?(value) when is_map(value) and map_size(value) == 3 do
    Enum.sort(Map.keys(value)) == @bounds and
      Enum.all?(Map.values(value), &(is_integer(&1) and &1 in 0..@maximum)) and
      value.expires_ms > value.received_store_ms and value.expires_ms <= value.owner_expires_ms
  end

  defp valid_bounds?(_), do: false
  defp sequence(nil), do: {:ok, nil}
  defp sequence(value), do: unsigned(value)

  defp signed(value) when is_binary(value) and byte_size(value) in 1..20 do
    if value != "-0" and Regex.match?(~r/\A-?(0|[1-9][0-9]*)\z/, value) do
      integer = String.to_integer(value)
      with :ok <- signed_integer(integer), do: {:ok, integer}
    else
      invalid()
    end
  end

  defp signed(value) when is_binary(value) and byte_size(value) > 20, do: limit()
  defp signed(_), do: invalid()

  defp unsigned(value) when is_binary(value) and byte_size(value) in 1..20 do
    if Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, value) do
      integer = String.to_integer(value)
      if integer <= @uint_max, do: {:ok, integer}, else: limit()
    else
      invalid()
    end
  end

  defp unsigned(value) when is_binary(value) and byte_size(value) > 20, do: limit()
  defp unsigned(_), do: invalid()

  defp signed_integer(value) when is_integer(value) do
    if value in @minimum..@maximum, do: :ok, else: limit()
  end

  defp signed_integer(_), do: invalid()
  defp positive(value) when is_integer(value) and value > @maximum, do: limit()
  defp positive(value) when is_integer(value) and value > 0, do: :ok
  defp positive(_), do: invalid()
  defp nonnegative(value) when is_integer(value) and value > @maximum, do: limit()
  defp nonnegative(value) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative(_), do: invalid()
  defp invalid, do: {:error, :invalid_external_input}
  defp limit, do: {:error, :external_input_limit}
end
