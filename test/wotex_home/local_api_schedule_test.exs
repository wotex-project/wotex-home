defmodule WotexHome.LocalAPIScheduleTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Rules.OperationInput, as: RuleInput
  alias WotexHome.Schedules.{Codec, OperationInput, Tzif}
  alias WotexHome.Semantics.Thing
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  setup do
    root = Path.join("/private/tmp", "woh-schedule-api-#{System.unique_integer([:positive])}")
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
