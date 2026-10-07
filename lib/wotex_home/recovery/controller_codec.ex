defmodule WotexHome.Recovery.ControllerCodec do
  @moduledoc "Closed canonical ownership-origin and source-retirement records; no authority effects."
  alias WotexHome.{Id, Profiles.Codec}
  @maximum 9_223_372_036_854_775_807
  @origin ~w(deployment_id owner_id authority_epoch store_revision provenance)
  @operation ~w(authority_epoch operation_id expected_revision destination_owner_id)
  @receipt ~w(principal_id authority_epoch operation_id expected_revision deployment_id source_owner_id destination_owner_id maintenance_revision revision)

  def encode("origin", value),
    do: encode_record("wotex-home.controller-origin.v1", @origin, value, &origin?/1)

  def encode("operation", value),
    do:
      encode_record(
        "wotex-home.controller-retirement-operation.v1",
        @operation,
        value,
        &operation?/1
      )

  def encode("retirement", value),
    do: encode_record("wotex-home.controller-retirement.v1", @receipt, value, &receipt?/1)

  def encode(_, _), do: invalid()

  def decode(kind, bytes) when is_binary(bytes) and byte_size(bytes) in 1..4_096 do
    with {:ok, [format, values]} <- JSON.decode(bytes),
         fields when is_list(fields) <- fields(kind, format),
         true <- is_list(values) and length(values) == length(fields),
         value = Map.new(Enum.zip(fields, values)),
         {:ok, ^bytes} <- encode(kind, value) do
      {:ok, value}
    else
      _ -> invalid()
    end
  end

  def decode(_, _), do: invalid()

  defp encode_record(format, fields, value, predicate) do
    if is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(fields) and
         predicate.(value),
       do: {:ok, JSON.encode!([format, Enum.map(fields, &value[&1])])},
       else: invalid()
  end

  defp origin?(value),
    do:
      Codec.digest?(value["deployment_id"]) and Codec.digest?(value["owner_id"]) and
        integer?(value["authority_epoch"], 1, @maximum) and
        integer?(value["store_revision"], 0, @maximum) and
        value["provenance"] == "local_bootstrap"

  defp operation?(value),
    do:
      integer?(value["authority_epoch"], 1, @maximum - 1) and Id.valid?(value["operation_id"]) and
        integer?(value["expected_revision"], 0, @maximum - 1) and
        Codec.digest?(value["destination_owner_id"])

  defp receipt?(value),
    do:
      operation?(value) and Id.valid?(value["principal_id"]) and
        Codec.digest?(value["deployment_id"]) and Codec.digest?(value["source_owner_id"]) and
        value["source_owner_id"] != value["destination_owner_id"] and
        integer?(value["maintenance_revision"], 1, @maximum) and
        value["maintenance_revision"] <= value["expected_revision"] and
        value["revision"] == value["expected_revision"] + 1

  defp fields("origin", "wotex-home.controller-origin.v1"), do: @origin
  defp fields("operation", "wotex-home.controller-retirement-operation.v1"), do: @operation
  defp fields("retirement", "wotex-home.controller-retirement.v1"), do: @receipt
  defp fields(_, _), do: :invalid
  defp integer?(value, minimum, maximum), do: is_integer(value) and value in minimum..maximum
  defp invalid, do: {:error, :invalid_controller_record}
end
