defmodule HomeValueArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{ExternalEnvelope, ExternalValue}

  defp fixture(name), do: JSON.decode!(File.read!("fixtures/" <> name <> ".json"))

  defp encode(data) do
    {:ok, bytes} = Wotex.JSON.encode(data)
    bytes
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp record(data, ref) do
    bytes = encode(data)
    %{"reference" => ref, "bytes" => bytes, "raw_sha256" => sha(bytes)}
  end

  defp compile(v) do
    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", %{
        "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
        "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
        "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
      })

    docs = %{
      "profile" => record(v["profile"], v["envelope"]["profile"]),
      "definitions" => Enum.zip_with(v["definitions"], v["envelope"]["definitions"], &record/2)
    }

    ExternalEnvelope.compile(
      encode(v["envelope"]),
      docs,
      installed,
      v["capture"],
      v["reader_limits"]
    )
  end

  defp report(family, index \\ 0),
    do:
      fixture("authoring-fixtures")[family]["fixtures"] |> Enum.at(index) |> Map.fetch!("report")

  defp selected(family), do: fixture("external-values")[family]["contract"]

  defp typed_fixture(v, schema) do
    limits = v["reader_limits"]
    [binding] = v["bindings"]
    binding = Map.put(binding, "raw_value_schema", schema)
    {:ok, digest} = Wotex.Profiles.Binding.digest(Map.delete(binding, "sha256"), limits)
    binding = Map.put(binding, "sha256", digest)
    {:ok, binding_ref} = Wotex.Profiles.Binding.reference(binding, limits)
    [definition] = v["definitions"]
    definition = Map.merge(definition, %{"unit" => nil, "value_schema" => schema})
    {:ok, semantic_ref} = Wotex.Profiles.Definition.reference(definition, limits)
    [channel] = v["profile"]["channels"]

    channel =
      Map.merge(channel, %{
        "semantic" => semantic_ref,
        "conversion" => nil,
        "invalid_values" => []
      })

    profile = Map.merge(v["profile"], %{"binding" => binding_ref, "channels" => [channel]})
    {:ok, profile_ref} = Wotex.Profiles.Profile.reference(profile, limits)
    capture = Map.put(v["capture"], "binding", binding_ref)
    {:ok, digest} = Wotex.Profiles.Capture.digest(Map.delete(capture, "digest"), binding, limits)
    capture = Map.put(capture, "digest", digest)

    envelope =
      Map.merge(v["envelope"], %{"profile" => profile_ref, "definitions" => [semantic_ref]})

    Map.merge(v, %{
      "bindings" => [binding],
      "definitions" => [definition],
      "profile" => profile,
      "capture" => capture,
      "envelope" => envelope
    })
  end

  test "Boolean and external record consumption preserve literal independently supplied values" do
    for {schema, value, kind} <- [
          {%{"type" => "boolean"}, %{"type" => "boolean", "value" => true}, "boolean"},
          {%{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["enabled"],
             "properties" => %{"enabled" => %{"type" => "boolean"}}
           },
           %{
             "type" => "object",
             "entries" => [
               %{"key" => "enabled", "value" => %{"type" => "boolean", "value" => true}}
             ]
           }, "external"}
        ] do
      v = typed_fixture(fixture("temperature"), schema)
      {:ok, envelope} = compile(v)

      contract =
        Map.merge(selected("temperature"), %{
          "semantic_ref" => hd(v["envelope"]["definitions"]),
          "value_kind" => kind,
          "unit" => nil,
          "constraints" => nil
        })

      input =
        report("temperature")
        |> Map.merge(%{
          "profile_sha256" => v["envelope"]["profile"]["sha256"],
          "binding" => v["capture"]["binding"],
          "value" => value
        })

      assert {:ok, result} = ExternalValue.project(envelope, input, contract, v["reader_limits"])
      assert result.data["normalized_value"] == value and result.data["unit"] == nil
      assert result.data["source_time"] == input["source_time"]
      assert {:ok, _} = ExternalValue.to_map(result, envelope, contract, v["reader_limits"])
    end
  end

  test "independent rational coordinates and exact consumer SHA bind both quantities" do
    for family <- ~w(temperature research) do
      v = fixture(family)
      expected = fixture("external-values")[family]
      {:ok, envelope} = compile(v)

      assert {:ok, result} =
               ExternalValue.project(
                 envelope,
                 report(family),
                 selected(family),
                 v["reader_limits"]
               )

      assert result.data["normalized_value"] == expected["expected_value"]
      assert result.data["unit"] == expected["contract"]["unit"]
      assert result.data["contract_sha256"] == expected["contract_sha256"]

      assert Map.take(result.data, Map.keys(expected["expected_provenance"])) ==
               expected["expected_provenance"]

      assert result.sha256 == sha("wotex-home.external-value@1\n" <> encode(result.data))

      assert {:ok, %{"data" => data, "sha256" => digest}} =
               ExternalValue.to_map(result, envelope, selected(family), v["reader_limits"])

      assert data == result.data and digest == result.sha256

      refute Map.has_key?(data, "report") or Map.has_key?(data, "capture") or
               Map.has_key?(data, "selector")
    end
  end

  test "sentinels, unusable quality and retained provenance never become zero or current evidence" do
    v = fixture("temperature")
    {:ok, envelope} = compile(v)

    for {quality, continuity} <- [
          {"unknown", "retained"},
          {"stale", "replayed"},
          {"invalid", "gap"}
        ] do
      input =
        report("temperature")
        |> Map.merge(%{
          "quality" => quality,
          "quality_reason" => if(quality == "stale", do: "stale", else: "missing"),
          "continuity" => continuity,
          "sequence" => nil,
          "source_time" => nil,
          "value" => %{"type" => "null"}
        })

      assert {:ok, result} =
               ExternalValue.project(envelope, input, selected("temperature"), v["reader_limits"])

      assert result.data["normalized_value"] == %{"type" => "null"}
      assert result.data["quality"] == quality and result.data["continuity"] == continuity
      assert result.data["sequence"] == nil and result.data["source_time"] == nil
      assert result.data["receipt_time"] == input["receipt_time"]
    end

    assert {:ok, sentinel} =
             ExternalValue.project(
               envelope,
               report("temperature", 1),
               selected("temperature"),
               v["reader_limits"]
             )

    assert sentinel.data["quality"] == "invalid" and
             sentinel.data["quality_reason"] == "profile_sentinel"

    assert sentinel.data["normalized_value"] == %{"type" => "null"}
  end

  test "exact semantic and installed consumer joins refuse mismatches without quantity inference" do
    v = fixture("temperature")
    {:ok, envelope} = compile(v)

    for contract <- [
          put_in(selected("temperature"), ["semantic_ref", "sha256"], String.duplicate("0", 64)),
          put_in(selected("temperature"), ["reference", "sha256"], String.duplicate("0", 64)),
          put_in(
            selected("temperature"),
            ["unit", "quantity_kind"],
            "urn:example:quantity:different"
          )
        ] do
      assert {:error, :unsupported_external_value} =
               ExternalValue.project(
                 envelope,
                 report("temperature"),
                 contract,
                 v["reader_limits"]
               )
    end

    invalid = report("temperature", 1)

    wrong_unit =
      put_in(selected("temperature"), ["unit", "quantity_kind"], "urn:example:quantity:different")

    assert {:error, :unsupported_external_value} =
             ExternalValue.project(envelope, invalid, wrong_unit, v["reader_limits"])
  end

  test "required integer conversion refuses fractions, range errors and signed-64 overflow" do
    v = fixture("temperature")
    {:ok, envelope} = compile(v)
    fractional = put_in(selected("temperature"), ["unit", "scale_d"], "1")

    assert {:error, :inexact_external_value} =
             ExternalValue.project(
               envelope,
               report("temperature"),
               fractional,
               v["reader_limits"]
             )

    range = put_in(selected("temperature"), ["constraints", "max"], 2499)

    repeating = put_in(selected("temperature"), ["unit", "scale_n"], "3")

    assert {:error, :inexact_external_value} =
             ExternalValue.project(envelope, report("temperature"), repeating, v["reader_limits"])

    assert {:error, :external_value_out_of_range} =
             ExternalValue.project(envelope, report("temperature"), range, v["reader_limits"])

    huge = put_in(selected("temperature"), ["unit", "scale_d"], "9223372036854775807")

    assert {:error, :external_profile_limit} =
             ExternalValue.project(envelope, report("temperature"), huge, v["reader_limits"])

    # Changing the supplied numeric budget never installs a rounding policy.
    unsigned = put_in(selected("temperature"), ["unit", "scale_d"], "4000000000000000000")

    assert {:error, :external_value_out_of_range} =
             ExternalValue.project(envelope, report("temperature"), unsigned, v["reader_limits"])

    limits = Map.put(v["reader_limits"], "max_numeric_digits", 1)

    assert {:error, :stale_external_basis} =
             ExternalValue.project(
               envelope,
               report("temperature"),
               selected("temperature"),
               limits
             )
  end

  test "stale report and current consumer selections cannot validate historical values" do
    v = fixture("temperature")
    {:ok, envelope} = compile(v)
    c = selected("temperature")

    assert {:ok, result} =
             ExternalValue.project(envelope, report("temperature"), c, v["reader_limits"])

    for input <- [
          Map.put(report("temperature"), "profile_sha256", String.duplicate("0", 64)),
          Map.put(report("temperature"), "capture_epoch", String.duplicate("0", 32))
        ] do
      assert {:error, :stale_external_basis} =
               ExternalValue.project(envelope, input, c, v["reader_limits"])
    end

    assert {:error, :unsupported_external_value} =
             ExternalValue.project(
               envelope,
               Map.put(report("temperature"), "channel_id", "unknown"),
               c,
               v["reader_limits"]
             )

    changed = put_in(c, ["constraints", "max"], 10000)

    assert {:error, :stale_external_basis} =
             ExternalValue.to_map(result, envelope, changed, v["reader_limits"])

    changed_v = put_in(v, ["envelope", "provenance", "publisher"], "changed attribution")
    {:ok, changed_envelope} = compile(changed_v)

    assert {:error, :stale_external_basis} =
             ExternalValue.to_map(result, changed_envelope, c, v["reader_limits"])

    for forged <- [
          Map.put(result, :extra, true),
          %{result | sha256: String.duplicate("0", 64)},
          %{
            result
            | data: Map.put(result.data, "normalized_value", %{"type" => "sint", "value" => "0"})
          },
          %{result | inputs: Map.put(result.inputs, "report", %{})}
        ] do
      assert {:error, :invalid_external_value} =
               ExternalValue.to_map(forged, envelope, c, v["reader_limits"])
    end
  end

  test "external values retain their original C02 coordinate and contract schema is closed" do
    v = fixture("research")
    {:ok, envelope} = compile(v)

    contract =
      Map.merge(selected("research"), %{
        "value_kind" => "external",
        "unit" => nil,
        "constraints" => nil
      })

    assert {:ok, result} =
             ExternalValue.project(envelope, report("research"), contract, v["reader_limits"])

    expected =
      fixture("authoring-fixtures")["research"]["fixtures"] |> hd() |> Map.fetch!("expected")

    assert result.data["normalized_value"] == expected["normalized_value"]
    assert result.data["unit"] == expected["unit"]
    schema = ExJsonSchema.Schema.resolve(fixture("external-consumer.schema"))
    assert :ok = ExJsonSchema.Validator.validate(schema, contract)
    assert :ok = ExJsonSchema.Validator.validate(schema, selected("temperature"))

    for bad <- [
          Map.put(contract, "extra", true),
          Map.put(contract, "unit", expected["unit"]),
          put_in(selected("research"), ["constraints", "min"], 9_223_372_036_854_775_808),
          put_in(selected("research"), ["constraints", "max"], -9_223_372_036_854_775_808)
          |> put_in(["constraints", "min"], 0)
        ] do
      assert {:error, :invalid_external_value} =
               ExternalValue.project(envelope, report("research"), bad, v["reader_limits"])
    end

    assert {:error, :external_profile_limit} =
             ExternalValue.project(
               envelope,
               Map.put(report("research"), "source_ref", String.duplicate("x", 4097)),
               contract,
               v["reader_limits"]
             )

    for value <- [
          %{"type" => "list", "items" => List.duplicate(%{"type" => "null"}, 257)},
          Enum.reduce(1..9, %{"type" => "null"}, fn _, inner ->
            %{"type" => "list", "items" => [inner]}
          end)
        ] do
      assert {:error, :external_profile_limit} =
               ExternalValue.project(
                 envelope,
                 Map.put(report("research"), "value", value),
                 contract,
                 v["reader_limits"]
               )
    end
  end
end
