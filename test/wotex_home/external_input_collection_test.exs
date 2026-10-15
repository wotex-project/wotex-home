Code.require_file(Path.expand("../support/external_input_store_fixture.exs", __DIR__))
Code.require_file(Path.expand("../support/external_input_review_fixture.exs", __DIR__))

defmodule WotexHome.ExternalInputCollectionTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.ExternalInputStoreFixture, as: F
  alias WotexHome.ExternalInputReviewFixture, as: R
  alias WotexHome.Profiles.ExternalReportOwner

  defmodule ReportProbe do
    @moduledoc false

    use GenServer
    def start_link(input), do: GenServer.start_link(__MODULE__, input)
    @impl true
    def init(input), do: {:ok, input}
    @impl true
    def handle_call(:clock, _, {clock, _} = state), do: {:reply, {:ok, clock}, state}
    def handle_call({:lifetime, _, _}, _, {_, response} = state), do: {:reply, response, state}

    def handle_call({:current, _, _, _, _}, _, {_, response} = state),
      do: {:reply, response, state}
  end

  setup tags do
    keys = R.keys()
    c = F.setup() |> Map.merge(keys)

    F.prepare(c,
      case_keys: keys.case_keys,
      decision_keys: keys.decision_keys,
      report_ttl_ms: tags[:report_ttl_ms] || 60_000
    )
  end

  test "actual current reader report and consumed lifetime yield one read-only qualified snapshot",
       c do
    review = R.review(c, "collection", "sample", freshness_ms: 5000)

    assert {:ok, installed} =
             Authority.change_external_routine_input(c.authority, c.credential, R.install(review))

    assert {:ok, clock} = ExternalReportOwner.receipt_clock(c.reports)

    report =
      F.fixture("external-transport-reports")["temperature"]["report"]
      |> Map.put("receipt_time", clock)
      |> Map.put("continuity", "baseline")
      |> Map.put("source_ref", c.selection.data["source_ref"])
      |> Map.put("source_epoch", c.selection.data["source_epoch"])

    assert {:ok, published} =
             ExternalReportOwner.publish(
               c.reports,
               "report:current",
               c.selection.data["source_ref"],
               c.selection.sha256,
               report
             )

    assert {:ok, observed} =
             Authority.accept_external_report(c.authority, %{
               "report_owner_epoch" => published["owner_epoch"],
               "report_id" => "report:current"
             })

    {:ok, credential, _} =
      Store.provision_principal(c.store, "collector:read-only", ~w(rule:review read), [
        "sensor:external"
      ])

    c = %{c | credential: credential}
    before = retained(c)
    assert {:ok, result} = collect(c, [scope("sample")])
    assert result["scope"] == "qualified_external_input_snapshot_only"
    assert result["store_boot_epoch"] == installed["store_boot_epoch"]
    assert [item] = result["items"]
    assert item["reason"] == nil
    assert item["install_revision"] == installed["revision"]
    assert item["report_revision"] == observed["revision"]
    assert item["report_ref"]["report_sha256"] == published["report_sha256"]
    assert item["projection"]["fact"]["received_at"] == nil
    assert item["projection"]["fact"]["continuity"] == "baseline"
    assert item["projection"]["fact"]["receipt_ms"] == observed["received_store_ms"]
    assert item["projection"]["fact"]["expires_ms"] == observed["received_store_ms"] + 5000
    assert item["owner_expires_ms"] > item["projection"]["fact"]["expires_ms"]
    assert retained(c) == before
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "complete absent 32-member scope performs no private calls and retains explicit nulls",
       c do
    :ok = :sys.suspend(c.sources)
    :ok = :sys.suspend(c.custody)
    before = retained(c)

    try do
      items =
        for n <- 1..32, do: scope("missing:" <> String.pad_leading(Integer.to_string(n), 2, "0"))

      assert {:ok, result} = collect(c, items)
      assert length(result["items"]) == 32
      assert Enum.all?(result["items"], &(&1["reason"] == "input_not_installed"))
      assert Enum.all?(result["items"], &(&1["binding_basis"] == nil and &1["report_ref"] == nil))
    after
      :ok = :sys.resume(c.sources)
      :ok = :sys.resume(c.custody)
    end

    assert retained(c) == before
  end

  test "malformed and foreign scope refuses wholly before private reads", c do
    :ok = :sys.suspend(c.sources)
    :ok = :sys.suspend(c.custody)

    try do
      for bad <- [
            [],
            [scope("sample"), scope("sample")],
            [scope("z"), scope("a")],
            [%{"target_id" => "sensor:external"}],
            [scope("sample") | :bad]
          ] do
        assert {:error, :invalid_external_input} = collect(c, bad)
      end

      assert {:error, :external_input_limit} = collect(c, Enum.map(1..33, &scope("key:#{&1}")))
      assert {:error, :unauthorized} = collect(%{c | credential: <<0>>}, [scope("sample")])

      foreign = [
        %{"target_id" => "foreign:target", "capability_key" => "sample"},
        scope("sample")
      ]

      assert {:error, :permission_denied} = collect(c, foreign)
      assert :sys.get_state(c.store).writable
    after
      :ok = :sys.resume(c.sources)
      :ok = :sys.resume(c.custody)
    end
  end

  test "actual report qualities and continuity retain unavailable meaning and exact original clocks",
       c do
    install(c)

    variants = [
      {nil, "usable", "baseline", "missing_sequence"},
      {"1", "usable", "continuous", nil},
      {"2", "usable", "retained", "retained"},
      {"3", "usable", "replayed", "replayed"},
      {"4", "usable", "gap", "gap"},
      {"5", "usable", "unknown", "baseline_required"},
      {"6", "unknown", "continuous", "unknown"},
      {"7", "invalid", "continuous", "invalid"},
      {"8", "stale", "continuous", "stale"},
      {"9223372036854775808", "usable", "gap", "unsupported_external_input"}
    ]

    for {{sequence, quality, continuity, expected}, n} <- Enum.with_index(variants) do
      observed =
        publish(c, "matrix:#{n}", %{
          "sequence" => sequence,
          "quality" => quality,
          "continuity" => continuity
        })

      before = retained(c)
      assert {:ok, result} = collect(c, [scope("sample")])
      assert [item] = result["items"]
      assert item["reason"] == expected
      assert item["report_revision"] == observed["revision"]
      assert item["binding_basis"] != nil

      if expected in ["missing_sequence", "baseline_required", "unsupported_external_input"] do
        assert item["projection"] == nil
      else
        assert item["projection"]["fact"]["receipt_ms"] == observed["received_store_ms"]
        assert item["projection"]["fact"]["quality"] == quality
        if quality != "usable", do: assert(item["projection"]["fact"]["value"] == nil)
      end

      assert retained(c) == before
    end
  end

  test "qualified binding remains explicit without a report, then revoke and restart stay unavailable",
       c do
    installed = install(c)
    assert {:ok, %{"items" => [item]}} = collect(c, [scope("sample")])
    assert item["reason"] == "missing_report"
    assert item["binding_basis"] != nil
    assert item["projection"] == nil and item["report_ref"] == nil

    assert {:ok, _} =
             Authority.change_external_routine_input(
               c.authority,
               c.credential,
               R.revoke(installed)
             )

    assert {:ok, %{"items" => [revoked]}} = collect(c, [scope("sample")])
    assert revoked["reason"] == "input_revoked"
    assert revoked["install_revision"] == installed["revision"]
    assert revoked["selection_revision"] == nil and revoked["binding_basis"] == nil
  end

  test "actual Store restart cannot make a retained installed package current", c do
    install(c)
    c = F.restart(c)
    :ok = :sys.suspend(c.sources)

    try do
      assert {:ok, %{"items" => [item]}} = collect(c, [scope("sample")])
      assert item["reason"] == "old_store_boot"
      assert item["selection_revision"] == nil
      assert item["binding_basis"] == nil
    after
      :ok = :sys.resume(c.sources)
    end
  end

  test "removed reviewer keys never borrow historical qualification", c do
    install(c)
    :sys.replace_state(c.store, &%{&1 | qualification_case_keys: %{}})
    assert {:ok, %{"items" => [item]}} = collect(c, [scope("sample")])
    assert item["reason"] == "input_unqualified"
    assert item["binding_basis"] == nil and item["report_ref"] == nil
    assert :sys.get_state(c.store).writable
  end

  test "a responsive source's replacement is unavailable without changing durable installation",
       c do
    install(c)
    before = retained(c)
    replace_source(c)
    assert {:ok, %{"items" => [item]}} = collect(c, [scope("sample")])
    assert item["reason"] == "source_unavailable"
    assert item["binding_basis"] == nil
    assert retained(c) == before
    assert :sys.get_state(c.store).writable
  end

  test "missing private object is a stable unavailable item with no invented reconstruction", c do
    install(c)
    [file | _] = File.ls!(c.custody_root)
    File.rm!(Path.join(c.custody_root, file))
    assert {:ok, %{"items" => [item]}} = collect(c, [scope("sample")])
    assert item["reason"] == "input_basis_changed"
    assert item["projection"] == nil
    assert :sys.get_state(c.store).writable
  end

  test "a hung owner refuses the whole scope under the shared budget", c do
    install(c)
    before = retained(c)
    :ok = :sys.suspend(c.sources)
    started = System.monotonic_time(:millisecond)

    try do
      assert {:error, :external_input_unavailable} =
               collect(c, [scope("missing"), scope("sample")])

      assert System.monotonic_time(:millisecond) - started < 11_000
    after
      :ok = :sys.resume(c.sources)
    end

    assert retained(c) == before
    assert :sys.get_state(c.store).writable
  end

  test "source replacement during actual private reads refuses the whole collection", c do
    install(c)
    before = retained(c)
    custody = c.custody
    :ok = :sys.suspend(custody)
    :erlang.trace(custody, true, [:receive])
    task = Task.async(fn -> collect(c, [scope("missing"), scope("sample")]) end)

    try do
      assert_receive {:trace, ^custody, :receive, {:"$gen_call", _, {:read_object, _}}}, 2000
      replace_source(c)
    after
      :erlang.trace(custody, false, [:receive])
      :ok = :sys.resume(custody)
    end

    assert {:error, :external_input_basis_changed} = Task.await(task, 5000)
    assert retained(c) == before
    assert :sys.get_state(c.store).writable
  end

  @tag report_ttl_ms: 2500
  test "owner expiry between passes preserves the original cap and uses one final sample", c do
    install(c)
    observed = publish(c, "expiring:original")
    entry = :sys.get_state(c.reports).entries["expiring:original"]
    {_received, deadline} = entry.lifetime
    reports = c.reports
    custody = c.custody
    :erlang.trace(reports, true, [:receive])
    task = Task.async(fn -> collect(c, [scope("sample")]) end)

    try do
      assert_receive {:trace, ^reports, :receive, {:"$gen_call", _, {:lifetime, _, _}}}, 2000
      :ok = :sys.suspend(custody)
      :erlang.trace(custody, true, [:receive])
      assert_receive {:trace, ^custody, :receive, {:"$gen_call", _, {:read_object, _}}}, 2000

      remaining =
        max(0, -Integer.floor_div(-(deadline - System.monotonic_time(:microsecond)), 1000) + 1)

      assert remaining < 3000
      Process.sleep(remaining)
    after
      :erlang.trace(reports, false, [:receive])
      :erlang.trace(custody, false, [:receive])
      :ok = :sys.resume(custody)
    end

    assert {:ok, result} = Task.await(task, 5000)
    assert [item] = result["items"]
    assert item["reason"] == "expired"
    assert result["sampled_ms"] >= item["owner_expires_ms"]
    assert item["projection"]["fact"]["receipt_ms"] == observed["received_store_ms"]
    assert item["projection"]["fact"]["expires_ms"] == item["owner_expires_ms"]
  end

  test "corrupt retained originals refuse the complete scope and fence writes", c do
    install(c)
    publish(c, "corrupt:original")
    db = :sys.get_state(c.store).db

    assert {:ok, []} =
             SQL.query(db, "UPDATE profile_external_observations SET receipt_document='[]'")

    assert {:error, :corrupt_external_observations} = collect(c, [scope("sample")])
    refute :sys.get_state(c.store).writable
  end

  test "null source UTC stays null and never supplies receipt UTC", c do
    review =
      R.review(c, "null-source-clock", "sample",
        freshness_ms: 5000,
        require_source_time: false,
        source_time_basis: nil
      )

    assert {:ok, _} =
             Authority.change_external_routine_input(c.authority, c.credential, R.install(review))

    observed = publish(c, "null-source-clock:original", %{"source_time" => nil})
    assert {:ok, result} = collect(c, [scope("sample")])
    assert [item] = result["items"]
    assert item["reason"] == nil
    fact = item["projection"]["fact"]
    assert fact["receipt_ms"] == observed["received_store_ms"]
    assert fact["source_time"] == nil
    assert fact["source_time_basis"] == nil
    assert fact["source_time_trust"] == "unknown"
    assert fact["source_uncertainty_ms"] == nil
    assert fact["received_at"] == nil
  end

  test "malformed owner results refuse the complete scope without fencing writes", c do
    install(c)
    publish(c, "malformed:original")
    {:ok, clock} = ExternalReportOwner.receipt_clock(c.reports)
    entry = :sys.get_state(c.reports).entries["malformed:original"]
    {received, deadline} = entry.lifetime

    # Start from an actual consumed original, then falsify the owner boundary.
    # This probe is deliberately not an alternative source of live evidence.
    witness =
      Map.take(
        entry.summary,
        ~w(owner_epoch report_id source_owner_epoch source_ref source_selection_sha256 channel_id source_epoch sequence report_sha256 state)
      )
      |> Map.merge(%{
        "format" => "wotex-home.external-report-lifetime@1",
        "receipt_monotonic_us" => Integer.to_string(received),
        "expires_at_us" => Integer.to_string(deadline)
      })

    before = retained(c)

    for bad <- [
          Map.put(witness, "extra", true),
          Map.put(witness, "receipt_monotonic_us", nil),
          Map.put(witness, "expires_at_us", "-0"),
          Map.put(witness, "sequence", 7),
          Map.put(witness, "channel_id", nil),
          Map.put(witness, "owner_epoch", "bad")
        ] do
      probe = start_supervised!({ReportProbe, {clock, {:ok, bad}}})
      :sys.replace_state(c.store, &%{&1 | external_report_owner: probe})

      try do
        assert {:error, :external_input_unavailable} =
                 collect(c, [scope("missing"), scope("sample")])
      after
        :sys.replace_state(c.store, &%{&1 | external_report_owner: c.reports})
        stop_supervised!(ReportProbe)
      end

      assert :sys.get_state(c.store).writable
      assert retained(c) == before
    end

    for epoch <- [nil, String.duplicate("0", 32)] do
      malformed_source = %{
        selection: c.selection,
        guard: %{
          owner_epoch: epoch,
          source_ref: c.selection.data["source_ref"],
          source_selection_sha256: c.selection.sha256
        }
      }

      probe = start_supervised!({ReportProbe, {clock, {:ok, malformed_source}}})
      :sys.replace_state(c.store, &%{&1 | external_source_owner: probe})

      try do
        assert {:error, :external_input_unavailable} = collect(c, [scope("sample")])
      after
        :sys.replace_state(c.store, &%{&1 | external_source_owner: c.sources})
        stop_supervised!(ReportProbe)
      end

      assert :sys.get_state(c.store).writable
      assert retained(c) == before
    end
  end

  test "typed invalid original clock stays an invalid item and never renews the report", c do
    install(c)
    publish(c, "invalid-clock:original")

    :sys.replace_state(c.reports, fn state ->
      update_in(state.entries["invalid-clock:original"].lifetime, fn {received, deadline} ->
        {received, deadline + 1}
      end)
    end)

    before = retained(c)
    assert {:ok, result} = collect(c, [scope("sample")])
    assert [item] = result["items"]
    assert item["reason"] == "invalid"
    assert item["owner_expires_ms"] == nil and item["projection"] == nil
    assert :sys.get_state(c.store).writable
    assert retained(c) == before
  end

  test "an exited report owner refuses the whole scope and leaves the writer usable", c do
    install(c)
    publish(c, "owner-exit:original")
    before = retained(c)
    stop_supervised!(ExternalReportOwner)

    assert {:error, :external_input_unavailable} =
             collect(c, [scope("missing"), scope("sample")])

    assert :sys.get_state(c.store).writable
    assert retained(c) == before
  end

  defp install(c) do
    review = R.review(c, "collection", "sample", freshness_ms: 5000)

    assert {:ok, receipt} =
             Authority.change_external_routine_input(c.authority, c.credential, R.install(review))

    receipt
  end

  defp publish(c, id, changes \\ %{}) do
    {:ok, clock} = ExternalReportOwner.receipt_clock(c.reports)

    report =
      F.fixture("external-transport-reports")["temperature"]["report"]
      |> Map.merge(%{
        "receipt_time" => clock,
        "continuity" => "baseline",
        "source_ref" => c.selection.data["source_ref"],
        "source_epoch" => c.selection.data["source_epoch"]
      })
      |> Map.merge(changes)

    {:ok, published} =
      ExternalReportOwner.publish(
        c.reports,
        id,
        c.selection.data["source_ref"],
        c.selection.sha256,
        report
      )

    assert {:ok, receipt} =
             Authority.accept_external_report(c.authority, %{
               "report_owner_epoch" => published["owner_epoch"],
               "report_id" => id
             })

    receipt
  end

  defp replace_source(c) do
    {:ok, newer} =
      WotexHome.Profiles.ExternalSourceSelection.new(
        Map.put(c.selection.inputs["source"], "source_generation", 2),
        c.selection.inputs["reader"],
        c.selection.inputs["channels"]
      )

    assert {:ok, _} = WotexHome.Profiles.ExternalSourceOwner.publish(c.sources, newer)
  end

  defp collect(c, scope), do: Authority.external_routine_facts(c.authority, c.credential, scope)
  defp scope(key), do: %{"target_id" => "sensor:external", "capability_key" => key}

  defp retained(c) do
    db = :sys.get_state(c.store).db

    for table <-
          ~w(meta routine_external_input_operations routine_external_input_history routine_external_input_current profile_external_observations profile_external_observation_current request_receipts authority_journal),
        into: %{} do
      {:ok, rows} = SQL.query(db, "SELECT * FROM " <> table <> " ORDER BY rowid")
      {table, rows}
    end
  end
end
