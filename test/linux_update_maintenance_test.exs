Code.require_file(Path.expand("support/linux_update_fixtures.exs", __DIR__))

defmodule WotexHome.LinuxUpdateMaintenanceTest do
  use ExUnit.Case

  alias Woh.Tool.{LinuxUpdateMaintenance, LinuxUpdateStop}

  test "invalid credentials refuse before observing installation or starting an exchange" do
    for credential <- [nil, "invalid", String.duplicate("A", 42) <> "B"] do
      assert {:error, :update_credential_refused} =
               LinuxUpdateMaintenance.activate("not an intent", credential,
                 inspect: fn _ -> flunk("must not inspect") end,
                 request: fn _, _, _, _, _, _ -> flunk("must not exchange") end
               )

      assert {:error, :update_credential_refused} =
               LinuxUpdateMaintenance.observe_active("not an intent", credential,
                 inspect: fn _ -> flunk("must not inspect") end
               )

      assert {:error, :update_credential_refused} =
               LinuxUpdateStop.run("not an intent", credential,
                 inspect: fn _ -> flunk("must not inspect") end
               )
    end
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    alias Woh.Tool.{
      LinuxInstallFiles,
      LinuxInstallMaintenance,
      LinuxInstallHost,
      LinuxServicePackage,
      LinuxUpdateJournal,
      LinuxUpdateSelection,
      ReleaseBootstrap,
      ReleaseInventory
    }

    alias WotexHome.{Authority, CLI}
    alias WotexHome.Durable.Store
    alias WotexHome.LocalAPI.Server
    alias WotexHome.Host.UpdateFence
    alias WotexHome.LinuxUpdateFixtures, as: F

    @tool Path.expand("../native/linux/installer-files", __DIR__)

    setup do
      root =
        Path.join("/root", "woh-update-maint-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      base = root <> "/opt/wotex-home"
      File.mkdir_p!(base <> "/releases")
      File.chmod!(base, 0o755)
      File.mkdir!(base <> "/.installer")
      File.chmod!(base <> "/.installer", 0o700)
      source = payload!(root, base, "source", "a")
      target = payload!(root, base, "target", "b")
      owner_bytes = F.owner(source)
      File.write!(base <> "/.installer/owner.json", owner_bytes)
      File.chmod!(base <> "/.installer/owner.json", 0o600)

      for {relative, bytes} <- LinuxServicePackage.files(source["artifact_id"], 2) do
        path = Path.join(root, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
        File.chmod!(path, 0o644)
      end

      {:ok, journal} = LinuxUpdateJournal.new(owner_bytes, source)
      {:ok, bytes} = LinuxUpdateJournal.persist(base, owner_bytes, journal, nil, @tool)
      {:ok, selection} = LinuxUpdateSelection.new(owner_bytes, journal)
      {:ok, _} = LinuxUpdateSelection.persist(base, owner_bytes, journal, selection, nil, @tool)
      nonce = F.nonce()
      process = F.process()
      {:ok, journal} = LinuxUpdateJournal.prepare(journal, nonce, source, target, process)
      {:ok, bytes} = LinuxUpdateJournal.persist(base, owner_bytes, journal, bytes, @tool)
      {:ok, journal} = LinuxUpdateJournal.advance(journal, nonce, "staged")
      {:ok, _} = LinuxUpdateJournal.persist(base, owner_bytes, journal, bytes, @tool)

      database = root <> "/private-store"
      File.mkdir!(database)
      File.chmod!(database, 0o700)

      store_options = [
        path: database <> "/home.sqlite",
        update_fence: %{artifact_id: source["artifact_id"], path: base <> "/update-guard.json"}
      ]

      store =
        start_supervised!(Supervisor.child_spec({Store, store_options}, restart: :temporary))

      {:ok, raw, _} =
        Store.provision_principal(store, "maintainer:original", ["host:maintain"], [])

      credential = Base.url_encode64(raw, padding: false)
      authority = Authority.new(store: store)
      Process.put(:update_fixture_authority, authority)
      Process.put(:update_fixture_commands, [])

      owned = %{base: base, owner_bytes: owner_bytes, initial_release: source}

      # Registration/cohort/process/socket peer are explicit synthetic seams.
      # Root custody, complete payload pins, native CAS and SQLite routes are real.
      options = [
        root: root,
        tool: @tool,
        inspect: fn _ -> {:ok, owned} end,
        observe: fn _, identity, 211, options ->
          assert identity == source and options[:expected] == process
          {:ok, Process.get(:update_fixture_process, process)}
        end,
        request: fn 211, socket, command, credential, @tool, expected ->
          assert socket == root <> "/var/lib/wotex-home/ipc/home.sock"
          assert expected == process
          {:ok, retained, _} = LinuxUpdateJournal.load(base, owner_bytes, @tool)

          if hd(command) == "maintenance-begin" do
            assert List.last(retained["updates"])["phase"] == "begin_recorded"
            {:ok, commands} = LinuxUpdateJournal.begin_commands(retained, nonce)
            assert commands.retry == command
          end

          Process.put(
            :update_fixture_commands,
            Process.get(:update_fixture_commands) ++ [command]
          )

          result = route(command, credential)

          if Process.delete(:update_fixture_change_process),
            do:
              Process.put(:update_fixture_process, %{
                process
                | start_ticks: process.start_ticks + 1
              })

          cond do
            hd(command) == "maintenance-begin" and Process.delete(:update_fixture_lose_begin) ->
              {:error, :synthetic_lost_reply}

            hd(command) == "maintenance-operation-status" and
                Process.get(:update_fixture_wrong_peer) ->
              with_peer(result, 124)

            true ->
              with_peer(result, process.pid)
          end
        end
      ]

      on_exit(fn -> File.rm_rf!(root) end)

      %{
        root: root,
        base: base,
        source: source,
        target: target,
        owner: owner_bytes,
        nonce: nonce,
        process: process,
        credential: credential,
        raw: raw,
        authority: authority,
        store: store,
        store_options: store_options,
        options: options
      }
    end

    test "actual original begin is retained and joined to a fresh active barrier", c do
      assert {:ok, result} = activate(c)
      assert result.intent["phase"] == "maintenance_active"
      assert result.process == c.process
      assert result.status["begin_revision"] == result.intent["maintenance"]["begin_revision"]
      assert result.status["principal_id"] == "maintainer:original"

      assert {:ok, %{"state" => "maintenance"}} =
               route(["maintenance-update-status"], c.credential)

      assert Enum.count(commands(), &(hd(&1) == "maintenance-begin")) == 1
      assert {:ok, repeated} = activate(c)
      assert repeated == result
      assert Enum.count(commands(), &(hd(&1) == "maintenance-begin")) == 1
      refute result.journal_bytes =~ c.credential
      assert File.read!(c.base <> "/.installer/owner.json") == c.owner
      assert result.journal["generation"] == 4
    end

    test "lost begin reply resumes the same lookup after actual Store restart", c do
      Process.put(:update_fixture_lose_begin, true)
      assert {:error, :update_exchange_unresolved} = activate(c)
      {journal, bytes} = retained(c)
      assert List.last(journal["updates"])["phase"] == "begin_recorded"
      original = List.last(journal["updates"])["maintenance"]
      assert original["begin_revision"] == nil

      assert {:ok, %{"state" => "maintenance"} = status} =
               route(["maintenance-update-status"], c.credential)

      :ok = GenServer.stop(c.store)
      restarted = start_supervised!({Store, c.store_options}, id: :restarted)
      Process.put(:update_fixture_authority, Authority.new(store: restarted))
      assert {:ok, result} = activate(c)

      assert Map.delete(result.intent["maintenance"], "begin_revision") ==
               Map.delete(original, "begin_revision")

      assert result.status["begin_revision"] == status["begin_revision"]
      assert Enum.count(commands(), &(hd(&1) == "maintenance-begin")) == 1
      refute bytes =~ c.credential
    end

    test "uncertain accepted-progress publication resolves the real retained phase", c do
      Process.put(:update_fixture_lose_progress, true)

      persist = fn base, owner, journal, bytes, tool ->
        result = LinuxUpdateJournal.persist(base, owner, journal, bytes, tool)

        if List.last(journal["updates"])["phase"] == "maintenance_active" and
             Process.delete(:update_fixture_lose_progress),
           do: {:error, :synthetic_lost_publication_reply},
           else: result
      end

      assert {:error, :update_progress_unresolved} = activate(c, persist: persist)
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "maintenance_active"
      assert {:ok, _} = activate(c)
      assert Enum.count(commands(), &(hd(&1) == "maintenance-begin")) == 1
    end

    test "failed original-intent publication sends no begin", c do
      assert {:error, :update_progress_unresolved} =
               activate(c,
                 persist: fn _, _, _, _, _ -> {:error, :synthetic_failed_publication} end
               )

      assert commands() == [["maintenance-update-status"]]
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "staged"
      assert {:ok, %{"state" => "normal"}} = route(["maintenance-update-status"], c.credential)
    end

    test "recorded principal and revision cannot be resnapshotted into another begin", c do
      record_original(c)
      {_, bytes} = retained(c)

      {:ok, other_raw, _} =
        Store.provision_principal(c.store, "maintainer:other", ["host:maintain"], [])

      other = Base.url_encode64(other_raw, padding: false)

      assert {:error, :update_original_basis_refused} =
               LinuxUpdateMaintenance.activate(c.nonce, other, c.options)

      assert commands() == [["maintenance-update-status"]]
      Process.put(:update_fixture_commands, [])
      assert {:error, :update_original_basis_refused} = activate(c)

      assert Enum.map(commands(), &hd/1) == [
               "maintenance-update-status",
               "maintenance-operation-status"
             ]

      assert {_, ^bytes} = retained(c)
      assert {:ok, %{"state" => "normal"}} = route(["maintenance-update-status"], c.credential)
    end

    test "changed source incarnation on either side of exchange refuses before begin", c do
      Process.put(:update_fixture_process, %{c.process | invocation_id: String.duplicate("3", 32)})

      assert {:error, :update_process_unavailable} = activate(c)
      assert commands() == []
      Process.delete(:update_fixture_process)
      Process.put(:update_fixture_change_process, true)
      assert {:error, :update_process_unavailable} = activate(c)
      assert commands() == [["maintenance-update-status"]]
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "staged"
      assert {:ok, %{"state" => "normal"}} = route(["maintenance-update-status"], c.credential)
    end

    test "not-found lookup still requires the retained source peer", c do
      record_original(c)
      Process.put(:update_fixture_wrong_peer, true)
      assert {:error, :update_peer_refused} = activate(c)
      refute Enum.any?(commands(), &(hd(&1) == "maintenance-begin"))
      assert {:ok, %{"state" => "normal"}} = route(["maintenance-update-status"], c.credential)
    end

    test "historical begin receipt cannot substitute for an active barrier", c do
      {:ok, result} = activate(c)
      status = result.status

      assert {:ok, _} =
               Authority.end_maintenance(
                 c.authority,
                 c.raw,
                 status["authority_epoch"],
                 "end:operator",
                 status["store_revision"],
                 status["begin_revision"]
               )

      {_, bytes} = retained(c)
      assert {:error, :update_live_barrier_refused} = activate(c)
      assert {_, ^bytes} = retained(c)
      assert Enum.count(commands(), &(hd(&1) == "maintenance-begin")) == 1
    end

    test "altered target payload and foreign source configuration refuse without effects", c do
      target = c.base <> "/releases/" <> c.target["artifact_id"] <> "/fixture"
      bytes = File.read!(target)
      File.write!(target, "foreign payload")
      assert {:error, :update_payload_refused} = activate(c)
      assert commands() == []
      assert File.read!(target) == "foreign payload"
      File.write!(target, bytes)
      unit = c.root <> "/etc/systemd/system/wotex-home.service"
      File.write!(unit, "foreign unit")
      assert {:error, :update_configuration_refused} = activate(c)
      assert commands() == []
      assert File.read!(unit) == "foreign unit"
    end

    test "wrong nonce or administrative future phase supplies no begin permission", c do
      assert {:error, :update_phase_refused} =
               LinuxUpdateMaintenance.activate(F.nonce(2), c.credential, c.options)

      record_original(c)
      {journal, bytes} = retained(c)
      {:ok, commands} = LinuxUpdateJournal.begin_commands(journal, c.nonce)
      {:ok, receipt} = route(commands.retry, c.credential)
      {:ok, journal} = LinuxUpdateJournal.accept_begin(journal, c.nonce, receipt)
      {:ok, bytes} = LinuxUpdateJournal.persist(c.base, c.owner, journal, bytes, @tool)
      {:ok, journal} = LinuxUpdateJournal.advance(journal, c.nonce, "fenced")
      {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, journal, bytes, @tool)
      assert {:error, :update_phase_refused} = activate(c)
      assert commands() == []
    end

    test "pending fence joins original barrier before one fixed stop and retains target boot",
         c do
      {:ok, active} = activate(c)
      assert {:ok, stopped} = stop(c)
      assert stopped.intent["phase"] == "stopped"
      assert stopped.intent["maintenance"] == active.intent["maintenance"]
      assert stopped.journal["generation"] == 6
      assert Process.get(:update_stop_changes) == [["--system", "stop", "wotex-home.service"]]
      count = length(commands())
      assert {:ok, ^stopped} = stop(c)
      assert length(commands()) == count
      assert File.read!(c.base <> "/.installer/owner.json") == c.owner

      assert {:ok, selection, _} =
               LinuxUpdateSelection.load(c.base, c.owner, stopped.journal, @tool)

      assert selection["release"] == c.source
      fence = %{artifact_id: c.target["artifact_id"], path: c.base <> "/update-guard.json"}
      options = Keyword.put(c.store_options, :update_fence, fence)
      target = start_supervised!({Store, options}, id: :inert_target_store)
      assert :ok = UpdateFence.check_boot(target, fence)

      assert {:error, :update_artifact_changed} =
               UpdateFence.check_boot(target, %{fence | artifact_id: c.source["artifact_id"]})

      assert {:ok, %{state: :maintenance, begin_revision: revision}} =
               Authority.maintenance_update_status(Authority.new(store: target), c.raw)

      assert revision == stopped.intent["maintenance"]["begin_revision"]

      assert {:error, :release_update_active} =
               Authority.end_maintenance(
                 Authority.new(store: target),
                 c.raw,
                 1,
                 "end:target-pending",
                 revision,
                 revision
               )
    end

    test "source observation entries grant no begin and distinguish live from stopped custody",
         c do
      assert {:error, :update_phase_refused} =
               LinuxUpdateMaintenance.inspect_source(c.nonce, c.options)

      assert {:error, :update_phase_refused} =
               LinuxUpdateMaintenance.observe_active(c.nonce, c.credential, c.options)

      {:ok, active} = activate(c)
      {:ok, inspected} = LinuxUpdateMaintenance.inspect_source(c.nonce, c.options)
      assert Map.delete(active, :status) == inspected
      before = Enum.count(commands(), &(hd(&1) == "maintenance-begin"))

      assert {:ok, ^active} =
               LinuxUpdateMaintenance.observe_active(c.nonce, c.credential, c.options)

      assert Enum.count(commands(), &(hd(&1) == "maintenance-begin")) == before
      {:ok, stopped} = stop(c)
      assert {:ok, stopped_source} = LinuxUpdateMaintenance.inspect_source(c.nonce, c.options)
      assert stopped_source == Map.delete(stopped, :guard)

      assert {:error, :update_phase_refused} =
               LinuxUpdateMaintenance.observe_active(c.nonce, c.credential, c.options)
    end

    test "lost guard publication reply resumes actual pending bytes before stop", c do
      {:ok, _} = activate(c)

      write = fn path, mode, bytes, previous, tool ->
        assert :ok = LinuxInstallFiles.write(path, mode, bytes, previous, tool)
        {:error, :synthetic_lost_guard_reply}
      end

      assert {:error, :update_guard_publication_unresolved} = stop(c, guard_write: write)
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "maintenance_active"
      assert Process.get(:update_stop_changes, []) == []
      bytes = File.read!(c.base <> "/update-guard.json")

      assert {:ok, stopped} =
               stop(c, guard_write: fn _, _, _, _, _ -> flunk("must not republish") end)

      assert File.read!(c.base <> "/update-guard.json") == bytes
      assert stopped.intent["phase"] == "stopped"
    end

    test "an operator end that wins before guard publication prevents fencing and stop", c do
      {:ok, active} = activate(c)

      write = fn path, mode, bytes, previous, tool ->
        status = active.status

        assert {:ok, _} =
                 Authority.end_maintenance(
                   c.authority,
                   c.raw,
                   1,
                   "end:before-guard",
                   status["store_revision"],
                   status["begin_revision"]
                 )

        LinuxInstallFiles.write(path, mode, bytes, previous, tool)
      end

      assert {:error, :update_live_barrier_unavailable} = stop(c, guard_write: write)
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "maintenance_active"
      assert Process.get(:update_stop_changes, []) == []

      assert {:ok, %{"state" => "pending"}} =
               UpdateFence.read(%{
                 artifact_id: c.target["artifact_id"],
                 path: c.base <> "/update-guard.json"
               })

      assert {:ok, %{"state" => "normal"}} = route(["maintenance-update-status"], c.credential)
    end

    test "lost fenced progress refuses first stop and resolves actual phase on resume", c do
      {:ok, _} = activate(c)

      persist = fn base, owner, journal, previous, tool ->
        result = LinuxUpdateJournal.persist(base, owner, journal, previous, tool)

        if List.last(journal["updates"])["phase"] == "fenced",
          do: {:error, :synthetic_lost_fenced_reply},
          else: result
      end

      assert {:error, :update_progress_unresolved} = stop(c, persist: persist)
      assert Process.get(:update_stop_changes, []) == []
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "fenced"
      assert {:ok, _} = stop(c)
      assert length(Process.get(:update_stop_changes)) == 1
    end

    test "lost stop reply resumes stopped cgroup without another command or socket exchange", c do
      {:ok, _} = activate(c)
      Process.put(:update_stop_lose_reply, true)
      assert {:error, :update_stop_unresolved} = stop(c)
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "fenced"
      refute Process.alive?(c.store)
      count = length(commands())
      assert {:ok, _} = stop(c)
      assert length(commands()) == count
      assert length(Process.get(:update_stop_changes)) == 1
    end

    test "populated stopped cgroup retains fenced intent until fresh empty observations", c do
      {:ok, _} = activate(c)
      Process.put(:update_stop_populated, true)
      assert {:error, :update_cgroup_unavailable} = stop(c)
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "fenced"
      assert {:error, :update_cgroup_unavailable} = stop(c)
      assert length(Process.get(:update_stop_changes)) == 1
      Process.delete(:update_stop_populated)
      assert {:ok, _} = stop(c)
      assert length(Process.get(:update_stop_changes)) == 1
    end

    test "changed source incarnation after fenced publication refuses stop", c do
      {:ok, _} = activate(c)

      persist = fn base, owner, journal, previous, tool ->
        result = LinuxUpdateJournal.persist(base, owner, journal, previous, tool)

        if List.last(journal["updates"])["phase"] == "fenced",
          do:
            Process.put(:update_fixture_process, %{
              c.process
              | start_ticks: c.process.start_ticks + 1
            })

        result
      end

      assert {:error, :update_live_barrier_unavailable} = stop(c, persist: persist)
      assert Process.get(:update_stop_changes, []) == []
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "fenced"
    end

    test "foreign or malformed guards and failed registration preserve bytes and service", c do
      {:ok, active} = activate(c)
      path = c.base <> "/update-guard.json"
      pending = pending_guard(active)

      for change <- [
            %{"owner_sha256" => String.duplicate("f", 64)},
            %{"begin_revision" => pending["begin_revision"] + 1},
            %{"state" => "complete"}
          ] do
        bytes = JSON.encode!(Map.merge(pending, change))
        File.write!(path, bytes)
        File.chmod!(path, 0o644)
        assert {:error, :update_guard_foreign} = stop(c)
        assert File.read!(path) == bytes
      end

      bytes = JSON.encode!(%{pending | "schema_version" => 1.0})
      File.write!(path, bytes)
      assert {:error, :update_guard_unavailable} = stop(c)
      assert File.read!(path) == bytes
      File.rm!(path)
      Process.put(:update_stop_state, :failed)
      assert {:error, :update_controller_unavailable} = stop(c)
      refute File.exists?(path)
      assert Process.get(:update_stop_changes, []) == []
      assert Process.alive?(c.store)
    end

    test "second update replaces only its completed historical guard and preserves first intent",
         c do
      c = next_update(c)
      {before, _} = retained(c)
      first = hd(before["updates"])
      old_guard = File.read!(c.base <> "/update-guard.json")
      {:ok, _} = activate(c)

      write = fn path, mode, bytes, previous, tool ->
        assert previous == LinuxInstallFiles.digest(old_guard)
        LinuxInstallFiles.write(path, mode, bytes, previous, tool)
      end

      assert {:ok, stopped} = stop(c, guard_write: write)
      assert hd(stopped.journal["updates"]) == first
      assert length(stopped.journal["updates"]) == 2
      assert stopped.intent["source"] == first["target"]

      assert stopped.intent["maintenance"]["begin_revision"] >
               first["maintenance"]["begin_revision"]

      assert stopped.guard["artifact_id"] == c.target["artifact_id"]
      assert File.read!(c.base <> "/.installer/owner.json") == c.owner
    end

    test "lost stopped-progress reply resolves retained phase without another stop", c do
      {:ok, _} = activate(c)

      persist = fn base, owner, journal, previous, tool ->
        result = LinuxUpdateJournal.persist(base, owner, journal, previous, tool)

        if List.last(journal["updates"])["phase"] == "stopped",
          do: {:error, :synthetic_lost_stopped_reply},
          else: result
      end

      assert {:error, :update_progress_unresolved} = stop(c, persist: persist)
      {journal, _} = retained(c)
      assert List.last(journal["updates"])["phase"] == "stopped"
      count = length(commands())
      assert {:ok, _} = stop(c)
      assert length(commands()) == count
      assert length(Process.get(:update_stop_changes)) == 1
    end

    test "administrative stopped claim does not permit stop of a running controller", c do
      {:ok, active} = activate(c)
      bytes = JSON.encode!(pending_guard(active)) <> "\n"

      assert :ok =
               LinuxInstallFiles.write(c.base <> "/update-guard.json", 0o644, bytes, nil, @tool)

      Enum.each(~w(fenced stopped), fn phase ->
        {journal, bytes} = retained(c)
        {:ok, journal} = LinuxUpdateJournal.advance(journal, c.nonce, phase)
        {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, journal, bytes, @tool)
      end)

      count = length(commands())
      assert {:error, :update_cgroup_unavailable} = stop(c)
      assert length(commands()) == count
      assert Process.get(:update_stop_changes, []) == []
      assert Process.alive?(c.store)
    end

    defp next_update(c) do
      {:ok, active} = activate(c)
      # Explicit completed-history fixture, not a service-switch claim. The
      # second update below consumes actual history/selection/guard bytes.
      Enum.each(~w(fenced stopped configuration_ready target_running), fn phase ->
        {journal, bytes} = retained(c)
        {:ok, journal} = LinuxUpdateJournal.advance(journal, c.nonce, phase)
        {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, journal, bytes, @tool)
      end)

      {journal, _} = retained(c)
      {:ok, selection, bytes} = LinuxUpdateSelection.load(c.base, c.owner, journal, @tool)
      {:ok, selection} = LinuxUpdateSelection.select(selection, journal, c.nonce)
      {:ok, _} = LinuxUpdateSelection.persist(c.base, c.owner, journal, selection, bytes, @tool)

      Enum.each(~w(selected complete), fn phase ->
        {journal, bytes} = retained(c)
        {:ok, journal} = LinuxUpdateJournal.advance(journal, c.nonce, phase)
        {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, journal, bytes, @tool)
      end)

      complete = %{pending_guard(active) | "state" => "complete"}

      assert :ok =
               LinuxInstallFiles.write(
                 c.base <> "/update-guard.json",
                 0o644,
                 JSON.encode!(complete) <> "\n",
                 nil,
                 @tool
               )

      for {relative, bytes} <- LinuxServicePackage.files(c.target["artifact_id"], 2),
          do: File.write!(Path.join(c.root, relative), bytes)

      :ok = GenServer.stop(c.store)

      store_options =
        Keyword.put(c.store_options, :update_fence, %{
          artifact_id: c.target["artifact_id"],
          path: c.base <> "/update-guard.json"
        })

      store = start_supervised!({Store, store_options}, id: :second_source_store)
      authority = Authority.new(store: store)
      Process.put(:update_fixture_authority, authority)

      assert {:ok, _} =
               Authority.end_maintenance(
                 authority,
                 c.raw,
                 1,
                 "end:first-update",
                 active.status["store_revision"],
                 active.status["begin_revision"]
               )

      target = payload!(c.root, c.base, "third", "c")
      source = c.target
      nonce = F.nonce(2)
      process = F.process(124)
      {journal, bytes} = retained(c)
      {:ok, journal} = LinuxUpdateJournal.prepare(journal, nonce, source, target, process)
      {:ok, bytes} = LinuxUpdateJournal.persist(c.base, c.owner, journal, bytes, @tool)
      {:ok, journal} = LinuxUpdateJournal.advance(journal, nonce, "staged")
      {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, journal, bytes, @tool)

      options =
        Keyword.merge(c.options,
          observe: fn _, identity, 211, options ->
            assert identity == source and options[:expected] == process
            {:ok, process}
          end,
          request: fn 211, socket, command, credential, @tool, expected ->
            assert socket == c.root <> "/var/lib/wotex-home/ipc/home.sock" and expected == process

            Process.put(
              :update_fixture_commands,
              Process.get(:update_fixture_commands) ++ [command]
            )

            with_peer(route(command, credential), process.pid)
          end
        )

      %{
        c
        | source: source,
          target: target,
          nonce: nonce,
          process: process,
          options: options,
          authority: authority,
          store: store,
          store_options: store_options
      }
    end

    defp stop(c, overrides \\ []),
      do:
        LinuxUpdateStop.run(
          c.nonce,
          c.credential,
          c.options |> Keyword.merge(stop_options(c)) |> Keyword.merge(overrides)
        )

    defp stop_options(c) do
      query = fn "/usr/bin/systemctl",
                 [
                   "--system",
                   "show",
                   "--all",
                   "--no-pager",
                   "--property=" <> properties,
                   "wotex-home.service"
                 ],
                 4096,
                 5000 ->
        state = Process.get(:update_stop_state, :running)

        fields = %{
          "LoadState" => "loaded",
          "ActiveState" => %{running: "active", stopped: "inactive", failed: "failed"}[state],
          "SubState" => %{running: "running", stopped: "dead", failed: "failed"}[state],
          "MainPID" => if(state == :running, do: to_string(c.process.pid), else: "0"),
          "ControlPID" => "0",
          "FragmentPath" => "/etc/systemd/system/wotex-home.service",
          "DropInPaths" => "",
          "ControlGroup" => c.process.cgroup,
          "InvocationID" => c.process.invocation_id
        }

        {:ok,
         Enum.map_join(
           String.split(properties, ","),
           "",
           &(&1 <> "=" <> Map.fetch!(fields, &1) <> "\n")
         )}
      end

      change = fn "/usr/bin/systemctl", ["--system", "stop", "wotex-home.service"] = command ->
        Process.put(:update_stop_changes, Process.get(:update_stop_changes, []) ++ [command])
        {journal, _} = retained(c)
        assert List.last(journal["updates"])["phase"] == "fenced"

        assert {:ok, guard} =
                 UpdateFence.read(%{
                   artifact_id: c.target["artifact_id"],
                   path: c.base <> "/update-guard.json"
                 })

        assert guard == pending_guard(%{journal: journal, intent: List.last(journal["updates"])})
        assert {:ok, status} = route(["maintenance-update-status"], c.credential)

        assert {:error, :release_update_active} =
                 Authority.end_maintenance(
                   c.authority,
                   c.raw,
                   1,
                   "end:stop-race",
                   status["store_revision"],
                   status["begin_revision"]
                 )

        assert :not_found =
                 Authority.maintenance_operation_status(c.authority, c.raw, 1, "end:stop-race")

        :ok = GenServer.stop(c.store)
        Process.put(:update_stop_state, :stopped)

        if Process.delete(:update_stop_lose_reply),
          do: {:error, :synthetic_lost_stop_reply},
          else: :ok
      end

      cgroup_probe = fn options ->
        assert {:ok, registration} = LinuxInstallHost.controller_registration(options[:query])

        if registration.state == :stopped and not Process.get(:update_stop_populated, false),
          do: :ok,
          else: {:error, :synthetic_populated_or_running_cgroup}
      end

      [query: query, change: change, cgroup_probe: cgroup_probe]
    end

    defp pending_guard(active),
      do: %{
        "schema_version" => 1,
        "scope" => "linux_release_update_guard",
        "owner_sha256" => active.journal["owner_sha256"],
        "artifact_id" => active.intent["target"]["artifact_id"],
        "authority_epoch" => active.intent["maintenance"]["authority_epoch"],
        "begin_revision" => active.intent["maintenance"]["begin_revision"],
        "state" => "pending"
      }

    defp activate(c, overrides \\ []),
      do:
        LinuxUpdateMaintenance.activate(
          c.nonce,
          c.credential,
          Keyword.merge(c.options, overrides)
        )

    defp retained(c) do
      {:ok, journal, bytes} = LinuxUpdateJournal.load(c.base, c.owner, @tool)
      {journal, bytes}
    end

    defp commands, do: Process.get(:update_fixture_commands)

    defp record_original(c) do
      {journal, bytes} = retained(c)
      {:ok, status} = route(["maintenance-update-status"], c.credential)
      {:ok, updated} = LinuxUpdateJournal.record_begin(journal, c.nonce, status)
      {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, updated, bytes, @tool)
    end

    defp route(command, credential) do
      {:ok, request} = CLI.build_request(command, credential)
      {:ok, frame} = WotexHome.LocalAPI.Frame.encode_request(request)

      {:ok, <<_size::unsigned-big-32, body::binary>>} =
        Server.route_frame(Process.get(:update_fixture_authority), frame)

      {:ok, response} = WotexHome.LocalAPI.Frame.decode_response(body)
      LinuxInstallMaintenance.decode_response(response, request)
    end

    defp with_peer({:ok, value}, pid), do: {:ok, value, pid}
    defp with_peer(:not_found, pid), do: {:not_found, pid}
    defp with_peer(result, _), do: result

    defp payload!(root, base, name, source) do
      release = Path.join(root, name)
      image = release <> "/erts-28.5.0.6/bin/beam.smp"
      File.mkdir_p!(Path.dirname(image))
      File.chmod!(release, 0o755)
      File.cp!("/usr/bin/sleep", image)
      File.chmod!(image, 0o755)
      File.write!(release <> "/fixture", "inert #{name} payload")
      {:ok, report} = LinuxServicePackage.assemble(release, String.duplicate(source, 40))
      {:ok, _} = ReleaseInventory.create(release, report["source_revision"])
      File.chmod!(release <> "/release-inventory.json", 0o644)
      {:ok, bootstrap} = ReleaseBootstrap.render(release)

      identity = %{
        "source_revision" => report["source_revision"],
        "artifact_id" => report["artifact_id"],
        "bootstrap_sha256" => LinuxInstallFiles.digest(bootstrap),
        "inventory_sha256" =>
          LinuxInstallFiles.digest(File.read!(release <> "/release-inventory.json"))
      }

      File.rename!(release, base <> "/releases/" <> identity["artifact_id"])
      identity
    end
  end
end
