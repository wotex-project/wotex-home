defmodule WotexHome.ControllerCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.Recovery.ControllerCodec
  @maximum 9_223_372_036_854_775_807

  setup do
    operation = %{
      "authority_epoch" => 2,
      "operation_id" => "retire:original",
      "expected_revision" => 10,
      "destination_owner_id" => String.duplicate("b", 64)
    }

    origin = %{
      "deployment_id" => String.duplicate("c", 64),
      "owner_id" => String.duplicate("a", 64),
      "authority_epoch" => 2,
      "store_revision" => 4,
      "provenance" => "local_bootstrap"
    }

    receipt =
      Map.merge(operation, %{
        "principal_id" => "transfer:operator",
        "deployment_id" => origin["deployment_id"],
        "source_owner_id" => origin["owner_id"],
        "maintenance_revision" => 8,
        "revision" => 11
      })

    %{operation: operation, origin: origin, receipt: receipt}
  end

  test "canonical origin, input and receipt retain exact ordered values", c do
    for {kind, format, fields, value} <- [
          {"origin", "wotex-home.controller-origin.v1",
           ~w(deployment_id owner_id authority_epoch store_revision provenance), c.origin},
          {"operation", "wotex-home.controller-retirement-operation.v1",
           ~w(authority_epoch operation_id expected_revision destination_owner_id), c.operation},
          {"retirement", "wotex-home.controller-retirement.v1",
           ~w(principal_id authority_epoch operation_id expected_revision deployment_id source_owner_id destination_owner_id maintenance_revision revision),
           c.receipt}
        ] do
      assert {:ok, document} = ControllerCodec.encode(kind, value)
      assert document == JSON.encode!([format, Enum.map(fields, &value[&1])])
      assert {:ok, ^value} = ControllerCodec.decode(kind, document)
      assert {:error, :invalid_controller_record} = ControllerCodec.decode(kind, " " <> document)
      assert {:error, :invalid_controller_record} = ControllerCodec.decode(kind, document <> "\n")

      assert {:error, :invalid_controller_record} =
               ControllerCodec.decode(
                 kind,
                 JSON.encode!([format, Enum.reverse(Enum.map(fields, &value[&1]))])
               )

      for field <- fields do
        assert {:error, :invalid_controller_record} =
                 ControllerCodec.encode(kind, Map.delete(value, field))
      end

      assert {:error, :invalid_controller_record} =
               ControllerCodec.encode(kind, Map.put(value, "isolated", true))
    end
  end

  test "finite original scope and retirement predecessor bounds fail closed", c do
    for {key, value} <- [
          {"authority_epoch", 0},
          {"authority_epoch", @maximum},
          {"expected_revision", -1},
          {"expected_revision", @maximum},
          {"operation_id", "../new"},
          {"destination_owner_id", String.duplicate("A", 64)}
        ] do
      assert {:error, :invalid_controller_record} =
               ControllerCodec.encode("operation", Map.put(c.operation, key, value))
    end

    for {key, value} <- [
          {"revision", 10},
          {"revision", 12},
          {"revision", 11.0},
          {"maintenance_revision", 0},
          {"maintenance_revision", 11},
          {"source_owner_id", c.operation["destination_owner_id"]},
          {"principal_id", ""}
        ] do
      assert {:error, :invalid_controller_record} =
               ControllerCodec.encode("retirement", Map.put(c.receipt, key, value))
    end

    assert {:error, :invalid_controller_record} =
             ControllerCodec.encode(
               "origin",
               Map.put(c.origin, "provenance", "restored_authority")
             )

    assert {:error, :invalid_controller_record} =
             ControllerCodec.encode("origin", Map.put(c.origin, "authority_epoch", 0))
  end

  test "arbitrary, oversized and cross-record documents cannot identify operations", c do
    for {kind, value} <- [
          {"origin", c.origin},
          {"operation", c.operation},
          {"retirement", c.receipt}
        ] do
      assert {:ok, document} = ControllerCodec.encode(kind, value)

      for other <- ["origin", "operation", "retirement"] -- [kind] do
        assert {:error, :invalid_controller_record} = ControllerCodec.decode(other, document)
      end

      for bytes <- [nil, "", "[]", "{}", "invalid", :binary.copy(" ", 4_097)] do
        assert {:error, :invalid_controller_record} = ControllerCodec.decode(kind, bytes)
      end
    end

    assert {:error, :invalid_controller_record} = ControllerCodec.encode("acceptance", c.receipt)
  end
end
