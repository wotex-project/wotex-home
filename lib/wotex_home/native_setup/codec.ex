defmodule WotexHome.NativeSetup.Codec do
  @moduledoc "Inert closed native setup records; no listener, credential or provisioning authority."
  alias WotexHome.Profiles.Codec, as: ProfileCodec
  @format "wotex-home.native-setup-authority.v1"
  @maximum 9_223_372_036_854_775_807
  @identity ~w(deployment_id owner_id authority_epoch store_revision)
  @ensure ~w(deployment_id owner_id authority_epoch role verifier)
  @existing @ensure ++ ["creation_revision"]
  @receipt ~w(deployment_id owner_id authority_epoch role principal_id revision)
  @reasons ~w(invalid_native_setup_record native_owner_changed native_custody_conflict native_setup_unavailable outcome_unknown frame_timeout core_owner_lost channel_closed)
  @roles %{
    "diagnostic" => ["read"],
    "operator" => [
      "read",
      "control:ordinary",
      "rule:review",
      "rule:manage",
      "enroll:review",
      "host:maintain",
      "profile:manage"
    ],
    "maintenance" => ["read", "host:maintain"],
    "transfer" => ["host:transfer"]
  }

  def roles, do: Map.keys(@roles) |> Enum.sort()
  def permissions(role), do: Map.fetch(@roles, role)
  def reserved?(id), do: is_binary(id) and String.starts_with?(id, "native-setup-v1:")
  def principal(epoch, role), do: "native-setup-v1:#{epoch}:#{role}"

  def encode("identity_request", value) when value == %{},
    do: {:ok, JSON.encode!([@format, "identity"])}

  def encode("identity", value), do: record("identity", @identity, value, &identity?/1)
  def encode("ensure", value), do: record("ensure", @ensure, value, &ensure?/1)
  def encode("ensured", value), do: record("ensured", @receipt, value, &receipt?/1)
  def encode("existing", value), do: record("existing", @existing, value, &existing?/1)
  def encode("found", value), do: record("found", @receipt, value, &receipt?/1)

  def encode("error", value),
    do: record("error", ["reason"], value, &(&1["reason"] in @reasons))

  def encode(_, _), do: invalid()

  def decode(kind, bytes) when is_binary(bytes) and byte_size(bytes) in 1..4_096 do
    with true <- String.valid?(bytes),
         {[format, operation | values], {0, 0, nil}, ""} <-
           JSON.decode(bytes, {0, 0, nil}, decoders()),
         true <- format == @format,
         fields when is_list(fields) <- fields(kind, operation),
         true <- length(fields) == length(values),
         value = Map.new(Enum.zip(fields, values)),
         {:ok, ^bytes} <- encode(kind, value) do
      {:ok, value}
    else
      _ -> invalid()
    end
  catch
    :throw, :invalid_native_setup_record -> invalid()
  end

  def decode(_, _), do: invalid()

  defp record(kind, fields, value, predicate) do
    if is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(fields) and
         predicate.(value),
       do: {:ok, JSON.encode!([@format, kind | Enum.map(fields, &value[&1])])},
       else: invalid()
  end

  defp identity?(value),
    do: scope?(value) and integer?(value["store_revision"], 0)

  defp scope?(value),
    do:
      ProfileCodec.digest?(value["deployment_id"]) and ProfileCodec.digest?(value["owner_id"]) and
        integer?(value["authority_epoch"], 1)

  defp ensure?(value),
    do:
      scope?(value) and Map.has_key?(@roles, value["role"]) and
        ProfileCodec.digest?(value["verifier"])

  defp receipt?(value),
    do:
      scope?(value) and Map.has_key?(@roles, value["role"]) and integer?(value["revision"], 1) and
        value["principal_id"] == principal(value["authority_epoch"], value["role"])

  defp existing?(value), do: ensure?(value) and integer?(value["creation_revision"], 1)

  defp fields("identity_request", "identity"), do: []
  defp fields("identity", "identity"), do: @identity
  defp fields("ensure", "ensure"), do: @ensure
  defp fields("ensured", "ensured"), do: @receipt
  defp fields("existing", "existing"), do: @existing
  defp fields("found", "found"), do: @receipt
  defp fields("error", "error"), do: ["reason"]
  defp fields(_, _), do: :invalid
  defp integer?(value, minimum), do: is_integer(value) and value in minimum..@maximum

  defp decoders do
    [
      array_start: fn
        {0, _, _} -> {1, 0, []}
        _ -> reject()
      end,
      array_push: fn
        value, {1, count, values} when count < 8 -> {1, count + 1, [value | values]}
        _, _ -> reject()
      end,
      array_finish: fn {1, _, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: fn _ -> reject() end,
      string: fn value -> if byte_size(value) <= 128, do: value, else: reject() end,
      integer: fn value ->
        if byte_size(value) <= 19 do
          integer = String.to_integer(value)
          if integer >= 0 and integer <= @maximum, do: integer, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end

  defp invalid, do: {:error, :invalid_native_setup_record}
  defp reject, do: throw(:invalid_native_setup_record)
end
