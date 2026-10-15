Code.require_file(Path.expand("../support/external_report_lifetime_fixture.exs", __DIR__))

defmodule WotexHome.ExternalReportLifetimeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.ExternalReportLifetimeFixture, as: F
  alias WotexHome.Profiles.{ExternalReportOwner, ExternalSourceOwner}

  for family <- ~w(temperature research multi) do
    @family family
    test "#{@family} actual consumed witness preserves the original pair and releases bodies" do
      c = owner(@family)
      assert {:ok, receipt} = publish(c)
      assert {:ok, borrowed} = ExternalReportOwner.checkout(c.owner, "report:1")
      assert :ok = ExternalReportOwner.finish(c.owner, "report:1")
      assert {:ok, witness} = lifetime(c)

      expected =
        receipt
        |> Map.put("state", "consumed")
        |> Map.merge(%{
          "format" => "wotex-home.external-report-lifetime@1",
          "receipt_monotonic_us" => c.report["receipt_time"]["monotonic_us"],
          "expires_at_us" => Integer.to_string(borrowed.guard.receipt_monotonic_us + 60_000_000)
        })

      assert witness == expected
      assert map_size(witness) == 13
      assert {:ok, ^witness} = lifetime(c)
      assert {:ok, consumed} = ExternalReportOwner.status(c.owner, "report:1")
      assert consumed == Map.put(receipt, "state", "consumed")
      assert {:ok, ^consumed} = publish(c)
      assert :ok = ExternalReportOwner.finish(c.owner, "report:1")

      assert {:error, :external_report_retired} =
               ExternalReportOwner.checkout(c.owner, "report:1")

      assert {:error, :external_report_duplicate} = publish(c, "report:2")

      entry = :sys.get_state(c.owner).entries["report:1"]
      assert entry.report == nil and entry.document == nil and entry.received == nil
      assert entry.deadline == nil and entry.caller == nil and entry.monitor == nil
      assert entry.lifetime == {borrowed.guard.receipt_monotonic_us, borrowed.guard.expires_at_us}
      refute inspect(:sys.get_status(c.owner)) =~ "receipt_monotonic_us"
    end
  end

  test "caller, original state and closed owner identity are checked independently" do
    c = owner("temperature")

    assert {:error, :external_report_store_denied} =
             Task.async(fn -> lifetime(c) end) |> Task.await()

    for {epoch, id} <- [{nil, "report:1"}, {c.epoch, %{}}, {"bad", "report:1"}] do
      assert {:error, :invalid_external_report_lease} =
               ExternalReportOwner.lifetime(c.owner, epoch, id)
    end

    assert {:error, :external_report_owner_changed} =
             ExternalReportOwner.lifetime(c.owner, String.duplicate("0", 32), "missing")

    assert :not_found = lifetime(c)
    assert {:ok, _} = publish(c)
    assert {:error, :external_report_not_consumed} = lifetime(c)
    assert {:ok, _} = ExternalReportOwner.checkout(c.owner, "report:1")
    assert {:error, :external_report_not_consumed} = lifetime(c)
    assert :ok = ExternalReportOwner.finish(c.owner, "report:1")
    assert {:ok, _} = lifetime(c)
  end

  test "unauthorized lifetime reads refuse without calling an unavailable source" do
    c = owner("temperature")
    assert {:ok, _} = publish(c)
    :sys.suspend(c.source)

    try do
      assert {:error, :external_report_store_denied} =
               Task.async(fn -> lifetime(c) end) |> Task.await(500)
    after
      :sys.resume(c.source)
    end
  end

  test "cancelled originals never retain or expose an original lifetime" do
    c = owner("temperature")
    assert {:ok, _} = publish(c)
    assert :ok = ExternalReportOwner.cancel(c.owner, "report:1")
    assert {:error, :external_report_retired} = lifetime(c)
    assert :sys.get_state(c.owner).entries["report:1"].lifetime == nil
  end

  test "source owner loss terminates lifetime custody instead of restoring a witness" do
    c = owner("temperature")
    assert {:ok, _} = publish(c)
    assert {:ok, _} = ExternalReportOwner.checkout(c.owner, "report:1")
    assert :ok = ExternalReportOwner.finish(c.owner, "report:1")
    monitor = Process.monitor(c.owner)
    GenServer.stop(c.source)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert catch_exit(lifetime(c))
  end

  test "source replacement refuses consumed lifetime without rewriting the original" do
    c = owner("temperature")
    assert {:ok, _} = publish(c)
    assert {:ok, _} = ExternalReportOwner.checkout(c.owner, "report:1")
    assert :ok = ExternalReportOwner.finish(c.owner, "report:1")
    assert {:ok, witness} = lifetime(c)

    next =
      F.selection("temperature", %{
        "source_generation" => c.selection.data["source_generation"] + 1
      })

    assert {:ok, _} = ExternalSourceOwner.publish(c.source, next)
    assert {:error, :external_report_retired} = lifetime(c)
    assert :ok = ExternalReportOwner.finish(c.owner, "report:1")
    assert {:ok, original} = ExternalReportOwner.status(c.owner, "report:1")
    assert original["state"] == "consumed"
    assert original["source_selection_sha256"] == witness["source_selection_sha256"]
  end

  test "the configured Store name resolves its current incarnation without transferring authority" do
    name = __MODULE__.Store
    Process.register(self(), name)
    c = owner("temperature", store_owner: name)
    assert {:ok, _} = publish(c)
    assert {:ok, _} = ExternalReportOwner.checkout(c.owner, "report:1")
    assert :ok = ExternalReportOwner.finish(c.owner, "report:1")
    assert {:ok, witness} = lifetime(c)
    Process.unregister(name)
    assert {:error, :external_report_store_denied} = lifetime(c)

    assert {:ok, ^witness} =
             Task.async(fn ->
               Process.register(self(), name)
               lifetime(c)
             end)
             |> Task.await()
  end

  test "malformed private clock pairs refuse rather than wrap or invent a deadline" do
    c = owner("temperature")
    assert {:ok, _} = publish(c)
    assert {:ok, borrowed} = ExternalReportOwner.checkout(c.owner, "report:1")
    assert :ok = ExternalReportOwner.finish(c.owner, "report:1")
    r = borrowed.guard.receipt_monotonic_us

    for pair <- [
          nil,
          {r, r + 99_000},
          {r, r + 100_001},
          {r, r + 60_001_000},
          {-9_223_372_036_854_775_809, -9_223_372_036_854_675_809},
          {9_223_372_036_854_675_808, 9_223_372_036_854_775_808}
        ] do
      :sys.replace_state(c.owner, fn state -> put_in(state.entries["report:1"].lifetime, pair) end)

      assert {:error, :invalid_external_report_clock} = lifetime(c)
    end
  end

  test "isolated actual owners match all frozen signed and exact exclusive deadline vectors" do
    script = ~S'''
    Code.require_file("test/support/external_report_lifetime_fixture.exs")
    alias WotexHome.ExternalReportLifetimeFixture, as: F
    alias WotexHome.Profiles.{ExternalReportOwner, ExternalSourceOwner}
    Code.compiler_options(ignore_module_conflict: true)
    source = File.read!("lib/wotex_home/profiles/external_report_owner.ex")
    marker = "  defp now, do: System.monotonic_time(:microsecond)"
    2 = length(String.split(source, marker))
    nonce = "  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)"
    2 = length(String.split(source, nonce))
    source = source |> String.replace(marker, "  defp now, do: :persistent_term.get(:report_lifetime_clock)")
      |> String.replace(nonce, "  defp nonce, do: String.duplicate(\"f\", 32)")
    Code.compile_string(source)
    source = File.read!("lib/wotex_home/profiles/external_source_owner.ex")
    2 = length(String.split(source, nonce))
    Code.compile_string(String.replace(source, nonce, "  defp nonce, do: String.duplicate(\"a\", 32)"))
    for {family, vector} <- F.read("external-report-lifetimes")["families"] do
      :persistent_term.put(:report_lifetime_clock, -5)
      selection = F.selection(family)
      {:ok, source} = ExternalSourceOwner.start_link(publisher: self())
      {:ok, _} = ExternalSourceOwner.publish(source, selection)
      {:ok, owner} = ExternalReportOwner.start_link(publisher: self(), source_owner: source, store_owner: self())
      report = F.read("external-transport-reports")[family]["report"]
      {:ok, _} = ExternalReportOwner.publish(owner, "report:1", selection.data["source_ref"], selection.sha256, report)
      {:ok, _} = ExternalReportOwner.checkout(owner, "report:1")
      :ok = ExternalReportOwner.finish(owner, "report:1")
      expected = vector["expected"]
      {:ok, ^expected} = ExternalReportOwner.lifetime(owner, String.duplicate("f", 32), "report:1")
      for row <- vector["checks"] do
        :persistent_term.put(:report_lifetime_clock, String.to_integer(row["now_us"]))
        result = ExternalReportOwner.lifetime(owner, String.duplicate("f", 32), "report:1")
        if row["expected"] == "live", do: ({:ok, ^expected} = result), else: ({:error, :external_report_retired} = result)
      end
      :ok = ExternalReportOwner.finish(owner, "report:1")
      {:ok, %{"state" => "consumed"}} = ExternalReportOwner.publish(owner, "report:1", selection.data["source_ref"], selection.sha256, report)
      GenServer.stop(owner)
      GenServer.stop(source)
    end
    IO.puts("three complete frozen witnesses and nine exclusive deadline probes passed")
    '''

    assert isolated(script) ==
             {"three complete frozen witnesses and nine exclusive deadline probes passed\n", 0}
  end

  test "consumed lifetime needs no reader producer and owner restart cannot restore it" do
    script = ~S'''
    Code.require_file("test/support/external_report_lifetime_fixture.exs")
    alias WotexHome.ExternalReportLifetimeFixture, as: F
    alias WotexHome.Profiles.{ExternalReportOwner, ExternalSourceOwner}
    selection = F.selection("temperature")
    {:ok, source} = ExternalSourceOwner.start_link(publisher: self())
    {:ok, _} = ExternalSourceOwner.publish(source, selection)
    {:ok, owner} = ExternalReportOwner.start_link(publisher: self(), source_owner: source, store_owner: self())
    {:ok, clock} = ExternalReportOwner.receipt_clock(owner)
    report = Map.put(F.read("external-transport-reports")["temperature"]["report"], "receipt_time", clock)
    {:ok, _} = ExternalReportOwner.publish(owner, "report:1", selection.data["source_ref"], selection.sha256, report)
    {:ok, _} = ExternalReportOwner.checkout(owner, "report:1")
    directory = Wotex.JSON |> :code.which() |> List.to_string() |> Path.dirname() |> String.to_charlist()
    true = :code.del_path(directory)
    :code.purge(Wotex.JSON)
    :code.delete(Wotex.JSON)
    false = Code.ensure_loaded?(Wotex.JSON)
    :ok = ExternalReportOwner.finish(owner, "report:1")
    {:ok, witness} = ExternalReportOwner.lifetime(owner, clock["epoch"], "report:1")
    true = witness["receipt_monotonic_us"] == clock["monotonic_us"]
    GenServer.stop(owner)
    {:ok, replacement} = ExternalReportOwner.start_link(publisher: self(), source_owner: source, store_owner: self())
    {:ok, next} = ExternalReportOwner.receipt_clock(replacement)
    true = next["epoch"] != clock["epoch"]
    {:error, :external_report_owner_changed} = ExternalReportOwner.lifetime(replacement, clock["epoch"], "report:1")
    :not_found = ExternalReportOwner.lifetime(replacement, next["epoch"], "report:1")
    IO.puts("producer-free lifetime and empty replacement verified")
    '''

    assert isolated(script) == {"producer-free lifetime and empty replacement verified\n", 0}
  end

  defp owner(family, options \\ []) do
    source = start_supervised!({ExternalSourceOwner, publisher: self()})
    selection = F.selection(family)
    {:ok, _} = ExternalSourceOwner.publish(source, selection)

    owner =
      start_supervised!(
        {ExternalReportOwner,
         Keyword.merge([publisher: self(), source_owner: source, store_owner: self()], options)}
      )

    {:ok, clock} = ExternalReportOwner.receipt_clock(owner)

    report =
      Map.put(F.read("external-transport-reports")[family]["report"], "receipt_time", clock)

    %{source: source, selection: selection, owner: owner, epoch: clock["epoch"], report: report}
  end

  defp publish(c, id \\ "report:1"),
    do:
      ExternalReportOwner.publish(
        c.owner,
        id,
        c.selection.data["source_ref"],
        c.selection.sha256,
        c.report
      )

  defp lifetime(c), do: ExternalReportOwner.lifetime(c.owner, c.epoch, "report:1")

  defp isolated(script) do
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
    System.cmd(System.find_executable("elixir"), paths ++ ["-e", script], stderr_to_stdout: true)
  end
end
