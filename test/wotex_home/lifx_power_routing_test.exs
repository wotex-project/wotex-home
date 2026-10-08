Code.require_file(Path.expand("../support/lifx_power_route_fixture.exs", __DIR__))

defmodule WotexHome.LifxPowerRoutingTest do
  use ExUnit.Case
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope}
  alias WotexHome.Semantics.Thing
  alias WotexHome.TestSupport.PowerRouteFixture

  for {mode, phase, expected} <- [
        {"route", :held, :ok},
        {"noise", :held, :ok},
        {"queued", :queued, :ok},
        {"late_discovery", :held, :device_unavailable},
        {"wrong_identity", :held, :device_unavailable},
        {"ambiguous", :held, :ambiguous_device},
        {"late_read", :held, :read_timeout}
      ] do
    @tag requires_socket: true
    test "bounded private #{phase} routing handles independent UDP #{mode}" do
      {peer, transport, cleanup} = PowerRouteFixture.open(unquote(mode))
      on_exit(cleanup)
      {:ok, scope} = IPv4Scope.new({127, 0, 0, 2}, 8)

      owner =
        start_supervised!(
          {CaptureSession, interface_id: "fixture:loopback", scope: scope, transport: transport}
        )

      started = System.monotonic_time(:millisecond)

      result =
        CaptureSession.power_route_auto(owner, "lifx:d073d5000001", thing(), unquote(phase))

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 650

      if unquote(expected == :ok) do
        assert {:ok, route} = result
        assert route.source_epoch == route.boot_epoch
        assert route.source_sequence == unquote(if phase == :held, do: 1, else: 0)
        assert route.candidate.claimed_identifiers["stable_id"] == "lifx:d073d5000001"
        assert length(route.reports) == unquote(if phase == :held, do: 1, else: 0)
        if unquote(phase == :held), do: assert(hd(route.reports).value.data == false)
      else
        assert {:error, unquote(expected)} = result
      end

      assert_receive {^peer, {:exit_status, 0}}, 2_000
    end
  end

  test "time queued behind the owner consumes the budget before any routing packet" do
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 2}, 8)

    owner =
      start_supervised!(
        {CaptureSession,
         interface_id: "fixture:loopback",
         scope: scope,
         transport: {WotexHome.LifxPowerRoutingTest.NoSendTransport, self()}}
      )

    :sys.suspend(owner)

    caller =
      Task.async(fn ->
        CaptureSession.power_route_auto(owner, "lifx:d073d5000001", thing(), :held)
      end)

    Process.sleep(150)
    :sys.resume(owner)
    assert {:error, :capture_deadline_expired} = Task.await(caller, 1_000)
    refute_receive :unexpected_route_packet, 20
    assert :sys.get_state(owner).read_sequence == 0
  end

  defmodule NoSendTransport do
    @behaviour WotexHome.Lifx.Transport
    def send(observer, _, _), do: Kernel.send(observer, :unexpected_route_packet)
    def recv(_, _), do: {:error, :timeout}
  end

  defp thing do
    {:ok, thing} =
      Thing.new(%{
        "id" => "light:fixture",
        "role" => "Light",
        "profile_ref" => "lifx.fixture:1",
        "capabilities" => [
          %{
            "thing_id" => "light:fixture",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "lifx.fixture:1",
            "evidence_ref" => "fixture:power",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    thing
  end
end
