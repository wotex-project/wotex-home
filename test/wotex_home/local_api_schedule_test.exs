defmodule WotexHome.LocalAPIScheduleTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Rules.OperationInput, as: RuleInput
  alias WotexHome.Schedules.{ClockCodec, ClockOwner, Codec, OperationInput, Tzif}
  alias WotexHome.Recovery.PrivateFile
  alias WotexHome.Semantics.Thing
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  setup do
    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "woh-schedule-api-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    zone_root = Path.join(root, "zones")
    File.mkdir!(zone_root)
    File.chmod!(zone_root, 0o700)
    File.mkdir!(Path.join(zone_root, "Fixture"))
    File.chmod!(Path.join(zone_root, "Fixture"), 0o700)
    record = JSON.decode!(File.read!(@fixture))["zones"] |> hd()
    bytes = Base.decode64!(record["data_base64"])
    File.write!(Path.join(zone_root, record["name"]), bytes)
    File.chmod!(Path.join(zone_root, record["name"]), 0o600)
    {:ok, zone} = Tzif.decode(record["name"], bytes)
    on_exit(fn -> File.rm_rf!(root) end)

    store =
      start_supervised!(
        Supervisor.child_spec({Store, path: Path.join(root, "home.sqlite")}, restart: :temporary)
      )

    gate = start_supervised!({ReviewGate, limit: 1})

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:one",
        "role" => "Light",
        "profile_ref" => "fixture:power",
        "capabilities" => [
          %{
            "thing_id" => "light:one",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:power",
            "evidence_ref" => "fixture:one",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, manager, 2} =
      Store.provision_principal(
        store,
        "manager:one",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    {:ok, other, 3} =
      Store.provision_principal(
        store,
        "manager:other",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    authority =
      Authority.new(
        store: store,
        review_gate: gate,
        capture: nil,
        timezone_options: [root: zone_root, owner_uid: File.stat!(root).uid]
      )

    %{
      root: root,
      zone_root: zone_root,
      zone: zone,
      record: record,
      store: store,
      gate: gate,
      authority: authority,
      manager: manager,
      other: other
    }
  end

  test "framed review/admit and original status bind closed receipts without activation", c do
    review = original("review", "schedule:review", 3)
    request = request("schedule_review", c.manager, review)
    assert %{"outcome" => "ok", "schedule_receipt" => receipt} = framed(c.authority, request)

    assert Map.keys(receipt) |> Enum.sort() ==
             Enum.sort(
               ~w(kind state principal_id authority_epoch operation_id input_digest artifact_digest revision)
             )

    assert receipt["kind"] == "review" && receipt["state"] == "reviewed" &&
             receipt["revision"] == 4

    assert receipt["principal_id"] == "manager:one" &&
             receipt["input_digest"] == Codec.hash(review)

    assert %{"schedule_receipt" => ^receipt} = framed(c.authority, request)

    assert %{"schedule_receipt" => ^receipt} =
             framed(c.authority, %{request | "operation" => "schedule_original_status"})

    admit = original("admit", "schedule:admit", 4)

    assert %{"schedule_receipt" => %{"state" => "admitted", "revision" => 5}} =
             framed(c.authority, request("schedule_admit", c.manager, admit))

    assert {:ok, %{state: :inactive, rule_generation: 0}} = Store.rule_status(c.store, c.manager)

    assert {:ok, %{held_requests: 0, queued_requests: 0, dispatch_enabled: false}} =
             Store.health(c.store)
  end

  test "framed countdown admission requires actual owned basis and expiry preserves private originals",
       c do
    attach_clock(c)
    {:ok, snapshot} = Store.temporal_clock_snapshot(c.store)

    trigger = [
      "countdown",
      snapshot.scope["store_boot_epoch"],
      snapshot.scope["clock_generation"],
      snapshot.now_ms,
      60_000
    ]

    document = original("admit", "countdown:admit", 3, %{"trigger" => trigger})
    admission = request("schedule_admit", c.manager, document)
    assert %{"outcome" => "ok", "schedule_receipt" => admitted} = framed(c.authority, admission)
    original = lifecycle("activate", "countdown:activate", 4, 4)
    activation = request("schedule_activate", c.manager, original)
    assert %{"outcome" => "ok", "schedule_receipt" => active} = framed(c.authority, activation)
    assert :ok = Store.invalidate_temporal_clock(c.store)

    assert %{
             "outcome" => "ok",
             "schedule_status" => %{
               "state" => "suspended",
               "reason" => "countdown_missed:clock_changed"
             }
           } = framed(c.authority, status_request(c.manager))

    assert %{"schedule_receipt" => ^admitted} = framed(c.authority, admission)
    assert %{"schedule_receipt" => ^active} = framed(c.authority, activation)

    assert %{"outcome" => "not_found"} =
             framed(c.authority, request("schedule_original_status", c.other, original))

    assert {:ok, 8} = Store.revision(c.store)
    successor = original("admit", "countdown:successor", 8, %{"trigger" => trigger})

    assert %{"outcome" => "error", "reason" => "temporal_clock_unavailable"} =
             framed(c.authority, request("schedule_admit", c.manager, successor))

    assert %{"outcome" => "not_found"} =
             framed(c.authority, request("schedule_original_status", c.manager, successor))

    assert {:ok, 8} = Store.revision(c.store)
  end

  test "read-only resolution exposes independent gap/fold choices and creates no time trust", c do
    for vector <- c.record["vectors"] do
      assert %{"outcome" => "ok", "timezone" => result} =
               framed(c.authority, timezone_request(c.manager, c.zone.name, vector["local"]))

      assert map_size(result) == 7 && result["basis_scope"] == "calendar_calculation_only"
      assert result["digest"] == c.zone.digest && result["name"] == c.zone.name
      assert result["instant_count"] == length(vector["utc_ms"])
      assert result["first_utc_ms"] == Enum.at(vector["utc_ms"], 0)
      assert result["second_utc_ms"] == Enum.at(vector["utc_ms"], 1)
    end

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "calendar creation reads the pinned installed bytes; exact recovery needs no current zone or gate",
       c do
    trigger = ["daily", c.zone.name, c.zone.digest, "02:30:00", 0, nil]
    original = original("admit", "schedule:daily", 3, %{"trigger" => trigger})
    request = request("schedule_admit", c.manager, original)
    assert %{"schedule_receipt" => receipt} = framed(c.authority, request)
    File.rm!(Path.join(c.zone_root, c.zone.name))
    without_gate = %{c.authority | review_gate: nil}

    assert %{"schedule_receipt" => ^receipt} =
             framed(without_gate, %{request | "operation" => "schedule_original_status"})

    assert %{"schedule_receipt" => ^receipt} = framed(without_gate, request)
    {:ok, 5} = Store.revoke_target_grant(c.store, "manager:one", "light:one")
    assert %{"schedule_receipt" => ^receipt} = framed(without_gate, request)
    assert {:ok, 5} = Store.revision(c.store)
  end

  test "missing or replaced installed calendar data cannot admit a successor", c do
    original =
      original("admit", "schedule:daily", 3, %{
        "trigger" => ["daily", c.zone.name, c.zone.digest, "02:30:00", 0, nil]
      })

    request = request("schedule_admit", c.manager, original)
    File.write!(Path.join(c.zone_root, c.zone.name), "invalid")

    assert %{"outcome" => "error", "reason" => "timezone_basis_changed"} =
             framed(c.authority, request)

    File.rm!(Path.join(c.zone_root, c.zone.name))

    assert %{"outcome" => "error", "reason" => "timezone_basis_changed"} =
             framed(c.authority, request)

    assert %{"outcome" => "not_found"} =
             framed(c.authority, %{request | "operation" => "schedule_original_status"})

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "principal-private lookup cannot recover another author's receipt and cannot alter original input",
       c do
    original = original("admit", "schedule:original", 3)
    request = request("schedule_admit", c.manager, original)
    assert %{"schedule_receipt" => _} = framed(c.authority, request)

    assert %{"outcome" => "not_found"} =
             framed(c.authority, request("schedule_original_status", c.other, original))

    changed = original("admit", "schedule:original", 3, %{"late_window_ms" => 11_000})

    for operation <- ["schedule_admit", "schedule_original_status"] do
      assert %{"outcome" => "error", "reason" => "schedule_operation_conflict"} =
               framed(c.authority, request(operation, c.manager, changed))
    end

    assert %{"outcome" => "error", "reason" => "schedule_operation_kind_mismatch"} =
             framed(c.authority, %{request | "operation" => "schedule_review"})

    assert {:ok, 4} = Store.revision(c.store)
  end

  test "all three management permissions and current authentication precede host timezone access",
       c do
    for {permissions, index} <-
          Enum.with_index([
            ~w(rule:review rule:manage),
            ~w(rule:review control:ordinary),
            ~w(rule:manage control:ordinary)
          ]) do
      {:ok, credential, _} =
        Store.provision_principal(c.store, "limited:#{index}", permissions, ["light:one"])

      inaccessible = %{c.authority | timezone_options: [root: "/absent"]}

      assert %{"outcome" => "error", "reason" => "permission_denied"} =
               framed(
                 inaccessible,
                 timezone_request(credential, c.zone.name, "2026-01-01T00:00:00")
               )
    end

    {:ok, _} = Store.revoke_principal(c.store, "manager:one")

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             framed(c.authority, timezone_request(c.manager, c.zone.name, "2026-01-01T00:00:00"))
  end

  test "closed routes refuse caller clocks, timezone bytes, roots and extra fields", c do
    request = request("schedule_admit", c.manager, original("admit", "schedule:one", 3))

    for field <- ~w(clock utc_ms timezone timezone_root author_id physical_qualification) do
      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(c.authority, Map.put(request, field, "caller"))

      query = timezone_request(c.manager, c.zone.name, "2026-01-01T00:00:00")

      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(c.authority, Map.put(query, field, "caller"))
    end

    for document <- [nil, %{}, String.duplicate("x", 8_193), "[]"] do
      assert %{"outcome" => "error", "reason" => "invalid_schedule_operation"} =
               framed(c.authority, %{request | "original_document" => document})
    end

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "new content uses bounded review capacity while original lookup remains available", c do
    first = request("schedule_admit", c.manager, original("admit", "schedule:first", 3))
    assert %{"schedule_receipt" => receipt} = framed(c.authority, first)
    assert :ok = GenServer.call(c.gate, :acquire)

    assert %{"outcome" => "error", "reason" => "review_capacity"} =
             framed(
               c.authority,
               request("schedule_admit", c.manager, original("admit", "schedule:second", 4))
             )

    assert %{"schedule_receipt" => ^receipt} = framed(c.authority, first)

    assert %{"schedule_receipt" => ^receipt} =
             framed(c.authority, %{first | "operation" => "schedule_original_status"})

    assert :ok = GenServer.call(c.gate, :release)
    assert {:ok, 4} = Store.revision(c.store)
  end

  @tag requires_socket: true
  test "actual private socket and CLI retain the exact operation file across lookup and retry",
       c do
    socket = Path.join(c.root, "ipc/home.sock")
    server = start_supervised!({Server, authority: c.authority, socket_path: socket})
    assert Process.alive?(server)
    credential_file = Path.join(c.root, "credential")
    File.write!(credential_file, Base.url_encode64(c.manager, padding: false) <> "\n")
    File.chmod!(credential_file, 0o600)
    flags = ["--socket", socket, "--credential-file", credential_file]
    path = Path.join(c.root, "original")
    original = original("admit", "schedule:cli", 3)
    File.write!(path, original)
    File.chmod!(path, 0o600)
    assert %{"outcome" => "not_found"} = cli(flags ++ ["schedule-original-status", path], 4)
    assert %{"schedule_receipt" => receipt} = cli(flags ++ ["admit-schedule", path], 0)
    assert %{"schedule_receipt" => ^receipt} = cli(flags ++ ["schedule-original-status", path], 0)
    assert %{"schedule_receipt" => ^receipt} = cli(flags ++ ["admit-schedule", path], 0)

    assert %{"timezone" => %{"basis_scope" => "calendar_calculation_only"}} =
             cli(flags ++ ["schedule-timezone", c.zone.name, "2026-01-01T00:00:00"], 0)

    assert {:ok, %{"schedule_receipt" => ^receipt}} =
             Client.request(socket, request("schedule_original_status", c.manager, original))

    assert {:error, :invalid_schedule_operation_file} =
             CLI.build_request(["review-schedule", path], "fixture")

    File.chmod!(path, 0o644)

    assert {:error, :invalid_schedule_operation_file} =
             CLI.build_request(["admit-schedule", path], "fixture")

    File.chmod!(path, 0o600)
    alias_path = Path.join(c.root, "alias")
    File.ln_s!(path, alias_path)

    assert {:error, :invalid_schedule_operation_file} =
             CLI.build_request(["admit-schedule", alias_path], "fixture")

    lost = original("admit", "schedule:lost", 4)
    File.write!(path, lost)
    fake_socket = Path.join(c.root, "lost.sock")

    assert {:ok, listener} =
             :gen_tcp.listen(0, [
               :binary,
               {:ifaddr, {:local, String.to_charlist(fake_socket)}},
               {:active, false},
               {:backlog, 1}
             ])

    File.chmod!(fake_socket, 0o600)

    peer =
      Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(listener, 3_000)
        {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(connection, 4, 3_000)
        {:ok, body} = :gen_tcp.recv(connection, size, 3_000)
        {:ok, request} = Frame.decode_request(body)
        result = Server.route(c.authority, request)
        :ok = :gen_tcp.close(connection)
        result
      end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.main([
                 "--socket",
                 fake_socket,
                 "--credential-file",
                 credential_file,
                 "admit-schedule",
                 path
               ]) == 3
      end)

    assert error =~ "schedule-original-status" && error =~ "exact retained operation file"
    refute error =~ Base.url_encode64(c.manager, padding: false)
    assert %{"schedule_receipt" => lost_receipt} = Task.await(peer, 3_000)
    :ok = :gen_tcp.close(listener)

    assert %{"schedule_receipt" => ^lost_receipt} =
             cli(flags ++ ["schedule-original-status", path], 0)

    assert %{"schedule_receipt" => ^lost_receipt} = cli(flags ++ ["admit-schedule", path], 0)
    assert {:ok, 5} = Store.revision(c.store)
  end

  test "framed lifecycle receipts preserve original state while readiness is principal-private",
       c do
    assert %{
             "schedule_status" => %{
               "state" => "inactive",
               "activation_revision" => 0,
               "reason" => nil
             }
           } = framed(c.authority, status_request(c.manager))

    attach_clock(c)
    admit = original("admit", "schedule:admit", 3, %{"uncertainty_tolerance_ms" => 1_000})

    assert %{"schedule_receipt" => %{"revision" => 4}} =
             framed(c.authority, request("schedule_admit", c.manager, admit))

    document = lifecycle("activate", "schedule:activate", 4, 4)
    activate = request("schedule_activate", c.manager, document)
    assert %{"schedule_receipt" => receipt} = framed(c.authority, activate)

    assert Enum.sort(Map.keys(receipt)) ==
             Enum.sort(
               ~w(kind state principal_id authority_epoch operation_id input_digest admission_revision previous_generation rule_generation barrier_revision revision affected_requests unknown_outcomes reason initial_watermark)
             )

    assert receipt["state"] == "activated" && receipt["revision"] == 6 &&
             receipt["rule_generation"] == 1

    assert %{"schedule_receipt" => ^receipt} = framed(c.authority, activate)

    assert %{"schedule_receipt" => ^receipt} =
             framed(c.authority, %{activate | "operation" => "schedule_original_status"})

    assert %{"outcome" => "not_found"} =
             framed(c.authority, request("schedule_original_status", c.other, document))

    assert %{"schedule_status" => %{"state" => "active", "revision" => 6}} =
             framed(c.authority, status_request(c.manager))

    assert %{"schedule_status" => %{"state" => "inactive", "activation_revision" => 0}} =
             framed(c.authority, status_request(c.other))

    # Another authorized manager can suspend the set without hiding the first author's history.
    suspend = request("schedule_suspend", c.other, lifecycle("suspend", "schedule:suspend", 6))

    assert %{"schedule_receipt" => %{"state" => "suspended", "revision" => 8}} =
             framed(c.authority, suspend)

    assert %{
             "schedule_status" => %{
               "state" => "suspended",
               "revision" => 6,
               "reason" => "stale_rule_generation"
             }
           } = framed(c.authority, status_request(c.manager))

    assert %{
             "schedule_status" => %{
               "state" => "suspended",
               "revision" => 8,
               "reason" => "explicit_suspension"
             }
           } = framed(c.authority, status_request(c.other))

    assert %{"schedule_receipt" => ^receipt} =
             framed(c.authority, %{activate | "operation" => "schedule_original_status"})

    assert {:ok, 8} = Store.revision(c.store)
  end

  test "lifecycle routes reject client time, extra fields, wrong kind and missing host clock",
       c do
    admit = original("admit", "schedule:admit", 3)

    assert %{"schedule_receipt" => %{"revision" => 4}} =
             framed(c.authority, request("schedule_admit", c.manager, admit))

    activate =
      request("schedule_activate", c.manager, lifecycle("activate", "schedule:activate", 4, 4))

    assert %{"outcome" => "error", "reason" => "temporal_clock_unavailable"} =
             framed(c.authority, activate)

    for field <-
          ~w(clock clock_sample now_ms timezone_document author_id principal_id qualification_digest) do
      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(c.authority, Map.put(activate, field, "caller"))

      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(c.authority, Map.put(status_request(c.manager), field, "caller"))
    end

    assert %{"outcome" => "error", "reason" => "schedule_operation_kind_mismatch"} =
             framed(c.authority, %{activate | "operation" => "schedule_suspend"})

    assert %{"outcome" => "error", "reason" => "schedule_operation_kind_mismatch"} =
             framed(c.authority, %{activate | "original_document" => admit})

    assert {:ok, 4} = Store.revision(c.store)
  end

  @tag requires_socket: true
  test "CLI lost activation reply recovers the exact original without a second generation", c do
    attach_clock(c)
    socket = Path.join(c.root, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    credential_file = Path.join(c.root, "credential")
    File.write!(credential_file, Base.url_encode64(c.manager, padding: false) <> "\n")
    File.chmod!(credential_file, 0o600)
    flags = ["--socket", socket, "--credential-file", credential_file]
    path = Path.join(c.root, "original")

    File.write!(
      path,
      original("admit", "schedule:cli:admit", 3, %{"uncertainty_tolerance_ms" => 1_000})
    )

    File.chmod!(path, 0o600)
    assert %{"schedule_receipt" => %{"revision" => 4}} = cli(flags ++ ["admit-schedule", path], 0)
    document = lifecycle("activate", "schedule:cli:activate", 4, 4)
    File.write!(path, document)
    assert %{"outcome" => "not_found"} = cli(flags ++ ["schedule-original-status", path], 4)
    fake_socket = Path.join(c.root, "lost-lifecycle.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, String.to_charlist(fake_socket)}},
        {:active, false},
        {:backlog, 1}
      ])

    File.chmod!(fake_socket, 0o600)

    peer =
      Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(listener, 3_000)
        {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(connection, 4, 3_000)
        {:ok, body} = :gen_tcp.recv(connection, size, 3_000)
        {:ok, request} = Frame.decode_request(body)
        result = Server.route(c.authority, request)
        :ok = :gen_tcp.close(connection)
        result
      end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.main([
                 "--socket",
                 fake_socket,
                 "--credential-file",
                 credential_file,
                 "activate-schedule",
                 path
               ]) == 3
      end)

    assert error =~ "schedule-original-status" && error =~ "exact retained operation file"
    refute error =~ Base.url_encode64(c.manager, padding: false)
    assert %{"schedule_receipt" => receipt} = Task.await(peer, 3_000)
    :ok = :gen_tcp.close(listener)
    assert %{"schedule_receipt" => ^receipt} = cli(flags ++ ["schedule-original-status", path], 0)
    assert %{"schedule_receipt" => ^receipt} = cli(flags ++ ["activate-schedule", path], 0)

    assert %{"schedule_status" => %{"state" => "active", "rule_generation" => 1}} =
             cli(flags ++ ["schedule-status"], 0)

    assert :ok = Store.invalidate_temporal_clock(c.store)

    assert %{
             "schedule_status" => %{
               "state" => "suspended",
               "reason" => "temporal_clock_unavailable"
             }
           } = cli(flags ++ ["schedule-status"], 0)

    assert %{"schedule_receipt" => ^receipt} = cli(flags ++ ["activate-schedule", path], 0)
    File.write!(path, lifecycle("suspend", "schedule:cli:suspend", 6))

    assert %{
             "schedule_receipt" =>
               %{"revision" => 8, "rule_generation" => 2, "state" => "suspended"} = suspended
           } = cli(flags ++ ["suspend-schedule", path], 0)

    assert %{"schedule_receipt" => ^suspended} =
             cli(flags ++ ["schedule-original-status", path], 0)

    assert {:ok, 8} = Store.revision(c.store)

    assert {:ok, %{held_requests: 0, queued_requests: 0, dispatch_enabled: false}} =
             Store.health(c.store)
  end

  test "private lifecycle files preserve exact bytes and reject wrong command, permissions and symlinks",
       c do
    path = Path.join(c.root, "lifecycle.original")
    document = lifecycle("activate", "schedule:file", 4, 4)
    File.write!(path, document)
    File.chmod!(path, 0o600)

    assert {:ok, %{"operation" => "schedule_activate", "original_document" => ^document}} =
             CLI.build_request(["activate-schedule", path], "fixture")

    assert {:ok, %{"operation" => "schedule_original_status", "original_document" => ^document}} =
             CLI.build_request(["schedule-original-status", path], "fixture")

    for command <- ["review-schedule", "admit-schedule", "suspend-schedule"] do
      assert {:error, :invalid_schedule_operation_file} =
               CLI.build_request([command, path], "fixture")
    end

    File.chmod!(path, 0o644)

    assert {:error, :invalid_schedule_operation_file} =
             CLI.build_request(["activate-schedule", path], "fixture")

    File.chmod!(path, 0o600)
    alias_path = path <> ".alias"
    File.ln_s!(path, alias_path)

    assert {:error, :invalid_schedule_operation_file} =
             CLI.build_request(["activate-schedule", alias_path], "fixture")

    File.write!(path, document <> " ")

    assert {:error, :invalid_schedule_operation_file} =
             CLI.build_request(["activate-schedule", path], "fixture")

    assert {:ok, %{"operation" => "schedule_status"} = request} =
             CLI.build_request(["schedule-status"], "fixture")

    assert map_size(request) == 3
  end

  test "retained source is principal-private, target-granted and separate from review or activation",
       c do
    assert %{"outcome" => "not_found"} = framed(c.authority, source_request(c.manager, 0))
    review = original("review", "schedule:source:review", 3)

    assert {:ok, %{revision: 4}} =
             Authority.retain_schedule_content(c.authority, c.manager, "review", review)

    assert %{"outcome" => "not_found"} = framed(c.authority, source_request(c.manager, 4))
    document = original("admit", "schedule:source:admit", 4)

    assert {:ok, receipt} =
             Authority.retain_schedule_content(c.authority, c.manager, "admit", document)

    assert %{"outcome" => "ok", "schedule_source" => source} =
             framed(c.authority, source_request(c.manager, 0))

    assert Map.keys(source) |> Enum.sort() == ~w(basis_scope original_document schedule_receipt)
    assert source["basis_scope"] == "historical_schedule_source_only"
    assert source["original_document"] == document
    assert source["schedule_receipt"]["input_digest"] == Codec.hash(document)
    assert source["schedule_receipt"]["revision"] == receipt.revision
    assert source["schedule_receipt"]["state"] == "admitted"
    assert %{"schedule_source" => ^source} = framed(c.authority, source_request(c.manager, 5))

    for revision <- [0, 5, 99] do
      assert %{"outcome" => "not_found"} = framed(c.authority, source_request(c.other, revision))
    end

    assert {:ok, 5} = Store.revision(c.store)
    assert {:ok, %{state: :inactive}} = Store.schedule_status(c.store, c.manager)

    assert {:ok,
            %{held_requests: 0, queued_requests: 0, claimed_requests: 0, dispatch_enabled: false}} =
             Store.health(c.store)

    assert {:ok, 6} = Store.revoke_target_grant(c.store, "manager:one", "light:one")

    for revision <- [0, 5] do
      assert %{"outcome" => "not_found"} =
               framed(c.authority, source_request(c.manager, revision))
    end

    assert {:ok, ^receipt} = Authority.original_schedule_status(c.authority, c.manager, document)
  end

  test "source reload survives same-owner restart without current timezone, gate or qualified clock",
       c do
    document =
      original("admit", "schedule:source:calendar", 3, %{
        "trigger" => ["daily", c.zone.name, c.zone.digest, "02:30:00", 0, nil]
      })

    assert {:ok, receipt} =
             Authority.retain_schedule_content(c.authority, c.manager, "admit", document)

    assert {:ok, source} = Authority.schedule_source(c.authority, c.manager, receipt.revision)
    File.rm!(Path.join(c.zone_root, c.zone.name))
    stop_supervised!(Store)
    store = start_supervised!({Store, path: Path.join(c.root, "home.sqlite")})
    authority = %{c.authority | store: store, review_gate: nil}
    assert {:ok, ^source} = Authority.schedule_source(authority, c.manager, 0)
    assert {:ok, ^source} = Authority.schedule_source(authority, c.manager, receipt.revision)
    assert {:ok, 4} = Store.revision(store)
    assert {:ok, %{state: :inactive}} = Store.schedule_status(store, c.manager)

    assert {:ok,
            %{
              reason: :temporal_clock_unavailable,
              interval: nil,
              sample: %{"wall_confidence" => "unqualified", "monotonic_continuous" => false}
            }} = Store.temporal_clock_snapshot(store)
  end

  test "latest visible selection skips a newer ungranted target and uses the current rotated credential",
       c do
    first = original("admit", "schedule:source:first", 3)

    assert {:ok, %{revision: 4}} =
             Authority.retain_schedule_content(c.authority, c.manager, "admit", first)

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:two",
        "role" => "Light",
        "profile_ref" => "fixture:power",
        "capabilities" => [
          %{
            "thing_id" => "light:two",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:power",
            "evidence_ref" => "fixture:two",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    assert {:ok, 5} = Store.enroll_thing(c.store, thing)
    assert {:ok, current, 6} = Store.grant_target_and_rotate(c.store, "manager:one", thing.id)
    {:ok, "admit", input} = OperationInput.decode(first)
    {:ok, source} = Codec.decode(input["source_document"])

    {:ok, rule} =
      RuleInput.source("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "rule:second",
        "expected_revision" => 6,
        "rule_id" => "rule:two",
        "source_revision" => 1,
        "target_id" => "light:two",
        "on" => false
      })

    {:ok, source} =
      Codec.encode(%{
        source
        | "id" => "schedule:two",
          "rule_id" => "rule:two",
          "rule_source_digest" => Codec.hash(rule),
          "target_id" => "light:two"
      })

    {:ok, second} =
      OperationInput.encode("admit", %{
        input
        | "operation_id" => "schedule:source:second",
          "expected_revision" => 6,
          "source_document" => source,
          "rule_document" => rule
      })

    assert {:ok, %{revision: 7}} =
             Authority.retain_schedule_content(c.authority, current, "admit", second)

    assert {:ok, %{original_document: ^second}} =
             Authority.schedule_source(c.authority, current, 0)

    assert {:ok, 8} = Store.revoke_target_grant(c.store, "manager:one", "light:two")

    assert {:ok, %{original_document: ^first}} =
             Authority.schedule_source(c.authority, current, 0)

    assert :not_found = Authority.schedule_source(c.authority, current, 7)

    assert {:ok, %{original_document: ^first}} =
             Authority.schedule_source(c.authority, current, 4)

    assert {:error, :unauthorized} = Authority.schedule_source(c.authority, c.manager, 4)
    assert {:ok, 8} = Store.revision(c.store)
  end

  test "source read rejects ungranted review permission, malformed selectors and authority-bearing fields",
       c do
    assert {:ok, reader, 4} =
             Store.provision_principal(c.store, "source:reader", ["read"], ["light:one"])

    assert %{"reason" => "permission_denied"} = framed(c.authority, source_request(reader, 0))

    for revision <- [-1, true, nil, "1", 1.0, 9_223_372_036_854_775_808] do
      assert %{"reason" => "invalid_schedule_source"} =
               framed(c.authority, source_request(c.manager, revision))
    end

    for field <-
          ~w(original_document clock_document timezone_document principal_id target_id active execute) do
      assert %{"outcome" => "error"} =
               framed(c.authority, Map.put(source_request(c.manager, 0), field, true))
    end

    assert {:ok, 4} = Store.revision(c.store)
  end

  @tag :requires_socket
  test "private socket CLI selects a retained source without the original file and never mutates",
       c do
    assert {:ok, %{"admission_revision" => 0}} = CLI.build_request(["schedule-source"], "fixture")

    for text <- ["0", "1", "9223372036854775807"] do
      assert {:ok, %{"admission_revision" => revision}} =
               CLI.build_request(["schedule-source", text], "fixture")

      assert Integer.to_string(revision) == text
    end

    for text <- [
          "",
          "01",
          "-1",
          "+1",
          "1.0",
          " 1",
          "1 ",
          "true",
          "9223372036854775808",
          String.duplicate("1", 20)
        ] do
      assert {:error, :invalid_schedule_source} =
               CLI.build_request(["schedule-source", text], "fixture")
    end

    credential_file = Path.join(c.root, "source.credential")
    File.write!(credential_file, Base.url_encode64(c.manager, padding: false))
    File.chmod!(credential_file, 0o600)
    socket = Path.join(c.root, "source.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    flags = ["--socket", socket, "--credential-file", credential_file]
    assert %{"outcome" => "not_found"} = cli(flags ++ ["schedule-source"], 4)
    document = original("admit", "schedule:source:cli", 3)

    assert {:ok, %{revision: 4}} =
             Authority.retain_schedule_content(c.authority, c.manager, "admit", document)

    assert %{"schedule_source" => source} = cli(flags ++ ["schedule-source"], 0)
    assert source["original_document"] == document
    assert %{"schedule_source" => ^source} = cli(flags ++ ["schedule-source", "4"], 0)
    assert %{"outcome" => "not_found"} = cli(flags ++ ["schedule-source", "5"], 4)
    assert {:ok, 4} = Store.revision(c.store)
    assert {:ok, %{held_requests: 0, dispatch_enabled: false}} = Store.health(c.store)
  end

  defp source_request(credential, revision),
    do: %{
      "api_version" => 1,
      "operation" => "schedule_source",
      "credential" => Base.url_encode64(credential, padding: false),
      "admission_revision" => revision
    }

  defp status_request(credential),
    do: %{
      "api_version" => 1,
      "operation" => "schedule_status",
      "credential" => Base.url_encode64(credential, padding: false)
    }

  defp lifecycle(kind, id, expected, admission \\ nil) do
    input = %{"authority_epoch" => 1, "operation_id" => id, "expected_revision" => expected}

    input =
      if kind == "activate", do: Map.put(input, "admission_revision", admission), else: input

    {:ok, document} = OperationInput.encode(kind, input)
    document
  end

  defp attach_clock(c) do
    root = Path.join(c.root, "clock-requests")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, runtime} = ClockOwner.runtime_digest()

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

    {:ok, document} = ClockCodec.policy_document(policy)
    file = Path.join(c.root, "clock.policy")
    :ok = PrivateFile.write(file, document, 4_096)

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {ClockOwner, store: c.store, operator: self(), root: root, policy_file: file},
          restart: :temporary
        )
      )

    {:ok, request} = ClockOwner.request(owner)
    {:ok, document} = PrivateFile.read(request.request_file, 4_096)
    {:ok, input} = ClockCodec.decode_request(document)

    record =
      Map.merge(input, %{
        "procedure_ref" => policy.procedure_ref,
        "observed_utc_ms" => System.system_time(:millisecond)
      })

    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(record, :crypto.sign(:eddsa, :none, payload, [private, :ed25519]))

    assert {:ok, _} = ClockOwner.approve(owner, request.request_digest, package)
    assert :ok = Store.attach_temporal_clock(c.store, owner)
  end

  defp cli(args, code), do: capture_io(fn -> assert CLI.main(args) == code end) |> JSON.decode!()

  defp timezone_request(credential, name, local),
    do: %{
      "api_version" => 1,
      "operation" => "schedule_timezone",
      "credential" => Base.url_encode64(credential, padding: false),
      "zone_name" => name,
      "local_datetime" => local
    }

  defp request(operation, credential, document),
    do: %{
      "api_version" => 1,
      "operation" => operation,
      "credential" => Base.url_encode64(credential, padding: false),
      "original_document" => document
    }

  defp framed(authority, request) do
    assert {:ok, frame} = Frame.encode_request(request)

    assert {:ok, <<size::unsigned-big-32, body::binary-size(size)>>} =
             Server.route_frame(authority, frame)

    assert {:ok, response} = Frame.decode_response(body)
    response
  end

  defp original(kind, operation, revision, changes \\ %{}) do
    {:ok, rule} =
      RuleInput.source("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "rule:body",
        "expected_revision" => 3,
        "rule_id" => "rule:one",
        "source_revision" => 1,
        "target_id" => "light:one",
        "on" => true
      })

    source =
      %{
        "id" => "schedule:one",
        "source_revision" => 1,
        "author_id" => "manager:one",
        "rule_id" => "rule:one",
        "rule_source_digest" => Codec.hash(rule),
        "target_id" => "light:one",
        "resource_revision" => 0,
        "late_window_ms" => 10_000,
        "uncertainty_tolerance_ms" => 100,
        "trigger" => ["interval", 100_000, 60_000, 0, nil]
      }
      |> Map.merge(changes)

    {:ok, source} = Codec.encode(source)

    {:ok, original} =
      OperationInput.encode(kind, %{
        "authority_epoch" => 1,
        "operation_id" => operation,
        "expected_revision" => revision,
        "source_document" => source,
        "rule_document" => rule
      })

    original
  end
end
