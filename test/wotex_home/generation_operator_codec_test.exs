defmodule WotexHome.GenerationOperatorCodecTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{GenerationAttempt, GenerationOperator}
  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp request(operation, input),
    do: %{
      "api_version" => 1,
      "operation" => operation,
      "credential" => "fixture",
      "input" => input
    }

  defp response(key, body), do: %{"api_version" => 1, "outcome" => "ok", key => body}

  test "independent policy metadata and original wrappers validate for both quantities" do
    for family <- ~w(temperature research) do
      options = fixture("generation-operators")[family]
      assert :ok = GenerationOperator.validate_options(options["options"])

      assert :ok =
               GenerationOperator.validate_response(
                 request("authoring_generation_options", nil),
                 options["response"]
               )

      p = fixture("generation-preparations")[family]
      a = fixture("generation-attempts")[family]

      assert :ok =
               GenerationOperator.validate_response(
                 request("authoring_generation_prepare", p["request"]),
                 response("authoring_generation_receipt", p["receipt"])
               )

      assert :ok =
               GenerationOperator.validate_response(
                 request("authoring_generation_start", a["request"]),
                 response("authoring_generation_attempt_receipt", a["receipt"])
               )
    end
  end

  test "policy metadata cannot forge actor binding, digests, field grammar or ordering" do
    value = fixture("generation-operators")["temperature"]["options"]

    for changed <- [
          Map.put(value, "principal_id", "foreign:actor"),
          Map.put(value, "authority_epoch", 1.0),
          Map.put(value, "store_revision", 9.0),
          Map.put(value, "credential", "private"),
          Map.put(value, "policies", value["policies"] ++ value["policies"]),
          Map.put(value, "policies", [hd(value["policies"]) | :improper]),
          update_in(value, ["policies", Access.at(0), "policy_sha256"], fn _ ->
            String.duplicate("0", 64)
          end),
          update_in(value, ["policies", Access.at(0), "provider_present"], fn _ -> "true" end),
          update_in(value, ["policies", Access.at(0)], &Map.put(&1, "pid", "private"))
        ] do
      assert {:error, :invalid_generation_response} = GenerationOperator.validate_options(changed)
    end

    assert :ok = GenerationOperator.validate_options(Map.put(value, "policies", []))

    assert :ok =
             GenerationOperator.validate_options(
               put_in(value, ["policies", Access.at(0), "provider_present"], false)
             )
  end

  test "receipt identity, revision, original hashes and closed wrapper must match the requested operation" do
    p = fixture("generation-preparations")["temperature"]
    r = request("authoring_generation_prepare", p["request"])
    good = response("authoring_generation_receipt", p["receipt"])

    for changed <- [
          Map.put(good, "extra", "private"),
          Map.put(good, "api_version", 1.0),
          put_in(good, ["authoring_generation_receipt", "operation_id"], "other:operation"),
          put_in(
            good,
            ["authoring_generation_receipt", "revision"],
            p["receipt"]["revision"] + 1
          ),
          put_in(
            good,
            ["authoring_generation_receipt", "input_sha256"],
            String.duplicate("0", 64)
          ),
          put_in(
            good,
            ["authoring_generation_receipt", "provider_sha256"],
            String.duplicate("0", 64)
          ),
          put_in(
            good,
            ["authoring_generation_receipt", "policy_sha256"],
            String.duplicate("0", 64)
          )
        ] do
      assert {:error, :invalid_generation_response} =
               GenerationOperator.validate_response(r, changed)
    end

    a = fixture("generation-attempts")["temperature"]
    r = request("authoring_generation_start", a["request"])
    good = response("authoring_generation_attempt_receipt", a["receipt"])

    for changed <- [
          put_in(
            good,
            ["authoring_generation_attempt_receipt", "preparation_sha256"],
            String.duplicate("0", 64)
          ),
          put_in(good, ["authoring_generation_attempt_receipt", "attempt"], 2),
          Map.delete(good, "authoring_generation_attempt_receipt")
        ] do
      assert {:error, :invalid_generation_response} =
               GenerationOperator.validate_response(r, changed)
    end
  end

  test "preparation and attempt state are separate from immutable receipts" do
    p = fixture("generation-preparations")["temperature"]["receipt"]

    request = %{
      "operation" => "authoring_generation_status",
      "authority_epoch" => 1,
      "operation_id" => p["operation_id"]
    }

    status = %{"original" => p, "state" => "prepared", "cancellation_revision" => nil}

    assert :ok =
             GenerationOperator.validate_response(
               request,
               response("authoring_generation", status)
             )

    assert {:error, :invalid_generation_response} =
             GenerationOperator.validate_response(
               Map.put(request, "operation", "authoring_generation_cancel"),
               response("authoring_generation", status)
             )

    cancelled = %{status | "state" => "cancelled", "cancellation_revision" => p["revision"] + 1}

    assert :ok =
             GenerationOperator.validate_response(
               Map.put(request, "operation", "authoring_generation_cancel"),
               response("authoring_generation", cancelled)
             )

    for changed <- [
          %{status | "state" => "cancelled"},
          %{cancelled | "cancellation_revision" => p["revision"]},
          %{cancelled | "cancellation_revision" => 11.0},
          Map.put(status, "deadline", "private")
        ] do
      assert {:error, :invalid_generation_response} =
               GenerationOperator.validate_response(
                 request,
                 response("authoring_generation", changed)
               )
    end

    a = fixture("generation-attempts")["temperature"]["receipt"]

    request = %{
      request
      | "operation" => "authoring_generation_attempt_status",
        "operation_id" => a["operation_id"]
    }

    status = %{"original" => a, "result" => nil, "result_revision" => nil, "state" => "unknown"}

    assert :ok =
             GenerationOperator.validate_response(
               request,
               response("authoring_generation_attempt", status)
             )

    result = GenerationAttempt.failure("cancelled")

    settled = %{
      status
      | "result" => result,
        "result_revision" => a["revision"] + 1,
        "state" => "cancelled"
    }

    assert :ok =
             GenerationOperator.validate_response(
               request,
               response("authoring_generation_attempt", settled)
             )

    for changed <- [
          %{settled | "state" => "candidate"},
          %{settled | "result_revision" => a["revision"]},
          %{status | "state" => "candidate"},
          %{status | "result_revision" => 12}
        ] do
      assert {:error, :invalid_generation_response} =
               GenerationOperator.validate_response(
                 request,
                 response("authoring_generation_attempt", changed)
               )
    end
  end

  test "errors and missing originals are closed data and never interpreted as success" do
    r =
      request(
        "authoring_generation_start",
        fixture("generation-attempts")["temperature"]["request"]
      )

    assert :ok =
             GenerationOperator.validate_response(r, %{
               "api_version" => 1,
               "outcome" => "not_found"
             })

    assert :ok =
             GenerationOperator.validate_response(r, %{
               "api_version" => 1,
               "outcome" => "error",
               "reason" => "outcome_unknown"
             })

    for reason <- [nil, 1, "private\nsource", String.duplicate("a", 129), "/private/path"] do
      assert {:error, :invalid_generation_response} =
               GenerationOperator.validate_response(r, %{
                 "api_version" => 1,
                 "outcome" => "error",
                 "reason" => reason
               })
    end

    assert {:error, :invalid_generation_response} =
             GenerationOperator.validate_response(request("authoring_generation_options", nil), %{
               "api_version" => 1,
               "outcome" => "not_found"
             })
  end
end
