defmodule WotexHome.LifxCaptureAPITest do
  @moduledoc false

  use ExUnit.Case

  import ExUnit.CaptureIO

  alias WotexHome.CLI
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, Transport}
  alias WotexHome.LocalAPI.Server

  defmodule ScriptedTransport do
    @moduledoc false

    @behaviour Transport

    @impl true
    def send(_handle, _endpoint, packet) do
      Process.put(:capture_api_packets, [packet | Process.get(:capture_api_packets, [])])
      :ok
    end

    @impl true
    def recv(_handle, _timeout_ms) do
      count = Process.get(:capture_api_receive_count, 0)
      Process.put(:capture_api_receive_count, count + 1)
      packets = Process.get(:capture_api_packets, [])

      case count do
        0 ->
          {:ok, "192.168.1.10:56700", response(hd(packets), 3, <<1, 56_700::little-32>>)}

        1 ->
          {:error, :timeout}

        2 ->
          {:ok, "192.168.1.10:56700",
           response(Enum.at(packets, 1), 33, <<1::little-32, 27::little-32, 0::32>>)}

        3 ->
          {:ok, "192.168.1.10:56700",
           response(
             hd(packets),
             15,
             <<1_700_000_000::little-64, 0::64, 60::little-16, 3::little-16>>
           )}

        _ ->
          {:error, :timeout}
      end
    end

    defp response(request, type, payload) do
      <<_::binary-size(4), source::little-32, target::binary-size(6), _::binary-size(9),
        sequence::8, _::binary>> = request

      target = if type == 3, do: <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>, else: target
      size = 36 + byte_size(payload)

      <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
        sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
    end
  end

  test "only a current enrollment reviewer can discover and interview a captured reference" do
    directory =
      Path.join(System.tmp_dir!(), "woh-capture-api-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))

    assert {:ok, reviewer, _} =
             Store.provision_principal(store, "operator:1", ["enroll:review"], [])

    assert {:ok, other_reviewer, _} =
             Store.provision_principal(store, "operator:2", ["enroll:review"], [])

    assert {:ok, reader, _} = Store.provision_principal(store, "reader:1", ["read"], [])
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)

    assert {:ok, capture} =
             CaptureSession.start_link(
               interface_id: "en0",
               scope: scope,
               transport: {ScriptedTransport, :fixture}
             )

    assert Process.register(capture, WotexHome.Host.LifxCapture)

    assert {:ok, server} =
             Server.start_link(
               store: store,
               socket_path: Path.join(directory, "private/home.sock")
             )

    socket = Path.join(directory, "private/home.sock")

    discover = fn credential ->
      request(socket, %{
        "api_version" => 1,
        "operation" => "lifx_discover",
        "credential" => Base.url_encode64(credential, padding: false)
      })
    end

    assert %{"outcome" => "error", "reason" => "permission_denied"} = discover.(reader)

    assert %{
             "outcome" => "ok",
             "capture" => %{
               "session_ref" => session_ref,
               "candidates" => [
                 %{
                   "candidate_ref" => candidate_ref,
                   "claimed_stable_id" => "lifx:d073d5001337",
                   "trust_class" => "untrusted_network"
                 }
               ]
             }
           } = discover.(reviewer)

    assert %{"outcome" => "error", "reason" => "capture_busy"} =
             discover.(other_reviewer)

    interview = %{
      "api_version" => 1,
      "operation" => "lifx_interview",
      "credential" => Base.url_encode64(reviewer, padding: false),
      "session_ref" => session_ref,
      "candidate_ref" => candidate_ref
    }

    assert %{"outcome" => "error", "reason" => "capture_missing"} =
             request(socket, %{
               interview
               | "credential" => Base.url_encode64(other_reviewer, padding: false)
             })

    assert %{"outcome" => "error", "reason" => "ambiguous_or_missing_candidate"} =
             request(socket, %{interview | "candidate_ref" => "lifx:forged"})

    credential_file = Path.join(directory, "reviewer.credential")
    File.write!(credential_file, Base.url_encode64(reviewer, padding: false))
    File.chmod!(credential_file, 0o600)

    cli_output =
      capture_io(fn ->
        assert 0 ==
                 CLI.main([
                   "--socket",
                   socket,
                   "--credential-file",
                   credential_file,
                   "lifx-interview",
                   session_ref,
                   candidate_ref
                 ])
      end)

    assert %{
             "outcome" => "ok",
             "interview" => %{
               "candidate_ref" => ^candidate_ref,
               "stable_id_claim" => "lifx:d073d5001337",
               "manufacturer_reported" => "lifx.vendor.1",
               "model_reported" => "lifx.product.27",
               "firmware_reported" => "3.60"
             }
           } = JSON.decode!(cli_output)

    assert %{"outcome" => "error", "reason" => "interview_unavailable"} =
             request(socket, interview)

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             request(socket, Map.put(interview, "thing_id", "light:desk"))

    assert {:error, :capture_missing} =
             CaptureSession.checkout(capture, session_ref)

    assert {:error, :capture_missing} =
             CaptureSession.checkout_auto(capture, "operator:2", session_ref)

    assert {:ok, evidence} = CaptureSession.checkout_auto(capture, "operator:1", session_ref)
    assert evidence.selected_candidate_ref == candidate_ref
    assert length(evidence.transcript) == 6

    assert {:error, :capture_missing} =
             CaptureSession.checkout_auto(capture, "operator:1", session_ref)

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(capture)

    assert %{"outcome" => "error", "reason" => "capture_unavailable"} =
             request_after_restart(store, socket, reviewer)

    :ok = GenServer.stop(store)
  end

  defp request_after_restart(store, socket, credential) do
    {:ok, server} = Server.start_link(store: store, socket_path: socket)

    result =
      request(socket, %{
        "api_version" => 1,
        "operation" => "lifx_discover",
        "credential" => Base.url_encode64(credential, padding: false)
      })

    :ok = GenServer.stop(server)
    result
  end

  defp request(path, body) do
    encoded = JSON.encode!(body)

    assert {:ok, socket} =
             :gen_tcp.connect(
               {:local, String.to_charlist(path)},
               0,
               [:binary, active: false],
               1_000
             )

    assert :ok = :gen_tcp.send(socket, <<byte_size(encoded)::unsigned-big-32, encoded::binary>>)
    assert {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(socket, 4, 5_000)
    assert {:ok, response} = :gen_tcp.recv(socket, size, 5_000)
    :ok = :gen_tcp.close(socket)
    JSON.decode!(response)
  end
end
