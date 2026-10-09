defmodule WotexHome.ControllerConnections.ConsumptionCodec do
  @moduledoc "Canonical secret-free original pairing consumption; never a credential replay."
  alias WotexHome.ControllerConnections.ReviewCodec
  alias WotexHome.Profiles.Codec, as: Profiles
  @format "wotex-home.controller-pairing-consumption.v1"
  @prefix "paired-controller-v1:"
  @original ~w(controller_id invitation_id client_id request_id request_digest)
  @maximum 9_223_372_036_854_775_807

  def principal(approval),
    do: @prefix <> Integer.to_string(approval["authority_epoch"]) <> ":" <> approval["client_id"]

  def reserved?(value) when is_binary(value), do: String.starts_with?(value, @prefix)
  def reserved?(_), do: false

  def lookup?(value),
    do:
      exact?(value, @original) and
        Enum.all?(@original, &Profiles.digest?(value[&1]))

  def encode(value) do
    with true <- exact?(value, ~w(approval principal_id revision)),
         {:ok, approval} <- ReviewCodec.encode("approval", value["approval"]),
         true <- value["principal_id"] == principal(value["approval"]),
         true <- value["revision"] == value["approval"]["expected_revision"] + 1 do
      body =
        JSON.encode!([@format, JSON.decode!(approval), value["principal_id"], value["revision"]])

      if byte_size(body) <= 8_192, do: {:ok, body}, else: invalid()
    else
      _ -> invalid()
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..8_192 do
    with true <- String.valid?(bytes),
         {[@format, approval, principal, revision], {0, 0, []}, ""} <-
           JSON.decode(bytes, {0, 0, []}, decoders()),
         {:ok, approval} <- ReviewCodec.decode("approval", JSON.encode!(approval)),
         value = %{"approval" => approval, "principal_id" => principal, "revision" => revision},
         {:ok, ^bytes} <- encode(value),
         do: {:ok, value},
         else: (_ -> invalid())
  catch
    :throw, :invalid_controller_pairing_consumption -> invalid()
  end

  def decode(_), do: invalid()

  def original_fields, do: @original

  defp exact?(value, fields),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp decoders do
    [
      array_start: fn
        {depth, _, _} when depth < 3 -> {depth + 1, 0, []}
        _ -> reject()
      end,
      array_push: fn
        value, {depth, count, values} when count < 32 -> {depth, count + 1, [value | values]}
        _, _ -> reject()
      end,
      array_finish: fn {_, _, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: fn _ -> reject() end,
      string: fn value -> if byte_size(value) <= 128, do: value, else: reject() end,
      integer: fn value ->
        if byte_size(value) <= 19 do
          n = String.to_integer(value)
          if n in 0..@maximum, do: n, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end

  defp invalid, do: {:error, :invalid_controller_pairing_consumption}
  defp reject, do: throw(:invalid_controller_pairing_consumption)
end
