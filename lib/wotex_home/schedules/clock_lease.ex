defmodule WotexHome.Schedules.ClockLease do
  @moduledoc "Pure conservative signed-clock lease. A host owner must establish original custody, monotonic continuity and current scope."
  alias WotexHome.Schedules.{ClockCodec, ClockSample, Codec}

  @scope ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest)
  @fields ~w(request_document policy_document package_document started_monotonic_ms received_monotonic_ms sample)a

  def establish(request_document, policy_document, package_document, started, received) do
    with {:ok, request} <- ClockCodec.decode_request(request_document),
         {:ok, policy} <- ClockCodec.decode_policy(policy_document),
         {:ok, parsed} <- ClockCodec.verify(package_document, request_document, policy_document),
         true <- elapsed?(started, received, policy),
         observed = parsed.record["observed_utc_ms"],
         response_elapsed = received - started,
         response_drift = drift(response_elapsed, policy.drift_ppm),
         error = policy.maximum_error_ms + policy.maximum_discontinuity_ms,
         lower = observed - error - response_drift,
         upper = observed + response_elapsed + error + response_drift,
         sample = %{
           "source_id" => policy.source_id,
           "qualification_digest" => policy.qualification_digest,
           "boot_epoch" => request["store_boot_epoch"],
           "generation" => request["clock_generation"],
           "sampled_monotonic_ms" => received,
           "utc_lower_ms" => lower,
           "utc_upper_ms" => upper,
           "maximum_age_ms" => policy.maximum_age_ms - response_elapsed,
           "drift_ppm" => policy.drift_ppm,
           "wall_confidence" => "qualified",
           "monotonic_continuous" => true
         },
         {:ok, _} <- ClockSample.encode(sample),
         do:
           {:ok,
            %{
              request_document: request_document,
              policy_document: policy_document,
              package_document: package_document,
              started_monotonic_ms: started,
              received_monotonic_ms: received,
              sample: sample
            }},
         else: (_ -> {:error, :schedule_clock_establishment_failed})
  end

  def current(lease, scope, now) do
    with true <- Codec.exact?(lease, @fields) and Codec.exact?(scope, @scope),
         {:ok, rebuilt} <-
           establish(
             lease.request_document,
             lease.policy_document,
             lease.package_document,
             lease.started_monotonic_ms,
             lease.received_monotonic_ms
           ),
         true <- rebuilt == lease,
         {:ok, request} <- ClockCodec.decode_request(lease.request_document),
         true <- Map.take(request, @scope) == scope,
         {:ok, policy} <- ClockCodec.decode_policy(lease.policy_document),
         true <-
           Codec.integer?(now, lease.received_monotonic_ms, Codec.maximum()) and
             now - lease.started_monotonic_ms < policy.maximum_age_ms,
         {:ok, interval} <-
           ClockSample.advance(
             lease.sample,
             scope["store_boot_epoch"],
             scope["clock_generation"],
             now
           ),
         do: {:ok, lease.sample, interval},
         else: (_ -> {:error, :schedule_clock_lease_unavailable})
  end

  def continuous?(policy, prior_monotonic, prior_wall, monotonic, wall) do
    with {:ok, _} <- ClockCodec.policy_document(policy),
         true <- Enum.all?([prior_monotonic, monotonic], &Codec.integer?(&1, 0, Codec.maximum())),
         true <-
           Enum.all?([prior_wall, wall], &Codec.integer?(&1, -Codec.maximum(), Codec.maximum())),
         true <- monotonic >= prior_monotonic do
      elapsed = monotonic - prior_monotonic

      abs(wall - prior_wall - elapsed) <=
        policy.maximum_discontinuity_ms + drift(elapsed, policy.drift_ppm)
    else
      _ -> false
    end
  end

  defp elapsed?(started, received, policy),
    do:
      Codec.integer?(started, 0, Codec.maximum() - 600_600) and
        Codec.integer?(received, started, Codec.maximum() - 600_600) and
        received - started < policy.maximum_response_ms

  defp drift(elapsed, ppm), do: div(elapsed * ppm + 999_999, 1_000_000)
end
