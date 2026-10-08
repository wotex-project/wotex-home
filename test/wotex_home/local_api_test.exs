defmodule WotexHome.LocalAPITest do
  @moduledoc false

  use ExUnit.Case
  import Bitwise

  alias WotexHome.Authority
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.Durable.Store
  alias WotexHome.Intent.Grammar
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Semantics.{Observation, Thing}

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

  @mutation %{
    "api_version" => 1,
    "operation_id" => "op:1",
    "authority_epoch" => 1,
    "expected_revision" => 0,
    "target_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => true}
  }

  @rule %{
    "version" => 1,
    "id" => "rule:1",
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
      Path.join(System.tmp_dir!(), "wotex-home-ipc-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    store_path = Path.join(directory, "home.sqlite")
    socket_path = Path.join(directory, "private/home.sock")
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory, store_path: store_path, socket_path: socket_path}
  end

  @tag requires_socket: true
  test "socket mutation and explicit invocation cannot manufacture temporal provenance", c do
    store = start_supervised!({Store, path: c.store_path})
    _controller = provision!(store)

    {:ok, manager, 3} =
      Store.provision_principal(
        store,
        "manager:temporal",
        ~w(rule:review rule:manage control:ordinary),
        ["light:desk"]
      )

    start_supervised!({Server, store: store, socket_path: c.socket_path})
    encoded = Base.url_encode64(manager, padding: false)
    operation = "occ:" <> String.duplicate("d", 64)

    for payload <- [
          %{
            "api_version" => 1,
            "operation" => "submit",
            "credential" => encoded,
            "mutation" => %{@mutation | "operation_id" => operation}
          },
          %{
            "api_version" => 1,
            "operation" => "invoke_rule",
            "credential" => encoded,
            "authority_epoch" => 1,
            "operation_id" => operation,
            "rule_generation" => 0,
            "rule_id" => "rule:one"
          }
        ] do
      assert %{"outcome" => "error", "reason" => "reserved_operation_id"} =
               request(c.socket_path, payload)
    end

    assert {:ok, 3} = Store.revision(store)
    assert :not_found = Store.request_status(store, manager, 1, operation)

    assert {:ok, %{held_requests: 0, queued_requests: 0, writable: true, dispatch_enabled: false}} =
             Store.health(store)
  end

  @tag requires_socket: true
  test "override read is scoped and reports only Store-timed remaining life", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    controller = provision!(store)

    assert {:ok, reader, 3} =
             Store.provision_principal(store, "reader:1", ["read"], ["light:desk"])

    assert {:ok, ungranted, 4} = Store.provision_principal(store, "reader:2", ["read"], [])

    assert {:ok, _lease, 5} =
             Store.issue_override_lease_live(store, controller, "light:desk", 1, 0, 5_000)

    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    query = fn credential, targets ->
      request(socket_path, %{
        "api_version" => 1,
        "operation" => "overrides",
        "credential" => Base.url_encode64(credential, padding: false),
        "target_ids" => targets
      })
    end

    assert %{
             "outcome" => "ok",
             "overrides" => [
               %{
                 "target_id" => "light:desk",
                 "operator_id" => "operator:1",
                 "authority_epoch" => 1,
                 "basis_revision" => 0,
                 "remaining_ms" => remaining
               }
             ]
           } = query.(reader, ["light:desk"])

    assert remaining in 1..5_000

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             query.(ungranted, ["light:desk"])

    assert %{"outcome" => "ok", "overrides" => []} = query.(ungranted, [])

    assert %{"outcome" => "error", "reason" => "invalid_override_query"} =
             query.(reader, ["light:desk", "light:desk"])

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "overrides",
               "credential" => Base.url_encode64(reader, padding: false),
               "target_ids" => ["light:desk"],
               "now_ms" => 0
             })

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "override mutation routes keep one durable issue across retries", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    controller = provision!(store)

    assert {:ok, reader, 3} =
             Store.provision_principal(store, "reader:1", ["read"], ["light:desk"])

    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)
    encoded = Base.url_encode64(controller, padding: false)

    issue = %{
      "api_version" => 1,
      "operation" => "override_issue",
      "credential" => encoded,
      "authority_epoch" => 1,
      "operation_id" => "override:socket:1",
      "target_id" => "light:desk",
      "basis_revision" => 0,
      "duration_ms" => 5_000
    }

    assert %{
             "outcome" => "ok",
             "override_receipt" => %{
               "operation_id" => "override:socket:1",
               "issue_revision" => 4,
               "active" => true,
               "remaining_ms" => remaining
             }
           } = request(socket_path, issue)

    assert remaining in 1..5_000

    overrides = fn credential ->
      request(socket_path, %{
        "api_version" => 1,
        "operation" => "overrides",
        "credential" => Base.url_encode64(credential, padding: false),
        "target_ids" => ["light:desk"]
      })
    end

    assert %{"overrides" => [%{"operation_id" => "override:socket:1"}]} =
             overrides.(controller)

    assert %{"overrides" => [%{"operation_id" => nil}]} = overrides.(reader)

    assert %{"override_receipt" => %{"issue_revision" => 4}} =
             request(socket_path, issue)

    assert %{"outcome" => "error", "reason" => "override_operation_conflict"} =
             request(socket_path, %{issue | "duration_ms" => 6_000})

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             request(socket_path, %{
               issue
               | "credential" => Base.url_encode64(reader, padding: false),
                 "operation_id" => "override:reader:1"
             })

    base = Map.take(issue, ["api_version", "credential", "authority_epoch", "operation_id"])

    assert %{"override_receipt" => %{"issue_revision" => 4, "active" => true}} =
             request(socket_path, Map.put(base, "operation", "override_status"))

    assert %{"outcome" => "not_found"} =
             request(
               socket_path,
               Map.merge(base, %{
                 "operation_id" => "override:missing",
                 "operation" => "override_status"
               })
             )

    assert %{
             "override_receipt" => %{
               "issue_revision" => 4,
               "revoke_revision" => 5,
               "active" => false,
               "remaining_ms" => 0
             }
           } = request(socket_path, Map.put(base, "operation", "override_revoke"))

    assert %{"override_receipt" => %{"revoke_revision" => 5}} =
             request(socket_path, Map.put(base, "operation", "override_revoke"))

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             request(socket_path, Map.put(issue, "now_ms", 0))

    assert {:ok, 5} = Store.revision(store)
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "baseline input surfaces cannot clear or hush a smoke detector", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:abstain, :unsupported_phrase} = Grammar.classify("hush hall smoke detector")
    assert {:ok, store} = Store.start_link(path: store_path)

    assert {:ok, smoke} =
             Thing.new(%{
               "id" => "smoke:hall",
               "role" => "SmokeDetector",
               "profile_ref" => "aqara.detector:1",
               "capabilities" => [
                 %{
                   "thing_id" => "smoke:hall",
                   "role" => "SmokeDetector",
                   "key" => "smoke_state",
                   "value_kind" => "smoke_state",
                   "unit" => "none",
                   "operations" => ["read"],
                   "risk_class" => "sensitive",
                   "profile_ref" => "aqara.detector:1",
                   "evidence_ref" => "fixture:smoke:1",
                   "freshness_ms" => 60_000,
                   "constraints" => %{},
                   "extensions" => %{}
                 }
               ]
             })

    assert {:ok, 1} = Store.enroll_thing(store, smoke)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["smoke:hall"])

    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    base = %{
      "api_version" => 1,
      "operation" => "submit",
      "credential" => Base.url_encode64(credential, padding: false)
    }

    assert %{
             "outcome" => "ok",
             "receipt" => %{"disposition" => "rejected", "reason" => "read_only_capability"}
           } =
             request(
               socket_path,
               Map.put(base, "mutation", %{
                 @mutation
                 | "operation_id" => "op:smoke:clear",
                   "target_id" => "smoke:hall",
                   "capability_key" => "smoke_state",
                   "value" => %{"type" => "smoke_state", "state" => "clear"}
               })
             )

    assert %{
             "outcome" => "ok",
             "receipt" => %{"disposition" => "rejected", "reason" => "unsupported_capability"}
           } =
             request(
               socket_path,
               Map.put(base, "mutation", %{
                 @mutation
                 | "operation_id" => "op:smoke:hush",
                   "target_id" => "smoke:hall",
                   "capability_key" => "hush",
                   "value" => %{"type" => "boolean", "value" => true}
               })
             )

    assert {:ok, %{held_requests: 0, dispatch_enabled: false}} = Store.health(store)
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "request journal cursor exposes only the authenticated principal's receipts", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    first_credential = provision!(store)

    assert {:ok, second_credential, 3} =
             Store.provision_principal(store, "operator:2", ["control:ordinary"], ["light:desk"])

    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    submit = fn credential, operation_id ->
      request(socket_path, %{
        "api_version" => 1,
        "operation" => "submit",
        "credential" => Base.url_encode64(credential, padding: false),
        "mutation" => %{@mutation | "operation_id" => operation_id}
      })
    end

    assert %{"receipt" => %{"revision" => 4, "disposition" => "held"}} =
             submit.(first_credential, "op:first")

    assert %{"receipt" => %{"revision" => 5, "disposition" => "held"}} =
             submit.(second_credential, "op:second")

    assert %{"receipt" => %{"revision" => 6, "disposition" => "rejected"}} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "cancel",
               "credential" => Base.url_encode64(first_credential, padding: false),
               "authority_epoch" => 1,
               "operation_id" => "op:first"
             })

    base = %{
      "api_version" => 1,
      "operation" => "request_events",
      "credential" => Base.url_encode64(first_credential, padding: false),
      "after_revision" => 0,
      "page_size" => 1
    }

    assert %{
             "outcome" => "ok",
             "request_events" => %{
               "items" => [
                 %{"operation_id" => "op:first", "disposition" => "held", "revision" => 4}
               ],
               "next_after" => 4,
               "has_more" => true
             }
           } = request(socket_path, base)

    assert %{
             "request_events" => %{
               "items" => [
                 %{"operation_id" => "op:first", "reason" => "cancelled", "revision" => 6}
               ],
               "next_after" => 6,
               "has_more" => false
             }
           } = request(socket_path, %{base | "after_revision" => 4})

    assert %{"request_events" => %{"items" => [], "next_after" => 6}} =
             request(socket_path, %{base | "after_revision" => 6})

    assert %{"outcome" => "error", "reason" => "invalid_event_cursor"} =
             request(socket_path, %{base | "after_revision" => 7})

    assert {:ok, 7} = Store.revoke_principal(store, "operator:1")

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             request(socket_path, base)

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "scoped draft review is pending, read-only, and revoked with its credential", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    control_credential = provision!(store)

    assert {:ok, review_credential, 3} =
             Store.provision_principal(store, "reviewer:1", ["rule:review"], ["light:desk"])

    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    review_request = %{
      "api_version" => 1,
      "operation" => "review_rules",
      "credential" => Base.url_encode64(review_credential, padding: false),
      "rules" => [@rule]
    }

    assert %{
             "outcome" => "ok",
             "review" => %{
               "decision" => "pending_positive_basis",
               "rule_digest" => rule_digest,
               "registry_digest" => registry_digest,
               "watermark" => 3
             }
           } = request(socket_path, review_request)

    assert byte_size(rule_digest) == 64
    assert byte_size(registry_digest) == 64
    assert {:ok, 3} = Store.revision(store)

    basis_rule = %{@rule | "cooldown_ms" => 0, "causal_budget" => 1}

    assert %{
             "outcome" => "ok",
             "review" => %{
               "decision" => "pending_positive_basis",
               "proposal_basis" => %{
                 "profile" => "explicit-boolean-light-v3",
                 "scope" => "proposal_generation_only",
                 "target_id" => "light:desk",
                 "runtime_digest" => runtime_digest,
                 "compiler_profile" => "home-rule-ir-v1",
                 "source_digest" => source_digest,
                 "ir_digest" => ir_digest
               },
               "watermark" => 3
             }
           } = request(socket_path, %{review_request | "rules" => [basis_rule]})

    assert byte_size(runtime_digest) == 64
    assert byte_size(source_digest) == 64 and byte_size(ir_digest) == 64
    assert {:ok, 3} = Store.revision(store)

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             request(socket_path, %{
               review_request
               | "credential" => Base.url_encode64(control_credential, padding: false)
             })

    assert %{"outcome" => "error", "reason" => "invalid_fields"} =
             request(socket_path, %{
               review_request
               | "rules" => [Map.put(@rule, "unexpected", true)]
             })

    assert {:ok, things, 3} = Store.review_inputs(store, review_credential)
    assert Map.keys(things) == ["light:desk"]
    assert :ok = Store.review_current(store, review_credential, 3)

    assert {:ok, 4} = Store.revoke_principal(store, "reviewer:1")
    assert {:error, :unauthorized} = Store.review_current(store, review_credential, 3)

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             request(socket_path, review_request)

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  test "draft review watermark expires after a registry change", %{store_path: store_path} do
    assert {:ok, store} = Store.start_link(path: store_path)
    _control_credential = provision!(store)

    assert {:ok, review_credential, 3} =
             Store.provision_principal(store, "reviewer:1", ["rule:review"], ["light:desk"])

    assert {:ok, _things, 3} = Store.review_inputs(store, review_credential)
    assert {:ok, 4} = Store.revoke_thing(store, "light:desk")
    assert {:error, :resnapshot_required} = Store.review_current(store, review_credential, 3)
    assert {:error, :review_scope_unavailable} = Store.review_inputs(store, review_credential)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "draft review has two checker slots and recovers a crashed caller", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    _control_credential = provision!(store)

    assert {:ok, review_credential, 3} =
             Store.provision_principal(store, "reviewer:1", ["rule:review"], ["light:desk"])

    assert {:ok, review_gate} = ReviewGate.start_link()

    authority =
      Authority.new(store: store, capture: nil, review_gate: review_gate)

    assert {:ok, server} =
             Server.start_link(authority: authority, socket_path: socket_path)

    parent = self()

    holders =
      for _ <- 1..2 do
        spawn(fn ->
          result =
            ReviewGate.run(review_gate, fn ->
              send(parent, {:review_slot, :ok})

              receive do
                :stop -> :ok
              end
            end)

          send(parent, {:review_finished, result})
        end)
      end

    assert_receive {:review_slot, :ok}
    assert_receive {:review_slot, :ok}

    review_request = %{
      "api_version" => 1,
      "operation" => "review_rules",
      "credential" => Base.url_encode64(review_credential, padding: false),
      "rules" => [@rule]
    }

    assert %{"outcome" => "error", "reason" => "review_capacity"} =
             request(socket_path, review_request)

    [crashed | _] = holders
    Process.exit(crashed, :kill)
    assert_review_slots(review_gate, 1, 100)

    assert %{"outcome" => "ok", "review" => %{"decision" => "pending_positive_basis"}} =
             request(socket_path, review_request)

    Enum.each(holders, &send(&1, :stop))
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(review_gate)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "private socket uses store authentication and returns held receipts", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    credential = provision!(store)
    encoded = Base.url_encode64(credential, padding: false)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    assert {:ok, directory_stat} = File.stat(Path.dirname(socket_path))
    assert (directory_stat.mode &&& 0o777) == 0o700
    assert {:ok, socket_stat} = File.lstat(socket_path)
    assert (socket_stat.mode &&& 0o777) == 0o600

    assert {:ok, %{"outcome" => "ok", "health" => %{"held_requests" => 0}}} =
             Client.request(socket_path, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => encoded
             })

    assert %{"outcome" => "ok", "health" => %{"held_requests" => 0}} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => encoded
             })

    assert %{"outcome" => "ok", "receipt" => %{"disposition" => "held", "revision" => 3}} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "submit",
               "credential" => encoded,
               "mutation" => @mutation
             })

    assert %{"outcome" => "ok", "receipt" => %{"disposition" => "held"}} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "status",
               "credential" => encoded,
               "authority_epoch" => 1,
               "operation_id" => "op:1"
             })

    assert %{"outcome" => "ok", "health" => %{"held_requests" => 1}} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => encoded
             })

    assert %{
             "outcome" => "ok",
             "receipt" => %{"disposition" => "rejected", "reason" => "cancelled", "revision" => 4}
           } =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "cancel",
               "credential" => encoded,
               "authority_epoch" => 1,
               "operation_id" => "op:1"
             })

    assert %{"outcome" => "ok", "health" => %{"held_requests" => 0}} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => encoded
             })

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "client rejects invalid paths and malformed response frames", %{directory: directory} do
    assert {:error, :invalid_socket_path} = Client.request("relative.sock", %{})
    assert {:error, :invalid_client_request} = Client.request("/tmp/home.sock", %{}, 0)

    private = Path.join(directory, "fake")
    File.mkdir!(private)
    File.chmod!(private, 0o700)
    endpoint = Path.join(private, "fake.sock")

    assert {:ok, listener} =
             :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, String.to_charlist(endpoint)}}])

    File.chmod!(endpoint, 0o666)
    assert {:error, :invalid_socket_path} = Client.request(endpoint, %{})
    File.chmod!(endpoint, 0o600)
    File.chmod!(private, 0o755)
    assert {:error, :invalid_socket_path} = Client.request(endpoint, %{})
    :ok = :gen_tcp.close(listener)

    assert {:error, :invalid_response} =
             Frame.decode_response(~s({"api_version":1,"outcome":"ok","outcome":"error"}))

    assert {:error, :invalid_response} =
             Frame.decode_response(~s({"api_version":2,"outcome":"ok"}))

    assert {:error, :response_too_large} =
             Frame.decode_response(:binary.copy("x", 1_048_577))
  end

  @tag requires_socket: true
  test "timed-out submission reports uncertainty and the original ID resolves", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    credential = provision!(store)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)
    encoded = Base.url_encode64(credential, padding: false)

    :ok = :sys.suspend(store)

    try do
      assert {:ok, %{"outcome" => "error", "reason" => "outcome_unknown"}} =
               Client.request(
                 socket_path,
                 %{
                   "api_version" => 1,
                   "operation" => "submit",
                   "credential" => encoded,
                   "mutation" => @mutation
                 },
                 10_000
               )
    after
      :ok = :sys.resume(store)
    end

    assert {:ok, %WotexHome.Durable.Receipt{disposition: :held}} =
             Store.request_status(store, credential, 1, "op:1")

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "uncertain recorded review resolves under its original operation ID", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    _controller = provision!(store)

    assert {:ok, reviewer, 3} =
             Store.provision_principal(store, "reviewer:uncertain", ["rule:review"], [
               "light:desk"
             ])

    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)
    encoded = Base.url_encode64(reviewer, padding: false)
    {:ok, rule} = WotexHome.Rules.Rule.new(@rule)
    {:ok, document} = WotexHome.Rules.Codec.encode([rule, rule])

    {:ok, :new, things, resources} =
      Store.prepare_rule_review(store, reviewer, 1, "review:uncertain", 3, document)

    {:ok, review} = WotexHome.Rules.CandidateReview.review([rule, rule], things)
    {:ok, artifact} = WotexHome.Rules.CandidateArtifact.build([rule, rule], resources, review)

    # Suspend only after checking: the original commit is already an admissible
    # Store call when its caller times out. Resuming may still commit that call.
    :ok = :sys.suspend(store)

    task =
      Task.async(fn ->
        try do
          Store.commit_rule_review(store, reviewer, 1, "review:uncertain", 3, document, artifact)
        catch
          :exit, {:timeout, _} -> :outcome_unknown
        end
      end)

    try do
      assert :outcome_unknown = Task.await(task, 6_000)
    after
      :ok = :sys.resume(store)
    end

    assert {:ok, %{"outcome" => "ok", "rule_review_receipt" => receipt}} =
             Client.request(socket_path, %{
               "api_version" => 1,
               "operation" => "rule_review_status",
               "credential" => encoded,
               "authority_epoch" => 1,
               "operation_id" => "review:uncertain"
             })

    assert receipt["decision"] == "rejected" and receipt["revision"] == 4

    assert {:ok, %{"rule_review_receipt" => ^receipt}} =
             Client.request(
               socket_path,
               %{
                 "api_version" => 1,
                 "operation" => "record_rule_review",
                 "credential" => encoded,
                 "authority_epoch" => 1,
                 "operation_id" => "review:uncertain",
                 "expected_revision" => 3,
                 "rules" => [@rule, @rule]
               },
               15_000
             )

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "wrong credentials, unknown fields, duplicate JSON and oversized frames fail closed", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    credential = provision!(store)
    encoded = Base.url_encode64(credential, padding: false)
    wrong = Base.url_encode64(:binary.copy(<<2>>, 32), padding: false)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => wrong
             })

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => encoded,
               "driver" => "raw"
             })

    assert %{"outcome" => "error", "reason" => "unsupported_api_version"} =
             request(socket_path, %{
               "api_version" => 2,
               "operation" => "health",
               "credential" => encoded
             })

    assert %{"outcome" => "error", "reason" => "duplicate_member"} =
             raw_request(
               socket_path,
               "{\"api_version\":1,\"operation\":\"health\",\"operation\":\"submit\"}"
             )

    assert %{"outcome" => "error", "reason" => "request_too_large"} =
             raw_frame(socket_path, <<65_537::unsigned-big-32>>)

    assert {:ok, 2} = Store.revision(store)
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "second socket owner is refused and a stopped owner releases its path", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    assert {:ok, first} = Server.start_link(store: store, socket_path: socket_path)
    Process.flag(:trap_exit, true)
    assert {:error, :already_running} = Server.start_link(store: store, socket_path: socket_path)
    :ok = GenServer.stop(first)
    assert {:ok, second} = Server.start_link(store: store, socket_path: socket_path)
    :ok = GenServer.stop(second)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "socket stops accepting when its authority store stops", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)
    server_ref = Process.monitor(server)

    :ok = GenServer.stop(store)
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 1_000
    refute File.exists?(socket_path)
  end

  @tag requires_socket: true
  test "a stalled local client does not block another authenticated request", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    credential = provision!(store)
    encoded = Base.url_encode64(credential, padding: false)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    assert {:ok, stalled} =
             :gen_tcp.connect(
               {:local, String.to_charlist(socket_path)},
               0,
               [:binary, {:active, false}],
               1_000
             )

    assert :ok = :gen_tcp.send(stalled, <<0, 0>>)

    assert %{"outcome" => "ok", "health" => %{"store_revision" => 2}} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => encoded
             })

    :ok = :gen_tcp.close(stalled)
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "snapshot pages are scoped, stable, and cut off on revocation", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    credential = provision!(store)
    encoded = Base.url_encode64(credential, padding: false)

    for {thing_id, revision} <- [{"light:desk", 3}, {"light:other", 5}] do
      if thing_id == "light:other" do
        assert {:ok, thing} =
                 Thing.new(%{
                   "id" => thing_id,
                   "role" => "Light",
                   "profile_ref" => "lifx.old:1",
                   "capabilities" => [%{@power | "thing_id" => thing_id}]
                 })

        assert {:ok, 4} = Store.enroll_thing(store, thing)
      end

      capability =
        if thing_id == "light:desk", do: @power, else: %{@power | "thing_id" => thing_id}

      assert {:ok, parsed_capability} = WotexHome.Semantics.Capability.new(capability)

      assert {:ok, observation} =
               Observation.new(
                 %{
                   "thing_id" => thing_id,
                   "capability_key" => "power",
                   "value" => %{"type" => "boolean", "value" => true},
                   "quality" => "reported",
                   "trust" => "unauthenticated_local",
                   "source_epoch" => "device:1",
                   "source_sequence" => 1,
                   "boot_epoch" => "boot:1",
                   "source_time_utc_ms" => nil,
                   "received_time_utc_ms" => 1_000,
                   "received_monotonic_ms" => 1_000
                 },
                 parsed_capability
               )

      assert {:ok, ^revision} = Store.record(store, observation, parsed_capability)
    end

    assert {:ok, observer, 6} =
             Store.provision_principal(store, "observer:1", ["read"], [
               "light:desk",
               "light:other"
             ])

    observer_encoded = Base.url_encode64(observer, padding: false)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    assert %{
             "outcome" => "ok",
             "catalogue" => %{
               "watermark" => 6,
               "items" => [%{"id" => "light:desk", "resource_revision" => 0}],
               "next_after" => "light:desk"
             }
           } =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "catalogue",
               "credential" => observer_encoded,
               "watermark" => nil,
               "after" => nil,
               "page_size" => 1
             })

    assert %{
             "outcome" => "ok",
             "catalogue" => %{
               "items" => [%{"id" => "light:other"}],
               "next_after" => nil
             }
           } =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "catalogue",
               "credential" => observer_encoded,
               "watermark" => 6,
               "after" => "light:desk",
               "page_size" => 1
             })

    first =
      request(socket_path, %{
        "api_version" => 1,
        "operation" => "snapshot",
        "credential" => observer_encoded,
        "watermark" => nil,
        "after" => nil,
        "page_size" => 1
      })

    assert %{
             "outcome" => "ok",
             "snapshot" => %{
               "watermark" => 6,
               "authority_epoch" => 1,
               "items" => [%{"thing_id" => "light:desk", "value" => %{"value" => true}}],
               "next_after" => %{"thing_id" => "light:desk"} = after_key
             }
           } = first

    assert %{"outcome" => "error", "reason" => "invalid_snapshot_request"} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "snapshot",
               "credential" => observer_encoded,
               "watermark" => nil,
               "after" => after_key,
               "page_size" => 101
             })

    second_request = %{
      "api_version" => 1,
      "operation" => "snapshot",
      "credential" => observer_encoded,
      "watermark" => 6,
      "after" => after_key,
      "page_size" => 1
    }

    assert %{
             "outcome" => "ok",
             "snapshot" => %{"items" => [%{"thing_id" => "light:other"}], "next_after" => nil}
           } =
             request(socket_path, second_request)

    assert %{
             "outcome" => "ok",
             "snapshot" => %{"items" => [%{"thing_id" => "light:desk"}], "next_after" => nil}
           } =
             request(socket_path, %{
               second_request
               | "credential" => encoded,
                 "watermark" => nil,
                 "after" => nil
             })

    assert {:ok, 7} = Store.revoke_thing(store, "light:other")

    assert %{"outcome" => "error", "reason" => "resnapshot_required"} =
             request(socket_path, second_request)

    assert %{"outcome" => "error", "reason" => "resnapshot_required"} =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "catalogue",
               "credential" => observer_encoded,
               "watermark" => 6,
               "after" => "light:desk",
               "page_size" => 1
             })

    assert %{
             "outcome" => "ok",
             "catalogue" => %{"items" => [%{"id" => "light:desk"}], "next_after" => nil}
           } =
             request(socket_path, %{
               "api_version" => 1,
               "operation" => "catalogue",
               "credential" => observer_encoded,
               "watermark" => nil,
               "after" => nil,
               "page_size" => 10
             })

    assert {:ok, 8} = Store.revoke_principal(store, "observer:1")

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             request(socket_path, %{second_request | "watermark" => nil, "after" => nil})

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "history pages expose only a granted capability and require a stable watermark", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    credential = provision!(store)
    encoded = Base.url_encode64(credential, padding: false)
    assert {:ok, capability} = WotexHome.Semantics.Capability.new(@power)

    base = %{
      "thing_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => false},
      "quality" => "reported",
      "trust" => "unauthenticated_local",
      "source_epoch" => "device:1",
      "source_sequence" => 1,
      "boot_epoch" => "boot:1",
      "source_time_utc_ms" => nil,
      "received_time_utc_ms" => 1_000,
      "received_monotonic_ms" => 1_000
    }

    assert {:ok, first} = Observation.new(base, capability)
    assert {:ok, 3} = Store.record(store, first, capability)

    assert {:ok, second} =
             Observation.new(
               %{
                 base
                 | "source_sequence" => 2,
                   "received_time_utc_ms" => 2_000,
                   "received_monotonic_ms" => 2_000,
                   "value" => %{"type" => "boolean", "value" => true}
               },
               capability
             )

    assert {:ok, 4} = Store.record(store, second, capability)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    request_base = %{
      "api_version" => 1,
      "operation" => "history",
      "credential" => encoded,
      "thing_id" => "light:desk",
      "capability_key" => "power",
      "watermark" => nil,
      "after_revision" => 0,
      "page_size" => 1
    }

    assert %{
             "outcome" => "ok",
             "history" => %{
               "watermark" => 4,
               "items" => [%{"revision" => 3, "value" => %{"value" => false}}],
               "next_after" => 3
             }
           } = request(socket_path, request_base)

    assert %{
             "outcome" => "ok",
             "history" => %{
               "items" => [%{"revision" => 4, "value" => %{"value" => true}}],
               "next_after" => nil
             }
           } =
             request(socket_path, %{request_base | "watermark" => 4, "after_revision" => 3})

    assert %{"outcome" => "error", "reason" => "unknown_capability"} =
             request(socket_path, %{request_base | "capability_key" => "colour_xy"})

    assert {:ok, 5} = Store.revoke_thing(store, "light:desk")

    assert %{"outcome" => "error", "reason" => "target_unavailable"} =
             request(socket_path, request_base)

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  @tag requires_socket: true
  test "event cursors page scoped observations and advance past hidden writes", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    credential = provision!(store)
    encoded = Base.url_encode64(credential, padding: false)
    assert {:ok, visible_capability} = WotexHome.Semantics.Capability.new(@power)
    hidden_declaration = %{@power | "thing_id" => "light:hidden"}

    assert {:ok, hidden_capability} =
             WotexHome.Semantics.Capability.new(hidden_declaration)

    assert {:ok, hidden_thing} =
             Thing.new(%{
               "id" => "light:hidden",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [hidden_declaration]
             })

    assert {:ok, 3} = Store.enroll_thing(store, hidden_thing)

    base = %{
      "thing_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => false},
      "quality" => "reported",
      "trust" => "unauthenticated_local",
      "source_epoch" => "device:1",
      "source_sequence" => 1,
      "boot_epoch" => "boot:1",
      "source_time_utc_ms" => nil,
      "received_time_utc_ms" => 1_000,
      "received_monotonic_ms" => 1_000
    }

    assert {:ok, hidden} =
             Observation.new(%{base | "thing_id" => "light:hidden"}, hidden_capability)

    assert {:ok, 4} = Store.record(store, hidden, hidden_capability)
    assert {:ok, first} = Observation.new(base, visible_capability)
    assert {:ok, 5} = Store.record(store, first, visible_capability)

    assert {:ok, second} =
             Observation.new(
               %{
                 base
                 | "source_sequence" => 2,
                   "received_time_utc_ms" => 2_000,
                   "received_monotonic_ms" => 2_000,
                   "value" => %{"type" => "boolean", "value" => true}
               },
               visible_capability
             )

    assert {:ok, 6} = Store.record(store, second, visible_capability)
    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)

    request_base = %{
      "api_version" => 1,
      "operation" => "events",
      "credential" => encoded,
      "after_revision" => 2,
      "page_size" => 1
    }

    assert %{
             "outcome" => "ok",
             "events" => %{
               "watermark" => 6,
               "items" => [%{"thing_id" => "light:desk", "revision" => 5}],
               "next_after" => 5,
               "has_more" => true
             }
           } = request(socket_path, request_base)

    assert %{
             "outcome" => "ok",
             "events" => %{
               "items" => [%{"thing_id" => "light:desk", "revision" => 6}],
               "next_after" => 6,
               "has_more" => false
             }
           } = request(socket_path, %{request_base | "after_revision" => 5})

    assert %{"outcome" => "error", "reason" => "invalid_event_cursor"} =
             request(socket_path, %{request_base | "after_revision" => 7})

    assert {:ok, later_hidden} =
             Observation.new(
               %{
                 base
                 | "thing_id" => "light:hidden",
                   "source_sequence" => 2,
                   "received_time_utc_ms" => 2_000,
                   "received_monotonic_ms" => 2_000
               },
               hidden_capability
             )

    assert {:ok, 7} = Store.record(store, later_hidden, hidden_capability)

    assert %{
             "outcome" => "ok",
             "events" => %{"items" => [], "next_after" => 7, "has_more" => false}
           } = request(socket_path, %{request_base | "after_revision" => 6})

    assert {:ok, 8} = Store.revoke_principal(store, "operator:1")

    assert %{"outcome" => "error", "reason" => "unauthorized"} =
             request(socket_path, %{request_base | "after_revision" => 7})

    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

  defp provision!(store) do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["light:desk"])

    credential
  end

  defp assert_review_slots(review_gate, count, attempts) when attempts > 0 do
    if map_size(:sys.get_state(review_gate).holders) == count do
      :ok
    else
      Process.sleep(1)
      assert_review_slots(review_gate, count, attempts - 1)
    end
  end

  defp assert_review_slots(review_gate, count, 0),
    do: assert(map_size(:sys.get_state(review_gate).holders) == count)

  defp request(path, map), do: raw_request(path, JSON.encode!(map))

  defp raw_request(path, body),
    do: raw_frame(path, <<byte_size(body)::unsigned-big-32, body::binary>>)

  defp raw_frame(path, frame) do
    assert {:ok, socket} =
             :gen_tcp.connect(
               {:local, String.to_charlist(path)},
               0,
               [:binary, {:active, false}],
               1_000
             )

    assert :ok = :gen_tcp.send(socket, frame)
    assert {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(socket, 4, 5_000)
    assert {:ok, body} = :gen_tcp.recv(socket, size, 5_000)
    :ok = :gen_tcp.close(socket)
    JSON.decode!(body)
  end
end
