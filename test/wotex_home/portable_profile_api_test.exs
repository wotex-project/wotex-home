defmodule WotexHome.PortableProfileAPITest do
  use ExUnit.Case, async: true
  alias WotexHome.CLI
  alias WotexHome.LocalAPI.{Frame, Server}
  alias WotexHome.Profiles.{Artifact, Wire}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "woh-profile-cli-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    bytes = File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))

    %{
      directory: directory,
      bytes: bytes,
      credential: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }
  end

  test "import has one exact unpadded encoding and fits the maximum request frame", c do
    maximum = c.bytes <> String.duplicate(" ", 32_768 - byte_size(c.bytes))
    assert {:ok, _} = Artifact.parse(maximum)
    encoded = Base.url_encode64(maximum, padding: false)
    assert byte_size(encoded) == 43_691
    assert {:ok, ^maximum} = Wire.decode_import(encoded)

    request = %{
      "api_version" => 1,
      "operation" => "profile_import",
      "credential" => c.credential,
      "artifact_base64" => encoded
    }

    assert {:ok, <<size::32, body::binary>>} = Frame.encode_request(request)
    assert size < 65_536
    assert {:ok, ^request} = Frame.decode_request(body)

    for invalid <- [
          encoded <> "=",
          " " <> encoded,
          encoded <> "\n",
          "?",
          nil,
          1,
          "",
          Base.url_encode64(maximum <> " ", padding: false),
          "Zh"
        ] do
      assert {:error, :invalid_profile_import} = Wire.decode_import(invalid)
    end

    assert {:ok, "f"} = Wire.decode_import("Zg")
  end

  test "CLI sends exact bytes or closed operation fields, never source paths", c do
    file = private_file(c, c.bytes)
    assert {:ok, imported} = CLI.build_request(["profile-import", file], c.credential)
    assert {:ok, bytes} = Wire.decode_import(imported["artifact_base64"])
    assert bytes == c.bytes
    refute Map.has_key?(imported, "path")
    {:ok, artifact} = Artifact.parse(bytes)

    input = %{
      "action" => "approve",
      "authority_epoch" => 1,
      "operation_id" => "approval:cli",
      "expected_revision" => 5,
      "artifact_digest" => artifact.digest,
      "expected_trust_revision" => 0
    }

    File.write!(file, JSON.encode!(input))

    assert {:ok, %{"change" => ^input}} =
             CLI.build_request(["profile-change", file], c.credential)

    assert {:error, :invalid_profile_operation_file} =
             CLI.build_request(["profile-prepare", file], c.credential)

    File.write!(file, JSON.encode!(Map.put(input, "principal_id", "caller:fake")))

    assert {:error, :invalid_profile_operation_file} =
             CLI.build_request(["profile-change", file], c.credential)

    File.write!(file, "{\"action\":\"approve\",\"action\":\"approve\"}")

    assert {:error, :invalid_profile_operation_file} =
             CLI.build_request(["profile-change", file], c.credential)

    for {command, fields} <- [
          {["profiles"], %{}},
          {["profiles-collect"], %{}},
          {["profile-target", "thing:cli"], %{"thing_id" => "thing:cli"}},
          {["profile-operation-status", "1", "op:cli"],
           %{"authority_epoch" => 1, "operation_id" => "op:cli"}},
          {["profile-review-status", "review:cli"], %{"review_token" => "review:cli"}},
          {["profile-review-cancel", "review:cli"], %{"review_token" => "review:cli"}}
        ] do
      assert {:ok, request} = CLI.build_request(command, c.credential)
      assert Map.drop(request, ["api_version", "operation", "credential"]) == fields
    end
  end

  test "CLI refuses changed file custody, oversize and symlink inputs", c do
    file = private_file(c, c.bytes)
    link = Path.join(c.directory, "link")
    File.ln_s!(file, link)

    assert {:error, :invalid_profile_file} =
             CLI.build_request(["profile-import", link], c.credential)

    File.chmod!(file, 0o644)

    assert {:error, :invalid_profile_file} =
             CLI.build_request(["profile-import", file], c.credential)

    File.chmod!(file, 0o600)
    File.write!(file, String.duplicate(" ", 32_769))

    assert {:error, :invalid_profile_file} =
             CLI.build_request(["profile-import", file], c.credential)

    File.write!(file, String.duplicate(" ", 8_193))

    assert {:error, :invalid_profile_operation_file} =
             CLI.build_request(["profile-change", file], c.credential)
  end

  test "duplicate and deeply nested profile input is rejected before Authority" do
    authority = WotexHome.Authority.new(store: :unavailable)

    for {body, reason} <- [
          {"{\"operation\":\"profiles\",\"operation\":\"profiles\"}", "duplicate_member"},
          {"{\"change\":" <> String.duplicate("[", 17) <> "0" <> String.duplicate("]", 17) <> "}",
           "too_deep"}
        ] do
      assert {:ok, <<_::32, response::binary>>} =
               Server.route_frame(authority, <<byte_size(body)::32, body::binary>>)

      assert JSON.decode!(response)["reason"] == reason
    end
  end

  defp private_file(c, bytes) do
    file = Path.join(c.directory, "profile.json")
    File.write!(file, bytes)
    File.chmod!(file, 0o600)
    file
  end
end
