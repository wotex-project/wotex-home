defmodule WotexHome.CLIEnrollmentRequestTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.CLI

  @credential String.duplicate("A", 43)
  @args [
    "capture:1",
    "candidate:1",
    "lifx.product-27:1.0.0",
    "light:bedroom",
    "review:1"
  ]

  test "enrollment and re-review CLI commands carry references only" do
    for {command, operation} <- [
          {"lifx-enroll", "lifx_enroll"},
          {"lifx-rereview", "lifx_rereview"}
        ] do
      assert {:ok,
              %{
                "api_version" => 1,
                "operation" => ^operation,
                "credential" => @credential,
                "session_ref" => "capture:1",
                "candidate_ref" => "candidate:1",
                "profile_ref" => "lifx.product-27:1.0.0",
                "thing_id" => "light:bedroom",
                "review_ref" => "review:1"
              } = request} = CLI.build_request([command | @args], @credential)

      assert map_size(request) == 8
    end
  end

  test "malformed or caller-expanded enrollment commands fail before socket use" do
    assert {:error, :usage} =
             CLI.build_request(
               ["lifx-enroll", "capture:1", "candidate:1", "profile:1", "bad thing", "review:1"],
               @credential
             )

    assert {:error, :usage} =
             CLI.build_request(["lifx-enroll" | @args ++ ["caller-body"]], @credential)
  end

  test "refresh accepts only one Home Thing reference" do
    assert {:ok,
            %{
              "api_version" => 1,
              "operation" => "lifx_refresh",
              "credential" => @credential,
              "thing_id" => "light:bedroom"
            } = request} = CLI.build_request(["lifx-refresh", "light:bedroom"], @credential)

    assert map_size(request) == 4

    assert {:error, :usage} =
             CLI.build_request(
               ["lifx-refresh", "light:bedroom", "192.168.1.10:56700"],
               @credential
             )
  end
end
