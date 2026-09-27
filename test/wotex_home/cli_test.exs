defmodule WotexHome.CLITest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias WotexHome.CLI
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Server}
  alias WotexHome.Semantics.Thing

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @rule %{
    "version" => 1,
    "id" => "rule:cli:1",
    "source_revision" => 1,
    "trigger" => %{"kind" => "explicit_request"},
    "predicate" => %{"op" => "literal_true"},
    "effect" => %{
      "target_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    },
    "authority_class" => "automation",
    "unknown_policy" => "block",
    "ownership_ms" => 10_000,
    "cooldown_ms" => 1_000,
    "causal_budget" => 4
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "read-only CLI uses a private credential file and returns scoped responses", %{
    directory: directory
  } do
    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))

    assert {:ok, credential, _revision} =
             Store.provision_principal(store, "reader:cli", ["read"], [])

    socket = Path.join(directory, "ipc/home.sock")
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket)

    credential_file = Path.join(directory, "credential")
    File.write!(credential_file, Base.url_encode64(credential, padding: false) <> "\n")
    File.chmod!(credential_file, 0o600)
    flags = ["--socket", socket, "--credential-file", credential_file]

    output =
      capture_io(fn ->
        assert 0 == CLI.main(flags ++ ["health"])
      end)

    assert %{"outcome" => "ok", "health" => %{"dispatch_enabled" => false}} =
             JSON.decode!(output)

    output =
      capture_io(fn ->
        assert 4 == CLI.main(flags ++ ["receipt", "1", "op:missing"])
      end)

    assert %{"outcome" => "not_found"} = JSON.decode!(output)

    assert %{"outcome" => "ok", "support" => support} =
             cli_json(flags ++ ["support-preview"], 0)

    assert {:ok, %{"outcome" => "error", "reason" => "unauthorized"}} =
             Client.request(socket, %{
               "api_version" => 1,
               "operation" => "support_preview",
               "credential" => Base.url_encode64(:binary.copy(<<0>>, 32), padding: false)
             })

    assert {:ok, %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"}} =
             Client.request(socket, %{
               "api_version" => 1,
               "operation" => "support_preview",
               "credential" => Base.url_encode64(credential, padding: false),
               "raw" => true
             })

    support_path = Path.join(directory, "support.json")

    assert %{"outcome" => "ok", "support_file" => ^support_path} =
             cli_json(flags ++ ["support-write", support_path], 0)

    assert JSON.decode!(File.read!(support_path)) == support
    assert {:ok, support_stat} = File.stat(support_path)
    assert Bitwise.band(support_stat.mode, 0o777) == 0o600

    error =
      capture_io(:stderr, fn -> assert 1 == CLI.main(flags ++ ["support-write", support_path]) end)

    assert error =~ "support_exists"

    assert %{"outcome" => "ok", "catalogue" => %{"items" => []}} =
             cli_json(flags ++ ["catalogue"], 0)

    assert %{"outcome" => "ok", "snapshot" => %{"items" => []}} =
             cli_json(flags ++ ["snapshot"], 0)

    assert %{"outcome" => "ok", "events" => %{"items" => []}} =
             cli_json(flags ++ ["events", "0"], 0)

    assert %{"outcome" => "ok", "request_events" => %{"items" => []}} =
             cli_json(flags ++ ["request-events", "0"], 0)

    File.chmod!(credential_file, 0o644)

    error =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main(flags ++ ["health"])
      end)

    assert error =~ "invalid_credential_file"
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  test "CLI stages held work and recovers exact IDs through the private socket", %{
    directory: directory
  } do
    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:cli", ["control:ordinary"], [thing.id])

    socket = Path.join(directory, "ipc/home.sock")
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket)
    credential_file = Path.join(directory, "credential")
    File.write!(credential_file, Base.url_encode64(credential, padding: false))
    File.chmod!(credential_file, 0o600)
    flags = ["--socket", socket, "--credential-file", credential_file]

    mutation_file = Path.join(directory, "mutation.json")

    File.write!(
      mutation_file,
      JSON.encode!(%{
        "api_version" => 1,
        "operation_id" => "op:cli:1",
        "authority_epoch" => 1,
        "expected_revision" => 0,
        "target_id" => thing.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })
    )

    File.chmod!(mutation_file, 0o600)

    assert %{"outcome" => "ok", "receipt" => %{"disposition" => "held"}} =
             cli_json(flags ++ ["submit", mutation_file], 0)

    assert %{"receipt" => %{"operation_id" => "op:cli:1", "disposition" => "held"}} =
             cli_json(flags ++ ["receipt", "1", "op:cli:1"], 0)

    assert %{"outcome" => "ok", "catalogue" => %{"items" => [_thing], "watermark" => watermark}} =
             cli_json(flags ++ ["catalogue"], 0)

    assert %{"outcome" => "ok", "catalogue" => %{"items" => []}} =
             cli_json(flags ++ ["catalogue", Integer.to_string(watermark), thing.id], 0)

    assert %{"outcome" => "ok", "history" => %{"items" => []}} =
             cli_json(flags ++ ["history", thing.id, "power"], 0)

    assert %{
             "outcome" => "ok",
             "request_events" => %{"items" => [_event], "next_after" => cursor}
           } =
             cli_json(flags ++ ["request-events", "0"], 0)

    assert %{"outcome" => "ok", "request_events" => %{"items" => []}} =
             cli_json(flags ++ ["request-events", Integer.to_string(cursor)], 0)

    assert %{"receipt" => %{"disposition" => "rejected", "reason" => "cancelled"}} =
             cli_json(flags ++ ["cancel", "1", "op:cli:1"], 0)

    assert %{"receipt" => %{"disposition" => "rejected"}} =
             cli_json(flags ++ ["receipt", "1", "op:cli:1"], 0)

    assert %{"override_receipt" => %{"operation_id" => "override:cli:1"}} =
             cli_json(
               flags ++ ["override-issue", "1", "override:cli:1", thing.id, "0", "5000"],
               0
             )

    assert %{"override_receipt" => %{"operation_id" => "override:cli:1"}} =
             cli_json(flags ++ ["override-status", "1", "override:cli:1"], 0)

    assert %{"override_receipt" => %{"operation_id" => "override:cli:1"}} =
             cli_json(flags ++ ["override-revoke", "1", "override:cli:1"], 0)

    File.chmod!(mutation_file, 0o644)

    error =
      capture_io(:stderr, fn -> assert 1 == CLI.main(flags ++ ["submit", mutation_file]) end)

    assert error =~ "invalid_mutation_file"

    File.chmod!(mutation_file, 0o600)
    File.write!(mutation_file, ~s({"api_version":1,"api_version":1}))

    error =
      capture_io(:stderr, fn -> assert 1 == CLI.main(flags ++ ["submit", mutation_file]) end)

    assert error =~ "invalid_mutation_file"

    assert {:ok, reviewer, _revision} =
             Store.provision_principal(store, "reviewer:cli", ["rule:review"], [thing.id])

    File.write!(credential_file, Base.url_encode64(reviewer, padding: false))
    rules_file = Path.join(directory, "rules.json")
    File.write!(rules_file, JSON.encode!(%{"rules" => [@rule]}))
    File.chmod!(rules_file, 0o600)

    assert %{"outcome" => "ok", "review" => %{"decision" => "pending_positive_basis"}} =
             cli_json(flags ++ ["review-rules", rules_file], 0)

    File.write!(rules_file, ~s({"rules":[],"rules":[]}))

    error =
      capture_io(:stderr, fn -> assert 1 == CLI.main(flags ++ ["review-rules", rules_file]) end)

    assert error =~ "invalid_rules_file"

    :ok = GenServer.stop(server)

    error =
      capture_io(:stderr, fn ->
        assert 3 == CLI.main(flags ++ ["cancel", "1", "op:cli:1"])
      end)

    assert error =~ "outcome unknown"
    assert error =~ "receipt 1 op:cli:1"
    :ok = GenServer.stop(store)
  end

  defp cli_json(args, expected_status) do
    args
    |> then(fn command ->
      capture_io(fn -> assert expected_status == CLI.main(command) end)
    end)
    |> JSON.decode!()
  end
end
