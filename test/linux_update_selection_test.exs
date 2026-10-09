Code.require_file(Path.expand("support/linux_update_fixtures.exs", __DIR__))

defmodule WotexHome.LinuxUpdateSelectionTest do
  @moduledoc false
  use ExUnit.Case
  alias Woh.Tool.{LinuxUpdateJournal, LinuxUpdateSelection}
  alias WotexHome.LinuxUpdateFixtures, as: F

  setup do
    source = F.identity(1)
    target = F.identity(2)
    owner = F.owner(source)
    {:ok, journal} = LinuxUpdateJournal.new(owner, source)
    {:ok, initial} = LinuxUpdateSelection.new(owner, journal)

    %{
      source: source,
      target: target,
      owner: owner,
      journal: journal,
      initial: initial,
      nonce: F.nonce()
    }
  end

  test "selection follows the exact latest intent and survives both sides of completion", c do
    {:ok, initial_bytes} = LinuxUpdateSelection.encode(c.initial)

    {:ok, planned} =
      LinuxUpdateJournal.prepare(c.journal, c.nonce, c.source, c.target, F.process())

    assert {:ok, c.initial} == LinuxUpdateSelection.decode(initial_bytes, c.owner, planned)
    assert {:error, _} = LinuxUpdateSelection.select(c.initial, planned, c.nonce)
    running = F.running(c.journal, c.source, c.target, c.nonce)
    assert {:ok, selected} = LinuxUpdateSelection.select(c.initial, running, c.nonce)
    assert selected["release"] == c.target and selected["selection_generation"] == 1
    assert selected["configuration"] == F.configuration(c.target["artifact_id"])
    assert {:ok, ^selected} = LinuxUpdateSelection.select(selected, running, c.nonce)
    {:ok, selected_bytes} = LinuxUpdateSelection.encode(selected)
    complete = F.complete(running, c.nonce)
    assert {:ok, ^selected} = LinuxUpdateSelection.decode(selected_bytes, c.owner, complete)
    assert {:error, _} = LinuxUpdateSelection.decode(initial_bytes, c.owner, complete)
    assert {:error, _} = LinuxUpdateSelection.select(selected, running, F.nonce(2))
    assert {:error, _} = LinuxUpdateSelection.new(c.owner, complete)
  end

  test "substituted owner, history, original begin and target fields refuse", c do
    running = F.running(c.journal, c.source, c.target, c.nonce)
    {:ok, selected} = LinuxUpdateSelection.select(c.initial, running, c.nonce)
    {:ok, bytes} = LinuxUpdateSelection.encode(selected)
    [intent] = running["updates"]
    assert {:error, _} = LinuxUpdateSelection.decode(bytes, c.owner <> " ", running)

    for change <- [
          %{"source" => %{c.source | "inventory_sha256" => String.duplicate("a", 64)}},
          %{"original_main_pid" => 124},
          %{"source_process" => %{intent["source_process"] | "start_ticks" => 91}},
          %{
            "source_process" => %{
              intent["source_process"]
              | "invocation_id" => String.duplicate("c", 32)
            }
          },
          %{"maintenance" => %{intent["maintenance"] | "begin_revision" => 7}},
          %{"maintenance" => %{intent["maintenance"] | "principal_id" => "maintainer:other"}}
        ] do
      journal = %{running | "updates" => [Map.merge(intent, change)]}
      assert {:error, _} = LinuxUpdateSelection.decode(bytes, c.owner, journal)
    end

    for changed <- [
          Map.put(selected, "credential", "inert canary"),
          %{selected | "schema_version" => 1.0},
          %{selected | "selection_generation" => 1.0},
          %{selected | "selection_generation" => 0},
          %{selected | "selected_nonce" => F.nonce(2)},
          %{selected | "intent_sha256" => String.duplicate("a", 64)},
          %{selected | "release" => c.source},
          %{selected | "configuration" => F.configuration(c.source["artifact_id"])}
        ],
        do:
          assert(
            {:error, _} = LinuxUpdateSelection.decode(JSON.encode!(changed), c.owner, running)
          )

    for bad <- ["{}{}", "{\"scope\":1,\"scope\":2}", String.duplicate("x", 65_537)],
        do: assert({:error, _} = LinuxUpdateSelection.decode(bad, c.owner, running))
  end

  test "a subsequent pending intent retains current selection and cannot skip a generation", c do
    first = F.running(c.journal, c.source, c.target, c.nonce)
    {:ok, selected} = LinuxUpdateSelection.select(c.initial, first, c.nonce)
    complete = F.complete(first, c.nonce)
    third = F.identity(3)
    second_nonce = F.nonce(2)

    {:ok, planned} =
      LinuxUpdateJournal.prepare(complete, second_nonce, c.target, third, F.process())

    {:ok, bytes} = LinuxUpdateSelection.encode(selected)
    assert {:ok, ^selected} = LinuxUpdateSelection.decode(bytes, c.owner, planned)
    assert {:error, _} = LinuxUpdateSelection.select(selected, planned, second_nonce)
    second = F.running(complete, c.target, third, second_nonce)
    assert {:error, _} = LinuxUpdateSelection.select(c.initial, second, second_nonce)
    assert {:ok, next} = LinuxUpdateSelection.select(selected, second, second_nonce)
    assert next["selection_generation"] == 2 and next["release"] == third
    assert {:error, _} = LinuxUpdateSelection.select(selected, second, c.nonce)
  end

  test "legacy completed selection retains its exact digest after journal format upgrade", c do
    running = F.running(c.journal, c.source, c.target, c.nonce)

    legacy = %{
      running
      | "schema_version" => 1,
        "updates" => Enum.map(running["updates"], &Map.delete(&1, "source_process"))
    }

    {:ok, selected} = LinuxUpdateSelection.select(c.initial, legacy, c.nonce)
    {:ok, bytes} = LinuxUpdateSelection.encode(selected)
    complete = F.complete(legacy, c.nonce)
    {:ok, upgraded} = LinuxUpdateJournal.upgrade(complete)
    assert {:ok, ^selected} = LinuxUpdateSelection.decode(bytes, c.owner, upgraded)
    next = F.identity(3)

    {:ok, appended} =
      LinuxUpdateJournal.prepare(upgraded, F.nonce(2), c.target, next, F.process())

    assert {:ok, ^selected} = LinuxUpdateSelection.decode(bytes, c.owner, appended)
    # Adding a fabricated original incarnation to completed legacy history
    # changes its digest; format upgrade itself never invents that evidence.
    [intent] = upgraded["updates"]
    {:ok, process} = Woh.Tool.LinuxUpdateProcess.retain(F.process())
    changed = %{upgraded | "updates" => [Map.put(intent, "source_process", process)]}
    assert {:error, _} = LinuxUpdateSelection.decode(bytes, c.owner, changed)
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    alias Woh.Tool.LinuxUpdateRecords
    @native Path.expand("../native/linux", __DIR__)
    setup c do
      root =
        Path.join(System.tmp_dir!(), "woh-selected-release-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      base = root <> "/installation"
      File.mkdir!(base)
      File.chmod!(base, 0o755)
      File.mkdir!(base <> "/.installer")
      File.chmod!(base <> "/.installer", 0o700)
      File.write!(base <> "/.installer/owner.json", c.owner)
      File.chmod!(base <> "/.installer/owner.json", 0o600)
      tools = root <> "/tools"
      File.mkdir!(tools)
      File.chmod!(tools, 0o700)

      for name <- ~w(installer-files installer-files.pl),
          do: File.cp!(@native <> "/" <> name, tools <> "/" <> name)

      tool = tools <> "/locked-file-tool"

      File.write!(tool, ~S"""
      #!/bin/sh
      set -eu
      probe_directory=$(dirname "$0")
      exec "$probe_directory/installer-files" lock-run "$probe_directory/fixture.lock" /bin/sh -c '
        probe_tool=$1
        probe_operation=$2
        shift 2
        exec "$probe_tool" "$probe_operation" --lock-owner "$$" "$WOTEX_HOME_INSTALL_LOCK_FD" "$WOTEX_HOME_INSTALL_LOCK_PATH" "$@"
      ' selection-fixture "$probe_directory/installer-files" "$@"
      """)

      File.chmod!(tool, 0o755)
      on_exit(fn -> File.rm_rf!(root) end)
      %{base: base, tool: tool, path: base <> "/.installer/current-release.json"}
    end

    test "native selection CAS retains original ownership and resolves publication before journal completion",
         c do
      {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, c.journal, nil, c.tool)

      assert {:ok, initial_bytes} =
               LinuxUpdateSelection.persist(c.base, c.owner, c.journal, c.initial, nil, c.tool)

      assert {:ok, c.initial, initial_bytes} ==
               LinuxUpdateSelection.load(c.base, c.owner, c.journal, c.tool)

      running = F.running(c.journal, c.source, c.target, c.nonce)
      {:ok, selected} = LinuxUpdateSelection.select(c.initial, running, c.nonce)

      assert {:error, _} =
               LinuxUpdateSelection.persist(
                 c.base,
                 c.owner,
                 running,
                 selected,
                 initial_bytes,
                 c.tool
               )

      assert File.read!(c.path) == initial_bytes
      publish_phase_fixture(c, running)

      assert {:ok, selected_bytes} =
               LinuxUpdateSelection.persist(
                 c.base,
                 c.owner,
                 running,
                 selected,
                 initial_bytes,
                 c.tool
               )

      assert {:ok, ^selected, ^selected_bytes} =
               LinuxUpdateSelection.load(c.base, c.owner, running, c.tool)

      complete = F.complete(running, c.nonce)
      assert {:error, _} = LinuxUpdateSelection.load(c.base, c.owner, complete, c.tool)
      publish_phase_fixture(c, complete)

      assert {:ok, ^selected, ^selected_bytes} =
               LinuxUpdateSelection.load(c.base, c.owner, complete, c.tool)

      assert {:error, _} =
               LinuxUpdateSelection.persist(
                 c.base,
                 c.owner,
                 running,
                 selected,
                 initial_bytes,
                 c.tool
               )

      assert {:error, _} =
               LinuxUpdateSelection.persist(
                 c.base,
                 c.owner,
                 running,
                 c.initial,
                 selected_bytes,
                 c.tool
               )

      assert File.read!(c.base <> "/.installer/owner.json") == c.owner
      assert File.read!(c.path) == selected_bytes
    end

    test "foreign progress, links, modes and expanded record names remain preserved", c do
      {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, c.journal, nil, c.tool)

      {:ok, bytes} =
        LinuxUpdateSelection.persist(c.base, c.owner, c.journal, c.initial, nil, c.tool)

      running = F.running(c.journal, c.source, c.target, c.nonce)
      {:ok, selected} = LinuxUpdateSelection.select(c.initial, running, c.nonce)
      publish_phase_fixture(c, running)
      File.write!(c.path, "foreign progress")

      assert {:error, _} =
               LinuxUpdateSelection.persist(c.base, c.owner, running, selected, bytes, c.tool)

      assert File.read!(c.path) == "foreign progress"
      File.write!(c.path, bytes)
      File.chmod!(c.path, 0o644)
      assert {:error, _} = LinuxUpdateSelection.load(c.base, c.owner, running, c.tool)
      File.chmod!(c.path, 0o600)
      File.rename!(c.path, c.path <> ".saved")
      File.ln_s!(c.path <> ".saved", c.path)
      assert {:error, _} = LinuxUpdateSelection.load(c.base, c.owner, running, c.tool)

      assert {:error, _} =
               LinuxUpdateSelection.persist(c.base, c.owner, running, selected, bytes, c.tool)

      assert File.read!(c.path <> ".saved") == bytes

      assert {:error, _} =
               LinuxUpdateRecords.write(c.base, c.owner, "owner.json", "foreign", nil, c.tool)

      assert {:error, _} =
               LinuxUpdateRecords.write(
                 c.base,
                 c.owner,
                 "../current-release.json",
                 "foreign",
                 nil,
                 c.tool
               )

      assert File.read!(c.base <> "/.installer/owner.json") == c.owner
    end

    defp publish_phase_fixture(c, journal) do
      # Synthetic phases only: this fixture does not switch/start a process.
      {:ok, bytes} = LinuxUpdateJournal.encode(journal)
      File.write!(c.base <> "/.installer/update-journal.json", bytes)
    end
  end
end
