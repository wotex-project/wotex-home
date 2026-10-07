defmodule WotexHome.ScheduleOperationInputTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Codec, OperationInput}

  # Independently serialized and hashed with Python json/hashlib.
  @rule ~s({"rules":[{"authority_class":"automation","causal_budget":1,"cooldown_ms":0,"effect":{"capability_key":"power","target_id":"light:one","value":{"type":"boolean","value":true}},"id":"rule:one","ownership_ms":1,"predicate":{"op":"literal_true"},"source_revision":2,"trigger":{"kind":"explicit_request"},"unknown_policy":"block","version":1}]})
  @source ~s(["wotex-home.schedule-source.v1","schedule:one",2,"operator:one","rule:one","c52b03660816ed5d79abf10615ebd6eb6f3f8126bea4f8c8727126c4f66ce646","light:one",4,10000,100,["interval",100000,60000,100000,null]])
  @input %{
    "authority_epoch" => 7,
    "operation_id" => "schedule:admit",
    "expected_revision" => 9,
    "source_document" => @source,
    "rule_document" => @rule
  }

  test "exact original bytes bind a separate schedule source and absolute effect" do
    assert {:ok, bytes} = OperationInput.encode("admit", @input)
    assert {:ok, "admit", @input} = OperationInput.decode(bytes)

    assert {:ok, "1733caf36b0a194037c5fba75126eaa4285ea779d9062c9c28e6ab507a3e8a42"} =
             OperationInput.digest("admit", @input)

    assert {:ok, source, rule} = OperationInput.source("admit", @input)
    assert source["author_id"] == "operator:one"
    assert source["target_id"] == elem(rule.effect, 0)
    assert source["rule_source_digest"] == Codec.hash(@rule)
    assert rule.ownership_ms == 1 && rule.cooldown_ms == 0 && rule.causal_budget == 1
    assert rule.predicate.op == :literal_true && rule.trigger == {:explicit_request, nil}
    assert {:ok, review} = OperationInput.digest("review", @input)
    refute review == "1733caf36b0a194037c5fba75126eaa4285ea779d9062c9c28e6ab507a3e8a42"

    for field <- ~w(authority_epoch expected_revision) do
      assert {:ok, changed} =
               OperationInput.digest("admit", Map.update!(@input, field, &(&1 + 1)))

      refute changed == "1733caf36b0a194037c5fba75126eaa4285ea779d9062c9c28e6ab507a3e8a42"
    end

    assert {:ok, changed} =
             OperationInput.digest("admit", %{
               @input
               | "source_document" => String.replace(@source, "operator:one", "operator:two")
             })

    refute changed == "1733caf36b0a194037c5fba75126eaa4285ea779d9062c9c28e6ab507a3e8a42"
  end

  test "a changed effect requires its exact digest and remains in the narrow grammar" do
    for rule <- [
          String.replace(@rule, "rule:one", "rule:two"),
          String.replace(@rule, "light:one", "light:two"),
          String.replace(@rule, ~s("value":true), ~s("value":false)),
          @rule <> "\n"
        ] do
      assert {:error, :invalid_schedule_operation} =
               OperationInput.encode("admit", %{@input | "rule_document" => rule})
    end

    for {from, to} <- [
          {~s("ownership_ms":1), ~s("ownership_ms":2)},
          {~s("cooldown_ms":0), ~s("cooldown_ms":1)},
          {~s("causal_budget":1), ~s("causal_budget":2)},
          {~s("explicit_request"), ~s("reported_edge")}
        ] do
      rule = String.replace(@rule, from, to)
      {:ok, source} = Codec.decode(@source)
      {:ok, document} = Codec.encode(%{source | "rule_source_digest" => Codec.hash(rule)})

      assert {:error, :invalid_schedule_operation} =
               OperationInput.encode("review", %{
                 @input
                 | "rule_document" => rule,
                   "source_document" => document
               })
    end

    rule = String.replace(@rule, ~s("value":true), ~s("value":false))
    {:ok, source} = Codec.decode(@source)
    {:ok, document} = Codec.encode(%{source | "rule_source_digest" => Codec.hash(rule)})

    assert {:ok, _, %{effect: {"light:one", "power", %{data: false}}}} =
             OperationInput.source("admit", %{
               @input
               | "rule_document" => rule,
                 "source_document" => document
             })
  end

  test "activation and suspension have distinct closed original inputs" do
    activation = %{
      "authority_epoch" => 7,
      "operation_id" => "schedule:activate",
      "expected_revision" => 9,
      "admission_revision" => 8
    }

    assert {:ok, ~s(["wotex-home.schedule-operation.v1","activate",7,"schedule:activate",9,8])} =
             OperationInput.encode("activate", activation)

    for revision <- [0, 10, true, 8.0] do
      assert {:error, :invalid_schedule_operation} =
               OperationInput.encode("activate", %{activation | "admission_revision" => revision})
    end

    suspension = Map.delete(activation, "admission_revision")

    assert {:ok, ~s(["wotex-home.schedule-operation.v1","suspend",7,"schedule:activate",9])} =
             OperationInput.encode("suspend", suspension)

    assert {:error, :invalid_schedule_operation} = OperationInput.source("activate", activation)
    assert {:error, :invalid_schedule_operation} = OperationInput.encode("suspend", activation)
    assert {:error, :invalid_schedule_operation} = OperationInput.encode("invoke", suspension)
  end

  test "bounded parsing refuses alternate scalars, nested fields and extra members" do
    {:ok, bytes} = OperationInput.encode("admit", @input)

    for document <- [
          " " <> bytes,
          bytes <> "\n",
          bytes <> "[]",
          String.replace(bytes, ",7,", ",7.0,"),
          String.replace(bytes, ",7,", ",true,"),
          String.replace(bytes, ",9,", ",-9,"),
          String.replace(bytes, ",9,", ",9223372036854775808,"),
          String.replace(bytes, "schedule:admit", "schedule\\u003aadmit"),
          String.replace(bytes, "schedule:admit", String.duplicate("a", 129)),
          String.slice(bytes, 0..-2//1) <> ",0]",
          "{}",
          "[[[]]]",
          <<255>>,
          String.duplicate(" ", 8_193)
        ] do
      assert {:error, :invalid_schedule_operation} = OperationInput.decode(document)
    end

    for input <- [
          Map.put(@input, "clock", 1),
          Map.delete(@input, "source_document"),
          %{@input | "authority_epoch" => 0},
          %{@input | "expected_revision" => Codec.maximum()},
          %{@input | "rule_document" => String.duplicate("[", 2_049)},
          %{@input | "source_document" => String.duplicate("[", 4_097)}
        ] do
      assert {:error, :invalid_schedule_operation} = OperationInput.encode("admit", input)
    end
  end
end
