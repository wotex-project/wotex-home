defmodule WotexHome.LifxPowerSessionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Lifx.{Ledger, Packet, PowerSession}
  alias WotexHome.Mutation
  alias WotexHome.Semantics.Thing

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>
  @endpoint "192.168.1.10:56701"
  @metadata %{
    "source_epoch" => "lifx:session:1",
    "source_sequence" => 43,
    "boot_epoch" => "host:boot:1",
    "received_time_utc_ms" => 1_700_000_000_000,
    "received_monotonic_ms" => 1_200
  }

  test "an ACK stays separate from a matching reported state" do
    assert {:ok, session} = PowerSession.new(candidate(), @target, thing(), mutation(true), 250)
    assert {:ok, ledger} = Ledger.new(2)
    assert {:error, :set_not_issued} = PowerSession.issue_read(session, ledger, 1_000, 500)
    assert {:ok, set_bytes, session, ledger} = PowerSession.issue_set(session, ledger, 1_000, 500)
    assert {:ok, %Packet{type: 117} = set_packet} = Packet.decode(set_bytes)
    assert set_packet.payload == <<65_535::little-16, 250::little-32>>
    assert {:error, :set_already_issued} = PowerSession.issue_set(session, ledger, 1_001, 500)

    ack = reply(set_packet, 45, <<>>)

    assert {:error, :endpoint_mismatch, ^ledger} =
             PowerSession.accept_ack(session, ledger, "192.168.1.11:56701", ack, 1_100)

    assert {:ok, acknowledged, ledger} =
             PowerSession.accept_ack(session, ledger, @endpoint, ack, 1_100)

    assert acknowledged.acknowledged?
    assert acknowledged.readback == nil

    assert {:error, :unmatched_response, ^ledger} =
             PowerSession.accept_ack(acknowledged, ledger, @endpoint, ack, 1_101)

    assert {:ok, read_bytes, acknowledged, ledger} =
             PowerSession.issue_read(acknowledged, ledger, 1_150, 500)

    assert {:ok, %Packet{type: 116} = read_packet} = Packet.decode(read_bytes)

    assert {:error, :read_already_issued} =
             PowerSession.issue_read(acknowledged, ledger, 1_151, 500)

    assert {:ok, :reported_match, report, completed, ledger} =
             PowerSession.accept_read(
               acknowledged,
               ledger,
               @endpoint,
               reply(read_packet, 118, <<65_535::little-16>>),
               1_200,
               @metadata
             )

    assert report.capability_key == "power"
    assert report.value.data == true
    assert report.trust == "unauthenticated_local"
    assert completed.readback == :reported_match
    assert map_size(ledger.pending) == 0
  end

  test "readback can disagree or be uncertain without an ACK" do
    assert {:ok, session} = PowerSession.new(candidate(), @target, thing(), mutation(true), 0)
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, set_bytes, session, ledger} = PowerSession.issue_set(session, ledger, 1_000, 100)
    assert {:ok, set_packet} = Packet.decode(set_bytes)

    assert {:ok, read_bytes, session, ledger} =
             PowerSession.issue_read(session, ledger, 1_050, 100)

    assert {:ok, read_packet} = Packet.decode(read_bytes)

    assert {:error, :unmatched_response, ^ledger} =
             PowerSession.accept_read(
               session,
               ledger,
               @endpoint,
               reply(set_packet, 118, <<0::little-16>>),
               1_100,
               @metadata
             )

    assert {:error, :expired, expired_ledger} =
             PowerSession.accept_ack(
               session,
               ledger,
               @endpoint,
               reply(set_packet, 45, <<>>),
               1_101
             )

    assert {:ok, :reported_mismatch, report, completed, _ledger} =
             PowerSession.accept_read(
               session,
               expired_ledger,
               @endpoint,
               reply(read_packet, 118, <<0::little-16>>),
               1_120,
               @metadata
             )

    assert report.value.data == false
    refute completed.acknowledged?
  end

  test "only a valid declared writable power capability can form a session" do
    assert {:error, :invalid_power_session} =
             PowerSession.new(candidate(), @target, thing(), mutation(false, "brightness"), 0)

    assert {:error, :invalid_power_session} =
             PowerSession.new(candidate(), @target, thing(), mutation(true), 60_001)

    assert {:error, :invalid_power_session} =
             PowerSession.new(candidate(), <<1::48>>, thing(), mutation(true), 0)
  end

  defp candidate do
    assert {:ok, candidate} =
             Candidate.new(%{
               "interface_id" => "en0",
               "transport" => "udp",
               "source_endpoint" => @endpoint,
               "receive_epoch" => "boot:1",
               "received_monotonic_ms" => 1_000,
               "raw_ref" => "lifx:d073d5001337:fixture",
               "claimed_identifiers" => %{"stable_id" => "lifx:d073d5001337"},
               "trust_class" => "untrusted_network"
             })

    candidate
  end

  defp thing do
    power = %{
      "thing_id" => "light:desk",
      "role" => "Light",
      "key" => "power",
      "value_kind" => "boolean",
      "unit" => "none",
      "operations" => ["read", "write"],
      "risk_class" => "ordinary",
      "profile_ref" => "lifx.old:1",
      "evidence_ref" => "fixture:power:1",
      "freshness_ms" => 5_000,
      "constraints" => %{},
      "extensions" => %{}
    }

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [power]
             })

    thing
  end

  defp mutation(on?, capability_key \\ "power") do
    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:power:1",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => "light:desk",
               "capability_key" => capability_key,
               "value" => %{"type" => "boolean", "value" => on?}
             })

    mutation
  end

  defp reply(%Packet{source: source, target: target, sequence: sequence}, type, payload) do
    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
      sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
  end
end
