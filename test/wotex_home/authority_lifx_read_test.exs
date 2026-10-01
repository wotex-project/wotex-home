defmodule WotexHome.AuthorityLifxReadTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Authority
  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{Ledger, Transport}
  alias WotexHome.Semantics.Thing

  defmodule MemoryTransport do
    @moduledoc false

    @behaviour Transport

    @impl true
    def send(handle, _endpoint, packet) do
      Process.put({__MODULE__, handle}, packet)
      :ok
    end

    @impl true
    def recv(handle, _timeout_ms) do
      <<_size::little-16, _frame::little-16, source::little-32, _::binary>> =
        Process.get({__MODULE__, handle})

      <<_::binary-size(23), sequence::8, _::binary>> = Process.get({__MODULE__, handle})
      target = <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

      payload =
        <<0::little-16, 0::little-16, 65_535::little-16, 3_500::little-16, 0::16,
          65_535::little-16, "Desk", 0::size(28)-unit(8), 0::64>>

      size = 36 + byte_size(payload)

      reply =
        <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48,
          0::8, sequence::8, 0::64, 107::little-16, 0::16, payload::binary>>

      {:ok, handle, reply}
    end
  end

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>
  @endpoint "127.0.0.1:56700"

  test "Authority owns the durable commit after a bounded LIFX read" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "wotex-home-authority-read-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))
    assert {:ok, thing} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)
    authority = Authority.new(store: store, capture: nil, review_gate: nil)
    assert {:ok, ledger} = Ledger.new(2)

    assert {:ok, [report], [2], _ledger} =
             Authority.lifx_read(authority, candidate(), @target, thing, ledger,
               transport: {MemoryTransport, @endpoint},
               clock: fn -> {1_100, 1_000_000} end,
               source_epoch: "device:1",
               source_sequence: 1,
               boot_epoch: "boot:1",
               timeout_ms: 2_000
             )

    assert report.value.data == true
    assert {:ok, ^report, 2} = Store.current(store, thing.id, "power")
    :ok = GenServer.stop(store)
  end

  defp candidate do
    {:ok, candidate} =
      Candidate.new(%{
        "interface_id" => "memory:1",
        "transport" => "udp",
        "source_endpoint" => @endpoint,
        "receive_epoch" => "boot:1",
        "received_monotonic_ms" => 100,
        "raw_ref" => "fixture:memory:1",
        "claimed_identifiers" => %{"stable_id" => "lifx:d073d5001337"},
        "trust_class" => "untrusted_network"
      })

    candidate
  end

  defp thing do
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
          "evidence_ref" => "fixture:memory:power:1",
          "freshness_ms" => 5_000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    })
  end
end
