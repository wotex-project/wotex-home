defmodule WotexHome.RuleOperationInputTest do
  use ExUnit.Case, async: true
  alias WotexHome.Rules.{Codec, Compiler, OperationInput}

  @source %{
    "authority_epoch" => 7,
    "operation_id" => "rule:admit",
    "expected_revision" => 9,
    "rule_id" => "rule:one",
    "source_revision" => 2,
    "target_id" => "light:one",
    "on" => true
  }
  @literal ~s(["wotex-home.explicit-rule-operation.v1","admit",7,"rule:admit",9,"rule:one",2,"light:one",true])
  @maximum 9_223_372_036_854_775_807

  test "independent literals bind each original operation and complete source" do
    assert {:ok, @literal} = OperationInput.encode("admit", @source)
    assert {:ok, "admit", @source} = OperationInput.decode(@literal)

    assert {:ok, "fc52e2c35a08d3c9dedd9fd58c22135913bd528be565bc0163ea1ae638f8a13a"} =
             OperationInput.digest("admit", @source)

    assert {:ok, document} = OperationInput.source("admit", @source)
    assert {:ok, [rule]} = Codec.decode(document)
    assert rule.id == "rule:one" && rule.source_revision == 2
    assert rule.trigger == {:explicit_request, nil} && rule.predicate.op == :literal_true

    assert rule.effect ==
             {"light:one", "power", %WotexHome.Semantics.Value{kind: :boolean, data: true}}

    assert rule.authority_class == :automation && rule.unknown_policy == :block
    assert {rule.ownership_ms, rule.cooldown_ms, rule.causal_budget} == {1, 0, 1}
    assert {:ok, program} = Compiler.compile([rule])
    assert Compiler.valid?(program)

    review = String.replace(@literal, ~s("admit"), ~s("review"))
    assert {:ok, ^review} = OperationInput.encode("review", @source)
    assert {:ok, ^document} = OperationInput.source("review", @source)
    assert {:ok, other} = OperationInput.digest("review", @source)
    refute other == "fc52e2c35a08d3c9dedd9fd58c22135913bd528be565bc0163ea1ae638f8a13a"

    activation = %{
      "authority_epoch" => 7,
      "operation_id" => "rule:activate",
      "expected_revision" => 9,
      "admission_revision" => 8
    }

    assert {:ok, ~s(["wotex-home.explicit-rule-operation.v1","activate",7,"rule:activate",9,8])} =
             OperationInput.encode("activate", activation)

    invocation = %{
      "authority_epoch" => 7,
      "operation_id" => "rule:invoke",
      "rule_generation" => 3,
      "rule_id" => "rule:one"
    }

    assert {:ok,
            ~s(["wotex-home.explicit-rule-operation.v1","invoke",7,"rule:invoke",3,"rule:one"])} =
             OperationInput.encode("invoke", invocation)

    assert {:error, :invalid_rule_operation_input} = OperationInput.source("activate", activation)
  end

  test "closed fields and scalar ranges refuse expansion and changed interpretation" do
    for value <- [
          Map.put(@source, "clock", 3),
          Map.put(@source, "trigger", "daily"),
          Map.delete(@source, "on"),
          %{@source | "authority_epoch" => 0},
          %{@source | "authority_epoch" => true},
          %{@source | "on" => 1},
          %{@source | "on" => nil},
          %{@source | "expected_revision" => @maximum},
          %{@source | "source_revision" => -1},
          %{@source | "target_id" => "light/one"}
        ] do
      assert {:error, :invalid_rule_operation_input} = OperationInput.encode("admit", value)
      assert {:error, :invalid_rule_operation_input} = OperationInput.source("admit", value)
    end

    assert {:ok, bytes} =
             OperationInput.encode("admit", %{
               @source
               | "expected_revision" => @maximum - 1,
                 "source_revision" => @maximum,
                 "on" => false
             })

    assert {:ok, "admit", %{"on" => false, "source_revision" => @maximum}} =
             OperationInput.decode(bytes)

    assert {:error, :invalid_rule_operation_input} =
             OperationInput.encode("activate", %{
               "authority_epoch" => 1,
               "operation_id" => "rule:one",
               "expected_revision" => 3,
               "admission_revision" => 4
             })

    assert {:error, :invalid_rule_operation_input} =
             OperationInput.encode("invoke", %{
               "authority_epoch" => 1,
               "operation_id" => "rule:one",
               "rule_generation" => 0,
               "rule_id" => "rule:one"
             })

    assert {:error, :invalid_rule_operation_input} = OperationInput.encode("schedule", @source)
  end

  test "bounded canonical input rejects alternate encodings before correspondence" do
    for bytes <- [
          " " <> @literal,
          @literal <> "\n",
          @literal <> "[]",
          String.replace(@literal, ",7,", ",07,"),
          String.replace(@literal, ",7,", ",7.0,"),
          String.replace(@literal, ",7,", ",true,"),
          String.replace(@literal, ",9,", ",-9,"),
          String.replace(@literal, ",9,", ",9223372036854775808,"),
          String.replace(@literal, "true]", "null]"),
          String.replace(@literal, "true]", "[true]]"),
          String.replace(@literal, "true]", "true,0]"),
          String.replace(@literal, "rule:one", "rule\\u003aone"),
          String.replace(@literal, "rule:one", String.duplicate("a", 129)),
          String.replace(@literal, "light:one", "灯"),
          String.duplicate(" ", 4_097),
          "{}",
          "[]",
          "[[[]]]"
        ] do
      assert {:error, :invalid_rule_operation_input} = OperationInput.decode(bytes)
    end

    assert {:ok, values} = JSON.decode(@literal)
    assert {:ok, "admit", @source} = OperationInput.from_record(values)
    assert {:error, :invalid_rule_operation_input} = OperationInput.from_record(values ++ [0])
    assert {:error, :invalid_rule_operation_input} = OperationInput.from_record(@source)
  end
end
