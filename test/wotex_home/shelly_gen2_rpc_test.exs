defmodule WotexHome.ShellyGen2RPCTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Shelly.Gen2RPC

  @device_id "shellypro4pm-f008d1d8b8b8"

  test "only read-only full frames can be built" do
    assert {:ok, identity} = Gen2RPC.request(:device_info, 7)
    assert JSON.decode!(identity) == %{"id" => 7, "method" => "Shelly.GetDeviceInfo"}

    assert {:ok, status} = Gen2RPC.request({:switch_status, 2}, 8)

    assert JSON.decode!(status) == %{
             "id" => 8,
             "method" => "Switch.GetStatus",
             "params" => %{"id" => 2}
           }

    assert {:error, :invalid_rpc_request} = Gen2RPC.request({:switch_status, 16}, 8)
    assert {:error, :invalid_rpc_request} = Gen2RPC.request({:switch_set, 0, true}, 8)
    assert {:error, :invalid_rpc_request} = Gen2RPC.request(:device_info, 0)
  end

  test "identity and switch status remain correlated, untrusted reports" do
    info = %{
      "id" => 7,
      "src" => @device_id,
      "result" => %{
        "id" => @device_id,
        "mac" => "F008D1D8B8B8",
        "model" => "SPSW-004PE16EU",
        "gen" => 2,
        "fw_id" => "20210720-153353/0.6.7-gc36674b",
        "ver" => "0.6.7",
        "auth_en" => true
      }
    }

    assert {:ok,
            %{
              device_id: @device_id,
              model: "SPSW-004PE16EU",
              generation: 2,
              firmware_version: "0.6.7",
              authentication_enabled: true,
              trust: :unauthenticated_local
            }} = Gen2RPC.response(JSON.encode!(info), 7, :device_info)

    assert {:error, :rpc_correlation_failed} =
             Gen2RPC.response(JSON.encode!(info), 8, :device_info)

    assert {:error, :invalid_device_identity} =
             Gen2RPC.response(
               JSON.encode!(put_in(info, ["result", "gen"], 1)),
               7,
               :device_info
             )

    assert {:error, :invalid_device_identity} =
             Gen2RPC.response(
               JSON.encode!(put_in(info, ["result", "id"], "another-device")),
               7,
               :device_info
             )

    switch = %{
      "id" => 8,
      "src" => @device_id,
      "result" => %{
        "id" => 2,
        "source" => "WS_in",
        "output" => false,
        "apower" => 0.0
      }
    }

    assert {:ok,
            %{device_id: @device_id, switch_id: 2, output: false, trust: :unauthenticated_local}} =
             Gen2RPC.response(JSON.encode!(switch), 8, {:switch_status, 2})

    assert {:error, :invalid_switch_status} =
             Gen2RPC.response(JSON.encode!(switch), 8, {:switch_status, 1})

    assert {:error, :device_status_error} =
             Gen2RPC.response(
               JSON.encode!(put_in(switch, ["result", "errors"], ["overpower"])),
               8,
               {:switch_status, 2}
             )
  end

  test "malformed, duplicate and error frames fail closed" do
    assert {:error, :invalid_rpc_response} =
             Gen2RPC.response(
               ~s({"id":7,"src":"#{@device_id}","result":{},"extra":1}),
               7,
               :device_info
             )

    assert {:error, :invalid_rpc_response} =
             Gen2RPC.response(
               ~s({"id":7,"id":7,"src":"#{@device_id}","result":{}}),
               7,
               :device_info
             )

    assert {:error, :device_error} =
             Gen2RPC.response(
               JSON.encode!(%{"id" => 7, "src" => @device_id, "error" => %{"code" => -103}}),
               7,
               :device_info
             )

    assert {:error, :invalid_rpc_response} =
             Gen2RPC.response(:binary.copy("x", 32_769), 7, :device_info)
  end
end
