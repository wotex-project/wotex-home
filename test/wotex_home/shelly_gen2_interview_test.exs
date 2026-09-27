defmodule WotexHome.ShellyGen2InterviewTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Lifx.IPv4Scope
  alias WotexHome.Shelly.Gen2Interview

  @device_id "shellyplus1pm-441793ce3f08"

  test "one peer supplies correlated identity and switch status as an untrusted report" do
    {port, task} = peer([identity(@device_id), status(@device_id)])
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 8)

    assert {:ok,
            %{
              device_id: @device_id,
              model: "SNSW-001P16EU",
              switch_id: 0,
              output: false,
              trust: :unauthenticated_local
            }} =
             Gen2Interview.run_scoped(scope, {127, 0, 0, 1}, port, 0, fn -> {:ok, scope} end)

    assert ["Shelly.GetDeviceInfo", "Switch.GetStatus"] = Task.await(task)
  end

  test "a changed interface stops before status and a different device source is rejected" do
    {port, task} = peer([identity(@device_id)])
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 8)
    Process.put(:shelly_scope_checks, 0)

    check_scope = fn ->
      count = Process.get(:shelly_scope_checks)
      Process.put(:shelly_scope_checks, count + 1)
      if count == 0, do: {:ok, scope}, else: {:error, :unavailable}
    end

    assert {:error, :selected_interface_changed} =
             Gen2Interview.run_scoped(scope, {127, 0, 0, 1}, port, 0, check_scope)

    assert ["Shelly.GetDeviceInfo"] = Task.await(task)
    assert Process.get(:shelly_scope_checks) == 2

    {port, task} = peer([identity(@device_id), status("shellyother-123456789abc")])

    assert {:error, :device_identity_changed} =
             Gen2Interview.run_scoped(scope, {127, 0, 0, 1}, port, 0, fn -> {:ok, scope} end)

    assert ["Shelly.GetDeviceInfo", "Switch.GetStatus"] = Task.await(task)
  end

  test "the operator task rejects ambiguous IPv4 spellings before opening a socket" do
    for address <- ["127.1", "010.0.0.1", "192.168.001.1", "0x7f.0.0.1"] do
      assert_raise Mix.Error, ~r/usage: mix woh.shelly.read/, fn ->
        Mix.Tasks.Woh.Shelly.Read.run(["en0", address, "0"])
      end
    end
  end

  defp identity(id) do
    %{
      "id" => 1,
      "src" => id,
      "result" => %{
        "id" => id,
        "model" => "SNSW-001P16EU",
        "gen" => 2,
        "fw_id" => "20210720-153353/0.6.7-gc36674b",
        "ver" => "0.6.7",
        "auth_en" => false
      }
    }
  end

  defp status(id),
    do: %{"id" => 2, "src" => id, "result" => %{"id" => 0, "output" => false}}

  defp peer(responses) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          Enum.map(responses, fn response ->
            {:ok, socket} = :gen_tcp.accept(listener, 2_000)

            try do
              {:ok, bytes} = request(socket, "")
              [head, body] = String.split(bytes, "\r\n\r\n", parts: 2)
              assert String.starts_with?(head, "POST /rpc HTTP/1.1\r\n")
              method = body |> JSON.decode!() |> Map.fetch!("method")
              encoded = JSON.encode!(response)

              :ok =
                :gen_tcp.send(
                  socket,
                  "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(encoded)}\r\nconnection: close\r\n\r\n" <>
                    encoded
                )

              method
            after
              :gen_tcp.close(socket)
            end
          end)
        after
          :gen_tcp.close(listener)
        end
      end)

    {port, task}
  end

  defp request(socket, bytes) when byte_size(bytes) <= 4_096 do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [head, body] ->
        case Regex.run(~r/content-length: (\d+)/i, head) do
          [_, length] ->
            if byte_size(body) >= String.to_integer(length),
              do: {:ok, bytes},
              else: request_more(socket, bytes)

          _ ->
            request_more(socket, bytes)
        end

      _ ->
        request_more(socket, bytes)
    end
  end

  defp request(_, _), do: {:error, :oversized_request}

  defp request_more(socket, bytes) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> request(socket, bytes <> chunk)
      error -> error
    end
  end
end
