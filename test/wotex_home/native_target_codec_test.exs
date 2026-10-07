defmodule WotexHome.NativeTargetCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.NativeSetup.TargetCodec
  @deployment String.duplicate("a", 64)
  @owner String.duplicate("b", 64)
  @verifier String.duplicate("c", 64)
  @artifact String.duplicate("d", 64)
  @grant "[\"wotex-home.native-target-access.v1\",\"grant\",\"#{@deployment}\",\"#{@owner}\",7,3,\"#{@verifier}\",\"access:one\",9,\"light:one\",4,5,2,\"#{@artifact}\"]"
  @revoke "[\"wotex-home.native-target-access.v1\",\"revoke\",\"#{@deployment}\",\"#{@owner}\",7,3,\"#{@verifier}\",\"access:two\",11,\"light:one\"]"
  @status "[\"wotex-home.native-target-access.v1\",\"status\",\"#{@deployment}\",\"#{@owner}\",7,3,\"#{@verifier}\",\"access:one\"]"

  test "independent closed grant, revoke and original status vectors" do
    for {kind, bytes} <- [
          {"grant", @grant},
          {"revoke", @revoke},
          {"status", @status},
          {"not_found", String.replace(@status, "\"status\"", "\"not_found\"")}
        ] do
      assert {:ok, input} = TargetCodec.decode(kind, bytes)
      assert {:ok, ^bytes} = TargetCodec.encode(kind, input)
      assert input["authority_epoch"] == 7
      assert input["creation_revision"] == 3
      assert input["verifier"] == @verifier

      assert {:error, :invalid_native_target_record} =
               TargetCodec.encode(kind, Map.put(input, "role", "diagnostic"))

      assert {:error, :invalid_native_target_record} = TargetCodec.decode("ensure", bytes)
    end
  end

  test "each original grant field binds the immutable input digest" do
    assert {:ok, input} = TargetCodec.decode("grant", @grant)
    assert {:ok, digest} = TargetCodec.digest("grant", input)
    assert digest == Base.encode16(:crypto.hash(:sha256, @grant), case: :lower)
    assert digest == "3cb0cc8dd8705ee7d071c5677ada5c1bd63e71880dfbc9f764e0f027747cebc2"

    for {field, value} <- input do
      changed =
        if is_integer(value),
          do: value + 1,
          else:
            if(field in ["deployment_id", "owner_id", "verifier", "artifact_digest"],
              do: String.duplicate("e", 64),
              else: value <> "x"
            )

      assert {:ok, other} = TargetCodec.digest("grant", Map.put(input, field, changed))
      refute other == digest
    end

    assert {:error, :invalid_native_target_record} = TargetCodec.digest("ensure", input)
  end

  test "bounded scanner and canonical encoding refuse coercions and arbitrary replay" do
    for bytes <- [
          String.replace(@grant, ",7,", ",7.0,"),
          String.replace(@grant, ",7,", ",true,"),
          String.replace(@grant, ",7,", ",0,"),
          String.replace(@grant, ",7,", ",07,"),
          String.replace(@grant, ",7,", ",1e1,"),
          String.replace(@grant, ",7,", ",9223372036854775808,"),
          String.replace(@grant, @verifier, String.upcase(@verifier)),
          String.replace(@grant, ",4,5,2,", ",0,5,2,"),
          String.replace(@grant, "light:one", "light/one"),
          String.replace(@grant, "access:one", String.duplicate("x", 129)),
          " " <> @grant,
          @grant <> "\n",
          @grant <> "[]",
          "[" <> @grant <> "]",
          "{\"a\":1,\"a\":2}",
          String.duplicate("[", 1_000) <> "0" <> String.duplicate("]", 1_000),
          "[\"wotex-home.native-target-access.v1\",\"grant\",null]",
          String.duplicate(" ", 4_097),
          <<255>>,
          "[" <> Enum.map_join(1..17, ",", fn _ -> "0" end) <> "]"
        ] do
      assert {:error, :invalid_native_target_record} = TargetCodec.decode("grant", bytes)
    end

    assert {:ok, input} = TargetCodec.decode("grant", @grant)

    for field <-
          ~w(authority_epoch creation_revision expected_revision resource_revision binding_revision selection_generation),
        value <- [false, nil, 1.0, -1, 0, 9_223_372_036_854_775_808] do
      assert {:error, :invalid_native_target_record} =
               TargetCodec.encode("grant", Map.put(input, field, value))
    end

    for changed <- [
          Map.put(input, "creation_revision", 10),
          Map.put(input, "expected_revision", 9_223_372_036_854_775_807)
        ] do
      assert {:error, :invalid_native_target_record} = TargetCodec.encode("grant", changed)
    end
  end

  test "receipt links fixed native operator and original revision arithmetic" do
    bytes =
      "[\"wotex-home.native-target-access.v1\",\"receipt\",\"#{@deployment}\",\"#{@owner}\",7,\"native-setup-v1:7:operator\",\"access:one\",\"grant\",\"light:one\",\"#{@artifact}\",9,10,12,2,1]"

    assert {:ok, receipt} = TargetCodec.decode("receipt", bytes)
    assert {:ok, ^bytes} = TargetCodec.encode("receipt", receipt)

    for {field, invalid} <- [
          {"principal_id", "native-setup-v1:7:diagnostic"},
          {"authority_epoch", 8},
          {"action", "rotate"},
          {"change_revision", 11},
          {"final_revision", 13},
          {"affected_requests", 1_025},
          {"unknown_outcomes", 3},
          {"expected_revision", 9_223_372_036_854_775_807}
        ] do
      assert {:error, :invalid_native_target_record} =
               TargetCodec.encode("receipt", Map.put(receipt, field, invalid))
    end

    assert {:ok, encoded} =
             TargetCodec.encode("error", %{"reason" => "native_operation_conflict"})

    assert {:ok, %{"reason" => "native_operation_conflict"}} =
             TargetCodec.decode("error", encoded)

    assert {:error, :invalid_native_target_record} =
             TargetCodec.encode("error", %{"reason" => "secret"})
  end
end
