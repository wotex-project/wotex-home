defmodule WotexHome.ControllerPairingReviewCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.ControllerConnections.ReviewCodec
  @fixture Path.expand("../fixtures/controller_connections/review_vectors.json", __DIR__)
  @corpus JSON.decode!(File.read!(@fixture))

  for vector <- @corpus["valid"] do
    test "independent #{vector["kind"]} #{vector["name"]}" do
      vector = unquote(Macro.escape(vector))
      assert {:ok, value} = ReviewCodec.decode(vector["kind"], vector["wire"])
      assert value == vector["value"]
      assert ReviewCodec.encode(vector["kind"], value) == {:ok, vector["wire"]}

      if vector["kind"] == "approval" do
        assert ReviewCodec.digest(value) == {:ok, vector["sha256"]}
      else
        assert ReviewCodec.scope?(value)
      end
    end
  end

  for {vector, index} <- Enum.with_index(@corpus["invalid"]) do
    test "independent refusal #{index} #{vector["kind"]} #{vector["name"]}" do
      vector = unquote(Macro.escape(vector))

      assert ReviewCodec.decode(vector["kind"], vector["wire"]) ==
               {:error, :invalid_controller_pairing_review}
    end
  end

  test "encoder accepts only exact proper secret-free records" do
    for kind <- ~w(scope approval), value <- [nil, true, [], %{}, "scope", %URI{}] do
      assert ReviewCodec.encode(kind, value) == {:error, :invalid_controller_pairing_review}
    end

    for vector <- @corpus["valid"], {field, _} <- vector["value"] do
      assert ReviewCodec.encode(vector["kind"], Map.put(vector["value"], field, nil)) ==
               {:error, :invalid_controller_pairing_review}
    end

    value = Enum.find(@corpus["valid"], &(&1["name"] == "default_read"))["value"]

    for field <- ~w(bootstrap_secret credential verifier role) do
      assert ReviewCodec.encode("approval", Map.put(value, field, "private")) ==
               {:error, :invalid_controller_pairing_review}
    end

    for {field, term} <- [
          {"permissions", ["read" | :bad]},
          {"target_ids", ["light:one" | :bad]},
          {"client_label", <<255>>}
        ] do
      assert ReviewCodec.encode("approval", Map.put(value, field, term)) ==
               {:error, :invalid_controller_pairing_review}
    end

    for body <- [nil, <<255>>, String.duplicate("[", 8_192)] do
      assert ReviewCodec.decode("approval", body) == {:error, :invalid_controller_pairing_review}
    end

    refute ReviewCodec.scope?(value)

    assert ReviewCodec.decode("unknown", @corpus["valid"] |> hd() |> Map.fetch!("wire")) ==
             {:error, :invalid_controller_pairing_review}
  end

  test "the approval digest covers every original, scope and access field" do
    original = Enum.find(@corpus["valid"], &(&1["name"] == "default_read"))["value"]
    {:ok, digest} = ReviewCodec.digest(original)

    for {field, changed} <- [
          {"controller_id", String.duplicate("f", 64)},
          {"invitation_id", String.duplicate("f", 64)},
          {"client_id", String.duplicate("f", 64)},
          {"request_id", String.duplicate("f", 64)},
          {"request_digest", String.duplicate("f", 64)},
          {"client_label", "other"},
          {"store_boot", "boot:" <> String.duplicate("f", 32)},
          {"deployment_id", String.duplicate("f", 64)},
          {"owner_id", String.duplicate("f", 64)},
          {"authority_epoch", 2},
          {"expected_revision", 1},
          {"permissions", ["enroll:review"]},
          {"target_ids", ["light:one"]}
        ] do
      assert {:ok, different} = ReviewCodec.digest(Map.put(original, field, changed))
      refute different == digest
    end
  end
end
