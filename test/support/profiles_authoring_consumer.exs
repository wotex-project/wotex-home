defmodule HomeAuthoringArchiveTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringAssessment, AuthoringContract}

  defp fixture(family), do: JSON.decode!(File.read!("fixtures/" <> family <> ".json"))
  defp vector(family), do: fixture("authoring-mechanics")[family]

  defp encode(data) do
    {:ok, bytes} = Wotex.JSON.encode(data)
    bytes
  end

  defp installed(v) do
    v
    |> Map.take(~w(bindings contracts home_contracts))
    |> Map.put("producer", %{
      "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
      "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
      "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
    })
  end

  defp contract(family, overrides \\ %{}) do
    {:ok, value} =
      AuthoringContract.export(
        installed(fixture(family)),
        Map.merge(vector(family)["limits"], overrides)
      )

    value
  end

  test "independent manual quantities bind exact contract, archive, draft and bundle identities" do
    refute Code.ensure_loaded?(WotexHome.Application)
    refute Code.ensure_loaded?(Wotex.Routines)

    for family <- ~w(temperature research) do
      c = contract(family)
      v = vector(family)
      assert {:ok, summary} = AuthoringContract.to_map(c)

      for key <- ~w(contract_sha256 contract_raw_sha256 basis_sha256),
          do: assert(summary[key] == v[key])

      assert {:ok, result} = AuthoringAssessment.assess(v["draft_bytes"], c, nil)
      assert {:ok, data} = AuthoringAssessment.to_map(result, c)
      assert data["draft_sha256"] == v["draft_sha256"]
      assert data["bundle_sha256"] == v["bundle_sha256"]
      assert data["disposition"] == "compatible"
      assert data["capture_status"] == "not_supplied"
      assert data["home_consumption"] == "not_assessed"
      assert data["source_review"] == "not_assessed"
      assert data["fixture_status"] == "not_supplied"
      refute inspect(data) =~ "synthetic-industrial"
      refute Map.has_key?(data, "draft_bytes")
    end
  end

  test "explicit capture matching and mismatch retain separate outcomes" do
    c = contract("temperature")
    draft = vector("temperature")["draft_bytes"]
    capture = fixture("temperature")["capture"]
    assert {:ok, result} = AuthoringAssessment.assess(draft, c, capture)
    assert result.data["capture_status"] == "matched"
    changed = Map.put(capture, "capture_epoch", String.duplicate("a", 32))
    assert {:ok, result} = AuthoringAssessment.assess(draft, c, changed)
    assert result.data["capture_status"] == "mismatch"
    assert result.data["disposition"] == "invalid"
    refute inspect(result.data) =~ "synthetic-industrial"
  end

  test "candidate syntax, duplicates and unsupported selector return safe invalid reports" do
    c = contract("temperature")
    draft = JSON.decode!(vector("temperature")["draft_bytes"])

    bad =
      put_in(draft, ["profile", "channels", Access.at(0), "selector"], %{
        "private-selector-canary" => "source-private-canary"
      })

    for bytes <- ["{", "{\"format\":1,\"format\":2}", encode(bad)] do
      assert {:ok, result} = AuthoringAssessment.assess(bytes, c, nil)
      assert result.data["disposition"] == "invalid"
      refute inspect(result.data) =~ "private-canary"
      refute inspect(result.data) =~ "private-selector"
      assert {:ok, data} = AuthoringAssessment.to_map(result, c)
      assert data == result.data
    end
  end

  test "closed inputs, explicit budgets and bounded capture refuse without hidden defaults" do
    v = fixture("temperature")
    limits = vector("temperature")["limits"]

    for changed <- [
          Map.delete(limits, "max_check_steps"),
          Map.put(limits, "extra", 1),
          Map.put(limits, "max_check_steps", 0),
          Map.put(limits, "reader", %{})
        ] do
      assert {:error, :invalid_authoring_contract} =
               AuthoringContract.export(installed(v), changed)
    end

    assert {:error, :authoring_limit} =
             AuthoringContract.export(
               installed(v),
               Map.put(limits, "max_bundle_bytes", 262_145)
             )

    for changed <- [
          Map.put(installed(v), "bindings", [%{} | :bad]),
          Map.put(installed(v), "bindings", List.duplicate(%{}, 33)),
          Map.put(installed(v), "producer", %{}),
          Map.put(installed(v), "extra", "secret")
        ] do
      assert {:error, :invalid_authoring_contract} = AuthoringContract.export(changed, limits)
    end

    c = contract("temperature")
    assert {:error, :invalid_authoring_assessment} = AuthoringAssessment.assess("", c, nil)

    assert {:error, :authoring_limit} =
             AuthoringAssessment.assess(String.duplicate("x", 262_145), c, nil)

    assert {:error, :invalid_authoring_assessment} = AuthoringAssessment.assess("{}", c, [])

    assert {:error, :authoring_limit} =
             AuthoringAssessment.assess("{}", c, %{"secret" => String.duplicate("x", 257)})

    assert {:error, :authoring_limit} =
             AuthoringAssessment.assess(
               vector("temperature")["draft_bytes"],
               contract("temperature", %{"max_check_steps" => 1}),
               nil
             )

    assert {:error, :authoring_limit} =
             AuthoringAssessment.assess(
               "{}",
               contract("temperature", %{"max_report_bytes" => 1}),
               nil
             )
  end

  test "forged native values refuse and changed archive, policy reference or budget retires the basis" do
    c = contract("temperature")

    assert {:ok, result} =
             AuthoringAssessment.assess(vector("temperature")["draft_bytes"], c, nil)

    for changed <- [
          %{c | bytes: c.bytes <> " "},
          %{c | basis_sha256: String.duplicate("0", 64)},
          %{c | contract_sha256: String.duplicate("0", 64)},
          Map.put(c, :extra, "secret")
        ] do
      assert {:error, :invalid_authoring_contract} = AuthoringContract.to_map(changed)
    end

    for changed <- [
          %{result | draft_bytes: "{}"},
          %{result | bundle_bytes: "{}"},
          %{result | data: %{}},
          %{result | capture: fixture("temperature")["capture"]},
          Map.put(result, :extra, "secret")
        ] do
      assert {:error, :invalid_authoring_assessment} = AuthoringAssessment.to_map(changed, c)
    end

    v = fixture("temperature")

    for i <- [
          put_in(
            installed(v),
            ["producer", "profiles_archive_sha256"],
            String.duplicate("0", 64)
          ),
          Map.put(installed(v), "home_contracts", [])
        ] do
      assert {:ok, changed} = AuthoringContract.export(i, vector("temperature")["limits"])
      assert changed.contract_sha256 == c.contract_sha256
      refute changed.basis_sha256 == c.basis_sha256
      assert {:error, :stale_authoring_basis} = AuthoringAssessment.to_map(result, changed)
    end

    changed = contract("temperature", %{"max_diagnostics" => 63})
    assert {:error, :stale_authoring_basis} = AuthoringAssessment.to_map(result, changed)
  end
end
