defmodule WotexHome.ControllerPairingCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.ControllerConnections.Codec
  @fixture Path.expand("../fixtures/controller_connections/wire_vectors.json", __DIR__)
  @corpus JSON.decode!(File.read!(@fixture))

  for vector <- @corpus["valid"] do
    test "independent valid #{vector["name"]}" do
      vector = unquote(Macro.escape(vector))
      assert {:ok, value} = Codec.decode(vector["kind"], vector["wire"])
      assert value == vector["value"]
      assert {:ok, encoded} = Codec.encode(vector["kind"], value)
      assert encoded == vector["wire"]
      assert byte_size(encoded) <= Codec.maximum_bytes()
      frame = Base.decode16!(vector["frame_hex"], case: :lower)
      assert Codec.encode_frame(vector["kind"], value) == {:ok, frame}
      assert Codec.decode_frame(vector["kind"], frame) == {:ok, value}

      for changed <- [binary_part(frame, 0, byte_size(frame) - 1), frame <> <<0>>] do
        assert {:error, :invalid_controller_connection_record} =
                 Codec.decode_frame(vector["kind"], changed)
      end

      assert {:error, :invalid_controller_connection_record} =
               Codec.encode(vector["kind"], Map.put(value, "role", "operator"))
    end
  end

  for header <- @corpus["headers"] do
    test "frame header #{header["hex"]}" do
      header = unquote(Macro.escape(header))
      bytes = Base.decode16!(header["hex"], case: :lower)

      expected =
        if header["size"],
          do: {:ok, header["size"]},
          else: {:error, :invalid_controller_connection_record}

      assert Codec.frame_size(bytes) == expected
    end
  end

  for vector <- @corpus["invalid"] do
    test "independent refusal #{vector["name"]}" do
      vector = unquote(Macro.escape(vector))

      assert {:error, :invalid_controller_connection_record} =
               Codec.decode(vector["kind"], vector["wire"])
    end
  end

  for vector <- @corpus["correspondence"] do
    test "exact original and approval #{vector["name"]}" do
      vector = unquote(Macro.escape(vector))
      request = Enum.find(@corpus["valid"], &(&1["name"] == vector["request"]))
      response = Enum.find(@corpus["valid"], &(&1["name"] == vector["response"]))
      assert {:ok, original} = Codec.decode("request", request["wire"])

      result = Codec.verify_response(response["wire"], original, vector["approved_access"])

      if vector["accepted"],
        do: assert(result == {:ok, response["value"]}),
        else: assert(result == {:error, :invalid_controller_connection_record})
    end
  end

  test "the complete original digest includes label and secret, not just client identity" do
    request = Enum.find(@corpus["valid"], &(&1["name"] == "request_unicode"))
    assert {:ok, original} = Codec.decode("request", request["wire"])
    assert {:ok, digest} = Codec.request_digest(original)
    assert digest == @corpus["request_digest"]

    for {field, changed} <- [
          {"controller_id", String.duplicate("f", 64)},
          {"invitation_id", String.duplicate("f", 64)},
          {"client_id", String.duplicate("f", 64)},
          {"request_id", String.duplicate("f", 64)},
          {"client_label", "other"},
          {"bootstrap_secret", Base.url_encode64(:binary.copy(<<255>>, 32), padding: false)}
        ] do
      assert {:ok, different} = Codec.request_digest(Map.put(original, field, changed))
      refute different == digest
    end
  end

  test "malformed encoder terms, raw target declarations and access coercions fail closed" do
    for kind <- ~w(invitation request paired refused), value <- [nil, true, [], %{}, "record"] do
      assert {:error, :invalid_controller_connection_record} = Codec.encode(kind, value)
    end

    for vector <- @corpus["valid"], {field, _} <- vector["value"] do
      assert {:error, :invalid_controller_connection_record} =
               Codec.encode(vector["kind"], Map.put(vector["value"], field, nil))
    end

    request = Enum.find(@corpus["valid"], &(&1["name"] == "request_unicode"))["value"]

    for field <- ~w(role permissions target_ids declaration authority_epoch credential) do
      assert {:error, :invalid_controller_connection_record} =
               Codec.encode("request", Map.put(request, field, ["control:ordinary"]))
    end

    assert Codec.default_access() == %{"permissions" => ["read"], "target_ids" => []}
    assert Codec.access?(Codec.default_access())

    for access <- [
          nil,
          [],
          %{},
          %{"permissions" => ["read" | :bad], "target_ids" => []},
          %{"permissions" => ["read"], "target_ids" => ["light:one" | :bad]}
        ] do
      refute Codec.access?(access)
    end

    for body <- [<<255>>, "", nil, String.duplicate("[", 8_192)] do
      assert {:error, :invalid_controller_connection_record} = Codec.decode("invitation", body)
    end
  end

  test "syntactic decoding alone does not grant approval or qualify certificate bytes" do
    vector = Enum.find(@corpus["valid"], &(&1["name"] == "paired_approved_control"))
    assert {:ok, scoped} = Codec.decode("response", vector["wire"])
    assert scoped["permissions"] == ~w(control:ordinary read rule:manage rule:review)
    request = Enum.find(@corpus["valid"], &(&1["name"] == "request_unicode"))["value"]

    assert {:error, :invalid_controller_connection_record} =
             Codec.verify_response(vector["wire"], request)

    anchor = Enum.find(@corpus["valid"], &(&1["name"] == "invitation_maximum_anchor_name"))
    assert {:ok, value} = Codec.decode("invitation", anchor["wire"])
    assert {:ok, bytes} = Base.url_decode64(value["trust_anchor"], padding: false)
    assert bytes == :binary.copy(<<0>>, 4_096)
  end
end
