defmodule WotexHome.MutationTest do
  use ExUnit.Case, async: true

  alias WotexHome.{Id, Mutation}

  @valid %{
    "api_version" => 1,
    "operation_id" => "request:001",
    "authority_epoch" => 1,
    "expected_revision" => 0,
    "target_id" => "lamp:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => true}
  }

  test "accepts a bounded envelope without granting authority" do
    assert {:ok, %Mutation{operation_id: "request:001"}} = Mutation.new(@valid)
  end

  test "rejects caller-supplied role and unknown fields" do
    assert {:error, :invalid_fields} = Mutation.new(Map.put(@valid, "role", "admin"))
    assert {:error, :invalid_fields} = Mutation.new(Map.delete(@valid, "expected_revision"))
  end

  test "requires exact API version and nonnegative revisions" do
    assert {:error, :unsupported_api_version} = Mutation.new(%{@valid | "api_version" => 2})
    assert {:error, :invalid_revision} = Mutation.new(%{@valid | "authority_epoch" => -1})
    assert {:error, :invalid_revision} = Mutation.new(%{@valid | "expected_revision" => 0.1})
  end

  test "identifiers never become atoms and have tight bounds" do
    assert Id.valid?(String.duplicate("a", 128))
    refute Id.valid?(String.duplicate("a", 129))
    refute Id.valid?("a/b")
    refute Id.valid?("å")
    assert {:error, :invalid_id} = Mutation.new(%{@valid | "target_id" => "../lamp"})
  end
end
