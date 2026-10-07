Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))

defmodule WotexHome.PortableProfileReviewTest do
  use ExUnit.Case, async: true

  alias WotexHome.Durable.Registry
  alias WotexHome.Profiles.{Artifact, Review}

  setup do
    WotexHome.Test.PortableProfileFixture.context()
  end

  test "the proposal binds exact bytes, pins, runtime and unqualified declaration", c do
    assert {:ok, review} = review(c)
    assert review.enrollment.operator_id == c.basis["principal_id"]
    assert review.enrollment.method == "legacy_tofu"
    assert review.thing.profile_ref == c.artifact.profile_ref
    assert review.digest == Artifact.digest(review.document)

    assert ["wotex-home.profile-selection-review.v1", _, pins, runtime, identity, document] =
             JSON.decode!(review.document)

    assert length(pins) == map_size(c.basis) and runtime == c.runtime
    assert identity == review.enrollment.identity_digest
    assert {:ok, review.thing} == Registry.decode_thing(document)
    assert review.summary.status == :pending_authenticated_selection
    assert review.summary.qualification_status == :pending_physical_evidence
    refute review.summary.new_control_grants
    assert {:ok, ^review} = review(c)
  end

  test "historical review decoding retains exact pins without capture bytes or current runtime",
       c do
    {:ok, review} = review(c)
    row = artifact_row(c)
    assert {:ok, historical} = Review.decode_history(review.document, row)
    assert historical.basis == c.basis
    assert historical.input == c.input
    assert historical.identity_digest == review.enrollment.identity_digest
    assert historical.thing == review.thing
    assert historical.runtime_digest == c.runtime
    refute Map.has_key?(historical, :capture_deadline)
    refute Map.has_key?(historical, :candidates)

    assert {:error, :invalid_profile_review_history} =
             Review.decode_history(review.document <> " ", row)

    assert {:error, :invalid_profile_review_history} =
             Review.decode_history(String.duplicate("x", 65_537), row)
  end

  test "historical declaration checks do not substitute a different digest projection or identity",
       c do
    {:ok, review} = review(c)
    row = artifact_row(c)

    for key <- ~w(artifact_digest projection_digest registry_digest) do
      assert {:error, :invalid_profile_review_history} =
               Review.decode_history(
                 review.document,
                 Map.put(row, key, String.duplicate("f", 64))
               )
    end

    decoded = JSON.decode!(review.document)

    for {index, replacement} <- [
          {1, review.input_document <> " "},
          {2, tl(Enum.at(decoded, 2))},
          {3, "runtime:not-digest"},
          {4, String.duplicate("f", 64)},
          {5, c.basis["current_thing_document"]}
        ] do
      assert {:error, :invalid_profile_review_history} =
               Review.decode_history(
                 JSON.encode!(List.replace_at(decoded, index, replacement)),
                 row
               )
    end

    assert {:error, :invalid_profile_review_history} =
             Review.decode_history(review.document, Map.put(row, "actor", "invented:fixture"))
  end

  test "historical decode repeats the no-widening check and original enrollment commitment", c do
    {:ok, review} = review(c)
    decoded = JSON.decode!(review.document)
    values = Enum.at(decoded, 2)

    tighter = %{
      c.current
      | capabilities: %{"power" => %{c.current.capabilities["power"] | operations: ["read"]}}
    }

    {:ok, document} = Registry.encode_thing(tighter)
    values = List.replace_at(values, length(values) - 1, document)
    tampered = JSON.encode!(List.replace_at(decoded, 2, values))

    assert {:error, :invalid_profile_review_history} =
             Review.decode_history(tampered, artifact_row(c))

    changed_input = Map.put(c.input, "operation_id", "profile:other")
    {:ok, input_document} = WotexHome.Profiles.Operation.encode(changed_input)
    # Operation identity is retained independently of the enrollment identity.
    assert {:ok, historical} =
             Review.decode_history(
               JSON.encode!(List.replace_at(decoded, 1, input_document)),
               artifact_row(c)
             )

    assert historical.input["operation_id"] == "profile:other"
    assert historical.identity_digest == review.enrollment.identity_digest
  end

  test "v2 initial review keeps absent prior identity separate from host-captured identity", c do
    basis =
      c.basis
      |> Map.merge(%{
        "resource_revision" => 0,
        "binding_revision" => 0,
        "selection_revision" => 0,
        "selection_generation" => 0,
        "current_thing_document" => nil,
        "stable_id" => nil,
        "manufacturer" => nil,
        "model" => nil,
        "firmware" => nil
      })

    c = %{c | basis: basis, input: Map.put(c.input, "expected_binding_revision", 0)}
    assert {:ok, review} = review(c)

    assert ["wotex-home.profile-selection-review.v2", "initial", _, pins, _, captured, _, _] =
             JSON.decode!(review.document)

    assert List.last(pins) == nil
    assert captured == ["lifx:d073d5000001", "lifx.vendor.1", "lifx.product.22", "1.22"]
    assert review.summary.current_profile_ref == nil
    assert hd(review.summary.capabilities).previous_operations == []
    refute review.summary.new_control_grants
    assert Review.valid?(review)
    assert {:ok, historical} = Review.decode_history(review.document, artifact_row(c))
    assert historical.mode == :initial and historical.version == 2
    assert historical.current_thing == nil
    assert historical.basis["stable_id"] == nil
    assert historical.captured_identity["stable_id"] == "lifx:d073d5000001"

    for change <- [
          %{"binding_revision" => 2},
          %{"stable_id" => "lifx:d073d5000001"},
          %{"resource_revision" => 1}
        ] do
      assert {:error, :invalid_profile_review_basis} =
               review(%{c | basis: Map.merge(basis, change)})
    end

    decoded = JSON.decode!(review.document)

    assert {:error, :invalid_profile_review_history} =
             Review.decode_history(
               JSON.encode!(List.replace_at(decoded, 1, "replacement")),
               artifact_row(c)
             )

    assert {:error, :invalid_profile_review_history} =
             Review.decode_history(
               JSON.encode!(List.replace_at(decoded, 5, captured ++ ["invented"])),
               artifact_row(c)
             )
  end

  test "v2 replacement binds fresh firmware without rewriting the prior reviewed tuple", c do
    data = put_in(c.artifact.data, ["fingerprint", "firmware_versions"], ["1.23"])
    {:ok, artifact} = Artifact.parse(JSON.encode!(data))

    c = %{
      c
      | artifact: artifact,
        basis:
          Map.merge(c.basis, %{
            "artifact_digest" => artifact.digest,
            "projection_digest" => artifact.projection_digest
          }),
        input: Map.put(c.input, "artifact_digest", artifact.digest),
        evidence: %{c.evidence | interview: %{c.evidence.interview | firmware: "1.23"}}
    }

    assert {:ok, review} = review(c)

    assert ["wotex-home.profile-selection-review.v2", "replacement", _, _, _, captured, _, _] =
             JSON.decode!(review.document)

    assert List.last(captured) == "1.23"
    assert review.basis["firmware"] == "1.22"
    assert Review.valid?(review)
    assert {:ok, historical} = Review.decode_history(review.document, artifact_row(c))
    assert historical.mode == :replacement and historical.basis["firmware"] == "1.22"
    assert historical.captured_identity["firmware"] == "1.23"
    assert historical.identity_digest == review.enrollment.identity_digest
    decoded = JSON.decode!(review.document)

    for changed <- [
          List.replace_at(captured, 0, "lifx:d073d5000002"),
          List.replace_at(captured, 3, "1.24")
        ] do
      assert {:error, :invalid_profile_review_history} =
               Review.decode_history(
                 JSON.encode!(List.replace_at(decoded, 5, changed)),
                 artifact_row(c)
               )
    end
  end

  defp artifact_row(c),
    do: %{
      "artifact_digest" => c.artifact.digest,
      "id" => c.artifact.data["id"],
      "version" => c.artifact.data["version"],
      "metadata_document" => JSON.encode!(c.artifact.data),
      "projection_document" => c.artifact.projection_document,
      "projection_digest" => c.artifact.projection_digest,
      "binding" => c.artifact.data["binding"],
      "registry_digest" => hd(c.artifact.data["dependencies"])["sha256"],
      "first_approval_revision" => 9
    }

  test "every caller CAS pin remains exact and cannot be silently refreshed", c do
    for key <-
          ~w(authority_epoch expected_revision expected_trust_revision expected_resource_revision expected_binding_revision expected_selection_generation expected_policy_generation expected_rule_generation) do
      assert {:error, :stale_profile_review_basis} =
               review(%{c | input: Map.update!(c.input, key, &(&1 + 1))})
    end

    assert {:error, :invalid_profile_review_basis} =
             review(%{c | basis: Map.put(c.basis, "caller_permission", "control:ordinary")})
  end

  test "another raw serialization, registry or projection cannot replace the approved digest",
       c do
    {:ok, changed} = Artifact.parse(c.artifact.bytes <> " ")
    assert changed.projection_digest == c.artifact.projection_digest
    assert {:error, :profile_review_mismatch} = review(%{c | artifact: changed})

    for key <- ~w(projection_digest registry_digest) do
      assert {:error, :profile_review_mismatch} =
               review(%{c | basis: Map.put(c.basis, key, String.duplicate("0", 64))})
    end
  end

  test "capture identity, firmware, selected reference and session cannot change", c do
    for key <- [:stable_id, :manufacturer, :model, :firmware, :candidate_ref] do
      evidence =
        Map.put(c.evidence, :interview, Map.put(c.evidence.interview, key, "changed:fixture"))

      assert {:error, :profile_capture_mismatch} = review(%{c | evidence: evidence})
    end

    assert {:error, :profile_capture_mismatch} =
             review(%{c | evidence: %{c.evidence | ref: "session:other"}})
  end

  test "a matching second candidate's conflicting stable identity stays unresolved", c do
    candidate = %{
      hd(c.evidence.candidates)
      | raw_ref: "capture:other",
        source_endpoint: "192.0.2.11:56700"
    }

    assert {:error, :claimed_identity_collision} =
             review(%{
               c
               | evidence: %{c.evidence | candidates: [hd(c.evidence.candidates), candidate]}
             })
  end

  test "a read-only or tighter previous declaration cannot inherit write or wider freshness", c do
    for power <- [
          %{c.current.capabilities["power"] | operations: ["read"]},
          %{c.current.capabilities["power"] | freshness_ms: 1_000}
        ] do
      current = %{c.current | capabilities: %{"power" => power}}
      {:ok, document} = Registry.encode_thing(current)

      assert {:error, :declaration_widening} =
               review(%{c | basis: Map.put(c.basis, "current_thing_document", document)})
    end
  end

  test "profile changes can only retain or remove already executable semantics", c do
    {:ok, next} = Artifact.declaration(c.artifact, c.current.id)
    assert :ok = Review.no_widening(c.current, next)
    power = %{next.capabilities["power"] | operations: ["read"], freshness_ms: 1_000}
    narrower = %{next | capabilities: %{"power" => power}}
    assert :ok = Review.no_widening(c.current, narrower)
    assert {:error, :declaration_widening} = Review.no_widening(narrower, next)

    assert {:error, :declaration_widening} =
             Review.no_widening(%{c.current | id: "light:other"}, next)
  end

  defp review(c), do: Review.new(c.basis, c.artifact, c.evidence, c.input, c.runtime)
end
