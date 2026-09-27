defmodule WotexHome.LifxInterviewSessionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Lifx.{DiscoveryWindow, IPv4Scope, InterviewSession, Ledger, Packet}

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>
  @endpoint "192.168.1.10:56700"

  test "version and host firmware replies produce a read-only exact interview" do
    candidate = candidate()
    assert {:ok, session} = InterviewSession.new(candidate, @target)
    assert {:error, :incomplete_interview} = InterviewSession.finish(session)
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, queries, session, ledger} = InterviewSession.issue(session, ledger, 1_000, 2_000)

    assert {:ok, version_query} = Packet.decode(queries.version)
    assert {:ok, firmware_query} = Packet.decode(queries.host_firmware)

    version_reply =
      reply(version_query, 33, <<1::little-32, 27::little-32, 0::32>>)

    firmware_reply =
      reply(
        firmware_query,
        15,
        <<1_700_000_000::little-64, 0::64, 60::little-16, 3::little-16>>
      )

    assert {:error, :endpoint_or_target_mismatch, ^session, ^ledger} =
             InterviewSession.accept(session, ledger, "192.168.1.11:56700", version_reply, 1_100)

    assert {:ok, session, ledger} =
             InterviewSession.accept(session, ledger, @endpoint, firmware_reply, 1_100)

    assert {:ok, session, ledger} =
             InterviewSession.accept(session, ledger, @endpoint, version_reply, 1_200)

    assert {:ok, interview} = InterviewSession.finish(session)
    assert interview.candidate_ref == candidate.raw_ref
    assert interview.stable_id == "lifx:d073d5001337"
    assert interview.manufacturer == "lifx.vendor.1"
    assert interview.model == "lifx.product.27"
    assert interview.firmware == "3.60"

    assert {:error, :unmatched_response, ^session, ^ledger} =
             InterviewSession.accept(session, ledger, @endpoint, version_reply, 1_300)
  end

  test "a candidate for another target cannot begin an interview" do
    candidate = candidate()
    assert {:error, :invalid_interview_candidate} = InterviewSession.new(candidate, <<1::48>>)
  end

  test "concurrent interviews keep their own version and firmware replies" do
    assert {:ok, first} = InterviewSession.new(candidate(), @target)
    assert {:ok, second} = InterviewSession.new(candidate(), @target)
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, first_queries, first, ledger} = InterviewSession.issue(first, ledger, 1_000, 500)

    assert {:ok, second_queries, second, ledger} =
             InterviewSession.issue(second, ledger, 1_000, 500)

    assert {:error, :interview_already_issued} = InterviewSession.issue(first, ledger, 1_001, 500)
    assert {:ok, first_version} = Packet.decode(first_queries.version)
    assert {:ok, second_version} = Packet.decode(second_queries.version)
    first_reply = reply(first_version, 33, <<1::little-32, 27::little-32, 0::32>>)
    second_reply = reply(second_version, 33, <<1::little-32, 27::little-32, 0::32>>)

    assert {:error, :endpoint_or_target_mismatch, ^second, ^ledger} =
             InterviewSession.accept(second, ledger, @endpoint, first_reply, 1_100)

    assert {:ok, first, ledger} =
             InterviewSession.accept(first, ledger, @endpoint, first_reply, 1_100)

    assert {:ok, second, _ledger} =
             InterviewSession.accept(second, ledger, @endpoint, second_reply, 1_101)

    assert first.version == second.version
  end

  defp candidate do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)
    assert {:ok, window, _query} = DiscoveryWindow.new("en0", "boot:1", scope, 2, 7, 1_000, 2_000)
    payload = <<1, 56_700::little-32>>

    discovery_reply =
      reply(
        %Packet{
          source: 2,
          target: @target,
          sequence: 7,
          type: 3,
          payload: payload,
          tagged: false
        },
        3,
        payload
      )

    assert {:ok, candidate, _window} =
             DiscoveryWindow.accept(window, discovery_reply, {192, 168, 1, 10}, 56_700, 1_100)

    candidate
  end

  defp reply(%Packet{source: source, target: target, sequence: sequence}, type, payload) do
    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
      sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
  end
end
