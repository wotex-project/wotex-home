defmodule WotexHome.LifxLedgerTest do
  use ExUnit.Case, async: true

  alias WotexHome.Lifx.{Ledger, Packet}

  @target <<0xD0, 0x73, 0xD5, 0, 0x13, 0x37>>
  @other <<0xD0, 0x73, 0xD5, 0, 0x13, 0x38>>

  test "only the expected source, target, sequence and response type complete a request" do
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, {2, @target, 0}, ledger} = Ledger.issue(ledger, @target, :power, 100, 1_000)

    assert {:error, :unmatched_response, ^ledger} =
             Ledger.accept(ledger, packet(3, @target, 0, 22), 101)

    assert {:error, :unmatched_response, ^ledger} =
             Ledger.accept(ledger, packet(2, @other, 0, 22), 101)

    assert {:error, :unmatched_response, ^ledger} =
             Ledger.accept(ledger, packet(2, @target, 1, 22), 101)

    assert {:error, :unexpected_response, ^ledger} =
             Ledger.accept(ledger, packet(2, @target, 0, 45), 101)

    assert {:ok, %{kind: :power, on?: true}, completed} =
             Ledger.accept(ledger, packet(2, @target, 0, 22, <<65_535::little-16>>), 101)

    assert completed.pending == %{}

    assert {:error, :unmatched_response, ^completed} =
             Ledger.accept(completed, packet(2, @target, 0, 22), 102)
  end

  test "sequence wrap rotates source so old replies cannot match" do
    assert {:ok, ledger} = Ledger.new(2)

    ledger =
      Enum.reduce(0..255, ledger, fn sequence, current ->
        assert {:ok, {2, @target, ^sequence}, issued} =
                 Ledger.issue(current, @target, :ack, sequence, 100)

        assert {:ok, %{kind: :ack}, complete} =
                 Ledger.accept(issued, packet(2, @target, sequence, 45), sequence)

        complete
      end)

    assert ledger.source == 3
    assert ledger.next_sequence == 0
    assert {:ok, {3, @target, 0}, new_ledger} = Ledger.issue(ledger, @target, :ack, 300, 100)

    assert {:error, :unmatched_response, ^new_ledger} =
             Ledger.accept(new_ledger, packet(2, @target, 0, 45), 301)
  end

  test "finite per-device work and deadlines keep stale effects unknown" do
    assert {:ok, ledger} = Ledger.new(2)

    ledger =
      Enum.reduce(1..4, ledger, fn _, current ->
        assert {:ok, _key, issued} = Ledger.issue(current, @target, :ack, 100, 1_000)
        issued
      end)

    assert {:error, :device_busy} = Ledger.issue(ledger, @target, :ack, 100, 1_000)
    assert {expired, empty} = Ledger.expire(ledger, 1_101)
    assert length(expired) == 4
    assert empty.pending == %{}

    assert {:error, :unmatched_response, ^empty} =
             Ledger.accept(empty, packet(2, @target, 0, 45), 1_102)

    assert {:error, :invalid_request} = Ledger.issue(empty, @target, :ack, 100, 0)
    assert {:error, :invalid_request} = Ledger.issue(empty, @target, :ack, 100, 10_001)
  end

  defp packet(source, target, sequence, type, payload \\ <<65_535::little-16>>) do
    %Packet{
      source: source,
      target: target,
      sequence: sequence,
      type: type,
      payload: if(type == 45, do: <<>>, else: payload),
      tagged: false
    }
  end
end
