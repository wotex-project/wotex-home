defmodule WotexHome.PortableProfileLedgerCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{Artifact, Bindings, LedgerCodec, Operation}
  alias WotexHome.Durable.Registry

  setup do
    {:ok, artifact} =
      Artifact.parse(File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__)))

    %{artifact: artifact}
  end

  test "artifact rows retain raw identity separately from validated metadata", %{
    artifact: artifact
  } do
    row = %{
      "artifact_digest" => artifact.digest,
      "id" => artifact.data["id"],
      "version" => artifact.data["version"],
      "metadata_document" => JSON.encode!(artifact.data),
      "projection_document" => artifact.projection_document,
      "projection_digest" => artifact.projection_digest,
      "binding" => artifact.data["binding"],
      "registry_digest" => hd(artifact.data["dependencies"])["sha256"],
      "first_approval_revision" => 5
    }

    assert {:ok, document} = LedgerCodec.encode("artifact", row)
    assert {:ok, "artifact", ^row} = LedgerCodec.decode(document)
    refute Artifact.digest(row["metadata_document"]) == artifact.digest

    assert {:error, :invalid_profile_row} =
             LedgerCodec.encode(
               "artifact",
               Map.put(row, "projection_digest", String.duplicate("0", 64))
             )

    assert {:error, :invalid_profile_row} =
             LedgerCodec.encode("artifact", Map.put(row, "first_approval_revision", 0))

    # A changed installed registry must not reinterpret or erase old history.
    old_data =
      put_in(artifact.data, ["dependencies"], [
        %{"kind" => "registry", "sha256" => String.duplicate("b", 64)}
      ])

    {:ok, old_projection} = Bindings.historical_projection(old_data)

    old_row =
      Map.merge(row, %{
        "metadata_document" => JSON.encode!(old_data),
        "projection_document" => old_projection,
        "projection_digest" => Artifact.digest(old_projection),
        "registry_digest" => String.duplicate("b", 64)
      })

    assert {:ok, historical} = LedgerCodec.encode("artifact", old_row)
    assert {:ok, "artifact", ^old_row} = LedgerCodec.decode(historical)
    assert {:error, :unsupported_profile_binding} = Artifact.parse(old_row["metadata_document"])
  end

  test "operation receipts bind exact input and historical counts", %{artifact: artifact} do
    input = %{
      "action" => "approve",
      "authority_epoch" => 1,
      "operation_id" => "profile:1",
      "expected_revision" => 4,
      "artifact_digest" => artifact.digest,
      "expected_trust_revision" => 0
    }

    {:ok, input_document} = Operation.encode(input)

    row =
      Map.merge(
        Map.take(
          input,
          ~w(action authority_epoch operation_id expected_revision artifact_digest)
        ),
        %{
          "principal_id" => "profile-manager:1",
          "input_document" => input_document,
          "input_digest" => Artifact.digest(input_document),
          "final_revision" => 5,
          "changed_targets" => 0,
          "invalidated_requests" => 0,
          "unknown_outcomes" => 0,
          "previous_trust_revision" => 0,
          "trust_generation" => 1,
          "policy_generation" => 1
        }
      )

    assert {:ok, document} = LedgerCodec.encode("operation", row)
    assert {:ok, "operation", ^row} = LedgerCodec.decode(document)

    for {field, value} <- [
          {"artifact_digest", String.duplicate("0", 64)},
          {"unknown_outcomes", 1},
          {"final_revision", 4},
          {"input_digest", String.duplicate("1", 64)},
          {"changed_targets", 65}
        ] do
      assert {:error, :invalid_profile_row} =
               LedgerCodec.encode("operation", Map.put(row, field, value))
    end
  end

  test "selection and current rows have explicit generations and predecessor pins", %{
    artifact: artifact
  } do
    {:ok, thing} = Artifact.declaration(artifact, "light:test")
    {:ok, thing_document} = Registry.encode_thing(thing)

    row = %{
      "target_id" => "light:test",
      "generation" => 1,
      "principal_id" => "manager:1",
      "authority_epoch" => 1,
      "operation_id" => "profile:select:1",
      "previous_selection_revision" => 0,
      "previous_resource_revision" => 0,
      "previous_binding_revision" => 3,
      "artifact_digest" => artifact.digest,
      "projection_digest" => artifact.projection_digest,
      "trust_revision" => 5,
      "state" => "selected",
      "resource_revision" => 1,
      "binding_revision" => 7,
      "runtime_digest" => String.duplicate("c", 64),
      "review_document" => "host-owned-review",
      "thing_document" => thing_document,
      "revision" => 7
    }

    assert {:ok, encoded} = LedgerCodec.encode("selection", row)
    assert {:ok, "selection", ^row} = LedgerCodec.decode(encoded)

    assert {:error, :invalid_profile_row} =
             LedgerCodec.encode("selection", Map.put(row, "resource_revision", 0))

    assert {:error, :invalid_profile_row} =
             LedgerCodec.encode("selection", Map.put(row, "target_id", "light:other"))

    current = Map.take(row, ~w(target_id generation state)) |> Map.put("selection_revision", 7)
    assert {:ok, document} = LedgerCodec.encode("current", current)
    assert {:ok, "current", ^current} = LedgerCodec.decode(document)
  end

  test "owning-domain pins are closed, positive and canonical", %{artifact: artifact} do
    pin = %{
      "target_id" => "light:test",
      "owner_revision" => 8,
      "artifact_digest" => artifact.digest,
      "projection_digest" => artifact.projection_digest,
      "selection_revision" => 7,
      "selection_generation" => 1,
      "trust_revision" => 5,
      "resource_revision" => 1
    }

    assert {:ok, document} = LedgerCodec.encode("pin", pin)
    assert {:ok, "pin", ^pin} = LedgerCodec.decode(document)

    assert {:error, :invalid_profile_row} =
             LedgerCodec.encode("pin", Map.put(pin, "owner_revision", 0))

    assert {:error, :invalid_profile_row} =
             LedgerCodec.encode("pin", Map.put(pin, "module", "arbitrary"))

    for document <- [" " <> document, document <> "[]", "[]", <<255>>] do
      assert {:error, :invalid_profile_row} = LedgerCodec.decode(document)
    end
  end
end
