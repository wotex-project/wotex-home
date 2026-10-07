defmodule WotexHome.Rules.OperationInput do
  @moduledoc "Inert exact explicit-rule operation correspondence; no Store, admission, clock or device authority."
  alias WotexHome.{Id, Rules.Codec, Rules.Rule}
  @format "wotex-home.explicit-rule-operation.v1"
  @maximum 9_223_372_036_854_775_807
  @source ~w(authority_epoch operation_id expected_revision rule_id source_revision target_id on)
  @activate ~w(authority_epoch operation_id expected_revision admission_revision)
  @invoke ~w(authority_epoch operation_id rule_generation rule_id)

  def encode(kind, value) when is_map(value) and not is_struct(value) do
    with fields when is_list(fields) <- fields(kind),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(fields),
         true <- valid?(kind, value) do
      {:ok, JSON.encode!([@format, kind | Enum.map(fields, &value[&1])])}
    else
      _ -> invalid()
    end
  end

  def encode(_, _), do: invalid()

  def from_record([@format, kind | values] = record) when length(record) <= 9 do
    with fields when is_list(fields) <- fields(kind),
         true <- length(values) == length(fields),
         input = Map.new(Enum.zip(fields, values)),
         {:ok, _} <- encode(kind, input),
         do: {:ok, kind, input},
         else: (_ -> invalid())
  end

  def from_record(_), do: invalid()

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..4_096 do
    with true <- String.valid?(bytes),
         {record, {0, 0, nil}, ""} <- JSON.decode(bytes, {0, 0, nil}, decoders()),
         {:ok, kind, input} <- from_record(record),
         {:ok, ^bytes} <- encode(kind, input),
         do: {:ok, kind, input},
         else: (_ -> invalid())
  catch
    :throw, :invalid_rule_operation_input -> invalid()
  end

  def decode(_), do: invalid()

  def digest(kind, input) do
    with {:ok, bytes} <- encode(kind, input),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  def source(kind, input) when kind in ["review", "admit"] do
    with {:ok, _} <- encode(kind, input),
         {:ok, rule} <-
           Rule.new(%{
             "version" => 1,
             "id" => input["rule_id"],
             "source_revision" => input["source_revision"],
             "trigger" => %{"kind" => "explicit_request"},
             "predicate" => %{"op" => "literal_true"},
             "effect" => %{
               "target_id" => input["target_id"],
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => input["on"]}
             },
             "authority_class" => "automation",
             "unknown_policy" => "block",
             "ownership_ms" => 1,
             "cooldown_ms" => 0,
             "causal_budget" => 1
           }),
         do: Codec.encode([rule])
  end

  def source(_, _), do: invalid()

  defp valid?(kind, value) do
    integer?(value["authority_epoch"], 1) && Id.valid?(value["operation_id"]) &&
      case kind do
        name when name in ["review", "admit"] ->
          expected?(value["expected_revision"]) && Id.valid?(value["rule_id"]) &&
            integer?(value["source_revision"], 0) && Id.valid?(value["target_id"]) &&
            is_boolean(value["on"])

        "activate" ->
          expected?(value["expected_revision"]) && integer?(value["admission_revision"], 0) &&
            value["admission_revision"] <= value["expected_revision"]

        "invoke" ->
          integer?(value["rule_generation"], 1) && Id.valid?(value["rule_id"])
      end
  end

  defp fields(kind) when kind in ["review", "admit"], do: @source
  defp fields("activate"), do: @activate
  defp fields("invoke"), do: @invoke
  defp fields(_), do: :invalid
  defp integer?(value, minimum), do: is_integer(value) && value in minimum..@maximum
  defp expected?(value), do: integer?(value, 0) && value < @maximum
  defp invalid, do: {:error, :invalid_rule_operation_input}
  defp reject, do: throw(:invalid_rule_operation_input)

  defp decoders do
    [
      array_start: fn
        {0, _, _} -> {1, 0, []}
        _ -> reject()
      end,
      array_push: fn
        value, {1, count, values} when count < 9 -> {1, count + 1, [value | values]}
        _, _ -> reject()
      end,
      array_finish: fn {1, _, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: fn _ -> reject() end,
      string: fn value -> if byte_size(value) <= 128, do: value, else: reject() end,
      integer: fn value ->
        if byte_size(value) <= 19 do
          integer = String.to_integer(value)
          if integer?(integer, 0), do: integer, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end
end
