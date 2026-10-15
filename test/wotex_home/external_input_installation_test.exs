Code.require_file(Path.expand("../support/external_input_store_fixture.exs", __DIR__))
Code.require_file(Path.expand("../support/external_input_review_fixture.exs", __DIR__))

defmodule WotexHome.ExternalInputInstallationTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{ExternalInputs, Integrity, SQL}
  alias WotexHome.ExternalInputStoreFixture, as: F
  alias WotexHome.ExternalInputReviewFixture, as: R
  alias WotexHome.Profiles.{ExternalSourceOwner, ExternalSourceSelection}
  alias WotexHome.Rules.{ExternalInputOperation, ExternalInputPackage}

  setup do
    keys = R.keys()
    c = F.setup() |> Map.merge(keys)
    F.prepare(c, case_keys: keys.case_keys, decision_keys: keys.decision_keys)
  end

  test "actual selected native context installs one exact reviewed package and original", c do
    review = R.review(c)

    assert {:ok, _} =
             ExternalInputPackage.verify(
               review.package,
               review.context,
               c.case_keys,
               c.decision_keys
             )

    input = R.install(review)
    {:ok, before} = Store.revision(c.store)
    assert {:ok, receipt} = change(c, input)
    assert receipt["revision"] == before + 1
    assert receipt["install_revision"] == receipt["revision"]
    assert receipt["generation"] == 1
    assert receipt["store_boot_epoch"] == review.context["store_boot_epoch"]

    assert {:ok, ^receipt} =
             Authority.external_routine_input_status(
               c.authority,
               c.credential,
               1,
               input["operation_id"]
             )

    assert {:ok, ^receipt} = change(c, input)
    db = db(c)

    assert {:ok, [[input_document, outcome_document, receipt_document]]} =
             SQL.query(
               db,
               "SELECT input_document,outcome_document,receipt_document FROM routine_external_input_operations"
             )

    assert {:ok, original} =
             ExternalInputOperation.validate_original(
               input_document,
               outcome_document,
               receipt_document
             )

    assert original["input"] == input
    assert original["outcome"]["package_document"] == review.package
    assert original["receipt"] == receipt
    assert {:ok, %{history_rows: 1}} = ExternalInputs.retirement_reserve(db)
    assert :ok = Integrity.validate_snapshot(db)
    assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM request_receipts")
  end

  test "producer-free replay, status and revoke preserve the installed original", c do
    review = R.review(c)
    input = R.install(review)
    {:ok, installed} = change(c, input)

    :sys.replace_state(
      c.store,
      &%{
        &1
        | external_source_owner: nil,
          external_report_owner: nil,
          profile_custody: nil,
          qualification_case_keys: %{},
          qualification_decision_keys: %{}
      }
    )

    assert {:ok, ^installed} = change(c, input)

    assert {:ok, ^installed} =
             Authority.external_routine_input_status(c.authority, c.credential, 1, "install:live")

    :sys.replace_state(c.store, &%{&1 | writable: false})
    assert {:ok, ^installed} = change(c, input)
    assert {:ok, ^installed} = status(c, "install:live")
    assert {:error, :store_unavailable} = change(c, R.revoke(installed))
    :sys.replace_state(c.store, &%{&1 | writable: true})

    assert {:ok, revoked} = change(c, R.revoke(installed))
    assert revoked["generation"] == 2
    assert revoked["install_revision"] == installed["revision"]
    assert revoked["action"] == "revoke"
    assert {:ok, ^installed} = change(c, input)
    assert {:ok, %{history_rows: 0, bytes: 0}} = ExternalInputs.retirement_reserve(db(c))
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "fresh originals check revision before generation and refuse absent or revoked slots", c do
    input = R.review(c) |> R.install()
    before = retained(db(c))

    assert {:error, :invalid_external_input} = change(c, %{input | "authority_epoch" => 2})

    assert {:error, :stale_external_input_revision} =
             change(c, %{input | "expected_install_revision" => 1, "expected_generation" => 1})

    assert {:error, :invalid_external_input} =
             change(c, %{input | "expected_generation" => 1})

    missing = %{input | "action" => "revoke", "package_document" => nil}
    assert {:error, :invalid_external_input} = change(c, missing)

    assert {:error, :stale_external_input_revision} =
             change(c, %{missing | "expected_install_revision" => 1, "expected_generation" => 1})

    assert retained(db(c)) == before

    assert {:ok, installed} = change(c, input)

    assert {:error, :stale_external_input_generation} =
             change(c, Map.put(R.revoke(installed), "expected_generation", 2))

    assert {:error, :stale_authority_epoch} =
             change(c, Map.put(R.revoke(installed), "authority_epoch", 2))

    assert {:ok, revoked} = change(c, R.revoke(installed))

    assert {:error, :external_input_not_installed} =
             change(c, R.revoke(revoked, "revoke:again"))

    assert :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "replacement and reinstallation require a different decoded signed decision", c do
    review = R.review(c)
    input = R.install(review)
    {:ok, first} = change(c, input)
    before = retained(db(c))

    assert {:error, :qualification_unavailable} = change(c, R.install(review, "reuse:1", first))

    {:ok, package} = ExternalInputPackage.decode(review.package)

    {:ok, changed_signature} =
      package["data"]
      |> put_in(["signed", "signature"], String.duplicate("A", 86))
      |> ExternalInputPackage.encode()

    assert {:error, :qualification_unavailable} =
             change(c, R.install(%{review | package: changed_signature}, "reuse:2", first))

    assert retained(db(c)) == before
    fresh = R.review(c, "replacement")
    assert fresh.definition.document == review.definition.document
    assert {:ok, replacement} = change(c, R.install(fresh, "replace:1", first))
    assert replacement["generation"] == 2
    assert replacement["install_revision"] == replacement["revision"]
    assert {:ok, revoked} = change(c, R.revoke(replacement))
    assert revoked["generation"] == 3

    for prior <- [review, fresh] do
      assert {:error, :qualification_unavailable} =
               change(c, R.install(prior, "reuse:after-revoke", revoked))
    end

    assert {:ok, reinstalled} = change(c, R.install(R.review(c, "new"), "reinstall:1", revoked))
    assert reinstalled["generation"] == 4
    assert {:ok, ^first} = change(c, input)
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "current permissions precede original reads and namespaces stay principal private", c do
    input = R.review(c) |> R.install()
    {:ok, installed} = change(c, input)

    denied =
      for {permissions, index} <-
            Enum.with_index([
              ~w(qualify:profile read),
              ~w(rule:review read),
              ~w(qualify:profile rule:review)
            ]) do
        {:ok, credential, _} =
          Store.provision_principal(c.store, "denied:#{index}", permissions, ["sensor:external"])

        credential
      end

    {:ok, other, _} =
      Store.provision_principal(
        c.store,
        "reviewer:other",
        ~w(qualify:profile rule:review read),
        ["sensor:external"]
      )

    before = retained(db(c))
    :ok = :sys.suspend(c.sources)
    :ok = :sys.suspend(c.custody)

    try do
      for credential <- denied do
        other_c = %{c | credential: credential}
        assert {:error, :permission_denied} = change(other_c, input)
        assert {:error, :permission_denied} = status(other_c, "install:live")
      end

      assert {:error, :unauthorized} = change(%{c | credential: <<0>>}, input)
      assert {:error, :unauthorized} = status(%{c | credential: <<0>>}, "install:live")

      assert {:error, :unauthorized} =
               Authority.external_routine_input_status(c.authority, <<0>>, 0, %{})

      assert :not_found = status(%{c | credential: other}, "install:live")
      assert :not_found = status(c, "absent:1")

      assert {:error, :stale_external_input_revision} = change(%{c | credential: other}, input)
      assert {:ok, ^installed} = change(c, input)

      assert {:error, :external_input_conflict} =
               change(c, R.revoke(installed, "install:live"))
    after
      :ok = :sys.resume(c.sources)
      :ok = :sys.resume(c.custody)
    end

    assert retained(db(c)) == before
    assert :sys.get_state(c.store).writable
  end

  test "retained target grants protect originals even when a changed submitted target is granted",
       c do
    input = R.review(c) |> R.install()
    {:ok, installed} = change(c, input)

    {:ok, thing} =
      WotexHome.Semantics.Thing.new(%{
        "id" => "target:other",
        "role" => "Light",
        "profile_ref" => "synthetic:other",
        "capabilities" => [
          %{
            "thing_id" => "target:other",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "synthetic:other",
            "evidence_ref" => "fixture:other",
            "freshness_ms" => 1000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, _} = Store.enroll_thing(c.store, thing)

    {:ok, credential, _} =
      Store.grant_target_and_rotate(c.store, "reviewer:input", "target:other")

    c = %{c | credential: credential}
    assert {:ok, _} = Store.revoke_target_grant(c.store, "reviewer:input", "sensor:external")

    changed = R.revoke(installed, "install:live") |> Map.put("target_id", "target:other")
    assert {:error, :permission_denied} = change(c, changed)
    assert {:error, :permission_denied} = change(c, input)
    assert {:error, :permission_denied} = status(c, "install:live")

    assert {:ok, [["revoked", 2]]} =
             SQL.query(db(c), "SELECT state,generation FROM routine_external_input_current")

    {:ok, credential, _} =
      Store.grant_target_and_rotate(c.store, "reviewer:input", "sensor:external")

    c = %{c | credential: credential}
    assert {:ok, ^installed} = change(c, input)
    assert {:ok, ^installed} = status(c, "install:live")

    assert {:ok, [["revoked", 2]]} =
             SQL.query(db(c), "SELECT state,generation FROM routine_external_input_current")

    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "maintenance withdraws actual native admission and retired or unhealthy owners retain originals",
       c do
    input = R.review(c) |> R.install()
    {:ok, installed} = change(c, input)
    {:ok, transfer, _} = Store.provision_transfer(c.store)
    {:ok, revision} = Store.revision(c.store)

    {:ok, barrier} =
      Store.begin_maintenance(c.store, c.credential, 1, "maintenance:live", revision)

    {:ok, final} = Store.revision(c.store)
    assert final == barrier.revision + 1
    assert {:ok, ^installed} = change(c, input)
    assert {:ok, ^installed} = status(c, "install:live")

    new_input = R.revoke(installed, "new:1") |> Map.put("expected_generation", 99)
    assert {:error, :maintenance_active} = change(c, new_input)
    assert {:error, :stale_authority_epoch} = change(c, %{new_input | "authority_epoch" => 2})

    {:ok, _} =
      Store.retire_controller(c.store, transfer, %{
        "authority_epoch" => 1,
        "operation_id" => "retire:live",
        "expected_revision" => final,
        "destination_owner_id" => String.duplicate("a", 64)
      })

    assert {:ok, ^installed} = change(c, input)
    assert {:ok, ^installed} = status(c, "install:live")
    assert :not_found = status(c, "absent:1")
    assert {:error, :source_retired} = change(c, new_input)
    :sys.replace_state(c.store, &%{&1 | writable: false})
    assert {:ok, ^installed} = change(c, input)
    assert {:ok, ^installed} = status(c, "install:live")
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "an actual restart preserves immutable originals but cannot reuse the old boot package",
       c do
    review = R.review(c)
    input = R.install(review)
    {:ok, installed} = change(c, input)
    unused = R.review(c, "unused-old-boot")
    c = F.restart(c)
    assert {:ok, ^installed} = change(c, input)
    assert {:ok, ^installed} = status(c, "install:live")
    fresh = R.install(review, "new:old-boot", installed)
    assert {:error, :qualification_unavailable} = change(c, fresh)

    assert {:error, :external_input_basis_changed} =
             change(c, R.install(unused, "unused:old-boot", installed))

    assert {:ok, revoked} = change(c, R.revoke(installed))
    assert revoked["store_boot_epoch"] != installed["store_boot_epoch"]
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  for {name, principal, mutation} <- [
        {"installer revocation", "reviewer:input", :revoke_principal},
        {"selector and approver revocation", "operator:1", :revoke_principal},
        {"selector and approver grant loss", "operator:1", :revoke_target_grant}
      ] do
    test "actual #{name} atomically withdraws a natively admitted input", c do
      input = R.review(c) |> R.install()
      {:ok, installed} = change(c, input)
      {:ok, before} = Store.revision(c.store)

      case unquote(mutation) do
        :revoke_principal ->
          assert {:ok, _} = Store.revoke_principal(c.store, unquote(principal))

        :revoke_target_grant ->
          assert {:ok, _} =
                   Store.revoke_target_grant(c.store, unquote(principal), "sensor:external")
      end

      assert {:ok, [["revoked", 2, install_revision]]} =
               SQL.query(
                 db(c),
                 "SELECT state,generation,install_revision FROM routine_external_input_current"
               )

      assert install_revision == installed["revision"]

      assert {:ok, [[cause, revision]]} =
               SQL.query(
                 db(c),
                 "SELECT cause_revision,revision FROM routine_external_input_history WHERE action='withdraw'"
               )

      assert cause == before + 1

      delta =
        if unquote(mutation) == :revoke_principal and unquote(principal) == "operator:1",
          do: 3,
          else: 2

      assert revision == before + delta
      assert {:ok, ^revision} = Store.revision(c.store)
      assert {:ok, %{history_rows: 0}} = ExternalInputs.retirement_reserve(db(c))

      cond do
        unquote(principal) == "reviewer:input" ->
          assert {:error, :unauthorized} = change(c, input)
          assert {:error, :unauthorized} = status(c, "install:live")

        unquote(mutation) == :revoke_principal ->
          # Revoking the selection author also retires the selected target
          # and its grants. Retained receipts still require a current grant.
          assert {:error, :permission_denied} = change(c, input)
          assert {:error, :permission_denied} = status(c, "install:live")

        true ->
          assert {:ok, ^installed} = change(c, input)
          assert {:ok, ^installed} = status(c, "install:live")
      end

      assert :ok = Integrity.validate_snapshot(db(c))
    end
  end

  test "signature and current-context refusals retain no attempted operation or revision", c do
    review = R.review(c)
    {:ok, package} = ExternalInputPackage.decode(review.package)

    {:ok, bad} =
      package["data"]
      |> put_in(["signed", "signature"], String.duplicate("A", 86))
      |> ExternalInputPackage.encode()

    before = retained(db(c))

    assert {:error, :invalid_external_input_decision} =
             change(c, R.install(%{review | package: bad}))

    :sys.replace_state(c.store, &%{&1 | qualification_case_keys: %{}})
    assert {:error, :qualification_unavailable} = change(c, R.install(review))
    :sys.replace_state(c.store, &%{&1 | qualification_case_keys: c.case_keys})
    publish_new_source(c)
    assert {:error, :external_input_basis_changed} = change(c, R.install(review))
    assert retained(db(c)) == before
    assert :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(db(c))
  end

  test "source drift after tentative rows rolls back the original history head and revision", c do
    input = R.review(c) |> R.install()
    borrowed = db(c)
    before = retained(borrowed)

    assert {:error, :external_input_basis_changed} =
             final_install(c, input, fn _ -> publish_new_source(c) end)

    assert retained(borrowed) == before
    assert :not_found = status(c, "install:live")
    assert :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(borrowed)
  end

  test "corruption discovered by the final context guard rolls back and fences writes", c do
    input = R.review(c) |> R.install()
    borrowed = db(c)
    before = retained(borrowed)

    assert {:error, :corrupt_external_inputs} =
             final_install(c, input, fn db ->
               assert {:ok, []} =
                        SQL.query(db, "UPDATE routine_external_input_current SET generation=2")
             end)

    assert retained(borrowed) == before
    refute :sys.get_state(c.store).writable
    assert :not_found = status(c, "install:live")
    assert :ok = Integrity.validate_snapshot(borrowed)
  end

  test "a stalled final private read consumes the shared budget without retaining tentative rows",
       c do
    input = R.review(c) |> R.install()
    borrowed = db(c)
    before = retained(borrowed)
    started = System.monotonic_time(:millisecond)

    assert {:error, :external_input_unavailable} = final_install(c, input, fn _ -> :ok end, true)
    assert System.monotonic_time(:millisecond) - started < 11_000
    assert retained(borrowed) == before
    assert :not_found = status(c, "install:live")
    assert :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(borrowed)
  end

  test "SQL failure after the attempted journal event rolls back and fences the writer", c do
    input = R.review(c) |> R.install()
    borrowed = db(c)
    before = retained(borrowed)

    :ok =
      Exqlite.Sqlite3.execute(
        borrowed,
        "CREATE TRIGGER reject_native_input AFTER INSERT ON authority_journal WHEN NEW.event_type='external_input_installed' BEGIN SELECT RAISE(ABORT,'injected native input failure'); END"
      )

    assert {:error, :store_unavailable} = change(c, input)
    assert retained(borrowed) == before
    refute :sys.get_state(c.store).writable
    assert :not_found = status(c, "install:live")
  end

  defp final_install(c, input, callback, await_suspended \\ false) do
    borrowed = db(c)
    sources = c.sources
    custody = c.custody
    :erlang.trace(sources, true, [:receive])
    task = Task.async(fn -> change(c, input) end)

    result =
      try do
        # Two complete opening captures each make opening/closing source calls.
        for _ <- 1..4 do
          assert_receive {:trace, ^sources, :receive, {:"$gen_call", _, {:current, _, _, _, _}}},
                         2000
        end

        :ok = :sys.suspend(custody)
        :erlang.trace(custody, true, [:receive])
        assert_receive {:trace, ^custody, :receive, {:"$gen_call", _, {:read_object, _}}}, 2000

        # Only this test borrows the captured handle while Store is paused in
        # the final guard. Production private owners never receive this handle.
        assert {:ok, [[1, 1, 1]]} =
                 SQL.query(
                   borrowed,
                   "SELECT (SELECT COUNT(*) FROM routine_external_input_operations),(SELECT COUNT(*) FROM routine_external_input_history),(SELECT COUNT(*) FROM routine_external_input_current)"
                 )

        callback.(borrowed)

        if await_suspended,
          do: {:reply, Task.await(task, 6500)},
          else: :continue
      after
        :erlang.trace(sources, false, [:receive])
        :erlang.trace(custody, false, [:receive])
        :ok = :sys.resume(custody)
      end

    case result do
      {:reply, reply} -> reply
      :continue -> Task.await(task, 5000)
    end
  end

  defp publish_new_source(c) do
    {:ok, newer} =
      ExternalSourceSelection.new(
        Map.put(c.selection.inputs["source"], "source_generation", 2),
        c.selection.inputs["reader"],
        c.selection.inputs["channels"]
      )

    assert {:ok, _} = ExternalSourceOwner.publish(c.sources, newer)
  end

  defp retained(db) do
    for table <- [
          "meta",
          "authority_journal",
          "routine_external_input_operations",
          "routine_external_input_history",
          "routine_external_input_current"
        ],
        into: %{} do
      {:ok, rows} = SQL.query(db, "SELECT * FROM " <> table <> " ORDER BY rowid")
      {table, rows}
    end
  end

  defp status(c, operation),
    do: Authority.external_routine_input_status(c.authority, c.credential, 1, operation)

  defp change(c, input),
    do: Authority.change_external_routine_input(c.authority, c.credential, input)

  defp db(c), do: :sys.get_state(c.store).db
end
