defmodule WotexHome.ShellyGen2ReadPathTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Lifx.IPv4Scope
  alias WotexHome.Shelly.Gen2ReadPath

  @device_id "shellypro4pm-f008d1d8b8b8"

  test "one selected-address HTTP read checks the full independent response" do
    result = %{
      "id" => @device_id,
      "model" => "SPSW-004PE16EU",
      "gen" => 2,
      "fw_id" => "20210720-153353/0.6.7-gc36674b",
      "ver" => "0.6.7",
      "auth_en" => false
    }

    response = JSON.encode!(%{"id" => 31, "src" => @device_id, "result" => result})
    {port, task} = peer(200, response)
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 8)

    assert {:ok,
            %{
              device_id: @device_id,
              model: "SPSW-004PE16EU",
              firmware_version: "0.6.7",
              trust: :unauthenticated_local
            }} = Gen2ReadPath.run(scope, {127, 0, 0, 1}, port, :device_info, 31)

    assert {:ok, %{"id" => 31, "method" => "Shelly.GetDeviceInfo"}} = Task.await(task)
  end

  test "authentication, redirect and out-of-scope endpoints fail closed" do
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 8)

    {port, task} = peer(401, ~s({"error":"authentication required"}))

    assert {:error, :authentication_required} =
             Gen2ReadPath.run(scope, {127, 0, 0, 1}, port, :device_info, 32)

    assert {:ok, %{"method" => "Shelly.GetDeviceInfo"}} = Task.await(task)

    {port, task} = peer(302, "")

    assert {:error, :unexpected_http_status} =
             Gen2ReadPath.run(scope, {127, 0, 0, 1}, port, :device_info, 33)

    assert {:ok, %{"method" => "Shelly.GetDeviceInfo"}} = Task.await(task)

    assert {:error, :invalid_read_target} =
             Gen2ReadPath.run(scope, {192, 168, 1, 10}, port, :device_info, 33)

    {port, task} = peer(200, :binary.copy("x", 32_769))

    assert {:error, :response_too_large} =
             Gen2ReadPath.run(scope, {127, 0, 0, 1}, port, :device_info, 34)

    assert {:ok, %{"method" => "Shelly.GetDeviceInfo"}} = Task.await(task)
  end

  defp peer(status, response_body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)

          try do
            {:ok, request} = receive_request(socket, "")
            [head, body] = String.split(request, "\r\n\r\n", parts: 2)
            assert String.starts_with?(head, "POST /rpc HTTP/1.1\r\n")
            assert String.contains?(String.downcase(head), "content-type: application/json")

            reason =
              case status do
                200 -> "OK"
                302 -> "Found"
                401 -> "Unauthorized"
              end

            header =
              "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(response_body)}\r\nconnection: close\r\n\r\n"

            :ok = :gen_tcp.send(socket, header)

            if response_body != "" do
              middle = div(byte_size(response_body), 2)
              <<first::binary-size(middle), second::binary>> = response_body
              :ok = :gen_tcp.send(socket, first)
              :ok = :gen_tcp.send(socket, second)
            end

            {:ok, JSON.decode!(body)}
          after
            :gen_tcp.close(socket)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    {port, task}
  end

  defp receive_request(socket, bytes) when byte_size(bytes) <= 4_096 do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [head, body] ->
        case Regex.run(~r/content-length: (\d+)/i, head) do
          [_, length] ->
            if byte_size(body) >= String.to_integer(length),
              do: {:ok, bytes},
              else: receive_more(socket, bytes)

          _ ->
            receive_more(socket, bytes)
        end

      _ ->
        receive_more(socket, bytes)
    end
  end

  defp receive_request(_, _), do: {:error, :oversized_request}

  defp receive_more(socket, bytes) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> receive_request(socket, bytes <> chunk)
      error -> error
    end
  end
end
