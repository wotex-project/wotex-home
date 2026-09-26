defmodule WotexHome.LocalAPITest do
  use ExUnit.Case
  import Bitwise

  alias WotexHome.Durable.Store
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

  test "draft review has two checker slots and recovers a crashed caller", %{
    store_path: store_path,
    socket_path: socket_path
  } do
    assert {:ok, store} = Store.start_link(path: store_path)
    _control_credential = provision!(store)

    assert {:ok, review_credential, 3} =
             Store.provision_principal(store, "reviewer:1", ["rule:review"], ["light:desk"])

    assert {:ok, server} = Server.start_link(store: store, socket_path: socket_path)
    parent = self()

    holders =
      for _ <- 1..2 do
        spawn(fn ->
          send(parent, {:review_slot, GenServer.call(server, :acquire_review)})

          receive do
            :stop -> :ok
          end
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
    assert_review_slots(server, 1, 100)

    assert %{"outcome" => "ok", "review" => %{"decision" => "pending_positive_basis"}} =
             request(socket_path, review_request)

    Enum.each(holders, &send(&1, :stop))
    :ok = GenServer.stop(server)
    :ok = GenServer.stop(store)
  end

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

  test "client rejects invalid paths and malformed response frames" do
    assert {:error, :invalid_socket_path} = Client.request("relative.sock", %{})
    assert {:error, :invalid_client_request} = Client.request("/tmp/home.sock", %{}, 0)

    assert {:error, :invalid_response} =
             Frame.decode_response(~s({"api_version":1,"outcome":"ok","outcome":"error"}))

    assert {:error, :invalid_response} =
             Frame.decode_response(~s({"api_version":2,"outcome":"ok"}))

    assert {:error, :response_too_large} =
             Frame.decode_response(:binary.copy("x", 1_048_577))
  end

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

  defp assert_review_slots(server, count, attempts) when attempts > 0 do
    if map_size(:sys.get_state(server).reviewers) == count do
      :ok
    else
      Process.sleep(1)
      assert_review_slots(server, count, attempts - 1)
    end
  end

  defp assert_review_slots(server, count, 0),
    do: assert(map_size(:sys.get_state(server).reviewers) == count)

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
