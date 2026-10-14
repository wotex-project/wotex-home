defmodule HomeFixtureArchiveTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringFixtures, ExternalEnvelope}

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

  defp resign(v, profile) do
    {:ok, ref} = Wotex.Profiles.Profile.reference(profile, v["reader_limits"])
    v |> Map.put("profile", profile) |> put_in(["envelope", "profile"], ref)
  end

  defp cases(family), do: fixture("authoring-fixtures")[family]["fixtures"]

  test "independent selectors, exact values, sentinels and source/receipt times pass for both quantities" do
    for family <- ~w(temperature research) do
      v = fixture(family)
      assert {:ok, envelope} = compile(v)
      assert {:ok, result} = AuthoringFixtures.check(envelope, cases(family), v["reader_limits"])
      assert {:ok, data} = AuthoringFixtures.to_map(result, envelope, v["reader_limits"])
      assert data["status"] == "passed"
      assert data["uncovered_channels"] == []
      assert data["fixtures_sha256"] == fixture("authoring-fixtures")[family]["fixtures_sha256"]
      assert Enum.all?(data["cases"], &(&1["disposition"] == "passed" and &1["reason"] == nil))
      refute inspect(data) =~ "independent-report-fixture"
      refute Map.has_key?(data, "expected")
    end
  end

  test "producer-compatible wrong register and conversion fail independently reviewed expectations" do
    v = fixture("temperature")

    for {field, value, reason} <- [
          {"selector", %{"register" => 5}, "selector_mismatch"},
          {"conversion",
           %{
             "kind" => "affine",
             "scale_n" => "1",
             "scale_d" => "5",
             "offset_n" => "0",
             "offset_d" => "1"
           }, "proposal_mismatch"}
        ] do
      profile = put_in(v["profile"], ["channels", Access.at(0), field], value)
      changed = resign(v, profile)
      assert {:ok, envelope} = compile(changed)

      fixtures =
        Enum.map(cases("temperature"), fn f ->
          put_in(f, ["report", "profile_sha256"], changed["envelope"]["profile"]["sha256"])
        end)

      assert {:ok, result} = AuthoringFixtures.check(envelope, fixtures, v["reader_limits"])
      assert result.data["status"] == "failed"
      assert hd(result.data["cases"])["reason"] == reason
      refute inspect(result.data) =~ "register"
    end
  end

  test "missing coverage, empty sets and stale report basis cannot become passed" do
    v = fixture("temperature")
    {:ok, envelope} = compile(v)
    assert {:ok, empty} = AuthoringFixtures.check(envelope, [], v["reader_limits"])
    assert empty.data["status"] == "not_supplied"
    assert empty.data["uncovered_channels"] == ["sample"]
    [first | _] = cases("temperature")
    changed = put_in(first, ["report", "capture_epoch"], String.duplicate("a", 32))
    assert {:ok, result} = AuthoringFixtures.check(envelope, [changed], v["reader_limits"])

    assert result.data["cases"] == [
             %{
               "id" => first["id"],
               "disposition" => "failed",
               "reason" => "interpretation_refused"
             }
           ]

    secondary =
      hd(v["profile"]["channels"])
      |> Map.put("id", "secondary")
      |> put_in(["affordance", "name"], "secondary")

    v = resign(v, Map.put(v["profile"], "channels", v["profile"]["channels"] ++ [secondary]))
    home = hd(v["envelope"]["home_contracts"]) |> Map.put("channel_id", "secondary")
    v = put_in(v, ["envelope", "home_contracts"], v["envelope"]["home_contracts"] ++ [home])
    assert {:ok, envelope} = compile(v)
    first = put_in(first, ["report", "profile_sha256"], v["envelope"]["profile"]["sha256"])
    assert {:ok, result} = AuthoringFixtures.check(envelope, [first], v["reader_limits"])
    assert result.data["status"] == "incomplete"
    assert result.data["uncovered_channels"] == ["secondary"]
  end

  test "aggregate fixture resources are bounded and independent source/receipt expectations compare exactly" do
    v = fixture("temperature")
    {:ok, envelope} = compile(v)
    [first | _] = cases("temperature")

    selector =
      Map.new(1..128, fn index ->
        {"entry:" <> Integer.to_string(index), String.duplicate("x", 256)}
      end)

    many =
      Enum.map(1..8, fn index ->
        first |> Map.put("id", "case:#{index}") |> Map.put("selector", selector)
      end)

    assert {:error, :authoring_limit} =
             AuthoringFixtures.check(envelope, many, v["reader_limits"])

    for changed <- [
          put_in(first, ["expected", "receipt_time", "monotonic_us"], "-4"),
          put_in(first, ["expected", "source_time", "uncertainty_us"], "4"),
          put_in(first, ["expected", "continuity"], "continuous")
        ] do
      assert {:ok, result} = AuthoringFixtures.check(envelope, [changed], v["reader_limits"])
      assert result.data["status"] == "failed"
      assert hd(result.data["cases"])["reason"] == "proposal_mismatch"
    end

    unavailable = put_in(first, ["report", "channel_id"], "absent")
    assert {:ok, result} = AuthoringFixtures.check(envelope, [unavailable], v["reader_limits"])
    assert hd(result.data["cases"])["reason"] == "channel_unavailable"
  end

  test "closed expectations and explicit limits refuse safely; native and current basis are rechecked" do
    v = fixture("temperature")
    {:ok, envelope} = compile(v)
    fixtures = cases("temperature")
    [first | _] = fixtures

    for bad <- [
          [first | :bad],
          [first, first],
          Enum.reverse(fixtures),
          [Map.put(first, "extra", "private-canary")],
          [put_in(first, ["expected", "normalized_value"], %{"type" => "made-up"})],
          [Map.put(first, "expected", %{})]
        ] do
      assert {:error, :invalid_authoring_fixture} =
               AuthoringFixtures.check(envelope, bad, v["reader_limits"])
    end

    many =
      Enum.map(
        1..32,
        &Map.put(first, "id", "case:" <> String.pad_leading(Integer.to_string(&1), 2, "0"))
      )

    assert {:ok, result} = AuthoringFixtures.check(envelope, many, v["reader_limits"])
    assert result.data["status"] == "passed"

    assert {:error, :authoring_limit} =
             AuthoringFixtures.check(
               envelope,
               many ++ [Map.put(first, "id", "case:33")],
               v["reader_limits"]
             )

    assert {:error, :authoring_limit} =
             AuthoringFixtures.check(
               envelope,
               [Map.put(first, "selector", %{"secret" => String.duplicate("x", 257)})],
               v["reader_limits"]
             )

    assert {:ok, result} = AuthoringFixtures.check(envelope, fixtures, v["reader_limits"])

    for bad <- [
          %{result | data: %{}},
          %{result | fixtures: []},
          Map.put(result, :extra, "secret")
        ] do
      assert {:error, :invalid_authoring_fixture} =
               AuthoringFixtures.to_map(bad, envelope, v["reader_limits"])
    end

    changed = put_in(v, ["envelope", "provenance", "source"], "new source")
    assert {:ok, current} = compile(changed)

    assert {:error, :stale_authoring_basis} =
             AuthoringFixtures.to_map(result, current, v["reader_limits"])
  end
end
