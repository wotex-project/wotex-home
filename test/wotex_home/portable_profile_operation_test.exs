defmodule WotexHome.PortableProfileOperationTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.Operation

  @common %{
    "action" => "approve",
    "authority_epoch" => 1,
    "operation_id" => "profile:approve:1",
    "expected_revision" => 3,
    "artifact_digest" => String.duplicate("a", 64),
    "expected_trust_revision" => 0
  }

  test "ordered encoding fixes every immutable input and is independent of map insertion" do
    assert {:ok, document} = Operation.encode(@common)

    expected =
      ~s(["wotex-home.profile-operation.v1",["approve",1,"profile:approve:1",3,"#{String.duplicate("a", 64)}",0]])

    assert document == expected
    assert {:ok, @common} = Operation.decode(document)
    assert {:ok, ^document} = @common |> Enum.reverse() |> Map.new() |> Operation.encode()

    for {key, value} <- [
          {"expected_revision", 4},
          {"expected_trust_revision", 9},
          {"action", "revoke"}
        ] do
      assert {:ok, changed} = Operation.encode(Map.put(@common, key, value))
      refute changed == document
    end
  end

  test "selection binds the exact capture and current authority dependency pins" do
    input =
      Map.merge(@common, %{
        "action" => "select",
        "target_id" => "light:test",
        "expected_resource_revision" => 0,
        "expected_binding_revision" => 2,
        "expected_selection_generation" => 0,
        "expected_policy_generation" => 1,
        "expected_rule_generation" => 2,
        "session_ref" => "capture:1",
        "candidate_ref" => "candidate:1",
        "review_ref" => "review:1"
      })

    assert {:ok, encoded} = Operation.encode(input)
    assert {:ok, ^input} = Operation.decode(encoded)

    assert {:error, :invalid_profile_operation} =
             Operation.encode(Map.delete(input, "session_ref"))

    for key <-
          ~w(expected_binding_revision expected_selection_generation expected_policy_generation expected_rule_generation) do
      assert {:ok, changed} = Operation.encode(Map.update!(input, key, &(&1 + 1)))
      refute changed == encoded
    end
  end

  test "revocation requires retained identity without a new capture or artifact body" do
    input =
      Map.merge(@common, %{
        "action" => "revoke_selection",
        "target_id" => "light:test",
        "expected_resource_revision" => 1,
        "expected_selection_generation" => 2
      })

    assert {:ok, encoded} = Operation.encode(input)
    assert {:ok, ^input} = Operation.decode(encoded)

    assert {:error, :invalid_profile_operation} =
             Operation.encode(Map.put(input, "bytes", "arbitrary"))
  end

  test "malformed, noncanonical and unbounded request identities fail" do
    for input <- [
          nil,
          Map.put(@common, "module", "Elixir.System"),
          Map.put(@common, "action", "rollback_without_review"),
          Map.put(@common, "operation_id", "invalid id"),
          Map.put(@common, "artifact_digest", String.duplicate("A", 64)),
          Map.put(@common, "authority_epoch", 0),
          Map.put(@common, "authority_epoch", nil),
          Map.put(@common, "authority_epoch", true),
          Map.put(@common, "expected_revision", -1),
          Map.put(@common, "expected_revision", 1.0),
          Map.put(@common, "expected_revision", 9_223_372_036_854_775_808)
        ] do
      assert {:error, :invalid_profile_operation} = Operation.encode(input)
    end

    {:ok, encoded} = Operation.encode(@common)

    for bytes <- [" " <> encoded, encoded <> "{}", "[]", String.duplicate("[", 4_097)] do
      assert {:error, :invalid_profile_operation} = Operation.decode(bytes)
    end
  end
end
