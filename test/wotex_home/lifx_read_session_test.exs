defmodule WotexHome.LifxReadSessionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Lifx.{Ledger, Packet, ReadSession}
  alias WotexHome.Semantics.Thing

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>
  @endpoint "192.168.1.10:56700"
  @metadata %{
    "source_epoch" => "lifx:session:1",
    "source_sequence" => 42,
    "boot_epoch" => "host:boot:1",
    "received_time_utc_ms" => 1_700_000_000_000,
    "received_monotonic_ms" => 1_100
  }

  test "a correlated GetColor reply yields only declared reports" do
    assert {:ok, session} = ReadSession.new(candidate(), @target, thing())
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, query, session, ledger} = ReadSession.issue(session, ledger, 1_000, 500)
    assert {:ok, %Packet{type: 101} = request} = Packet.decode(query)
    reply = reply(request, @target)

    assert {:error, :endpoint_or_target_mismatch, ^ledger} =
             ReadSession.accept(session, ledger, "192.168.1.11:56700", reply, 1_100, @metadata)

    assert {:error, :endpoint_or_target_mismatch, ^ledger} =
             ReadSession.accept(
               session,
               ledger,
               @endpoint,
               reply(request, <<1::48>>),
               1_100,
               @metadata
             )

    assert {:ok, [observation], completed} =
             ReadSession.accept(session, ledger, @endpoint, reply, 1_100, @metadata)

    assert observation.capability_key == "power"
    assert observation.value.data == true
    assert observation.trust == "unauthenticated_local"

    assert {:error, :unmatched_response, ^completed} =
             ReadSession.accept(session, completed, @endpoint, reply, 1_200, @metadata)
  end

  test "expired, malformed and wrong-target replies cannot create reports" do
    assert {:ok, session} = ReadSession.new(candidate(), @target, thing())
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, query, session, ledger} = ReadSession.issue(session, ledger, 1_000, 100)
    assert {:ok, request} = Packet.decode(query)
    reply = reply(request, @target)

    assert {:error, :invalid_payload, ^ledger} =
             ReadSession.accept(
               session,
               ledger,
               @endpoint,
               binary_part(reply, 0, 36) |> with_size(),
               1_050,
               @metadata
             )

    assert {:error, :expired, _expired_ledger} =
             ReadSession.accept(session, ledger, @endpoint, reply, 1_101, @metadata)
  end

  test "two reads of the same bulb cannot consume each other's response" do
    assert {:ok, first} = ReadSession.new(candidate(), @target, thing())
    assert {:ok, second} = ReadSession.new(candidate(), @target, thing())
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, first_query, first, ledger} = ReadSession.issue(first, ledger, 1_000, 500)
    assert {:ok, second_query, second, ledger} = ReadSession.issue(second, ledger, 1_000, 500)
    assert {:error, :read_already_issued} = ReadSession.issue(first, ledger, 1_001, 500)
    assert {:ok, first_packet} = Packet.decode(first_query)
    assert {:ok, second_packet} = Packet.decode(second_query)

    assert {:error, :endpoint_or_target_mismatch, ^ledger} =
             ReadSession.accept(
               second,
               ledger,
               @endpoint,
               reply(first_packet, @target),
               1_100,
               @metadata
             )

    assert {:ok, [_report], ledger} =
             ReadSession.accept(
               first,
               ledger,
               @endpoint,
               reply(first_packet, @target),
               1_100,
               @metadata
             )

    assert {:ok, [_report], _ledger} =
             ReadSession.accept(
               second,
               ledger,
               @endpoint,
               reply(second_packet, @target),
               1_101,
               @metadata
             )
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

  defp reply(%Packet{source: source, sequence: sequence}, target) do
    payload =
      <<0::little-16, 0::little-16, 65_535::little-16, 3_500::little-16, 0::16, 65_535::little-16,
        "Desk", 0::size(28)-unit(8), 0::64>>

    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
      sequence::8, 0::64, 107::little-16, 0::16, payload::binary>>
  end

  defp with_size(<<_size::little-16, rest::binary>>), do: <<36::little-16, rest::binary>>
end
