defmodule HomeReportReceiver do
  use GenServer
  def start_link(options), do: GenServer.start_link(__MODULE__, nil, options)
  def init(_), do: {:ok, nil}
  def handle_call({:run, f}, _, state), do: {:reply, f.(), state}
end

defmodule HomeReportOwnerArchiveTest do
  use ExUnit.Case

  alias WotexHome.Profiles.{
    ExternalReportOwner,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ReaderSelection
  }

  @receiver __MODULE__.Receiver
  defp fixture(name), do: JSON.decode!(File.read!("fixtures/" <> name <> ".json"))

  defp value(family, changes \\ %{}) do
    i = fixture("external-source-selections")[family]["inputs"]
    r = i["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, v} = ExternalSourceSelection.new(Map.merge(i["source"], changes), reader, i["channels"])
    v
  end

  defp setup_owner(options \\ [], family \\ "temperature") do
    source = start_supervised!({ExternalSourceOwner, publisher: self()})
    selection = value(family)
    {:ok, _} = ExternalSourceOwner.publish(source, selection)
    receiver = start_supervised!({HomeReportReceiver, name: @receiver})

    owner =
      start_supervised!(
        {ExternalReportOwner,
         [publisher: self(), source_owner: source, store_owner: @receiver] ++ options}
      )

    %{source: source, selection: selection, receiver: receiver, owner: owner, family: family}
  end

  defp report(c, changes \\ %{}) do
    {:ok, clock} = ExternalReportOwner.receipt_clock(c.owner)

    fixture("external-transport-reports")[c.family]["report"]
    |> Map.put("receipt_time", clock)
    |> Map.merge(changes)
  end

  defp publish(c, id, r),
    do:
      ExternalReportOwner.publish(
        c.owner,
        id,
        c.selection.data["source_ref"],
        c.selection.sha256,
        r
      )

  defp run(c, f), do: GenServer.call(c.receiver, {:run, f})
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  for family <- ~w(temperature research multi) do
    @family family
    test "#{@family} receipt retains independent exact bytes, original time and Store-only checkout" do
      c = setup_owner([], @family)
      r = report(c)
      assert {:ok, receipt} = publish(c, "packet:1", r)
      assert {:ok, ^receipt} = publish(c, "packet:1", r)

      assert {:error, :external_report_store_denied} =
               ExternalReportOwner.checkout(c.owner, "packet:1")

      assert {:ok, borrowed} = run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)
      v = fixture("external-transport-reports")[@family]

      expected =
        v["document"]
        |> String.replace(String.duplicate("f", 32), r["receipt_time"]["epoch"])
        |> String.replace(~s("-5"), JSON.encode!(r["receipt_time"]["monotonic_us"]))

      assert borrowed.document == expected and borrowed.report == r

      assert receipt["report_sha256"] ==
               sha("wotex-home.external-transport-report@1\n" <> expected)

      assert borrowed.guard.receipt_monotonic_us ==
               String.to_integer(r["receipt_time"]["monotonic_us"])

      assert borrowed.guard.checkout_pid == c.receiver

      assert {:ok, ^borrowed} =
               run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)

      assert {:ok, guard} =
               run(c, fn -> ExternalReportOwner.validate(c.owner, "packet:1", self()) end)

      assert guard == borrowed.guard
      assert :ok = run(c, fn -> ExternalReportOwner.finish(c.owner, "packet:1") end)
      assert :ok = run(c, fn -> ExternalReportOwner.finish(c.owner, "packet:1") end)
      assert {:ok, %{"state" => "consumed"}} = publish(c, "packet:1", r)

      assert {:error, :external_report_retired} =
               run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)

      assert {:error, :external_report_duplicate} = publish(c, "packet:other", r)

      assert {:error, :external_report_conflict} =
               publish(c, "packet:1", Map.put(r, "quality", "unknown"))

      assert Enum.all?(:sys.get_state(c.owner).entries, fn {_, e} ->
               e.report == nil and e.document == nil and e.received == nil and e.caller == nil and
                 e.monitor == nil
             end)

      refute inspect(:sys.get_status(c.owner)) =~ "normalized_value"

      assert %{state: :private_external_report_owner, message: :redacted} =
               ExternalReportOwner.format_status(%{state: r, message: r})
    end
  end

  test "publisher and configured Store are enforced before producer work and state changes" do
    c = setup_owner()

    assert {:error, :external_report_publisher_denied} =
             Task.async(fn -> publish(c, "x", %{}) end) |> Task.await()

    r = report(c)
    {:ok, _} = publish(c, "packet:1", r)

    assert {:error, :external_report_store_denied} =
             ExternalReportOwner.finish(c.owner, "packet:1")

    assert {:error, :external_report_publisher_denied} =
             run(c, fn -> ExternalReportOwner.cancel(c.owner, "packet:1") end)

    {:ok, _} = run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)
    assert {:error, :external_report_busy} = ExternalReportOwner.cancel(c.owner, "packet:1")

    assert {:error, :external_report_busy} =
             run(c, fn -> ExternalReportOwner.validate(c.owner, "packet:1", c.owner) end)

    assert {:ok, %{"state" => "checked_out"}} = ExternalReportOwner.status(c.owner, "packet:1")
  end

  test "closed report, clock and source refusals never publish an original" do
    c = setup_owner()
    r = report(c)

    for bad <- [
          Map.put(r, "extra", true),
          Map.put(r, "sequence", 7),
          Map.put(r, "sequence", "07"),
          Map.put(r, "sequence", "18446744073709551616"),
          Map.put(r, "channel_id", "bad/id"),
          Map.put(r, "receipt_time", %{
            "epoch" => r["receipt_time"]["epoch"],
            "monotonic_us" => "-0"
          }),
          Map.put(r, "source_ref", "source:wrong")
        ] do
      assert {:error, :invalid_external_transport_report} = publish(c, "bad", bad)
    end

    assert {:error, :invalid_external_report_clock} =
             publish(c, "bad", put_in(r, ["receipt_time", "epoch"], String.duplicate("0", 32)))

    assert {:error, :invalid_external_report_clock} =
             publish(c, "bad", put_in(r, ["receipt_time", "monotonic_us"], "9223372036854775807"))

    assert {:error, :stale_external_source} =
             publish(c, "bad", Map.put(r, "source_epoch", String.duplicate("0", 32)))

    assert {:error, :external_profile_limit} =
             publish(c, "bad", Map.put(r, "value", String.duplicate("x", 4097)))

    assert :not_found = ExternalReportOwner.status(c.owner, "bad")
  end

  test "new source generation invalidates pending and borrowed bodies and preserves tombstones" do
    c = setup_owner()
    r = report(c)
    {:ok, _} = publish(c, "packet:1", r)
    {:ok, borrowed} = run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)

    {:ok, _} =
      ExternalSourceOwner.publish(c.source, value("temperature", %{"source_generation" => 2}))

    assert {:error, :external_report_retired} =
             run(c, fn ->
               ExternalReportOwner.validate(c.owner, "packet:1", borrowed.guard.checkout_pid)
             end)

    assert {:ok, %{"state" => "invalidated"}} = ExternalReportOwner.status(c.owner, "packet:1")
    assert {:ok, %{"state" => "invalidated"}} = publish(c, "packet:1", r)
    assert :not_found = ExternalReportOwner.status(c.owner, "other")
  end

  test "expiry is based on transport receipt and includes checked-out bodies" do
    c = setup_owner(ttl_ms: 100)
    r = report(c)
    {:ok, _} = publish(c, "packet:1", r)
    {:ok, borrowed} = run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)

    assert borrowed.guard.expires_at_us ==
             String.to_integer(r["receipt_time"]["monotonic_us"]) + 100_000

    Process.sleep(150)
    assert {:ok, %{"state" => "expired"}} = ExternalReportOwner.status(c.owner, "packet:1")
    assert {:ok, %{"state" => "expired"}} = publish(c, "packet:1", r)
    assert {:error, :external_report_retired} = publish(c, "late", Map.put(r, "sequence", "8"))
  end

  test "active count and exact byte capacity are released by retirement, not original identity" do
    c = setup_owner(report_limit: 1)
    r = report(c)
    {:ok, _} = publish(c, "packet:1", r)

    assert {:error, :external_report_capacity} =
             publish(c, "packet:2", Map.put(r, "sequence", "8"))

    assert :ok = ExternalReportOwner.cancel(c.owner, "packet:1")
    assert :ok = ExternalReportOwner.cancel(c.owner, "packet:1")
    assert {:ok, _} = publish(c, "packet:2", Map.put(r, "sequence", "8"))

    assert {:error, :external_report_conflict} =
             publish(c, "packet:1", Map.put(r, "sequence", "9"))

    stop_supervised(ExternalReportOwner)

    owner =
      start_supervised!(
        {ExternalReportOwner,
         publisher: self(), source_owner: c.source, store_owner: @receiver, max_bytes: 1}
      )

    c = %{c | owner: owner}
    assert {:error, :external_report_capacity} = publish(c, "over", report(c))
    assert {:ok, %{"receipts" => []}} = ExternalReportOwner.catalogue(owner)
  end

  test "configured Store death cancels its checkout and a new incarnation cannot revive it" do
    c = setup_owner()
    {:ok, _} = publish(c, "packet:1", report(c))
    {:ok, _} = run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)
    stop_supervised(HomeReportReceiver)
    receiver = start_supervised!({HomeReportReceiver, name: @receiver})
    c = %{c | receiver: receiver}
    assert {:ok, %{"state" => "cancelled"}} = ExternalReportOwner.status(c.owner, "packet:1")

    assert {:error, :external_report_retired} =
             run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)
  end

  test "1024 retired originals retain correlation and refuse new publication without eviction" do
    c = setup_owner()
    r = report(c)

    for n <- 1..1024 do
      assert {:ok, _} = publish(c, "packet:#{n}", Map.put(r, "sequence", Integer.to_string(n)))
      assert :ok = ExternalReportOwner.cancel(c.owner, "packet:#{n}")
    end

    assert {:error, :external_report_capacity} =
             publish(c, "over", Map.put(r, "sequence", "1025"))

    assert {:error, :external_report_duplicate} =
             publish(c, "duplicate", Map.put(r, "sequence", "1"))

    assert {:ok, %{"state" => "cancelled"}} = publish(c, "packet:1", Map.put(r, "sequence", "1"))
    assert {:ok, %{"receipts" => receipts}} = ExternalReportOwner.catalogue(c.owner)
    assert length(receipts) == 1024
    assert Enum.all?(:sys.get_state(c.owner).entries, fn {_, e} -> e.document == nil end)
  end

  test "source owner death stops custody, and explicit reinstall changes the clock incarnation" do
    c = setup_owner()
    {:ok, _} = publish(c, "packet:1", report(c))
    {:ok, old_clock} = ExternalReportOwner.receipt_clock(c.owner)
    monitor = Process.monitor(c.owner)
    stop_supervised(ExternalSourceOwner)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1000
    stop_supervised(ExternalReportOwner)
    source = start_supervised!({ExternalSourceOwner, publisher: self()})
    {:ok, _} = ExternalSourceOwner.publish(source, c.selection)

    owner =
      start_supervised!(
        {ExternalReportOwner, publisher: self(), source_owner: source, store_owner: @receiver}
      )

    {:ok, clock} = ExternalReportOwner.receipt_clock(owner)
    refute clock["epoch"] == old_clock["epoch"]
    assert :not_found = ExternalReportOwner.status(owner, "packet:1")
  end

  test "producer removal preserves status, checkout and consumption while new publication refuses" do
    c = setup_owner()
    r = report(c)
    {:ok, first} = publish(c, "packet:1", r)
    module = Wotex.JSON
    {^module, beam, path} = :code.get_object_code(module)
    :code.purge(module)
    :code.delete(module)
    directory = path |> List.to_string() |> Path.dirname()
    true = :code.del_path(String.to_charlist(directory))

    try do
      refute Code.ensure_loaded?(module)
      assert {:ok, ^first} = ExternalReportOwner.status(c.owner, "packet:1")
      assert {:ok, _} = run(c, fn -> ExternalReportOwner.checkout(c.owner, "packet:1") end)
      assert :ok = run(c, fn -> ExternalReportOwner.finish(c.owner, "packet:1") end)

      assert {:error, :profiles_producer_unavailable} =
               publish(c, "packet:2", Map.put(r, "sequence", "8"))
    after
      true = :code.add_patha(String.to_charlist(directory))
      {:module, ^module} = :code.load_binary(module, path, beam)
    end
  end

  test "exact encoded byte ceiling is inclusive and does not round the receipt clock" do
    c = setup_owner()
    r = report(c)
    {:ok, document} = Wotex.JSON.encode(r)
    size = byte_size(document)
    :sys.replace_state(c.owner, &%{&1 | max_bytes: size})
    assert {:ok, _} = publish(c, "exact", r)
    assert :ok = ExternalReportOwner.cancel(c.owner, "exact")
    :sys.replace_state(c.owner, &%{&1 | max_bytes: size - 1})
    assert {:error, :external_report_capacity} = publish(c, "over", Map.put(r, "sequence", "8"))
    assert :not_found = ExternalReportOwner.status(c.owner, "over")
  end

  test "timer retires abandoned bodies without needing a status call" do
    c = setup_owner(ttl_ms: 100)
    {:ok, _} = publish(c, "packet:1", report(c))
    Process.sleep(250)
    state = :sys.get_state(c.owner)
    assert state.entries["packet:1"].state == :expired
    assert state.entries["packet:1"].document == nil
  end

  test "publisher loss stops the owner normally without supervising a dead publisher restart" do
    c = setup_owner()
    stop_supervised(ExternalReportOwner)

    publisher =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, owner} =
      ExternalReportOwner.start_link(
        publisher: publisher,
        source_owner: c.source,
        store_owner: @receiver
      )

    monitor = Process.monitor(owner)
    Process.exit(publisher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1000
    refute Process.alive?(owner)
  end

  test "nullable and maximum unsigned sequences are preserved without inventing continuity" do
    c = setup_owner(name: nil)
    r = report(c, %{"sequence" => nil, "continuity" => "unknown"})
    assert {:ok, %{"sequence" => nil}} = publish(c, "null:1", r)
    assert {:ok, %{"sequence" => nil}} = publish(c, "null:2", r)
    maximum = Map.put(r, "sequence", "18446744073709551615")
    assert {:ok, %{"sequence" => "18446744073709551615"}} = publish(c, "maximum", maximum)
    assert {:error, :external_report_duplicate} = publish(c, "repeat", maximum)
    assert {:ok, borrowed} = run(c, fn -> ExternalReportOwner.checkout(c.owner, "maximum") end)
    assert borrowed.report["continuity"] == "unknown"
    assert borrowed.report["sequence"] == "18446744073709551615"
  end
end
