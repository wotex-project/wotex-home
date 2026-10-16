defmodule WotexHome.Schedules.RoutineClockMath do
  @moduledoc """
  Checks exact receipt coordinates, anchored continuity and original sample expiry.

  `WotexHome.Schedules.RoutineClockMath.coordinate/2` takes raw primary and
  origin readings as signed-64 integer milliseconds. It subtracts exactly before
  checking the nonnegative signed-64 result, returning `{:ok, elapsed_ms}`.
  For example, negative raw readings remain valid:

      WotexHome.Schedules.RoutineClockMath.coordinate(-9_990, -10_000)
      # => {:ok, 10}

  `WotexHome.Schedules.RoutineClockMath.continuity/4` takes the complete elapsed
  policy, immutable initial observation, previous successful observation and
  new observation. It returns `:ok` only when source/reference/lifecycle identity,
  sample width, nonregressing continuous time and nonoverlapping primary
  intervals agree. Both anchor-to-current and previous-to-current relations
  must fit the full uncertainty intervals with ceiling-rounded ppm drift and
  the selected discontinuity allowance. The original anchor remains required
  after later successful reads; this function retains no state.

  `WotexHome.Schedules.RoutineClockMath.freshness/4` takes Store binding, policy,
  original native observation and final Store-relative elapsed milliseconds.
  It returns `{:ok, %{"sampled_ms" => sampled, "expires_ms" => expires}}`, where
  sampled is the original primary upper endpoint minus Store's raw origin and
  expires is sampled plus maximum_sample_ms. Runtime claims must match, and
  the final coordinate must satisfy sampled <= now < expires. A processing
  timestamp never replaces or renews that original pair.

  `WotexHome.Schedules.RoutineClockMath.utc_interval/6` takes original qualified
  ClockSample, exact UTC scope, Store-relative exchange start, raw native
  lifecycle start, raw Store origin and final Store-relative coordinate, all
  in milliseconds. It returns `{:ok, {lower, upper}}` in Unix UTC milliseconds
  by advancing the original sample through
  `WotexHome.Schedules.ClockSample.advance/4`. Exchange start must be strictly
  after lifecycle_start minus origin and no later than the original sample.
  Final time must be at least the sample coordinate and strictly before its
  original sampled_monotonic_ms + maximum_age_ms expiry. Equality is stale.

  Errors are payload-free `{:error, code}`: malformed claims use
  `:invalid_routine_clock`, exceeded signed arithmetic/output bounds use
  `:routine_clock_limit`, incompatible identities/continuity or lifecycle joins
  use `:routine_clock_unavailable`, and a valid expired sample uses
  `:routine_clock_snapshot_stale`. No result is clamped, renewed or partially
  returned.

  These calculations read no clock, Store or native owner. The clock owner and
  `WotexHome.Durable.Store` supply actual current observations, retain the
  immutable anchor and last successful witness, and irreversibly withdraw lost
  bases. A supplied qualified flag or passing arithmetic establishes neither
  source custody nor continuing authority.
  """

  alias WotexHome.Schedules.{ClockSample, RoutineClockCodec}

  @maximum 9_223_372_036_854_775_807
  @minimum -9_223_372_036_854_775_808
  @identity ~w(source_id reference_id source_digest reference_epoch reference_started_ms lifecycle_generation lifecycle_started_ms)

  @doc "Subtracts raw signed-64 primary/origin readings and checks the final nonnegative coordinate."
  @spec coordinate(term(), term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def coordinate(primary, origin) do
    protect(fn ->
      signed!(primary)
      signed!(origin)
      coordinate!(primary, origin)
    end)
  end

  @doc "Checks immutable identity and complete original/rolling interval relations."
  @spec continuity(term(), term(), term(), term()) :: :ok | {:error, atom()}
  def continuity(policy, anchor, previous, current) do
    case protect(fn ->
           anchor = take!(RoutineClockCodec.observation(anchor, policy))
           previous = take!(RoutineClockCodec.observation(previous, policy))
           current = take!(RoutineClockCodec.observation(current, policy))
           identity = Map.take(anchor, @identity)
           require!(Map.take(previous, @identity) === identity)
           require!(Map.take(current, @identity) === identity)
           if previous !== anchor, do: relation!(anchor, previous, policy)
           relation!(anchor, current, policy)
           relation!(previous, current, policy)
           :ok
         end) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Checks final time against the original native pair's exclusive sampling expiry."
  @spec freshness(term(), term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def freshness(binding, policy, observation, now) do
    protect(fn ->
      binding = take!(RoutineClockCodec.binding(binding))
      observation = take!(RoutineClockCodec.observation(observation, policy))
      require!(binding["runtime_digest"] === policy["runtime_digest"])
      nonnegative!(now)

      sampled =
        coordinate!(
          observation["primary_upper_ms"],
          String.to_integer(binding["monotonic_origin_ms"])
        )

      expires = signed!(sampled + policy["maximum_sample_ms"])
      require!(now >= sampled)
      require!(now < expires, :routine_clock_snapshot_stale)
      %{"sampled_ms" => sampled, "expires_ms" => expires}
    end)
  end

  @doc "Advances the original qualified UTC sample after strict lifecycle and exclusive-expiry checks."
  @spec utc_interval(term(), term(), term(), term(), term(), term()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, atom()}
  def utc_interval(sample, scope, started, lifecycle_started, origin, now) do
    protect(fn ->
      sample = take!(RoutineClockCodec.utc_sample(sample, scope))
      nonnegative!(started)
      signed!(lifecycle_started)
      signed!(origin)
      nonnegative!(now)
      boundary = signed!(lifecycle_started - origin)
      require!(started > boundary and started <= sample["sampled_monotonic_ms"])
      require!(now >= sample["sampled_monotonic_ms"])
      expires = signed!(sample["sampled_monotonic_ms"] + sample["maximum_age_ms"])
      require!(now < expires, :routine_clock_snapshot_stale)

      case ClockSample.advance(sample, scope["store_boot_epoch"], scope["clock_generation"], now) do
        {:ok, interval} -> interval
        {:error, :clock_out_of_range} -> fail(:routine_clock_limit)
        _ -> fail(:routine_clock_unavailable)
      end
    end)
  end

  defp relation!(old, new, policy) do
    delta = signed!(new["continuous_ms"] - old["continuous_ms"])
    require!(delta >= 0 and new["primary_lower_ms"] >= old["primary_upper_ms"])

    allowance =
      signed!(
        policy["maximum_discontinuity_ms"] + div(delta * policy["drift_ppm"] + 999_999, 1_000_000)
      )

    low = signed!(new["primary_lower_ms"] - old["primary_upper_ms"])
    high = signed!(new["primary_upper_ms"] - old["primary_lower_ms"])
    lower = signed!(delta - allowance)
    upper = signed!(delta + allowance)
    require!(low >= lower and high <= upper)
  end

  defp coordinate!(primary, origin) do
    elapsed = signed!(primary - origin)
    require!(elapsed >= 0)
    elapsed
  end

  defp signed!(value) do
    require!(is_integer(value), :invalid_routine_clock)
    require!(value >= @minimum and value <= @maximum, :routine_clock_limit)
    value
  end

  defp nonnegative!(value) do
    signed!(value)
    require!(value >= 0, :invalid_routine_clock)
    value
  end

  defp take!({:ok, value}), do: value
  defp take!({:error, code}), do: fail(code)
  defp require!(condition, code \\ :routine_clock_unavailable)
  defp require!(true, _), do: :ok
  defp require!(_, code), do: fail(code)
  defp fail(code), do: throw({:routine_clock_error, code})

  defp protect(callback) do
    {:ok, callback.()}
  rescue
    _ -> {:error, :invalid_routine_clock}
  catch
    :throw, {:routine_clock_error, code} -> {:error, code}
  end
end
