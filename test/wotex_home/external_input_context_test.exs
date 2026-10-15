Code.require_file(Path.expand("../support/external_input_store_fixture.exs", __DIR__))

defmodule WotexHome.ExternalInputContextTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.ExternalInputStoreFixture, as: F
  alias WotexHome.Profiles.{ExternalSourceOwner, ExternalSourceSelection, ProducerIdentity}
  alias WotexHome.Rules.ExternalInputRuntime

  setup do
    F.setup()
  end

  test "actual selected private reader returns a stable closed context without creating authority",
       c do
    c = F.prepare(c)
    before = state(c)
    sources_before = :sys.get_state(c.sources)
    assert {:ok, context} = context(c)
    assert context["format"] == "wotex-home.external-input-context@1"
    assert context["target_id"] == "sensor:external"
    assert context["capability_key"] == "sample"
    assert context["selection_revision"] == c.selected["revision"]
    assert context["binding_revision"] == c.selected["revision"]
    assert context["resource_revision"] == c.selected["resource_revision"]
    assert context["trust_revision"] == c.trust["revision"]
    assert context["policy_generation"] == c.trust["policy_generation"]
    assert context["selection_author"] == "operator:1"
    assert context["trust_author"] == "operator:1"
    assert context["source_selection_sha256"] == c.selection.sha256
    assert context["stable_id_sha256"] == c.selection.data["stable_id_sha256"]
    assert context["source_trust"] == "authenticated_device"
    assert context["reader_limits"] == c.reader.inputs["reader_limits"]
    assert context["declaration"]["value_kind"] == "integer"
    assert context["declaration"]["unit"]["scale_d"] == "1000"
    assert context["reader"]["external_unit"]["scale_d"] == "1"
    assert context["reader"]["value_schema"] == %{"type" => "number"}
    assert context["reader"]["channel_id"] == "sample"
    assert context["reader"]["reader_contract_ref"] == Wotex.Profiles.Proposal.identity()
    assert {:ok, producer} = ProducerIdentity.current()
    assert context["declaration"]["producer"] == producer
    assert context["runtime"]["profiles"] == producer
    assert :ok = ExternalInputRuntime.check_current(context["runtime"], context["runtime_sha256"])

    assert context["receipt_clock"] == %{
             "format" => "wotex.routines.receipt-clock@1",
             "projection" => "floor_millisecond",
             "source_epoch" => context["report_owner_epoch"],
             "source_origin_us" => Integer.to_string(1000 * before.clock_origin),
             "target_epoch" => before.clock_epoch,
             "target_origin_ms" => 0
           }

    refute Map.has_key?(context, "store_revision")
    refute Map.has_key?(context, "stable_id")
    assert {:ok, ^context} = context(c)
    assert state(c) == before
    assert :sys.get_state(c.custody).leases == %{}
    assert :sys.get_state(c.sources).entries == sources_before.entries
    assert :sys.get_state(c.sources).tokens == sources_before.tokens

    assert {:ok, [[0, 0, 0]]} =
             SQL.query(
               before.db,
               "SELECT (SELECT COUNT(*) FROM routine_external_input_operations),(SELECT COUNT(*) FROM routine_external_input_history),(SELECT COUNT(*) FROM routine_external_input_current)"
             )

    assert :ok = Integrity.validate_snapshot(before.db)
  end

  test "unrelated durable revisions do not invalidate a review context", c do
    c = F.prepare(c)
    assert {:ok, original} = context(c)
    assert {:ok, _, _} = Store.provision_principal(c.store, "unrelated:actor", ["read"], [])
    assert {:ok, ^original} = context(c)
  end

  test "all caller permissions and the target grant precede source and custody reads", c do
    c = F.prepare(c)

    for {permissions, targets} <- [
          {["qualify:profile", "read"], ["sensor:external"]},
          {["rule:review", "read"], ["sensor:external"]},
          {["qualify:profile", "rule:review"], ["sensor:external"]},
          {["qualify:profile", "rule:review", "read"], []}
        ] do
      id = "denied:" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, credential, _} =
        Store.provision_principal(c.store, id, permissions, ["sensor:external"])

      if targets == [], do: Store.revoke_target_grant(c.store, id, "sensor:external")
      :ok = :sys.suspend(c.sources)
      :ok = :sys.suspend(c.custody)

      try do
        assert {:error, :permission_denied} = context(%{c | credential: credential})
        assert {:error, :unauthorized} = context(%{c | credential: <<0>>})
        assert {:error, :unauthorized} = context(%{c | credential: :bad})
      after
        :ok = :sys.resume(c.sources)
        :ok = :sys.resume(c.custody)
      end
    end

    assert state(c).writable
  end

  test "the selector and approver need their own target grant even for an authorized caller", c do
    c = F.prepare(c, grant: false)

    {:ok, credential, _} =
      Store.provision_principal(
        c.store,
        "reviewer:1",
        ["qualify:profile", "rule:review", "read"],
        ["sensor:external"]
      )

    :ok = :sys.suspend(c.sources)

    try do
      assert {:error, :external_input_basis_changed} = context(%{c | credential: credential})
    after
      :ok = :sys.resume(c.sources)
    end

    assert state(c).writable
  end

  test "synthetic sources and archive-only producers cannot seed a current context", c do
    c = F.prepare(c, source: %{"trust" => "synthetic_lab"})
    assert {:error, :unsupported_external_input} = context(c)
    assert state(c).writable
  end

  test "a historical three-archive producer remains readable but cannot seed current input review",
       c do
    c = F.prepare(c, legacy: true)
    assert {:error, :external_input_unavailable} = context(c)
    assert state(c).writable
    assert :ok = Integrity.validate_snapshot(state(c).db)
  end

  test "multi-channel selection resolves the exact requested channel and rejects absent keys",
       c do
    c = F.prepare(c, family: "multi")
    assert {:ok, density} = context(c, "density")
    assert {:ok, sample} = context(c, "sample")
    assert density["reader"]["semantic_ref"] != sample["reader"]["semantic_ref"]
    assert density["source_selection_sha256"] == sample["source_selection_sha256"]
    assert density["receipt_clock"] == sample["receipt_clock"]
    assert {:error, :unsupported_external_input} = context(c, "absent")
    assert {:error, :invalid_external_input} = context(c, %{})
  end

  test "maintenance and unhealthy writers refuse before private owner calls", c do
    c = F.prepare(c)
    {:ok, revision} = Store.revision(c.store)
    {:ok, _} = Store.begin_maintenance(c.store, c.credential, 1, "maintenance:again", revision)
    :ok = :sys.suspend(c.sources)

    try do
      assert {:error, :maintenance_active} = context(c)
      :sys.replace_state(c.store, &%{&1 | writable: false})
      assert {:error, :store_unavailable} = context(c)
    after
      :ok = :sys.resume(c.sources)
    end
  end

  test "a missing boot selection cannot be recovered by replaying the original selection", c do
    c = F.prepare(c)
    assert {:ok, _} = context(c)
    old_boot = state(c).clock_epoch
    c = F.restart(c)
    refute state(c).clock_epoch == old_boot
    assert {:error, :external_input_basis_changed} = context(c)
    assert {:ok, original} = Store.change_external_target(c.store, c.operator_credential, c.input)
    assert original == c.selected
    assert {:error, :external_input_basis_changed} = context(c)
    assert state(c).writable
  end

  test "source replacement during private reads cannot return the opening context", c do
    c = F.prepare(c)
    :ok = :sys.suspend(c.custody)
    :erlang.trace(c.custody, true, [:receive])
    task = Task.async(fn -> context(c) end)
    custody = c.custody

    try do
      assert_receive {:trace, ^custody, :receive, {:"$gen_call", _, {:read_object, _}}}, 2000
      selection = c.selection

      {:ok, newer} =
        ExternalSourceSelection.new(
          Map.put(selection.inputs["source"], "source_generation", 2),
          selection.inputs["reader"],
          selection.inputs["channels"]
        )

      assert {:ok, _} = ExternalSourceOwner.publish(c.sources, newer)
    after
      :erlang.trace(c.custody, false, [:receive])
      :ok = :sys.resume(c.custody)
    end

    assert {:error, :external_input_basis_changed} = Task.await(task, 5000)
    assert state(c).writable
    assert :sys.get_state(c.custody).leases == %{}
  end

  test "missing private bytes, source owners and report owners never become a context", c do
    c = F.prepare(c)

    for field <- [:external_source_owner, :external_report_owner, :profile_custody] do
      original = state(c)[field]
      :sys.replace_state(c.store, &Map.put(&1, field, nil))
      assert {:error, :external_input_unavailable} = context(c)
      assert state(c).writable
      :sys.replace_state(c.store, &Map.put(&1, field, original))
    end

    [file | _] = File.ls!(c.custody_root)
    File.rm!(Path.join(c.custody_root, file))
    assert {:error, :external_input_unavailable} = context(c)
    assert state(c).writable
  end

  test "signed clock origin multiplication refuses overflow without changing Store history", c do
    c = F.prepare(c)
    :sys.replace_state(c.store, &%{&1 | clock_origin: 9_223_372_036_854_776})
    before = state(c)
    assert {:error, :external_input_limit} = context(c)
    assert state(c) == before
  end

  test "a hung owner fails within the preparation budget and leaves no custody work", c do
    c = F.prepare(c)
    before = state(c)
    :ok = :sys.suspend(c.sources)
    started = System.monotonic_time(:millisecond)

    try do
      assert {:error, :external_input_unavailable} = context(c)
      assert System.monotonic_time(:millisecond) - started < 10_000
      assert state(c) == before
      assert :sys.get_state(c.custody).leases == %{}
    after
      :ok = :sys.resume(c.sources)
    end

    assert {:ok, _} = context(c)
  end

  test "corrupt input history fences the writer even on this read-only use case", c do
    c = F.prepare(c)
    db = state(c).db

    assert :ok =
             Exqlite.Sqlite3.execute(
               db,
               "CREATE INDEX unexpected_input_index ON routine_external_input_current(target_id)"
             )

    assert {:error, :corrupt_external_inputs} = context(c)
    refute state(c).writable
    assert {:error, :store_unavailable} = context(c)
  end

  @tag timeout: 60_000
  test "each runtime group is remeasured after actual Store private preparation" do
    root =
      Path.join(
        System.tmp_dir!(),
        "woh-external-input-context-runtime-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    try do
      args =
        Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)]) ++
          [Path.expand("../support/external_input_context_runtime_probe.exs", __DIR__)]

      {output, status} =
        System.cmd(System.find_executable("elixir"), args,
          env: [{"WOH_INPUT_CONTEXT_RUNTIME_ROOT", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "4 tests, 0 failures"
    after
      File.rm_rf!(root)
    end

    refute File.exists?(root)
  end

  defp context(c, key \\ "sample"),
    do:
      Authority.external_routine_input_context(c.authority, c.credential, "sensor:external", key)

  defp state(c), do: :sys.get_state(c.store)
end
