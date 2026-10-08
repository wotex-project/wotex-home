defmodule WotexHome.Schedules.CountdownExpiry do
  @moduledoc "Inert original countdown expiry correspondence. It contains no qualified time, future sample or effect authority."
  alias WotexHome.{Id, Schedules.Codec}
  @format "wotex-home.schedule-countdown-expiry.v1"
  @reasons ~w(countdown_missed:old_boot countdown_missed:clock_changed countdown_missed:clock_unavailable)
  @fields ~w(activation_revision authority_epoch expected_revision reason boot_epoch clock_generation)a

  def build(%{revision: revision, epoch: epoch}, expected, reason, boot, generation)
      when reason in [:old_boot, :clock_changed, :clock_unavailable] do
    with true <-
           Codec.integer?(revision, 1, Codec.maximum()) and
             Codec.integer?(epoch, 1, Codec.maximum()),
         true <- Codec.integer?(expected, revision, Codec.maximum()) and Id.valid?(boot),
         true <- is_nil(generation) or Codec.integer?(generation, 0, Codec.maximum()) do
      document =
        JSON.encode!([
          @format,
          revision,
          epoch,
          expected,
          "countdown_missed:" <> Atom.to_string(reason),
          boot,
          generation
        ])

      with {:ok, _} <- decode(document), do: {:ok, document}
    else
      _ -> {:error, :invalid_countdown_expiry}
    end
  end

  def build(_, _, _, _, _), do: {:error, :invalid_countdown_expiry}

  def decode(document) do
    with {:ok, [@format, activation, epoch, expected, reason, boot, generation]} <-
           Codec.record(document),
         true <- Codec.integer?(activation, 1, Codec.maximum()),
         true <- Codec.integer?(epoch, 1, Codec.maximum()),
         true <- Codec.integer?(expected, activation, Codec.maximum()),
         true <- reason in @reasons and Id.valid?(boot),
         true <- is_nil(generation) or Codec.integer?(generation, 0, Codec.maximum()),
         true <- reason == "countdown_missed:clock_unavailable" or not is_nil(generation),
         true <-
           document ==
             JSON.encode!([@format, activation, epoch, expected, reason, boot, generation]),
         do:
           {:ok,
            %{
              activation_revision: activation,
              authority_epoch: epoch,
              expected_revision: expected,
              reason: reason,
              boot_epoch: boot,
              clock_generation: generation
            }},
         else: (_ -> {:error, :invalid_countdown_expiry})
  end

  def for_source?(record, source) do
    with true <- Codec.exact?(record, @fields),
         {:ok, ^record} <-
           decode(
             JSON.encode!([
               @format,
               record.activation_revision,
               record.authority_epoch,
               record.expected_revision,
               record.reason,
               record.boot_epoch,
               record.clock_generation
             ])
           ),
         {:ok, _} <- Codec.encode(source),
         ["countdown", boot, generation, _, _] <- source["trigger"] do
      case record.reason do
        "countdown_missed:old_boot" ->
          record.boot_epoch != boot

        "countdown_missed:clock_changed" ->
          record.boot_epoch == boot and record.clock_generation != generation

        "countdown_missed:clock_unavailable" ->
          record.boot_epoch == boot and record.clock_generation in [nil, generation]

        _ ->
          false
      end
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
