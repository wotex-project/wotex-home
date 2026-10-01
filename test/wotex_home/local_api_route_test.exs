defmodule WotexHome.LocalAPI.RouteTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Authority
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Frame, Server}
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
    "evidence_ref" => "fixture:route:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @mutation %{
    "api_version" => 1,
    "operation_id" => "op:route:1",
    "authority_epoch" => 1,
    "expected_revision" => 0,
    "target_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => true}
  }

  @rule %{
    "version" => 1,
    "id" => "rule:route:1",
    "source_revision" => 3,
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
      Path.join(System.tmp_dir!(), "wotex-home-route-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))
    assert {:ok, gate} = ReviewGate.start_link()

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, controller, 2} =
             Store.provision_principal(
               store,
               "operator:1",
               ["control:ordinary"],
               ["light:desk"]
             )

    assert {:ok, reviewer, 3} =
             Store.provision_principal(store, "reviewer:1", ["rule:review"], ["light:desk"])

    authority = Authority.new(store: store, capture: nil, review_gate: gate)

    on_exit(fn ->
      if Process.alive?(gate), do: GenServer.stop(gate)
      if Process.alive?(store), do: GenServer.stop(store)
    end)

    {:ok, authority: authority, controller: controller, reviewer: reviewer, thing: thing}
  end

  test "framed health, submit, status and cancel use the exact Authority route", context do
    controller = Base.url_encode64(context.controller, padding: false)

    assert %{"outcome" => "ok", "health" => %{"store_revision" => 3}} =
             framed(context.authority, %{
               "api_version" => 1,
               "operation" => "health",
               "credential" => controller
             })

    assert %{"outcome" => "ok", "receipt" => %{"disposition" => "held", "revision" => 4}} =
             framed(context.authority, %{
               "api_version" => 1,
               "operation" => "submit",
               "credential" => controller,
               "mutation" => @mutation
             })

    lookup = %{
      "api_version" => 1,
      "operation" => "status",
      "credential" => controller,
      "authority_epoch" => 1,
      "operation_id" => "op:route:1"
    }

    assert %{"receipt" => %{"disposition" => "held", "revision" => 4}} =
             framed(context.authority, lookup)

    assert %{"receipt" => %{"disposition" => "rejected", "reason" => "cancelled"}} =
             framed(context.authority, %{lookup | "operation" => "cancel"})
  end

  test "framed rule review uses the bounded application review gate", context do
    assert %{
             "outcome" => "ok",
             "review" => %{"decision" => "pending_positive_basis", "watermark" => 3}
           } =
             framed(context.authority, %{
               "api_version" => 1,
               "operation" => "review_rules",
               "credential" => Base.url_encode64(context.reviewer, padding: false),
               "rules" => [@rule]
             })
  end

  test "framed read projections match direct Authority scope, cursors and revision fences",
       context do
    store = context.authority.store
    credential = Base.url_encode64(context.controller, padding: false)

    assert {:ok, hidden} =
             Thing.new(%{
               "id" => "light:hidden",
               "role" => "Light",
               "profile_ref" => @power["profile_ref"],
               "capabilities" => [%{@power | "thing_id" => "light:hidden"}]
             })

    assert {:ok, 4} = Store.enroll_thing(store, hidden)
    visible = context.thing
    # Reports enter through the Store API, not through a read projection.
    desk = report(visible.capabilities["power"], false, 1)
    assert {:ok, 5} = Store.record(store, desk, visible.capabilities["power"])

    assert {:ok, 6} =
             Store.record(
               store,
               report(hidden.capabilities["power"], true, 1),
               hidden.capabilities["power"]
             )

    base = %{"api_version" => 1, "credential" => credential}
    pages = %{"watermark" => nil, "after" => nil, "page_size" => 10}

    for {operation, call} <- [
          {"snapshot",
           fn -> Authority.snapshot(context.authority, context.controller, nil, nil, 10) end},
          {"catalogue",
           fn -> Authority.catalogue(context.authority, context.controller, nil, nil, 10) end}
        ] do
      assert {:ok, direct} = call.()

      response =
        framed(context.authority, Map.merge(base, Map.put(pages, "operation", operation)))

      assert response[operation] == JSON.decode!(JSON.encode!(direct))
      assert length(response[operation]["items"]) == 1
    end

    history =
      Map.merge(base, %{
        "operation" => "history",
        "thing_id" => "light:desk",
        "capability_key" => "power",
        "watermark" => nil,
        "after_revision" => 0,
        "page_size" => 100
      })

    assert {:ok, direct_history} =
             Authority.history(
               context.authority,
               context.controller,
               "light:desk",
               "power",
               nil,
               0,
               100
             )

    assert framed(context.authority, history)["history"] ==
             JSON.decode!(JSON.encode!(direct_history))

    assert %{"reason" => "permission_denied"} =
             framed(context.authority, %{history | "thing_id" => "light:hidden"})

    events =
      Map.merge(base, %{"operation" => "events", "after_revision" => 0, "page_size" => 100})

    assert {:ok, direct_events} = Authority.events(context.authority, context.controller, 0, 100)

    assert %{"events" => %{"items" => [%{"revision" => 5}], "next_after" => 6}} =
             framed(context.authority, events)

    assert framed(context.authority, events)["events"] ==
             JSON.decode!(JSON.encode!(direct_events))

    assert {:ok, 7} =
             Store.record(store, %{desk | source_sequence: 2}, visible.capabilities["power"])

    for operation <- ["snapshot", "catalogue"] do
      request = Map.merge(base, Map.merge(pages, %{"operation" => operation, "watermark" => 6}))
      assert %{"reason" => "resnapshot_required"} = framed(context.authority, request)
    end

    assert %{"reason" => "resnapshot_required"} =
             framed(context.authority, %{history | "watermark" => 6})

    assert %{"events" => %{"items" => [%{"revision" => 7}], "next_after" => 7}} =
             framed(context.authority, %{events | "after_revision" => 6})

    assert {:ok, 8} = Store.revoke_principal(store, "operator:1")
    assert %{"reason" => "unauthorized"} = framed(context.authority, events)
  end

  test "framed request events skip another principal's same operation ID", context do
    assert {:ok, %{revision: 4}} =
             Authority.submit(context.authority, context.controller, @mutation)

    assert {:ok, %{revision: 5, disposition: :rejected}} =
             Authority.submit(context.authority, context.reviewer, @mutation)

    events = %{
      "api_version" => 1,
      "operation" => "request_events",
      "credential" => Base.url_encode64(context.controller, padding: false),
      "after_revision" => 0,
      "page_size" => 100
    }

    assert %{
             "request_events" => %{
               "items" => [%{"disposition" => "held", "revision" => 4}],
               "next_after" => 5
             }
           } = framed(context.authority, events)

    assert {:ok, %{revision: 6}} =
             Authority.cancel(context.authority, context.controller, 1, @mutation["operation_id"])

    assert %{
             "request_events" => %{
               "items" => [
                 %{"disposition" => "rejected", "reason" => "cancelled", "revision" => 6}
               ],
               "next_after" => 6
             }
           } =
             framed(context.authority, %{events | "after_revision" => 5})
  end

  test "the frame seam rejects duplicate JSON, truncation and oversized bodies", context do
    duplicate =
      ~s({"api_version":1,"operation":"health","operation":"submit"})

    assert %{"outcome" => "error", "reason" => "duplicate_member"} =
             raw_framed(
               context.authority,
               <<byte_size(duplicate)::unsigned-big-32, duplicate::binary>>
             )

    assert %{"outcome" => "error", "reason" => "invalid_request"} =
             raw_framed(context.authority, <<10::unsigned-big-32, "short">>)

    oversized = :binary.copy("x", 65_537)

    assert %{"outcome" => "error", "reason" => "request_too_large"} =
             raw_framed(
               context.authority,
               <<byte_size(oversized)::unsigned-big-32, oversized::binary>>
             )
  end

  defp report(capability, value, sequence) do
    assert {:ok, observation} =
             Observation.new(
               %{
                 "thing_id" => capability.thing_id,
                 "capability_key" => capability.key,
                 "value" => %{"type" => "boolean", "value" => value},
                 "quality" => "reported",
                 "trust" => "unauthenticated_local",
                 "source_epoch" => "device:route",
                 "source_sequence" => sequence,
                 "boot_epoch" => "boot:route",
                 "source_time_utc_ms" => nil,
                 "received_time_utc_ms" => 1_000,
                 "received_monotonic_ms" => 100
               },
               capability
             )

    observation
  end

  defp framed(authority, request) do
    assert {:ok, frame} = Frame.encode_request(request)
    raw_framed(authority, frame)
  end

  defp raw_framed(authority, frame) do
    assert {:ok, <<size::unsigned-big-32, body::binary-size(size)>>} =
             Server.route_frame(authority, frame)

    assert {:ok, response} = Frame.decode_response(body)
    response
  end
end
