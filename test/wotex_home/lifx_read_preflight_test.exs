defmodule WotexHome.LifxReadPreflightTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Lifx.{Ledger, ReadPath, Transport}
  alias WotexHome.Semantics.Thing

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  defmodule UnsupportedRouteTransport do
    @moduledoc false

    @behaviour Transport

    @impl true
    def preflight(_handle, _endpoint, :unicast), do: {:error, :unsupported_unicast_endpoint}

    @impl true
    def send(_handle, _endpoint, _packet), do: raise("preflight must reject before send")

    @impl true
    def recv(_handle, _timeout_ms), do: raise("preflight must reject before receive")
  end

  test "an unsupported unicast route is rejected before ledger issue or commit" do
    assert {:ok, ledger} = Ledger.new(2)
    commit = fn _thing, _reports -> raise("preflight must reject before commit") end

    assert {:error, :unsupported_unicast_endpoint, ^ledger} =
             ReadPath.run(commit, candidate(), @target, thing(), ledger,
               transport: {UnsupportedRouteTransport, nil},
               clock: fn -> raise("preflight must reject before the clock") end,
               source_epoch: "device:1",
               source_sequence: 1,
               boot_epoch: "boot:1",
               timeout_ms: 2_000
             )
  end

  defp candidate do
    {:ok, candidate} =
      Candidate.new(%{
        "interface_id" => "fixture:1",
        "transport" => "udp",
        "source_endpoint" => "192.168.0.255:56700",
        "receive_epoch" => "boot:1",
        "received_monotonic_ms" => 100,
        "raw_ref" => "fixture:preflight:1",
        "claimed_identifiers" => %{"stable_id" => "lifx:d073d5001337"},
        "trust_class" => "untrusted_network"
      })

    candidate
  end

  defp thing do
    {:ok, thing} =
      Thing.new(%{
        "id" => "light:desk",
        "role" => "Light",
        "profile_ref" => "lifx.old:1",
        "capabilities" => [
          %{
            "thing_id" => "light:desk",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "lifx.old:1",
            "evidence_ref" => "fixture:preflight:1",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    thing
  end
end
