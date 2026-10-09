Code.require_file(Path.expand("support/linux_update_fixtures.exs", __DIR__))

defmodule WotexHome.LinuxUpdateJournalTest do
  @moduledoc false
  use ExUnit.Case
  alias Woh.Tool.{LinuxInstallFiles, LinuxServicePackage, LinuxUpdateJournal}
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.Store
  alias WotexHome.LinuxUpdateFixtures, as: F

  @nonce String.duplicate("a", 64)
  @other String.duplicate("b", 64)
  @identity %{
    "source_revision" => String.duplicate("1", 40),
    "artifact_id" => String.duplicate("2", 64),
    "bootstrap_sha256" => String.duplicate("3", 64),
    "inventory_sha256" => String.duplicate("4", 64)
  }
  @target %{
    "source_revision" => String.duplicate("5", 40),
    "artifact_id" => String.duplicate("6", 64),
    "bootstrap_sha256" => String.duplicate("7", 64),
    "inventory_sha256" => String.duplicate("8", 64)
  }
  @status %{
    "principal_id" => "maintainer:fixture",
    "authority_epoch" => 1,
    "store_revision" => 4,
    "rule_generation" => 0,
    "begin_revision" => 0,
    "state" => "normal",
    "store_schema_version" => 28,
    "writable" => true,
    "update_fence_enabled" => true
  }

  setup do
    owner = owner_bytes()
    assert {:ok, journal} = LinuxUpdateJournal.new(owner, @identity)
    %{owner: owner, journal: journal}
  end

  test "intent repeats retain their original phase and refuse substitution or overlapping work",
       c do
    assert {:ok, planned} =
             LinuxUpdateJournal.prepare(c.journal, @nonce, @identity, @target, F.process())

    assert {:ok, ^planned} =
             LinuxUpdateJournal.prepare(planned, @nonce, @identity, @target, F.process())

    assert {:ok, staged} = LinuxUpdateJournal.advance(planned, @nonce, "staged")

    assert {:ok, ^staged} =
             LinuxUpdateJournal.prepare(staged, @nonce, @identity, @target, F.process())

    assert {:error, _} =
             LinuxUpdateJournal.prepare(staged, @nonce, @identity, @target, F.process(124))

    assert {:error, _} =
             LinuxUpdateJournal.prepare(staged, @nonce, @identity, @identity, F.process())

    assert {:error, _} =
             LinuxUpdateJournal.prepare(staged, @other, @identity, @target, F.process())

    assert {:error, _} = LinuxUpdateJournal.advance(staged, @nonce, "fenced")
    assert {:error, _} = LinuxUpdateJournal.advance(staged, @nonce, "begin_recorded")
    assert {:error, _} = LinuxUpdateJournal.advance(staged, @other, "staged")
  end

  test "original begin tuple cannot be replaced after recording or a lost reply", c do
    staged = staged(c.journal)
    assert {:ok, recorded} = LinuxUpdateJournal.record_begin(staged, @nonce, @status)
    assert {:ok, commands} = LinuxUpdateJournal.begin_commands(recorded, @nonce)
    assert commands.retry == ["maintenance-begin", "1", "update:" <> @nonce, "4"]
    assert commands.lookup == ["maintenance-operation-status", "1", "update:" <> @nonce]
    assert {:ok, bytes} = LinuxUpdateJournal.encode(recorded)
    assert {:ok, ^recorded} = LinuxUpdateJournal.decode(bytes, c.owner)
    assert {:error, _} = LinuxUpdateJournal.record_begin(recorded, @nonce, @status)

    assert {:error, _} =
             LinuxUpdateJournal.record_begin(recorded, @nonce, %{@status | "store_revision" => 9})

    for change <- [
          %{"store_schema_version" => 27},
          %{"writable" => false},
          %{"update_fence_enabled" => false},
          %{"credential" => "inert canary"},
          %{"state" => "maintenance", "begin_revision" => 4},
          %{"store_revision" => 9_223_372_036_854_775_807},
          %{"authority_epoch" => 0}
        ] do
      assert {:error, _} =
               LinuxUpdateJournal.record_begin(staged, @nonce, Map.merge(@status, change))
    end

    receipt = receipt()
    assert {:ok, accepted} = LinuxUpdateJournal.accept_begin(recorded, @nonce, receipt)
    assert {:ok, ^commands} = LinuxUpdateJournal.begin_commands(accepted, @nonce)

    for change <- [
          %{"principal_id" => "maintainer:other"},
          %{"authority_epoch" => 2},
          %{"operation_id" => "update:" <> @other},
          %{"begin_revision" => 5},
          %{"action" => "end"},
          %{"revision" => 4},
          %{"credential" => "inert canary"}
        ],
        do:
          assert(
            {:error, _} =
              LinuxUpdateJournal.accept_begin(recorded, @nonce, Map.merge(receipt, change))
          )
  end

  test "source incarnation is immutable even when its numeric PID is reused", c do
    process = F.process()
    {:ok, planned} = LinuxUpdateJournal.prepare(c.journal, @nonce, @identity, @target, process)
    {:ok, staged} = LinuxUpdateJournal.advance(planned, @nonce, "staged")
    assert c.journal["schema_version"] == 2
    assert {:error, _} = LinuxUpdateJournal.prepare(c.journal, @nonce, @identity, @target, 123)

    for changed <- [
          %{process | start_ticks: 91},
          %{process | boot_id: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"},
          %{process | invocation_id: String.duplicate("c", 32)},
          %{process | image_inode: 8},
          %{process | image_sha256: String.duplicate("c", 64)}
        ],
        do:
          assert(
            {:error, _} = LinuxUpdateJournal.prepare(staged, @nonce, @identity, @target, changed)
          )

    [intent] = planned["updates"]
    {:ok, observation} = Woh.Tool.LinuxUpdateProcess.restore(intent["source_process"])
    assert observation == process

    for changed <- [
          Map.put(intent["source_process"], "credential", "inert canary"),
          Map.put(intent["source_process"], "pid", 124),
          Map.put(intent["source_process"], "account_id", 212)
        ] do
      candidate = %{planned | "updates" => [%{intent | "source_process" => changed}]}
      assert {:error, _} = LinuxUpdateJournal.decode(JSON.encode!(candidate), c.owner)
    end
  end

  test "completed legacy history upgrades without manufacturing process evidence", c do
    current = F.complete(F.running(c.journal, @identity, @target, @nonce), @nonce)

    legacy = %{
      current
      | "schema_version" => 1,
        "updates" => Enum.map(current["updates"], &Map.delete(&1, "source_process"))
    }

    {:ok, bytes} = LinuxUpdateJournal.encode(legacy)
    assert {:ok, ^legacy} = LinuxUpdateJournal.decode(bytes, c.owner)
    assert {:ok, upgraded} = LinuxUpdateJournal.upgrade(legacy)

    assert upgraded["updates"] == legacy["updates"] and
             upgraded["generation"] == legacy["generation"]

    assert {:ok, ^upgraded} = LinuxUpdateJournal.upgrade(upgraded)
    assert {:ok, _} = LinuxUpdateJournal.decode(JSON.encode!(upgraded), c.owner)
    next = F.identity(3)

    assert {:ok, appended} =
             LinuxUpdateJournal.prepare(upgraded, @other, @target, next, F.process())

    assert hd(appended["updates"]) == hd(legacy["updates"])
    assert Map.has_key?(List.last(appended["updates"]), "source_process")
    assert {:error, _} = LinuxUpdateJournal.prepare(legacy, @other, @target, next, 123)
    [intent] = legacy["updates"]

    pending = %{
      legacy
      | "generation" => 1,
        "updates" => [%{intent | "phase" => "planned", "maintenance" => nil}]
    }

    assert {:ok, _} = LinuxUpdateJournal.decode(JSON.encode!(pending), c.owner)
    assert {:error, _} = LinuxUpdateJournal.upgrade(pending)

    assert {:error, _} =
             LinuxUpdateJournal.decode(
               JSON.encode!(Map.put(pending, "schema_version", 2)),
               c.owner
             )
  end

  test "closed records refuse damaged links, history, modes of identity and expanded private fields",
       c do
    {:ok, recorded} = LinuxUpdateJournal.record_begin(staged(c.journal), @nonce, @status)
    [intent] = recorded["updates"]

    for changed <- [
          Map.put(recorded, "credential", "inert canary"),
          %{recorded | "owner_sha256" => String.duplicate("f", 64)},
          %{recorded | "generation" => 2},
          %{recorded | "generation" => 3.0},
          %{recorded | "schema_version" => 1.0},
          %{recorded | "updates" => [Map.put(intent, "credential", "inert canary")]},
          %{recorded | "updates" => [%{intent | "source" => @target}]},
          %{recorded | "updates" => [intent, intent]},
          %{recorded | "updates" => [%{intent | "original_main_pid" => 1}]},
          %{recorded | "updates" => [%{intent | "maintenance" => nil}]},
          %{recorded | "updates" => [%{intent | "phase" => "planned"}]},
          %{
            recorded
            | "updates" => [%{intent | "target" => Map.put(@target, "artifact_id", "invalid")}]
          }
        ] do
      assert {:error, _} = LinuxUpdateJournal.decode(JSON.encode!(changed), c.owner)
    end

    for bytes <- ["{}", "[]", "{}{}", "{\"scope\":1,\"scope\":2}", String.duplicate("x", 65_537)],
        do: assert({:error, _} = LinuxUpdateJournal.decode(bytes, c.owner))

    assert {:error, _} = LinuxUpdateJournal.new(c.owner, @target)
    assert {:error, _} = LinuxUpdateJournal.decode(JSON.encode!(recorded), c.owner <> " ")
  end

  test "history is finite, chained and retained without eviction", c do
    journal =
      Enum.reduce(1..16, c.journal, fn number, journal ->
        source = if number == 1, do: @identity, else: List.last(journal["updates"])["target"]

        target = %{
          @target
          | "artifact_id" =>
              number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")
        }

        nonce =
          number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

        {:ok, journal} = LinuxUpdateJournal.prepare(journal, nonce, source, target, F.process())
        {:ok, journal} = LinuxUpdateJournal.advance(journal, nonce, "staged")
        {:ok, journal} = LinuxUpdateJournal.record_begin(journal, nonce, @status)

        {:ok, journal} =
          LinuxUpdateJournal.accept_begin(
            journal,
            nonce,
            Map.put(receipt(), "operation_id", "update:" <> nonce)
          )

        Enum.reduce(
          ~w(fenced stopped configuration_ready target_running selected complete),
          journal,
          fn phase, value ->
            {:ok, updated} = LinuxUpdateJournal.advance(value, nonce, phase)
            updated
          end
        )
      end)

    assert length(journal["updates"]) == 16
    assert journal["generation"] == 160
    assert {:ok, bytes} = LinuxUpdateJournal.encode(journal)
    assert {:ok, ^journal} = LinuxUpdateJournal.decode(bytes, c.owner)

    assert {:error, _} =
             LinuxUpdateJournal.prepare(
               journal,
               @nonce,
               List.last(journal["updates"])["target"],
               @target,
               F.process()
             )

    assert List.first(journal["updates"])["source"] == @identity
  end

  test "actual SQLite lost begin reply resolves only the original operation after restart", c do
    directory =
      Path.join(System.tmp_dir!(), "woh-update-receipt-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")

    options = [
      path: path,
      update_fence: %{artifact_id: @identity["artifact_id"], path: directory <> "/guard.json"}
    ]

    store = start_supervised!(Supervisor.child_spec({Store, options}, restart: :temporary))

    {:ok, credential, _} =
      Store.provision_principal(store, "maintainer:fixture", ["host:maintain"], [])

    authority = Authority.new(store: store)
    {:ok, status} = Authority.maintenance_update_status(authority, credential)
    status = wire(status)
    {:ok, recorded} = LinuxUpdateJournal.record_begin(staged(c.journal), @nonce, status)
    {:ok, bytes} = LinuxUpdateJournal.encode(recorded)
    # The caller discards the response; its persisted original tuple remains.
    {:ok, commands} = LinuxUpdateJournal.begin_commands(recorded, @nonce)
    {:ok, request} = CLI.build_request(commands.retry, credential)

    {:ok, original} =
      Authority.begin_maintenance(
        authority,
        credential,
        request["authority_epoch"],
        request["operation_id"],
        request["expected_revision"]
      )

    :ok = GenServer.stop(store)
    restarted = start_supervised!({Store, options}, id: :restarted_update)
    authority = Authority.new(store: restarted)
    assert {:ok, retained} = LinuxUpdateJournal.decode(bytes, c.owner)
    assert {:ok, ^commands} = LinuxUpdateJournal.begin_commands(retained, @nonce)

    assert {:ok, ^original} =
             Authority.maintenance_operation_status(
               authority,
               credential,
               request["authority_epoch"],
               request["operation_id"]
             )

    assert {:ok, ^original} =
             Authority.begin_maintenance(
               authority,
               credential,
               request["authority_epoch"],
               request["operation_id"],
               request["expected_revision"]
             )

    assert {:ok, accepted} = LinuxUpdateJournal.accept_begin(retained, @nonce, wire(original))

    assert List.last(accepted["updates"])["maintenance"]["begin_revision"] ==
             original.begin_revision

    assert {:ok, %{state: :maintenance, begin_revision: begin}} =
             Authority.maintenance_update_status(authority, credential)

    assert begin == original.begin_revision
    assert {:error, _} = LinuxUpdateJournal.record_begin(retained, @nonce, status)
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    @native Path.expand("../native/linux", __DIR__)
    setup c do
      root =
        Path.join(System.tmp_dir!(), "woh-update-journal-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      base = Path.join(root, "installation")
      File.mkdir!(base)
      File.chmod!(base, 0o755)
      File.mkdir!(base <> "/.installer")
      File.chmod!(base <> "/.installer", 0o700)
      File.write!(base <> "/.installer/owner.json", c.owner)
      File.chmod!(base <> "/.installer/owner.json", 0o600)
      tools = Path.join(root, "tools")
      File.mkdir!(tools)
      File.chmod!(tools, 0o700)

      for name <- ~w(installer-files installer-files.pl),
          do: File.cp!(Path.join(@native, name), Path.join(tools, name))

      tool = Path.join(tools, "locked-file-tool")

      File.write!(tool, ~S"""
      #!/bin/sh
      set -eu
      probe_directory=$(dirname "$0")
      exec "$probe_directory/installer-files" lock-run "$probe_directory/fixture.lock" /bin/sh -c '
        probe_tool=$1
        probe_operation=$2
        shift 2
        exec "$probe_tool" "$probe_operation" --lock-owner "$$" "$WOTEX_HOME_INSTALL_LOCK_FD" "$WOTEX_HOME_INSTALL_LOCK_PATH" "$@"
      ' journal-fixture "$probe_directory/installer-files" "$@"
      """)

      File.chmod!(tool, 0o755)
      unlocked = Path.join(tools, "unlocked-file-tool")

      File.write!(unlocked, ~S"""
      #!/bin/sh
      set -eu
      probe_directory=$(dirname "$0")
      exec "$probe_directory/installer-files" "$@"
      """)

      File.chmod!(unlocked, 0o755)
      on_exit(fn -> File.rm_rf!(root) end)

      %{
        base: base,
        tool: tool,
        unlocked: unlocked,
        path: base <> "/.installer/update-journal.json"
      }
    end

    test "native CAS persists exact intent and original begin across reload, rejecting stale or skipped writes",
         c do
      assert {:ok, initial_bytes} =
               LinuxUpdateJournal.persist(c.base, c.owner, c.journal, nil, c.tool)

      {:ok, planned} =
        LinuxUpdateJournal.prepare(c.journal, @nonce, @identity, @target, F.process())

      assert {:ok, planned_bytes} =
               LinuxUpdateJournal.persist(c.base, c.owner, planned, initial_bytes, c.tool)

      assert {:ok, ^planned, ^planned_bytes} = LinuxUpdateJournal.load(c.base, c.owner, c.tool)
      {:ok, staged} = LinuxUpdateJournal.advance(planned, @nonce, "staged")
      [intent] = staged["updates"]

      replaced = %{
        staged
        | "updates" => [
            %{intent | "source_process" => %{intent["source_process"] | "start_ticks" => 91}}
          ]
      }

      assert {:ok, _} = LinuxUpdateJournal.encode(replaced)

      assert {:error, _} =
               LinuxUpdateJournal.persist(c.base, c.owner, replaced, planned_bytes, c.tool)

      assert File.read!(c.path) == planned_bytes
      {:ok, recorded} = LinuxUpdateJournal.record_begin(staged, @nonce, @status)

      assert {:error, _} =
               LinuxUpdateJournal.persist(c.base, c.owner, recorded, planned_bytes, c.tool)

      assert {:ok, staged_bytes} =
               LinuxUpdateJournal.persist(c.base, c.owner, staged, planned_bytes, c.tool)

      assert {:error, _} =
               LinuxUpdateJournal.persist(c.base, c.owner, staged, planned_bytes, c.tool)

      assert {:ok, recorded_bytes} =
               LinuxUpdateJournal.persist(c.base, c.owner, recorded, staged_bytes, c.tool)

      assert {:ok, ^recorded, ^recorded_bytes} = LinuxUpdateJournal.load(c.base, c.owner, c.tool)

      assert {:error, _} =
               LinuxUpdateJournal.persist(c.base, c.owner, planned, recorded_bytes, c.tool)

      assert File.read!(c.base <> "/.installer/owner.json") == c.owner
      assert File.read!(c.path) == recorded_bytes
    end

    test "foreign bytes, links, private modes, substituted owner and missing lock refuse without mutation",
         c do
      assert {:ok, bytes} = LinuxUpdateJournal.persist(c.base, c.owner, c.journal, nil, c.tool)

      {:ok, planned} =
        LinuxUpdateJournal.prepare(c.journal, @nonce, @identity, @target, F.process())

      File.write!(c.path, "foreign progress")
      assert {:error, _} = LinuxUpdateJournal.persist(c.base, c.owner, planned, bytes, c.tool)
      assert File.read!(c.path) == "foreign progress"
      File.write!(c.path, bytes)
      File.chmod!(c.path, 0o644)
      assert {:error, _} = LinuxUpdateJournal.load(c.base, c.owner, c.tool)
      assert {:error, _} = LinuxUpdateJournal.persist(c.base, c.owner, planned, bytes, c.tool)
      File.chmod!(c.path, 0o600)
      File.ln!(c.path, c.path <> ".link")
      assert {:error, _} = LinuxUpdateJournal.load(c.base, c.owner, c.tool)
      File.rm!(c.path <> ".link")
      File.rename!(c.path, c.path <> ".original")
      File.ln_s!(c.path <> ".original", c.path)
      assert {:error, _} = LinuxUpdateJournal.load(c.base, c.owner, c.tool)
      assert {:error, _} = LinuxUpdateJournal.persist(c.base, c.owner, planned, bytes, c.tool)
      assert File.read!(c.path <> ".original") == bytes
      File.rm!(c.path)
      File.rename!(c.path <> ".original", c.path)
      assert {:error, _} = LinuxUpdateJournal.load(c.base, c.owner <> " ", c.tool)

      assert {:error, _} =
               LinuxUpdateJournal.load(c.base, c.owner, c.unlocked)

      File.write!(c.base <> "/.installer/owner.json", "foreign owner")
      assert {:error, _} = LinuxUpdateJournal.persist(c.base, c.owner, planned, bytes, c.tool)
      assert File.read!(c.path) == bytes
    end

    test "native format upgrade uses original-byte CAS without changing completed history", c do
      current = F.complete(F.running(c.journal, @identity, @target, @nonce), @nonce)

      legacy = %{
        current
        | "schema_version" => 1,
          "updates" => Enum.map(current["updates"], &Map.delete(&1, "source_process"))
      }

      {:ok, bytes} = LinuxUpdateJournal.encode(legacy)
      # Completed administrative values are synthetic; publication/CAS and
      # preservation of the exact retained original are actual native operations.
      File.write!(c.path, bytes)
      File.chmod!(c.path, 0o600)
      {:ok, upgraded} = LinuxUpdateJournal.upgrade(legacy)

      forged =
        put_in(upgraded, ["initial_release", "inventory_sha256"], String.duplicate("f", 64))

      assert {:error, _} = LinuxUpdateJournal.persist(c.base, c.owner, forged, bytes, c.tool)
      assert File.read!(c.path) == bytes

      assert {:ok, upgraded_bytes} =
               LinuxUpdateJournal.persist(c.base, c.owner, upgraded, bytes, c.tool)

      assert {:ok, ^upgraded, ^upgraded_bytes} = LinuxUpdateJournal.load(c.base, c.owner, c.tool)
      assert {:error, _} = LinuxUpdateJournal.persist(c.base, c.owner, upgraded, bytes, c.tool)

      assert {:error, _} =
               LinuxUpdateJournal.persist(c.base, c.owner, legacy, upgraded_bytes, c.tool)

      assert File.read!(c.path) == upgraded_bytes
      assert File.read!(c.base <> "/.installer/owner.json") == c.owner
    end
  end

  defp staged(journal) do
    {:ok, planned} = LinuxUpdateJournal.prepare(journal, @nonce, @identity, @target, F.process())
    {:ok, staged} = LinuxUpdateJournal.advance(planned, @nonce, "staged")
    staged
  end

  defp receipt,
    do: %{
      "principal_id" => "maintainer:fixture",
      "authority_epoch" => 1,
      "operation_id" => "update:" <> @nonce,
      "action" => "begin",
      "begin_revision" => 6,
      "revision" => 6,
      "rule_generation" => 1,
      "affected_requests" => 0,
      "unknown_outcomes" => 0,
      "state" => "maintenance"
    }

  defp wire(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp owner_bytes do
    JSON.encode!(%{
      "schema_version" => 1,
      "scope" => "linux_initial_installation",
      "installation_id" => String.duplicate("9", 64),
      "source_revision" => @identity["source_revision"],
      "artifact_id" => @identity["artifact_id"],
      "bootstrap_sha256" => @identity["bootstrap_sha256"],
      "profile" => LinuxServicePackage.profile(),
      "account_id" => 211,
      "configuration" =>
        Map.new(LinuxServicePackage.files(@identity["artifact_id"], 2), fn {path, bytes} ->
          {"/" <> path, LinuxInstallFiles.digest(bytes)}
        end)
    }) <> "\n"
  end
end
