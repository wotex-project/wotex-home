defmodule WotexHome.ControllerConnections.Codec do
  @moduledoc """
  Inert, bounded controller invitation and bootstrap records.

  Decoding grants no pairing or TLS authority. A transport must validate the
  invited chain, service identity, validity and leaf pin before sending any
  secret. Responses must also match the exact original request and approved
  access through `verify_response/3` before credential custody.
  """
  alias WotexHome.{Id, Permissions, Profiles.Codec}

  @maximum 9_223_372_036_854_775_807
  @bound 8_192
  @invitation ~w(controller_id identity leaf_pin trust_anchor endpoint invitation_id bootstrap_secret)
  @request ~w(controller_id invitation_id client_id request_id client_label bootstrap_secret)
  @context ~w(controller_id invitation_id client_id request_id request_digest)
  @paired ~w(deployment_id owner_id authority_epoch principal_id revision permissions target_ids credential)
  @reasons ~w(pairing_closed pairing_expired invitation_unavailable invitation_consumed confirmation_denied pairing_busy pairing_unavailable outcome_unknown)
  @formats %{
    "invitation" => "wotex-home.controller-invitation.v1",
    "request" => "wotex-home.controller-bootstrap-request.v1",
    "response" => "wotex-home.controller-bootstrap-response.v1"
  }

  def maximum_bytes, do: @bound
  def default_access, do: %{"permissions" => ["read"], "target_ids" => []}
  def valid_client_label?(value), do: label?(value)

  def frame_size(<<size::unsigned-big-32>>) when size in 1..@bound, do: {:ok, size}
  def frame_size(_), do: invalid()

  def encode_frame(kind, value) do
    with {:ok, bytes} <- encode(kind, value),
         do: {:ok, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>}
  end

  def decode_frame(kind, <<header::binary-size(4), body::binary>>) do
    with {:ok, size} <- frame_size(header),
         true <- byte_size(body) == size,
         do: decode(kind, body),
         else: (_ -> invalid())
  end

  def decode_frame(_, _), do: invalid()

  def encode("invitation", value) do
    if exact?(value, @invitation) and invitation?(value),
      do: bounded([@formats["invitation"], 1 | Enum.map(@invitation, &value[&1])]),
      else: invalid()
  end

  def encode("request", value) do
    if exact?(value, @request) and request?(value) do
      wire = Map.update!(value, "client_label", &Base.url_encode64(&1, padding: false))
      bounded([@formats["request"], 1 | Enum.map(@request, &wire[&1])])
    else
      invalid()
    end
  end

  def encode("paired", value) do
    if exact?(value, @context ++ @paired) and context?(value) and paired?(value),
      do:
        bounded(
          [@formats["response"], 1 | Enum.map(@context, &value[&1])] ++
            [["paired" | Enum.map(@paired, &value[&1])]]
        ),
      else: invalid()
  end

  def encode("refused", value) do
    if exact?(value, @context ++ ["reason"]) and context?(value) and
         value["reason"] in @reasons,
       do:
         bounded(
           [@formats["response"], 1 | Enum.map(@context, &value[&1])] ++
             [["refused", value["reason"]]]
         ),
       else: invalid()
  end

  def encode(_, _), do: invalid()

  def decode(kind, bytes) when is_binary(bytes) and byte_size(bytes) in 1..@bound do
    with true <- String.valid?(bytes),
         {wire, {0, 0, []}, ""} <- JSON.decode(bytes, {0, 0, []}, decoders()),
         {:ok, actual_kind, value} <- from_wire(kind, wire),
         {:ok, ^bytes} <- encode(actual_kind, value) do
      {:ok, value}
    else
      _ -> invalid()
    end
  catch
    :throw, :invalid_controller_connection_record -> invalid()
  end

  def decode(_, _), do: invalid()

  def request_digest(request) do
    with {:ok, bytes} <- encode("request", request),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  def verify_response(bytes, request, approved_access \\ default_access()) do
    with {:ok, digest} <- request_digest(request),
         true <- access?(approved_access),
         {:ok, value} <- decode("response", bytes),
         true <-
           Enum.all?(~w(controller_id invitation_id client_id request_id), fn key ->
             value[key] == request[key]
           end),
         true <- value["request_digest"] == digest,
         true <-
           Map.has_key?(value, "reason") or
             (Map.take(value, ~w(permissions target_ids)) == approved_access and
                value["credential"] != request["bootstrap_secret"]) do
      {:ok, value}
    else
      _ -> invalid()
    end
  end

  def access?(value) do
    exact?(value, ~w(permissions target_ids)) and is_list(value["permissions"]) and
      value["permissions"] != [] and Permissions.valid?(value["permissions"]) and
      value["permissions"] == Enum.sort(value["permissions"]) and
      targets?(value["target_ids"], nil, 32) and
      ("host:transfer" not in value["permissions"] or value["target_ids"] == []) and
      (value["target_ids"] != [] or
         Enum.all?(
           value["permissions"],
           &(&1 in ~w(read enroll:review host:maintain profile:manage host:transfer))
         ))
  end

  defp targets?([], _, _), do: true

  defp targets?([id | rest], previous, remaining) when remaining > 0,
    do: Id.valid?(id) and (previous == nil or previous < id) and targets?(rest, id, remaining - 1)

  defp targets?(_, _, _), do: false

  defp from_wire("invitation", [format, 1 | values]) when length(values) == 7 do
    if format == @formats["invitation"],
      do: {:ok, "invitation", Map.new(Enum.zip(@invitation, values))},
      else: invalid()
  end

  defp from_wire("request", [format, 1 | values]) when length(values) == 6 do
    value = Map.new(Enum.zip(@request, values))

    with true <- format == @formats["request"],
         {:ok, label} <- unbase64(value["client_label"], 1, 80) do
      {:ok, "request", Map.put(value, "client_label", label)}
    else
      _ -> invalid()
    end
  end

  defp from_wire(kind, [format, 1, controller, invitation, client, request, digest, payload])
       when kind in ["response", "paired", "refused"] do
    context = Map.new(Enum.zip(@context, [controller, invitation, client, request, digest]))

    case {format, payload} do
      {expected, ["paired" | values]} when length(values) == 8 and kind != "refused" ->
        if expected == @formats["response"],
          do: {:ok, "paired", Map.merge(context, Map.new(Enum.zip(@paired, values)))},
          else: invalid()

      {expected, ["refused", reason]} when kind != "paired" ->
        if expected == @formats["response"],
          do: {:ok, "refused", Map.put(context, "reason", reason)},
          else: invalid()

      _ ->
        invalid()
    end
  end

  defp from_wire(_, _), do: invalid()

  defp invitation?(value) do
    Codec.digest?(value["controller_id"]) and identity?(value["identity"]) and
      Codec.digest?(value["leaf_pin"]) and
      match?({:ok, _}, unbase64(value["trust_anchor"], 1, 4_096)) and
      endpoint?(value["endpoint"]) and Codec.digest?(value["invitation_id"]) and
      secret?(value["bootstrap_secret"])
  end

  defp request?(value),
    do:
      Enum.all?(~w(controller_id invitation_id client_id request_id), &Codec.digest?(value[&1])) and
        label?(value["client_label"]) and secret?(value["bootstrap_secret"])

  defp context?(value), do: Enum.all?(@context, &Codec.digest?(value[&1]))

  defp paired?(value),
    do:
      Codec.digest?(value["deployment_id"]) and Codec.digest?(value["owner_id"]) and
        integer?(value["authority_epoch"], 1, @maximum) and Id.valid?(value["principal_id"]) and
        integer?(value["revision"], 1, @maximum) and
        access?(Map.take(value, ~w(permissions target_ids))) and secret?(value["credential"])

  defp identity?([kind, value]), do: address?(kind, value)
  defp identity?(_), do: false

  defp endpoint?([kind, address, port]),
    do: address?(kind, address) and integer?(port, 1_024, 65_535)

  defp endpoint?(_), do: false

  defp address?("dns", value) when is_binary(value) and byte_size(value) in 1..253 do
    labels = String.split(value, ".")

    Enum.all?(
      labels,
      &(byte_size(&1) in 1..63 and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, &1))
    ) and
      Regex.match?(~r/[a-z]/, List.last(labels))
  end

  defp address?("ipv4", value) when is_binary(value) and byte_size(value) in 7..15 do
    parts = String.split(value, ".")

    length(parts) == 4 and
      Enum.all?(parts, fn part ->
        case Integer.parse(part) do
          {number, ""} -> number in 0..255 and Integer.to_string(number) == part
          _ -> false
        end
      end)
  end

  defp address?("ipv6", value) when is_binary(value),
    do: byte_size(value) == 39 and Regex.match?(~r/\A[0-9a-f]{4}(?::[0-9a-f]{4}){7}\z/, value)

  defp address?(_, _), do: false

  defp label?(value) when is_binary(value) and byte_size(value) in 1..80 do
    String.valid?(value) and
      Enum.all?(String.to_charlist(value), fn scalar ->
        scalar not in 0..31 and scalar not in 127..159 and
          scalar not in [0x061C, 0x200E, 0x200F, 0x2028, 0x2029] and
          scalar not in 0x202A..0x202E and scalar not in 0x2066..0x2069
      end)
  end

  defp label?(_), do: false
  defp secret?(value), do: match?({:ok, _}, unbase64(value, 32, 32))

  defp unbase64(value, minimum, maximum) when is_binary(value) do
    with true <- byte_size(value) <= div(maximum * 4 + 2, 3),
         {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- byte_size(bytes) in minimum..maximum,
         true <- Base.url_encode64(bytes, padding: false) == value,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  defp unbase64(_, _, _), do: invalid()
  defp integer?(value, minimum, maximum), do: is_integer(value) and value in minimum..maximum

  defp exact?(value, fields),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp bounded(value) do
    bytes = JSON.encode!(value)
    if byte_size(bytes) <= @bound, do: {:ok, bytes}, else: invalid()
  end

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
      string: fn value -> if byte_size(value) <= 5_462, do: value, else: reject() end,
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

  defp invalid, do: {:error, :invalid_controller_connection_record}
  defp reject, do: throw(:invalid_controller_connection_record)
end
