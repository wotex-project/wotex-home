Code.require_file("../support/controller_tls_fixture.exs", __DIR__)

defmodule WotexHome.ControllerTLSBootstrapTest do
  use ExUnit.Case
  alias WotexHome.ControllerConnections.{BootstrapClient, CertificateClock, TLSIdentity}
  alias WotexHome.TestSupport.ControllerTLSFixture, as: Peer
  @moduletag requires_socket: true

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "woh-controller-tls-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    %{fixture: Peer.create(root)}
  end

  for identity <- [
        ["dns", "home.example"],
        ["ipv4", "127.0.0.1"],
        ["ipv6", "0000:0000:0000:0000:0000:0000:0000:0001"]
      ] do
    test "validated TLS 1.3 bootstrap with #{hd(identity)} SAN", %{fixture: f} do
      {port, task} = Peer.peer(f)
      invitation = Peer.invitation(f, port, "valid", unquote(identity))
      assert {:ok, result} = BootstrapClient.run(invitation, Peer.request(), clock())
      assert result["permissions"] == ["read"]
      assert result["target_ids"] == []
      assert result["principal_id"] == "paired-client"
      assert result["credential"] != invitation["bootstrap_secret"]
      assert Task.await(task, 8_000) == {:request, Peer.request_body()}
    end
  end

  test "IPv6 endpoint is separate from its expected DNS identity", %{fixture: f} do
    {port, task} = Peer.peer(f, "valid", :paired, ip: {0, 0, 0, 0, 0, 0, 0, 1})

    invitation =
      Peer.invitation(f, port)
      |> Map.put("endpoint", ["ipv6", "0000:0000:0000:0000:0000:0000:0000:0001", port])

    assert {:ok, _} = BootstrapClient.run(invitation, Peer.request(), clock())
    assert Task.await(task, 8_000) == {:request, Peer.request_body()}
  end

  test "the platform DNS resolver can select an IPv6 endpoint without replacing identity", %{
    fixture: f
  } do
    {port, task} = Peer.peer(f, "valid", :paired, ip: {0, 0, 0, 0, 0, 0, 0, 1})
    invitation = Peer.invitation(f, port) |> Map.put("endpoint", ["dns", "localhost", port])
    assert {:ok, _} = BootstrapClient.run(invitation, Peer.request(), clock())
    assert Task.await(task, 8_000) == {:request, Peer.request_body()}
  end

  for variant <-
        ~w(wrong_name common_name_only uri_name_only wrong_purpose expired future unknown_critical unknown_ca corrupt) do
    test "#{variant} never receives bootstrap bytes", %{fixture: f} do
      variant = unquote(variant)
      {port, task} = Peer.peer(f, variant)

      assert {:error, :tls_peer_unverified} =
               BootstrapClient.run(Peer.invitation(f, port, variant), Peer.request(), clock())

      assert Task.await(task, 8_000) == :no_application_bytes
    end
  end

  test "a different valid leaf under the same CA cannot replace the invited pin", %{fixture: f} do
    {port, task} = Peer.peer(f, "changed")

    assert {:error, :tls_pin_changed} =
             BootstrapClient.run(Peer.invitation(f, port), Peer.request(), clock())

    assert Task.await(task, 8_000) == :no_application_bytes
  end

  test "TLS 1.2 cannot receive bootstrap bytes", %{fixture: f} do
    {port, task} = Peer.peer(f, "valid", :paired, versions: [:"tlsv1.2"])

    assert {:error, :tls_peer_unverified} =
             BootstrapClient.run(Peer.invitation(f, port), Peer.request(), clock())

    assert Task.await(task, 8_000) == :no_application_bytes
  end

  test "an uncertainty interval crossing the leaf validity refuses before sending", %{fixture: f} do
    {port, task} = Peer.peer(f)
    now = System.system_time(:millisecond)
    {:ok, wide} = CertificateClock.new(now, now + 86_401_000)

    assert {:error, :tls_clock_uncertain} =
             BootstrapClient.run(Peer.invitation(f, port), Peer.request(), wide)

    assert Task.await(task, 8_000) == :no_application_bytes
  end

  for mode <- [:fragmented, :refused] do
    test "one complete #{mode} response is exactly correlated", %{fixture: f} do
      mode = unquote(mode)
      {port, task} = Peer.peer(f, "valid", mode)

      assert {:ok, result} =
               BootstrapClient.run(Peer.invitation(f, port), Peer.request(), clock())

      assert result["reason"] ==
               unquote(if(mode == :refused, do: "confirmation_denied", else: nil))

      assert Task.await(task, 8_000) == {:request, Peer.request_body()}
    end
  end

  for mode <- [
        :lost,
        :oversize,
        :empty,
        :truncated,
        :wrong_digest,
        :widened,
        :slow_header,
        :slow_body
      ] do
    test "#{mode} after sending retains outcome_unknown", %{fixture: f} do
      mode = unquote(mode)
      {port, task} = Peer.peer(f, "valid", mode)
      started = System.monotonic_time(:millisecond)

      assert {:error, :outcome_unknown} =
               BootstrapClient.run(Peer.invitation(f, port), Peer.request(), clock())

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 6_500
      assert elapsed >= unquote(if(mode in [:slow_header, :slow_body], do: 4_900, else: 0))
      assert Task.await(task, 8_000) == {:request, Peer.request_body()}
    end
  end

  test "the handshake has its own five-second hard limit and closes the owner", %{fixture: f} do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 7_000)

          try do
            drain(socket, 0)
          after
            :gen_tcp.close(socket)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :tls_handshake_timeout} =
             BootstrapClient.run(Peer.invitation(f, port), Peer.request(), clock())

    assert (System.monotonic_time(:millisecond) - started) in 4_900..6_500
    assert Task.await(task, 8_000) == :closed
  end

  test "invalid anchors, expired clocks and request substitution do not dial", %{fixture: f} do
    invitation = Peer.invitation(f, 49_999)

    assert {:error, :invalid_controller_tls_trust} =
             BootstrapClient.run(
               Map.put(invitation, "trust_anchor", "YWJj"),
               Peer.request(),
               clock()
             )

    assert {:error, :tls_clock_uncertain} = BootstrapClient.run(invitation, Peer.request(), nil)
    expired = %{clock() | expires: System.monotonic_time(:millisecond) - 1}

    assert {:error, :tls_clock_uncertain} =
             BootstrapClient.run(invitation, Peer.request(), expired)

    for field <- ~w(controller_id invitation_id bootstrap_secret) do
      changed =
        if field == "bootstrap_secret",
          do: Base.url_encode64(:binary.copy(<<9>>, 32), padding: false),
          else: String.duplicate("9", 64)

      assert {:error, :invalid_controller_connection_record} =
               BootstrapClient.run(invitation, Map.put(Peer.request(), field, changed), clock())
    end

    link =
      Map.put(invitation, "endpoint", ["ipv6", "fe80:0000:0000:0000:0000:0000:0000:0001", 49_999])

    assert {:error, :tls_client_interface_required} =
             BootstrapClient.run(link, Peer.request(), clock())
  end

  test "TLS state excludes bearer/bootstrap material and cannot waive a platform failure", %{
    fixture: f
  } do
    {:ok, trust} = TLSIdentity.new(Peer.invitation(f, 49_999))
    {:ok, options} = TLSIdentity.options(trust, clock())
    assert options[:verify] == :verify_peer
    assert options[:versions] == [:"tlsv1.3"]
    assert options[:session_tickets] == :disabled
    refute Keyword.has_key?(options, :early_data)
    {_, state} = options[:verify_fun]
    refute Map.has_key?(Map.from_struct(state.trust), :bootstrap_secret)
    assert inspect(trust) == "#ControllerTLSIdentity<private>"

    assert {:fail, {:bad_cert, :cert_expired}} =
             TLSIdentity.verify(nil, nil, {:bad_cert, :cert_expired}, state)
  end

  defp clock do
    now = System.system_time(:millisecond)
    {:ok, clock} = CertificateClock.new(now, now)
    clock
  end

  defp drain(socket, size) when size < 65_536 do
    case :gen_tcp.recv(socket, 0, 7_000) do
      {:ok, bytes} -> drain(socket, size + byte_size(bytes))
      {:error, :closed} -> :closed
      _ -> :not_closed
    end
  end
end
