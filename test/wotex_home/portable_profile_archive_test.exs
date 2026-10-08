defmodule WotexHome.PortableProfileArchiveTest do
  use ExUnit.Case
  import Bitwise
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, ProfileRestore, Store}
  alias WotexHome.Profiles.{Archive, Artifact, Bindings, Codec, Custody}
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, Transport}
  alias WotexHome.Profiles.ReviewSession
  @store __MODULE__.Store
  @reviews __MODULE__.Reviews

  defmodule Peer do
    @behaviour Transport
    @impl true
    def send(
          _,
          _,
          <<_::32, source::little-32, target::binary-size(6), _::72, sequence::8, _::64,
            type::little-16, _::16, _::binary>>
        ) do
      {reply_type, payload} =
        case type do
          2 -> {3, <<1, 56_700::little-32>>}
          32 -> {33, <<1::little-32, 22::little-32, 0::32>>}
          14 -> {15, <<1_700_000_000::little-64, 0::64, 22::little-16, 1::little-16>>}
        end

      target = if type == 2, do: <<0xD0, 0x73, 0xD5, 0, 0, 1>>, else: target

      reply =
        <<36 + byte_size(payload)::little-16, 0x1400::little-16, source::little-32,
          target::binary, 0::16, 0::48, 0::8, sequence::8, 0::64, reply_type::little-16, 0::16,
          payload::binary>>

      Process.put(:archive_peer, Process.get(:archive_peer, []) ++ [reply])
      :ok
    end

    @impl true
    def recv(_, _) do
      case Process.get(:archive_peer, []) do
        [reply | rest] ->
          Process.put(:archive_peer, rest)
          {:ok, "192.0.2.10:56700", reply}

        [] ->
          {:error, :timeout}
      end
    end
  end

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()

    directory =
      Path.join(
        temporary,
        "woh-profile-archive-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    root = Path.join(directory, "profiles")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    custody = start_supervised!({Custody, root: root, store_owner: @store})
    path = Path.join(directory, "home.sqlite")

    store =
      start_supervised!(
        {Store, path: path, name: @store, profile_custody: custody, profile_reviews: @reviews}
      )

    {:ok, manager, 1} =
      Store.provision_principal(store, "manager:archive", ["profile:manage"], [])

    {:ok, maintainer, 2} =
      Store.provision_principal(store, "maintenance:archive", ["host:maintain"], [])

    authority = Authority.new(store: store, profile_custody: custody)
    {:ok, _} = Authority.begin_maintenance(authority, maintainer, 1, "maintenance:archive", 2)
    bytes = File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))
    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      directory: directory,
      root: root,
      path: path,
      custody: custody,
      store: store,
      manager: manager,
      maintainer: maintainer,
      authority: authority,
      bytes: bytes,
      key: :crypto.strong_rand_bytes(32)
    }
  end

  test "inclusive archive retains approved and revoked exact bytes, excludes leased orphans and refuses startup",
       c do
    {artifact, original} = approve(c)
    {:ok, orphan} = Custody.stage(c.custody, c.bytes <> " ")
    {:ok, lease} = Custody.lease(c.custody, orphan)
    {:ok, revision} = Store.revision(c.store)

    revoke = %{
      original
      | "action" => "revoke",
        "operation_id" => "profile:revoke:archive",
        "expected_revision" => revision,
        "expected_trust_revision" => revision
    }

    {:ok, revoked} = Authority.profile_change(c.authority, c.manager, revoke)
    archive = Path.join(c.directory, "inclusive.backup")

    assert {:ok, %{portable_profile_objects: 1, store_revision: revision}} =
             Store.export_profile_backup(c.store, archive, c.key)

    assert revision == revoked.final_revision
    assert {:ok, %{dependencies: dependencies}} = Backup.verify(archive, c.key)
    assert dependencies.portable_profile_bytes_included
    assert dependencies.portable_profile_object_count == 1
    assert dependencies.profile_artifacts == [commitment(artifact)]
    assert dependencies.profile_operation_rows == 2
    assert dependencies.raw_qualification_artifacts_included == false
    assert dependencies.profile_history_reactivates_on_restore == false
    assert dependencies.device_credentials_and_counters == "external"
    assert mode(archive) == 0o600

    assert {:error, :profile_restore_required} =
             Backup.stage_restore(archive, c.key, archive <> ".db")

    refute File.exists?(archive <> ".db")
    destination = Path.join(c.directory, "restored")

    assert {:error, :invalid_backup} =
             Backup.stage_profile_restore(archive, :crypto.strong_rand_bytes(32), destination)

    refute File.exists?(destination)

    assert {:ok, %{quarantined: true, portable_profile_objects: 1}} =
             Backup.stage_profile_restore(archive, c.key, destination)

    assert mode(destination) == 0o700
    assert mode(Path.join(destination, "profiles")) == 0o700
    restored = Path.join(destination, "profiles/#{artifact.digest}.json")
    assert mode(restored) == 0o400
    assert File.read!(restored) == c.bytes
    refute File.exists?(Path.join(destination, "profiles/#{orphan}.json"))
    database = Path.join(destination, "home.sqlite")
    assert mode(database) == 0o600
    {:ok, db} = Sqlite3.open(database, mode: :readonly)
    assert [[1]] == rows(db, "SELECT value FROM meta WHERE key='restore_quarantine'")

    assert [["revoke"]] ==
             rows(
               db,
               "SELECT action FROM profile_operations ORDER BY final_revision DESC LIMIT 1"
             )

    Sqlite3.close(db)
    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: database)

    assert {:error, :restore_exists} = Backup.stage_profile_restore(archive, c.key, destination)

    assert {:ok, ^revoked} =
             Authority.profile_operation_status(c.authority, c.manager, 1, revoke["operation_id"])

    assert {:ok, %{dispatch_enabled: false, writable: true}} = Store.health(c.store)
    assert :ok = Custody.release(c.custody, lease.token)
    assert {:error, :backup_exists} = Store.export_profile_backup(c.store, archive, c.key)
    assert {:ok, _} = Backup.verify(archive, c.key)
  end

  test "missing, corrupt and unavailable custody reject complete export without changing source history",
       c do
    {artifact, original} = approve(c)

    assert {:ok, receipt} =
             Authority.profile_operation_status(
               c.authority,
               c.manager,
               1,
               original["operation_id"]
             )

    archive = Path.join(c.directory, "unavailable.backup")
    path = Path.join(c.root, artifact.digest <> ".json")
    File.rm!(path)

    assert {:error, :profile_artifact_unavailable} =
             Store.export_profile_backup(c.store, archive, c.key)

    refute File.exists?(archive)
    File.write!(path, c.bytes <> " ")
    File.chmod!(path, 0o400)

    assert {:error, :profile_artifact_unavailable} =
             Store.export_profile_backup(c.store, archive, c.key)

    refute File.exists?(archive)
    stop_supervised!(Custody)

    assert {:error, :profile_artifact_unavailable} =
             Store.export_profile_backup(c.store, archive, c.key)

    assert {:ok, ^receipt} =
             Authority.profile_operation_status(
               c.authority,
               c.manager,
               1,
               original["operation_id"]
             )

    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(c.store)
    refute Enum.any?(File.ls!(c.directory), &String.starts_with?(&1, ".wotex-backup-"))
  end

  test "a selected target retains one-use review, declaration and original receipt through byte quarantine",
       c do
    {_artifact, input, selected, authority, operator} = select_target(c)
    archive = Path.join(c.directory, "selected.backup")

    assert {:ok, %{portable_profile_objects: 1}} =
             Store.export_profile_backup(c.store, archive, c.key)

    assert {:ok, %{dependencies: %{profile_selection_rows: 1, profile_operation_rows: 2}}} =
             Backup.verify(archive, c.key)

    destination = Path.join(c.directory, "selected-quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, c.key, destination)
    {:ok, db} = Sqlite3.open(Path.join(destination, "home.sqlite"), mode: :readonly)
    assert [["selected", 1]] == rows(db, "SELECT state,generation FROM profile_current")
    assert [[0]] == rows(db, "SELECT COUNT(*) FROM principal_targets")
    assert [[0]] == rows(db, "SELECT COUNT(*) FROM profile_qualifications")
    Sqlite3.close(db)

    assert {:ok, ^selected} =
             Authority.profile_operation_status(authority, operator, 1, input["operation_id"])
  end

  for transition <- [:unrelated_write, :prepared_commit] do
    test "selected-profile schedules retain originals after #{transition} observes byte loss",
         c do
      {artifact, _input, _selected, authority, operator} = select_target(c)
      {:ok, revision} = Store.revision(c.store)
      {:ok, status} = Store.maintenance_status(c.store, c.maintainer)

      assert {:ok, _} =
               Store.end_maintenance(
                 c.store,
                 c.maintainer,
                 1,
                 "maintenance:schedule",
                 revision,
                 status.begin_revision
               )

      target = "light:archive:initial"
      {:ok, current} = Authority.profile_target(authority, operator, target)

      {:ok, manager, _} =
        Store.provision_principal(
          c.store,
          "manager:schedule",
          ~w(rule:review rule:manage control:ordinary),
          [target]
        )

      {:ok, revision} = Store.revision(c.store)

      {:ok, rule} =
        WotexHome.Rules.OperationInput.source("admit", %{
          "authority_epoch" => 1,
          "operation_id" => "rule:profile-body",
          "expected_revision" => revision,
          "rule_id" => "rule:profile-schedule",
          "source_revision" => 1,
          "target_id" => target,
          "on" => true
        })

      {:ok, source} =
        WotexHome.Schedules.Codec.encode(%{
          "id" => "schedule:profile",
          "source_revision" => 1,
          "author_id" => "manager:schedule",
          "rule_id" => "rule:profile-schedule",
          "rule_source_digest" => WotexHome.Schedules.Codec.hash(rule),
          "target_id" => target,
          "resource_revision" => current.resource_revision,
          "late_window_ms" => 10_000,
          "uncertainty_tolerance_ms" => 1_000,
          "trigger" => ["interval", 100_000, 60_000, 0, nil]
        })

      {:ok, original} =
        WotexHome.Schedules.OperationInput.encode("admit", %{
          "authority_epoch" => 1,
          "operation_id" => "schedule:profile:admit",
          "expected_revision" => revision,
          "source_document" => source,
          "rule_document" => rule
        })

      assert {:ok, admitted} = Store.retain_schedule_content(c.store, manager, original)
      clock(%{root: c.directory, store: c.store}, :profile_clock, 90_000)

      {:ok, activate} =
        WotexHome.Schedules.OperationInput.encode("activate", %{
          "authority_epoch" => 1,
          "operation_id" => "schedule:profile:activate",
          "expected_revision" => admitted.revision,
          "admission_revision" => admitted.revision
        })

      assert {:ok, _} = Store.change_schedule(c.store, manager, activate)
      assert {:ok, _, _} = Store.provision_principal(c.store, "reader:schedule", ["read"], [])
      assert {:ok, %{state: :active}} = Store.schedule_status(c.store, manager)
      reference = prepare_profile_schedule_poll(c.store, unquote(transition))
      artifact_file = Path.join(c.root, artifact.digest <> ".json")
      retained_bytes = File.read!(artifact_file)
      File.rm!(artifact_file)
      close_profile_schedule_poll(c.store, reference)

      if reference do
        assert :ok = WotexHome.Recovery.PrivateFile.write(artifact_file, retained_bytes, 65_536)

        assert {:ok, %{state: :suspended, reason: "profile_artifact_unavailable"}} =
                 Store.schedule_status(c.store, manager)
      end

      assert {:ok, _, _} =
               Store.provision_principal(c.store, "reader:schedule:missing", ["read"], [])

      assert {:ok, %{state: :suspended, reason: "profile_artifact_unavailable"}} =
               Store.schedule_status(c.store, manager)

      unless File.exists?(artifact_file) do
        assert :ok = WotexHome.Recovery.PrivateFile.write(artifact_file, retained_bytes, 65_536)
      end

      assert {:ok, %{state: :suspended, reason: "profile_artifact_unavailable"}} =
               Store.schedule_status(c.store, manager)

      assert {:ok, ^admitted} = Store.retain_schedule_content(c.store, manager, original)
      assert {:ok, ^admitted} = Store.original_schedule_status(c.store, manager, original)
      assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(c.store)
    end
  end

  test "custody transfer is Store-only, bounded and historical rather than current admission",
       c do
    {artifact, _} = approve(c)

    assert {:error, :invalid_profile_export} =
             Custody.export_many(c.custody, [commitment(artifact)])

    historic_root = Path.join(c.directory, "historic")
    File.mkdir!(historic_root)
    File.chmod!(historic_root, 0o700)
    {:ok, owner} = Custody.start_link(root: historic_root, store_owner: self())

    try do
      for malformed <- [nil, 1, [1], [%{}], List.duplicate(commitment(artifact), 65)] do
        assert {:error, :invalid_profile_export} = Custody.export_many(owner, malformed)
      end

      {:ok, data} = Codec.decode(c.bytes)

      data =
        Map.put(data, "dependencies", [
          %{"kind" => "registry", "sha256" => String.duplicate("a", 64)}
        ])

      bytes = JSON.encode!(data)
      {:ok, projection} = Bindings.historical_projection(data)

      expected = %{
        artifact_digest: Artifact.digest(bytes),
        projection_digest: Artifact.digest(projection),
        registry_digest: String.duplicate("a", 64)
      }

      path = Path.join(historic_root, expected.artifact_digest <> ".json")
      File.write!(path, bytes)
      File.chmod!(path, 0o400)

      assert {:error, :profile_artifact_unavailable} =
               Custody.read(owner, expected.artifact_digest)

      assert {:ok, [object]} = Custody.export_many(owner, [expected])
      assert object.bytes == bytes
      assert :ok = Archive.validate([expected], [object])
    after
      GenServer.stop(owner)
    end
  end

  test "authenticated damaged record sets, raw/projection/registry identities and database links fail before restore",
       c do
    {artifact, _} = approve(c)
    archive = Path.join(c.directory, "source.backup")
    {:ok, _} = Store.export_profile_backup(c.store, archive, c.key)
    {revision, epoch, plain} = unpack(archive, c.key)
    {:ok, database, [object]} = Archive.decode(plain)
    object_record = record(object)
    prefix = <<byte_size(database)::32, database::binary>>

    invalid_plain = [
      prefix <> <<0::16>>,
      prefix <> <<2::16>> <> object_record <> object_record,
      plain <> "trailing",
      prefix <> <<65::16>>,
      prefix <> <<1::16>> <> record(%{object | bytes: object.bytes <> " "}),
      prefix <> <<1::16>> <> record(%{object | projection_digest: String.duplicate("b", 64)}),
      prefix <> <<1::16>> <> record(%{object | registry_digest: String.duplicate("c", 64)}),
      prefix <> <<1::16>> <> binary_part(object_record, 0, byte_size(object_record) - 1)
    ]

    # A valid extra artifact has exact internal hashes but no retained DB parent.
    {:ok, extra} = Artifact.parse(c.bytes <> " ")

    objects =
      Enum.sort_by(
        [object, Map.put(commitment(extra), :bytes, extra.bytes)],
        & &1.artifact_digest
      )

    {:ok, extra_plain} = Archive.encode(database, objects)
    invalid_plain = [extra_plain | invalid_plain]
    {:ok, copy} = Sqlite3.open(":memory:")
    :ok = Sqlite3.deserialize(copy, "main", database)

    :ok =
      Sqlite3.execute(
        copy,
        "DELETE FROM authority_journal WHERE event_type='portable_profile_approved'"
      )

    {:ok, corrupt_database} = Sqlite3.serialize(copy, "main")
    Sqlite3.close(copy)
    {:ok, corrupt_plain} = Archive.encode(corrupt_database, [object])

    for {body, index} <- Enum.with_index([corrupt_plain | invalid_plain]) do
      path = Path.join(c.directory, "invalid-#{index}.backup")
      File.write!(path, seal(revision, epoch, body, c.key))
      assert {:error, :invalid_backup} = Backup.verify(path, c.key)
      destination = Path.join(c.directory, "invalid-#{index}")
      assert {:error, :invalid_backup} = Backup.stage_profile_restore(path, c.key, destination)
      refute File.exists?(destination)
    end

    assert {:error, :invalid_profile_archive} = Archive.decode(<<0::32, 0::16>>)
    assert {:error, :invalid_profile_archive} = Archive.decode(<<33_554_433::32>>)
    assert {:error, :invalid_profile_archive} = Archive.encode(database, [%{bytes: c.bytes}])
    assert Archive.max_bytes() == 35_664_134

    assert {:ok, %{dependencies: %{profile_artifacts: [expected]}}} =
             Backup.verify(archive, c.key)

    assert expected == commitment(artifact)
  end

  test "database-only archives keep compatibility and cannot silently claim missing profile transfer",
       c do
    archive = Path.join(c.directory, "empty.backup")
    assert {:ok, _} = Store.export_backup(c.store, archive, c.key)

    assert {:ok, %{quarantined: true, portable_profile_objects: 0}} =
             Backup.stage_profile_restore(
               archive,
               c.key,
               Path.join(c.directory, "empty-restored")
             )

    approve(c)
    dependent = Path.join(c.directory, "dependent.backup")
    assert {:ok, _} = Store.export_backup(c.store, dependent, c.key)

    assert {:ok, %{dependencies: %{portable_profile_bytes_included: false}}} =
             Backup.verify(dependent, c.key)

    destination = Path.join(c.directory, "dependent-restored")

    assert {:error, :profile_bytes_missing} =
             Backup.stage_profile_restore(dependent, c.key, destination)

    refute File.exists?(destination)

    assert {:ok, %{quarantined: true}} =
             Backup.stage_restore(dependent, c.key, dependent <> ".sqlite")
  end

  test "foreground recovery parses only a canonical stdin key and never exports through an absent host",
       c do
    encoded = Base.url_encode64(c.key, padding: false)

    for input <- [
          :eof,
          nil,
          encoded,
          encoded <> "=\n",
          encoded <> "\r\n",
          String.duplicate("!", 43) <> "\n"
        ] do
      assert {:error, :invalid_backup_key} = WotexHome.Recovery.run(["verify", "unused"], input)
    end

    assert {:error, :host_unavailable} =
             WotexHome.Recovery.run(
               ["export", Path.join(c.directory, "absent.backup")],
               encoded <> "\n"
             )

    assert {:error, :usage} = WotexHome.Recovery.run(["activate", "unused"], encoded <> "\n")
    archive = Path.join(c.directory, "recovery.backup")
    {:ok, _} = Store.export_profile_backup(c.store, archive, c.key)

    assert {:ok, %{authority_epoch: 1}} =
             WotexHome.Recovery.run(["verify", archive], encoded <> "\n")

    assert {:ok, %{quarantined: true}} =
             WotexHome.Recovery.run(
               ["stage", archive, Path.join(c.directory, "recovery-stage")],
               encoded <> "\n"
             )

    refute File.exists?(Path.join(c.directory, "absent.backup"))
  end

  @tag :requires_socket
  test "foreground export and offline verification/staging scripts use stdin custody on the actual private host",
       c do
    {artifact, _} = approve(c)
    stop_supervised!(Store)
    stop_supervised!(Custody)
    archive = Path.join(c.directory, "foreground.backup")
    destination = Path.join(c.directory, "foreground-restore")
    input = Base.url_encode64(c.key, padding: false) <> "\n"
    # Select only this fixture Host and disable optional network/write configuration
    # before startup. No credential or key enters arguments or environment.
    startup = """
    Logger.configure(level: :error)
    System.delete_env("WOTEX_HOME_LIFX_INTERFACE")
    Application.delete_env(:wotex_home, :lifx_capture_interface)
    Application.delete_env(:wotex_home, :component_preview)
    Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, false)
    {:ok, _} = Application.ensure_all_started(:wotex_home)
    Code.require_file("bin/recovery.exs")
    """

    environment = [
      {"WOTEX_HOME_DATA_DIR", c.directory},
      {"WOTEX_HOME_GIT_DEPS", "1"},
      {"MIX_ENV", "test"}
    ]

    assert {:ok, exported} =
             Woh.Tool.Command.run(
               "mix",
               ["run", "--no-start", "-e", startup, "--", "export", archive],
               65_536,
               30_000,
               environment,
               input
             )

    assert {:ok, %{"portable_profile_objects" => 1}} = JSON.decode(String.trim(exported))

    assert {:ok, verified} =
             Woh.Tool.Command.run(
               "mix",
               ["run", "--no-start", "bin/recovery.exs", "verify", archive],
               65_536,
               30_000,
               environment,
               input
             )

    assert {:ok, %{"dependencies" => %{"portable_profile_bytes_included" => true}}} =
             JSON.decode(String.trim(verified))

    assert {:ok, staged} =
             Woh.Tool.Command.run(
               "mix",
               ["run", "--no-start", "bin/recovery.exs", "stage", archive, destination],
               65_536,
               30_000,
               environment,
               input
             )

    assert {:ok, %{"quarantined" => true}} = JSON.decode(String.trim(staged))
    refute exported <> verified <> staged =~ String.trim(input)
    assert File.read!(Path.join(destination, "profiles/#{artifact.digest}.json")) == c.bytes
  end

  test "destination aliases, symlinks, nonprivate parents and existing content are never rewritten",
       c do
    approve(c)
    archive = Path.join(c.directory, "source.backup")
    {:ok, _} = Store.export_profile_backup(c.store, archive, c.key)
    public = Path.join(c.directory, "public")
    File.mkdir!(public)
    File.chmod!(public, 0o755)

    assert {:error, :invalid_restore_request} =
             Backup.stage_profile_restore(archive, c.key, Path.join(public, "restore"))

    assert mode(public) == 0o755
    link = Path.join(c.directory, "alias")
    File.ln_s!(c.directory, link)

    assert {:error, :invalid_restore_request} =
             Backup.stage_profile_restore(archive, c.key, Path.join(link, "restore"))

    assert {:error, :invalid_restore_request} =
             Backup.stage_profile_restore(archive, c.key, c.directory <> "/../restore")

    existing = Path.join(c.directory, "existing")
    File.write!(existing, "canary")
    assert {:error, :restore_exists} = Backup.stage_profile_restore(archive, c.key, existing)
    assert File.read!(existing) == "canary"
    # Verification itself must reject an archive symlink before descriptor access.
    archive_link = Path.join(c.directory, "source-link.backup")
    File.ln_s!(archive, archive_link)
    assert {:error, :invalid_backup} = Backup.verify(archive_link, c.key)
  end

  test "failed file and directory synchronization removes only newly owned quarantine", c do
    {artifact, _} = approve(c)
    archive = Path.join(c.directory, "source.backup")
    {:ok, _} = Store.export_profile_backup(c.store, archive, c.key)
    {_, _, plain} = unpack(archive, c.key)
    {:ok, database, objects} = Archive.decode(plain)

    {:ok, quarantined} = Sqlite3.open(":memory:")
    :ok = Sqlite3.deserialize(quarantined, "main", database)

    :ok =
      Sqlite3.execute(quarantined, "INSERT INTO meta(key,value) VALUES ('restore_quarantine',1)")

    {:ok, database} = Sqlite3.serialize(quarantined, "main")
    Sqlite3.close(quarantined)

    for failure <- 1..5 do
      counter = :counters.new(1, [])

      sync = fn handle ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == failure, do: {:error, :enospc}, else: :file.sync(handle)
      end

      destination = Path.join(c.directory, "failed-#{failure}")

      assert {:error, :restore_unavailable} =
               ProfileRestore.stage(destination, database, objects, sync)

      refute File.exists?(destination)
      assert {:ok, current} = Custody.read(c.custody, artifact.digest)
      assert current.bytes == c.bytes
      assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(c.store)
    end
  end

  test "maximum object framing is finite and rejects unordered and oversized data", c do
    {:ok, data} = Codec.decode(c.bytes)

    objects =
      for index <- 1..64 do
        updated = Map.put(data, "id", "profile:bound:#{index}")
        bytes = JSON.encode!(updated)
        bytes = bytes <> String.duplicate(" ", 32_768 - byte_size(bytes))
        {:ok, projection} = Bindings.historical_projection(updated)

        %{
          artifact_digest: Artifact.digest(bytes),
          projection_digest: Artifact.digest(projection),
          registry_digest: hd(updated["dependencies"])["sha256"],
          bytes: bytes
        }
      end
      |> Enum.sort_by(& &1.artifact_digest)

    assert {:ok, encoded} = Archive.encode("database", objects)
    assert {:ok, "database", ^objects} = Archive.decode(encoded)
    assert byte_size(encoded) == 8 + 6 + 64 * (196 + 32_768)

    assert {:error, :invalid_profile_archive} =
             Archive.encode("database", objects ++ [hd(objects)])

    unordered =
      <<8::32, "database", 64::16>> <>
        IO.iodata_to_binary(Enum.map(Enum.reverse(objects), &record/1))

    assert {:error, :invalid_profile_archive} = Archive.decode(unordered)
    object = hd(objects)
    oversized = <<8::32, "database", 1::16>> <> record(%{object | bytes: object.bytes <> " "})
    assert {:error, :invalid_profile_archive} = Archive.decode(oversized)
    assert {:error, :invalid_profile_archive} = Archive.encode("", [])
  end

  defp clock(c, id, observed) do
    requests = Path.join(c.root, Atom.to_string(id))
    File.mkdir!(requests)
    File.chmod!(requests, 0o700)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, runtime} = WotexHome.Schedules.ClockOwner.runtime_digest()

    policy = %{
      source_id: "clock:software-fixture",
      issuer_id: "issuer:software-fixture",
      public_key: public,
      issuer_generation: 1,
      procedure_ref: "procedure:software-only",
      qualification_digest: String.duplicate("a", 64),
      runtime_digest: runtime,
      maximum_response_ms: 30_000,
      maximum_age_ms: 120_000,
      maximum_error_ms: 0,
      drift_ppm: 10,
      maximum_discontinuity_ms: 20,
      monotonic_policy: "invalidate_on_discontinuity"
    }

    {:ok, document} = WotexHome.Schedules.ClockCodec.policy_document(policy)
    file = Path.join(c.root, Atom.to_string(id) <> ".policy")
    :ok = WotexHome.Recovery.PrivateFile.write(file, document, 4_096)

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {WotexHome.Schedules.ClockOwner,
           store: c.store, operator: self(), root: requests, policy_file: file},
          id: id,
          restart: :temporary
        )
      )

    {:ok, request} = WotexHome.Schedules.ClockOwner.request(owner)
    {:ok, document} = WotexHome.Recovery.PrivateFile.read(request.request_file, 4_096)
    {:ok, input} = WotexHome.Schedules.ClockCodec.decode_request(document)

    record =
      Map.merge(input, %{
        "procedure_ref" => policy.procedure_ref,
        "observed_utc_ms" => observed
      })

    {:ok, payload} = WotexHome.Schedules.ClockCodec.signing_payload(record)

    {:ok, package} =
      WotexHome.Schedules.ClockCodec.encode(
        record,
        :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      )

    assert {:ok, _} =
             WotexHome.Schedules.ClockOwner.approve(owner, request.request_digest, package)

    assert :ok = Store.attach_temporal_clock(c.store, owner)
    owner
  end

  defp prepare_profile_schedule_poll(_store, :unrelated_write), do: nil

  defp prepare_profile_schedule_poll(store, :prepared_commit) do
    assert {:ok, reference, _} = Store.prepare_schedule_poll(store)
    reference
  end

  defp close_profile_schedule_poll(_store, nil), do: :ok

  defp close_profile_schedule_poll(store, reference) do
    assert {:error, :schedule_basis_changed} = Store.commit_schedule_poll(store, reference, :idle)
  end

  defp select_target(c) do
    {artifact, _} = approve(c)

    {:ok, operator, _} =
      Store.provision_principal(
        c.store,
        "operator:archive",
        ["profile:manage", "enroll:review"],
        []
      )

    reviews = start_supervised!({ReviewSession, custody: c.custody, name: @reviews})
    {:ok, scope} = IPv4Scope.new({192, 0, 2, 2}, 24)

    capture =
      start_supervised!(
        {CaptureSession, interface_id: "en0", scope: scope, transport: {Peer, :fixture}}
      )

    authority =
      Authority.new(
        store: c.store,
        profile_custody: c.custody,
        profile_reviews: reviews,
        capture: capture
      )

    {:ok, session, [%{raw_ref: candidate}]} = Authority.lifx_discover(authority, operator)
    assert {:ok, _, _} = Authority.lifx_interview(authority, operator, session, candidate)
    {:ok, target} = Authority.profile_target(authority, operator, "light:archive:initial")
    {:ok, catalogue} = Authority.profile_catalogue(authority, operator)

    input = %{
      "action" => "select",
      "authority_epoch" => target.authority_epoch,
      "operation_id" => "profile:select:archive",
      "expected_revision" => target.store_revision,
      "artifact_digest" => artifact.digest,
      "expected_trust_revision" => hd(catalogue.items)["trust_revision"],
      "target_id" => target.target_id,
      "expected_resource_revision" => 0,
      "expected_binding_revision" => 0,
      "expected_selection_generation" => 0,
      "expected_policy_generation" => target.policy_generation,
      "expected_rule_generation" => target.rule_generation,
      "session_ref" => session,
      "candidate_ref" => candidate,
      "review_ref" => "review:archive:initial"
    }

    assert {:ok, _} = Authority.prepare_profile_selection(authority, operator, input)
    assert {:ok, selected} = Authority.profile_change(authority, operator, input)
    {artifact, input, selected, authority, operator}
  end

  defp approve(c) do
    {:ok, digest} = Authority.stage_profile(c.authority, c.manager, c.bytes)
    {:ok, artifact} = Artifact.parse(c.bytes)
    {:ok, revision} = Store.revision(c.store)

    input = %{
      "action" => "approve",
      "authority_epoch" => 1,
      "operation_id" => "profile:approve:archive",
      "expected_revision" => revision,
      "artifact_digest" => digest,
      "expected_trust_revision" => 0
    }

    {:ok, _} = Authority.profile_change(c.authority, c.manager, input)
    {artifact, input}
  end

  defp commitment(artifact),
    do: %{
      artifact_digest: artifact.digest,
      projection_digest: artifact.projection_digest,
      registry_digest: hd(artifact.data["dependencies"])["sha256"]
    }

  defp mode(path), do: band(File.lstat!(path).mode, 0o777)

  defp rows(db, sql) do
    {:ok, statement} = Sqlite3.prepare(db, sql)
    {:ok, values} = Sqlite3.fetch_all(db, statement)
    Sqlite3.release(db, statement)
    values
  end

  defp unpack(path, key) do
    <<"WOHBK2\0", revision::64, epoch::64, nonce::binary-size(12), size::32, rest::binary>> =
      File.read!(path)

    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = rest
    header = <<"WOHBK2\0", revision::64, epoch::64, nonce::binary-size(12), size::32>>

    {revision, epoch,
     :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, header, tag, false)}
  end

  defp seal(revision, epoch, plain, key) do
    nonce = :crypto.strong_rand_bytes(12)
    header = <<"WOHBK2\0", revision::64, epoch::64, nonce::binary-size(12), byte_size(plain)::32>>
    {bytes, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plain, header, true)
    header <> bytes <> tag
  end

  defp record(object),
    do:
      <<object.artifact_digest::binary-size(64), object.projection_digest::binary-size(64),
        object.registry_digest::binary-size(64), byte_size(object.bytes)::32,
        object.bytes::binary>>
end
