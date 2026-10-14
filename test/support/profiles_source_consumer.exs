defmodule HomeSourceReviewArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Profiles.{
    AuthoredEnvelope,
    AuthoringAssessment,
    AuthoringContract,
    SourceReview,
    ExternalEnvelope
  }

  defp fixture(n), do: JSON.decode!(File.read!("fixtures/" <> n <> ".json"))

  defp assessment(family) do
    v = fixture(family)
    a = fixture("authoring-mechanics")[family]

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", %{
        "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
        "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
        "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
      })

    {:ok, c} = AuthoringContract.export(installed, a["limits"])
    {:ok, value} = AuthoringAssessment.assess(a["draft_bytes"], c, nil)
    value
  end

  defp encode(data) do
    {:ok, b} = Wotex.JSON.encode(data)
    b
  end

  test "both quantities match independent fact roots, exact source/evidence identities and inert attribution" do
    for family <- ~w(temperature research) do
      a = assessment(family)
      v = fixture("authoring-sources")[family]
      assert {:ok, result} = SourceReview.check(a, [v["source"]], v["evidence"], [])
      assert {:ok, data} = SourceReview.to_map(result, a)
      assert data == v["expected"]
      refute inspect(data) =~ "synthetic reviewed fact"
      refute Map.has_key?(data, "evidence")
      assert {:ok, none} = SourceReview.check(a, [], [], [])

      assert none.data["status"] == "incomplete" and
               none.data["missing_paths"] == data["required_paths"]
    end
  end

  test "unresolved and ambiguous citations block attribution; unrelated and derived paths cannot cover facts" do
    a = assessment("temperature")
    v = fixture("authoring-sources")["temperature"]
    [first | _] = v["evidence"]

    assert {:ok, result} =
             SourceReview.check(a, [v["source"]], v["evidence"], [first["instance_path"]])

    assert result.data["status"] == "incomplete"
    refute first["instance_path"] in result.data["covered_paths"]
    extra = Map.put(first, "locator", "another citation")

    evidence =
      Enum.sort_by(
        [extra | v["evidence"]],
        &{&1["instance_path"], &1["source_ref"], &1["locator"]}
      )

    assert {:ok, result} = SourceReview.check(a, [v["source"]], evidence, [])

    assert result.data["status"] == "ambiguous" and
             result.data["ambiguous_paths"] == [first["instance_path"]]

    for path <- [
          "/profile",
          "/profile/channels/0/conversion/scale_n",
          "/definitions/0/annotations",
          "/missing",
          "/profile/channels/00/selector"
        ] do
      assert {:error, :invalid_authoring_review} =
               SourceReview.check(a, [v["source"]], [Map.put(first, "instance_path", path)], [])
    end
  end

  test "closed bounded sources/citations and forged native values refuse; changed draft/basis is stale" do
    a = assessment("temperature")
    v = fixture("authoring-sources")["temperature"]
    [first | _] = v["evidence"]

    for evidence <- [
          [first | :bad],
          [first, first],
          Enum.reverse(v["evidence"]),
          [Map.put(first, "extra", "secret")],
          [Map.put(first, "source_ref", String.duplicate("0", 64))],
          [Map.put(first, "locator", "bad\0")]
        ] do
      assert {:error, :invalid_authoring_review} =
               SourceReview.check(a, [v["source"]], evidence, [])
    end

    assert {:error, :authoring_limit} =
             SourceReview.check(a, [v["source"]], List.duplicate(first, 257), [])

    assert {:error, :authoring_limit} =
             SourceReview.check(a, [v["source"]], [], List.duplicate(first["instance_path"], 65))

    for source <- [
          Map.put(v["source"], "payload", "wrong"),
          Map.put(v["source"], "first_revision", 0),
          Map.put(v["source"], "extra", "secret")
        ] do
      assert {:error, :invalid_authoring_review} =
               SourceReview.check(a, [source], v["evidence"], [])
    end

    assert {:ok, result} = SourceReview.check(a, [v["source"]], v["evidence"], [])

    for forged <- [
          %{result | data: %{}},
          %{result | evidence: []},
          Map.put(result, :extra, "secret")
        ] do
      assert {:error, :invalid_authoring_review} = SourceReview.to_map(forged, a)
    end

    assert {:error, :stale_authoring_basis} = SourceReview.to_map(result, assessment("research"))
    assert {:ok, bad} = AuthoringAssessment.assess("{", a.contract, nil)

    assert {:error, :candidate_incompatible} =
             SourceReview.check(bad, [v["source"]], v["evidence"], [])
  end

  test "derived bundle documents reproduce both frozen envelopes and capture/consumption identities" do
    for family <- ~w(temperature research) do
      v = fixture(family)
      a = assessment(family)
      assert {:ok, envelope} = AuthoredEnvelope.compile(a, encode(v["envelope"]), v["capture"])
      assert {:ok, data} = ExternalEnvelope.to_map(envelope, v["reader_limits"])
      assert data["projection_sha256"] == v["expected"]["projection_sha256"]
      assert data["consumption_sha256"] == v["expected"]["consumption_sha256"]
      changed = put_in(v["envelope"], ["profile", "sha256"], String.duplicate("0", 64))

      assert {:error, :invalid_external_closure} =
               AuthoredEnvelope.compile(a, encode(changed), v["capture"])
    end
  end
end
