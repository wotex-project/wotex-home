defmodule WotexHome.Schedules.OperationInput do
  @moduledoc "Closed original schedule-operation correspondence; no admission, trusted time or writer authority."
  alias WotexHome.{Id, Schedules.Codec}
  alias WotexHome.Rules.Rule
  alias WotexHome.Semantics.Value

  @format "wotex-home.schedule-operation.v1"
  @source ~w(authority_epoch operation_id expected_revision source_document rule_document)
  @activate ~w(authority_epoch operation_id expected_revision admission_revision)
  @suspend ~w(authority_epoch operation_id expected_revision)

  def encode(kind, input) do
    with fields when is_list(fields) <- fields(kind),
         true <- Codec.exact?(input, fields),
         true <- common?(input),
         :ok <- action(kind, input),
         bytes = JSON.encode!([@format, kind | Enum.map(fields, &input[&1])]),
         true <- byte_size(bytes) <= 8_192,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..8_192 do
    with true <- String.valid?(bytes),
         {[@format, kind | values], {0, 0, nil}, ""} <-
           JSON.decode(bytes, {0, 0, nil}, decoders()),
         fields when is_list(fields) <- fields(kind),
         true <- length(values) == length(fields),
         input = Map.new(Enum.zip(fields, values)),
         {:ok, ^bytes} <- encode(kind, input),
         do: {:ok, kind, input},
         else: (_ -> invalid())
  catch
    :throw, :invalid_schedule_operation -> invalid()
  end

  def decode(_), do: invalid()

  def digest(kind, input),
    do: with({:ok, bytes} <- encode(kind, input), do: {:ok, Codec.hash(bytes)})

  def source(kind, input) when kind in ["review", "admit"] do
    with {:ok, _} <- encode(kind, input),
         {:ok, source} <- Codec.decode(input["source_document"]),
         {:ok, [rule]} <- WotexHome.Rules.Codec.decode(input["rule_document"]),
         do: {:ok, source, rule}
  end

  def source(_, _), do: invalid()

  defp fields(kind) when kind in ["review", "admit"], do: @source
  defp fields("activate"), do: @activate
  defp fields("suspend"), do: @suspend
  defp fields(_), do: :invalid

  defp common?(input),
    do:
      Codec.integer?(input["authority_epoch"], 1, Codec.maximum()) and
        Id.valid?(input["operation_id"]) and
        Codec.integer?(input["expected_revision"], 0, Codec.maximum() - 1)

  defp action(kind, input) when kind in ["review", "admit"] do
    with {:ok, source} <- Codec.decode(input["source_document"]),
         document when is_binary(document) and byte_size(document) <= 2_048 <-
           input["rule_document"],
         {:ok, [rule]} <- WotexHome.Rules.Codec.decode(document),
         true <-
           rule.id == source["rule_id"] and elem(rule.effect, 0) == source["target_id"] and
             Codec.hash(document) == source["rule_source_digest"] and narrow?(rule),
         do: :ok,
         else: (_ -> invalid())
  end

  defp action("activate", input),
    do:
      if(Codec.integer?(input["admission_revision"], 1, input["expected_revision"]),
        do: :ok,
        else: invalid()
      )

  defp action("suspend", _), do: :ok

  defp narrow?(%Rule{
         trigger: {:explicit_request, nil},
         predicate: %WotexHome.Rules.Predicate{op: :literal_true, args: nil},
         effect: {_, "power", %Value{kind: :boolean}},
         authority_class: :automation,
         unknown_policy: :block,
         ownership_ms: 1,
         cooldown_ms: 0,
         causal_budget: 1
       }),
       do: true

  defp narrow?(_), do: false

  defp reject, do: throw(:invalid_schedule_operation)
  defp invalid, do: {:error, :invalid_schedule_operation}

  defp decoders do
    [
      array_start: fn
        {0, _, _} -> {1, 0, []}
        _ -> reject()
      end,
      array_push: fn
        value, {1, count, values} when count < 7 -> {1, count + 1, [value | values]}
        _, _ -> reject()
      end,
      array_finish: fn {1, _, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: fn _ -> reject() end,
      string: fn value -> if byte_size(value) <= 4_096, do: value, else: reject() end,
      integer: fn text ->
        if byte_size(text) <= 19 do
          value = String.to_integer(text)
          if Codec.integer?(value, 0, Codec.maximum()), do: value, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end
end
