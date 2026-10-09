defmodule WotexHome.ControllerConnections.ReviewCodec do
  @moduledoc """
  Closed, secret-free local pairing scope and exact approval records.

  These records authorize nothing by themselves. Only trusted local review
  creates an approval; a live window and the single Store must recheck the
  original request, current scope, grants, revision and one-use consumption.
  """
  alias WotexHome.ControllerConnections.Codec
  alias WotexHome.Profiles.Codec, as: Profiles
  @format "wotex-home.controller-pairing-review.v1"
  @maximum 9_223_372_036_854_775_807
  @scope ~w(store_boot deployment_id owner_id authority_epoch expected_revision)
  @request ~w(controller_id invitation_id client_id request_id request_digest client_label)
  @approval @request ++ @scope ++ ~w(permissions target_ids)

  def scope_fields, do: @scope

  def encode("scope", value), do: record("scope", @scope, value, &scope?/1)
  def encode("approval", value), do: record("approval", @approval, value, &approval?/1)
  def encode(_, _), do: invalid()

  def decode(kind, bytes) when is_binary(bytes) and byte_size(bytes) in 1..8_192 do
    with true <- String.valid?(bytes),
         {[@format, ^kind | values], {0, 0, []}, ""} <- JSON.decode(bytes, {0, 0, []}, decoders()),
         fields when is_list(fields) <- fields(kind),
         true <- length(fields) == length(values),
         {:ok, values} <- label(kind, values),
         value = Map.new(Enum.zip(fields, values)),
         {:ok, ^bytes} <- encode(kind, value),
         do: {:ok, value},
         else: (_ -> invalid())
  catch
    :throw, :invalid_controller_pairing_review -> invalid()
  end

  def decode(_, _), do: invalid()

  def digest(approval) do
    with {:ok, body} <- encode("approval", approval),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, body), case: :lower)}
  end

  def scope?(value) do
    exact?(value, @scope) and boot?(value["store_boot"]) and
      Profiles.digest?(value["deployment_id"]) and Profiles.digest?(value["owner_id"]) and
      integer?(value["authority_epoch"], 1, @maximum) and
      integer?(value["expected_revision"], 0, @maximum - 1)
  end

  defp approval?(value) do
    scope?(Map.take(value, @scope)) and
      Enum.all?(
        ~w(controller_id invitation_id client_id request_id request_digest),
        &Profiles.digest?(value[&1])
      ) and Codec.valid_client_label?(value["client_label"]) and
      Codec.access?(Map.take(value, ~w(permissions target_ids)))
  end

  defp record(kind, fields, value, predicate) do
    if exact?(value, fields) and predicate.(value) do
      value =
        if kind == "approval",
          do: Map.update!(value, "client_label", &Base.url_encode64(&1, padding: false)),
          else: value

      bytes = JSON.encode!([@format, kind | Enum.map(fields, &value[&1])])
      if byte_size(bytes) <= 8_192, do: {:ok, bytes}, else: invalid()
    else
      invalid()
    end
  end

  defp label("scope", values), do: {:ok, values}

  defp label("approval", values) do
    encoded = Enum.at(values, 5)

    with true <- is_binary(encoded) and byte_size(encoded) in 2..107,
         {:ok, label} <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(label, padding: false) == encoded,
         true <- Codec.valid_client_label?(label),
         do: {:ok, List.replace_at(values, 5, label)},
         else: (_ -> invalid())
  end

  defp fields("scope"), do: @scope
  defp fields("approval"), do: @approval
  defp fields(_), do: :invalid

  defp exact?(value, fields),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp boot?(<<"boot:", value::binary-size(32)>>), do: Regex.match?(~r/\A[0-9a-f]{32}\z/, value)
  defp boot?(_), do: false
  defp integer?(value, first, last), do: is_integer(value) and value in first..last

  defp decoders do
    [
      array_start: fn
        {depth, _, _} when depth < 2 -> {depth + 1, 0, []}
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
          integer = String.to_integer(value)
          if integer in 0..@maximum, do: integer, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end

  defp invalid, do: {:error, :invalid_controller_pairing_review}
  defp reject, do: throw(:invalid_controller_pairing_review)
end
