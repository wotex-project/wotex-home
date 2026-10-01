defmodule WotexHome.Durable.Store.ObservationCodec do
  @moduledoc """
  Closed SQLite representation for semantic observations.

  The codec is pure: it validates persisted rows and translates values without
  owning a database handle or advancing durable state.
  """

  alias WotexHome.Id
  alias WotexHome.Semantics.{Observation, Value}

  @max_i64 9_223_372_036_854_775_807

  @spec encode_value(Value.t() | nil) ::
          {String.t() | nil, String.t() | nil, String.t() | nil}
  def encode_value(nil), do: {nil, nil, nil}

  def encode_value(%Value{kind: :boolean, data: value}),
    do: {"boolean", if(value, do: "1", else: "0"), nil}

  def encode_value(%Value{kind: :fraction, data: value}),
    do: {"fraction", Integer.to_string(value), nil}

  def encode_value(%Value{kind: :kelvin, data: value}),
    do: {"kelvin", Integer.to_string(value), nil}

  def encode_value(%Value{kind: :hsv, data: {hue, saturation}}),
    do: {"hsv", Integer.to_string(hue), Integer.to_string(saturation)}

  def encode_value(%Value{kind: :xy, data: {x, y}}),
    do: {"xy", Integer.to_string(x), Integer.to_string(y)}

  def encode_value(%Value{kind: :smoke_state, data: value}),
    do: {"smoke_state", value, nil}

  @spec decode_value(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, Value.t() | nil} | {:error, :corrupt_value}
  def decode_value(nil, nil, nil), do: {:ok, nil}
  def decode_value("boolean", "1", nil), do: {:ok, %Value{kind: :boolean, data: true}}
  def decode_value("boolean", "0", nil), do: {:ok, %Value{kind: :boolean, data: false}}

  def decode_value("smoke_state", value, nil) when value in ["clear", "alarm"],
    do: {:ok, %Value{kind: :smoke_state, data: value}}

  def decode_value(kind, a, nil) when kind in ["fraction", "kelvin"] and is_binary(a) do
    case Integer.parse(a) do
      {value, ""} ->
        {:ok, %Value{kind: if(kind == "fraction", do: :fraction, else: :kelvin), data: value}}

      _ ->
        {:error, :corrupt_value}
    end
  end

  def decode_value(kind, a, b)
      when kind in ["hsv", "xy"] and is_binary(a) and is_binary(b) do
    with {first, ""} <- Integer.parse(a),
         {second, ""} <- Integer.parse(b) do
      {:ok, %Value{kind: if(kind == "hsv", do: :hsv, else: :xy), data: {first, second}}}
    else
      _ -> {:error, :corrupt_value}
    end
  end

  def decode_value(_kind, _a, _b), do: {:error, :corrupt_value}

  @spec decode_current(String.t(), String.t(), list()) ::
          {:ok, Observation.t(), non_neg_integer()} | {:error, :corrupt_value}
  def decode_current(thing_id, capability_key, row) do
    case row do
      [
        _profile_ref,
        _evidence_ref,
        source_epoch,
        source_sequence,
        boot_epoch,
        source_time,
        received_time,
        received_mono,
        quality,
        trust,
        kind,
        a,
        b,
        revision
      ] ->
        with {:ok, value} <- decode_value(kind, a, b),
             true <-
               valid_persisted_observation?(
                 thing_id,
                 capability_key,
                 source_epoch,
                 source_sequence,
                 boot_epoch,
                 source_time,
                 received_time,
                 received_mono,
                 quality,
                 trust,
                 value,
                 revision
               ) do
          observation = %Observation{
            thing_id: thing_id,
            capability_key: capability_key,
            value: value,
            quality: quality,
            trust: trust,
            source_epoch: source_epoch,
            source_sequence: source_sequence,
            boot_epoch: boot_epoch,
            source_time_utc_ms: source_time,
            received_time_utc_ms: received_time,
            received_monotonic_ms: received_mono
          }

          {:ok, observation, revision}
        else
          _ -> {:error, :corrupt_value}
        end

      _ ->
        {:error, :corrupt_value}
    end
  end

  defp valid_persisted_observation?(
         thing_id,
         capability_key,
         source_epoch,
         source_sequence,
         boot_epoch,
         source_time,
         received_time,
         received_mono,
         quality,
         trust,
         value,
         revision
       ) do
    Id.valid?(thing_id) and Id.valid?(capability_key) and Id.valid?(source_epoch) and
      Id.valid?(boot_epoch) and valid_stored_integer?(source_sequence) and
      (is_nil(source_time) or valid_stored_integer?(source_time)) and
      valid_stored_integer?(received_time) and valid_stored_integer?(received_mono) and
      valid_stored_integer?(revision) and quality in ["reported", "unknown"] and
      trust in [
        "unauthenticated_local",
        "authenticated_device",
        "bridge_attested",
        "synthetic_lab"
      ] and
      ((quality == "unknown" and is_nil(value)) or
         (quality == "reported" and match?(%Value{}, value) and Value.valid?(value)))
  end

  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64
end
