defmodule WotexHome.Schedules.ClockSample do
  @moduledoc "Inert boot/generation-scoped uncertainty calculation. Only a qualified host owner may establish these inputs."
  alias WotexHome.{Id, Schedules.Codec}
  alias WotexHome.Profiles.Codec, as: ProfileCodec

  @format "wotex-home.schedule-clock.v1"
  @fields ~w(source_id qualification_digest boot_epoch generation sampled_monotonic_ms utc_lower_ms utc_upper_ms maximum_age_ms drift_ppm wall_confidence monotonic_continuous)

  def encode(sample) do
    if Codec.exact?(sample, @fields) and Id.valid?(sample["source_id"]) and
         Id.valid?(sample["boot_epoch"]) and
         Codec.integer?(sample["generation"], 1, Codec.maximum()) and
         Codec.integer?(sample["sampled_monotonic_ms"], 0, Codec.maximum() - 600_600) and
         Codec.integer?(sample["maximum_age_ms"], 1, 600_000) and
         Codec.integer?(sample["drift_ppm"], 0, 1_000) and
         is_boolean(sample["monotonic_continuous"]) and confidence?(sample) do
      {:ok, JSON.encode!([@format | Enum.map(@fields, &sample[&1])])}
    else
      invalid()
    end
  end

  def decode(bytes) do
    with {:ok, [@format | values]} <- Codec.record(bytes),
         true <- length(values) == length(@fields),
         sample = Map.new(Enum.zip(@fields, values)),
         {:ok, ^bytes} <- encode(sample),
         do: {:ok, sample},
         else: (_ -> invalid())
  end

  def advance(sample, boot, generation, now) do
    with {:ok, _} <- encode(sample),
         true <- Id.valid?(boot) and Codec.integer?(generation, 1, Codec.maximum()),
         true <- Codec.integer?(now, 0, Codec.maximum()) do
      cond do
        sample["boot_epoch"] != boot -> {:error, :old_boot}
        sample["generation"] != generation -> {:error, :clock_changed}
        now < sample["sampled_monotonic_ms"] -> {:error, :clock_rollback}
        now - sample["sampled_monotonic_ms"] > sample["maximum_age_ms"] -> {:error, :clock_stale}
        sample["wall_confidence"] != "qualified" -> {:error, :clock_uncertain}
        not sample["monotonic_continuous"] -> {:error, :clock_discontinuous}
        true -> advance_interval(sample, now)
      end
    else
      _ -> invalid()
    end
  end

  defp advance_interval(sample, now) do
    elapsed = now - sample["sampled_monotonic_ms"]
    drift = div(elapsed * sample["drift_ppm"] + 999_999, 1_000_000)
    lower = sample["utc_lower_ms"] + elapsed - drift
    upper = sample["utc_upper_ms"] + elapsed + drift

    if lower >= 0 and upper <= Codec.utc_maximum(),
      do: {:ok, {lower, upper}},
      else: {:error, :clock_out_of_range}
  end

  defp confidence?(%{"wall_confidence" => "qualified"} = sample),
    do:
      ProfileCodec.digest?(sample["qualification_digest"]) and Codec.utc?(sample["utc_lower_ms"]) and
        Codec.utc?(sample["utc_upper_ms"]) and sample["utc_upper_ms"] >= sample["utc_lower_ms"]

  defp confidence?(%{"wall_confidence" => "unqualified"} = sample),
    do:
      sample["utc_lower_ms"] == nil and sample["utc_upper_ms"] == nil and
        if(sample["monotonic_continuous"],
          do: ProfileCodec.digest?(sample["qualification_digest"]),
          else: sample["qualification_digest"] == nil
        )

  defp confidence?(_), do: false
  defp invalid, do: {:error, :invalid_schedule_clock}
end
