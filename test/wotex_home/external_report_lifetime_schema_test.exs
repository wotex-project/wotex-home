defmodule WotexHome.ExternalReportLifetimeSchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  setup_all do
    vectors = JSON.decode!(File.read!("test/fixtures/profiles/external-report-lifetimes.json"))

    schema =
      "priv/profiles/external-report-lifetime.schema.json"
      |> File.read!()
      |> JSON.decode!()
      |> ExJsonSchema.Schema.resolve()

    %{vectors: vectors, schema: schema}
  end

  test "independent signed original lifetimes preserve their exclusive boundary", c do
    for {_family, row} <- c.vectors["families"] do
      witness = row["expected"]
      assert :ok = ExJsonSchema.Validator.validate(c.schema, witness)
      assert map_size(witness) == 13
      assert witness["receipt_monotonic_us"] == "-5"
      assert witness["expires_at_us"] == "59999995"

      assert String.to_integer(witness["expires_at_us"]) -
               String.to_integer(witness["receipt_monotonic_us"]) == 60_000_000

      assert Enum.map(row["checks"], & &1["expected"]) == [
               "live",
               "external_report_retired",
               "external_report_retired"
             ]
    end
  end

  test "closed lifetime result has no body, authority, new receive instant or UTC", c do
    witness = c.vectors["families"]["temperature"]["expected"]

    for changed <- [
          Map.put(witness, "report", %{}),
          Map.put(witness, "now_us", "1"),
          Map.put(witness, "received_at", "2026-10-15T00:00:00Z"),
          Map.put(witness, "state", "pending"),
          Map.delete(witness, "expires_at_us"),
          Map.put(witness, "receipt_monotonic_us", "-0"),
          Map.put(witness, "expires_at_us", "+1"),
          Map.put(witness, "report_id", "report:1\n")
        ] do
      refute ExJsonSchema.Validator.valid?(c.schema, changed)
    end
  end
end
