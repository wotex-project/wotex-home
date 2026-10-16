defmodule WotexHome.RoutineClockSchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  setup_all do
    raw = "priv/profiles/routine-clock.schema.json" |> File.read!() |> JSON.decode!()
    vectors = "test/fixtures/routines/clock-bases.json" |> File.read!() |> JSON.decode!()
    %{schema: ExJsonSchema.Schema.resolve(raw), v: vectors}
  end

  test "complete independent private inputs fit closed shapes", c do
    binding =
      Map.take(
        c.v["request"],
        ~w(deployment_id owner_id authority_epoch store_boot_epoch elapsed_generation runtime_digest monotonic_origin_ms)
      )

    for {fragment, value} <- [
          {"policy", c.v["policy"]},
          {"request", c.v["request"]},
          {"binding", binding}
        ] do
      assert valid?(c.schema, fragment, value)
      refute valid?(c.schema, fragment, Map.put(value, "authorized", true))
      for key <- Map.keys(value), do: refute(valid?(c.schema, fragment, Map.delete(value, key)))
    end

    for pair <- c.v["pairs"], side <- ["old", "new"] do
      assert valid?(c.schema, "observation", pair[side])
    end

    assert valid?(c.schema, "utc_scope", c.v["utc"]["scope"])

    for kind <- ["policy", "request"] do
      wire = JSON.decode!(c.v[kind <> "_document"])
      assert valid?(c.schema, kind <> "_wire", wire)
      refute valid?(c.schema, kind <> "_wire", wire ++ [nil])
      refute valid?(c.schema, kind <> "_wire", tl(wire))
    end
  end

  test "canonical bytes and arithmetic vectors regenerate without application code" do
    {output, code} = System.cmd("python3", ["test/support/routine_clock_oracle.py", "--check"])
    assert code == 0, output
    assert output =~ "15 independent interval cases and 7 exact-coordinate cases agree"
  end

  defp valid?(schema, fragment, value),
    do: ExJsonSchema.Validator.valid_fragment?(schema, "#/definitions/" <> fragment, value)
end
