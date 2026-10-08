defmodule WotexHome.DurableColorGuardTest do
  @moduledoc false

  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.{Receipt, Store}
  alias WotexHome.Mutation
  alias WotexHome.Semantics.{Observation, Thing}

  @base %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "unit" => "ppm",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:lightstate:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  test "held colour guard requires one fresh coherent Store baseline" do
    directory =
      Path.join(System.tmp_dir!(), "wotex-color-guard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))
    thing = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["light:desk"])

    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:colour:1",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => "light:desk",
               "capability_key" => "brightness",
               "value" => %{"type" => "fraction", "ppm" => 600_000}
             })

    assert {:ok, %Receipt{disposition: :held}} =
             Store.submit_request(store, credential, mutation)

    assert {:error, :unauthorized} =
             Store.inspect_held_color(
               store,
               :binary.copy(<<2>>, 32),
               1,
               "op:colour:1",
               "boot:1",
               101
             )

    assert {:error, :observation_unavailable} =
             Store.inspect_held_color(store, credential, 1, "op:colour:1", "boot:1", 101)

    reports = [
      report(thing, "brightness", %{"type" => "fraction", "ppm" => 400_000}, 1, 100),
      report(
        thing,
        "colour_hsv",
        %{"type" => "hsv", "hue_mdeg" => 180_000, "saturation_ppm" => 500_000},
        1,
        100
      ),
      report(thing, "colour_temperature", %{"type" => "kelvin", "kelvin" => 3_500}, 1, 100)
    ]

    assert {:ok, [_a, _b, _c]} = Store.record_batch(store, thing, reports)

    assert {:ok, plan, metadata} =
             Store.inspect_held_color(store, credential, 1, "op:colour:1", "boot:1", 101)

    assert plan.requested == "brightness"

    assert plan.raw_hsbk == %{
             hue: 32_768,
             saturation: 32_768,
             brightness: 39_321,
             kelvin: 3_500
           }

    assert metadata.resource_revision == 0
    assert map_size(metadata.observation_revisions) == 3

    assert {:error, :effect_required} =
             Store.settle_held_color_noop(store, credential, 1, "op:colour:1", "boot:1", 101)

    assert {:ok, matching_mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:colour:match",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => "light:desk",
               "capability_key" => "brightness",
               "value" => %{"type" => "fraction", "ppm" => 400_000}
             })

    assert {:ok, %Receipt{disposition: :held}} =
             Store.submit_request(store, credential, matching_mutation)

    assert {:error, :unauthorized} =
             Store.settle_held_color_noop(
               store,
               :binary.copy(<<2>>, 32),
               1,
               "op:colour:match",
               "boot:1",
               101
             )

    assert {:error, :color_plan_unavailable} =
             Store.settle_held_color_noop(
               store,
               credential,
               1,
               "op:colour:match",
               "boot:2",
               101
             )

    assert {:ok, %Receipt{disposition: :rejected, reason: "already_reported_no_send"} = settled} =
             Store.settle_held_color_noop(
               store,
               credential,
               1,
               "op:colour:match",
               "boot:1",
               101
             )

    assert {:ok, ^settled} =
             Store.settle_held_color_noop(
               store,
               credential,
               1,
               "op:colour:match",
               "boot:1",
               10_000
             )

    assert {:ok, ^settled} = Store.submit_request(store, credential, matching_mutation)

    assert {:error, :color_plan_unavailable} =
             Store.inspect_held_color(store, credential, 1, "op:colour:1", "boot:2", 101)

    assert {:error, :color_plan_unavailable} =
             Store.inspect_held_color(store, credential, 1, "op:colour:1", "boot:1", 5_101)

    assert {:ok, newer} =
             Observation.new(
               %{
                 "thing_id" => "light:desk",
                 "capability_key" => "brightness",
                 "value" => %{"type" => "fraction", "ppm" => 450_000},
                 "quality" => "reported",
                 "trust" => "unauthenticated_local",
                 "source_epoch" => "device:1",
                 "source_sequence" => 2,
                 "boot_epoch" => "boot:1",
                 "source_time_utc_ms" => nil,
                 "received_time_utc_ms" => 1_000_102,
                 "received_monotonic_ms" => 102
               },
               thing.capabilities["brightness"]
             )

    assert {:ok, _revision} = Store.record(store, newer, thing.capabilities["brightness"])

    assert {:error, :color_plan_unavailable} =
             Store.inspect_held_color(store, credential, 1, "op:colour:1", "boot:1", 103)

    assert {:ok, %Receipt{disposition: :rejected}} =
             Store.cancel_request(store, credential, 1, "op:colour:1")

    assert {:error, :request_not_held} =
             Store.inspect_held_color(store, credential, 1, "op:colour:1", "boot:1", 103)

    :ok = GenServer.stop(store)
  end

  for failure <- [:enrollment, :observation, :sql_read] do
    @tag inspection_failure: true
    test "colour no-send inspection fails closed on #{failure} without closing or spending held work" do
      directory =
        Path.join(System.tmp_dir!(), "wotex-color-fault-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)
      path = Path.join(directory, "home.sqlite")
      assert {:ok, store} = Store.start_link(path: path)
      thing = thing()
      assert {:ok, _} = Store.enroll_thing(store, thing)

      assert {:ok, credential, _} =
               Store.provision_principal(store, "operator:1", ["control:ordinary"], [thing.id])

      reports = [
        report(thing, "brightness", %{"type" => "fraction", "ppm" => 400_000}, 1, 100),
        report(
          thing,
          "colour_hsv",
          %{"type" => "hsv", "hue_mdeg" => 180_000, "saturation_ppm" => 500_000},
          1,
          100
        ),
        report(thing, "colour_temperature", %{"type" => "kelvin", "kelvin" => 3_500}, 1, 100)
      ]

      assert {:ok, _} = Store.record_batch(store, thing, reports)

      assert {:ok, mutation} =
               Mutation.new(%{
                 "api_version" => 1,
                 "operation_id" => "op:colour:fault",
                 "authority_epoch" => 1,
                 "expected_revision" => 0,
                 "target_id" => thing.id,
                 "capability_key" => "brightness",
                 "value" => %{"type" => "fraction", "ppm" => 400_000}
               })

      assert {:ok, original} = Store.submit_request(store, credential, mutation)
      assert {:ok, before} = Store.revision(store)
      {:ok, db} = Sqlite3.open(path)
      {:ok, declaration} = WotexHome.Durable.Registry.encode_thing(thing)

      statement =
        unquote(
          case failure do
            :enrollment ->
              "UPDATE enrolled_things SET document='{}'"

            :observation ->
              "UPDATE observation_current SET value_kind='invalid' WHERE capability_key='brightness'"

            :sql_read ->
              "ALTER TABLE observation_current RENAME TO inspection_fault"
          end
        )

      assert :ok = Sqlite3.execute(db, statement)

      result =
        Store.settle_held_color_noop(store, credential, 1, mutation.operation_id, "boot:1", 101)

      case unquote(failure) do
        :enrollment ->
          {:ok, statement} = Sqlite3.prepare(db, "UPDATE enrolled_things SET document=?")
          assert :ok = Sqlite3.bind(statement, [declaration])
          assert {:ok, []} = Sqlite3.fetch_all(db, statement)
          assert :ok = Sqlite3.release(db, statement)

        :observation ->
          assert :ok =
                   Sqlite3.execute(
                     db,
                     "UPDATE observation_current SET value_kind='fraction' WHERE capability_key='brightness'"
                   )

        :sql_read ->
          assert :ok =
                   Sqlite3.execute(
                     db,
                     "ALTER TABLE inspection_fault RENAME TO observation_current"
                   )
      end

      expected =
        unquote(
          case failure do
            :enrollment -> :corrupt_enrollment
            :observation -> :corrupt_value
            :sql_read -> :store_unavailable
          end
        )

      assert {:error, ^expected} = result
      assert {:ok, %{writable: false, dispatch_enabled: false}} = Store.health(store)
      assert {:ok, ^before} = Store.revision(store)
      assert {:ok, ^original} = Store.request_status(store, credential, 1, mutation.operation_id)

      assert {:ok, [[0, 0, 1]]} =
               WotexHome.Durable.Store.SQL.query(
                 db,
                 "SELECT reserved_effects,(SELECT COUNT(*) FROM request_execution),(SELECT COUNT(*) FROM request_journal) FROM request_causal_roots"
               )

      assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(db)
      assert :ok = Sqlite3.close(db)
      assert {:error, :store_unavailable} = Store.submit_request(store, credential, mutation)
      :ok = GenServer.stop(store)
      assert {:ok, reopened} = Store.start_link(path: path)

      assert {:ok, ^original} =
               Store.request_status(reopened, credential, 1, mutation.operation_id)

      assert {:ok, ^before} = Store.revision(reopened)
      :ok = GenServer.stop(reopened)
    end
  end

  defp thing do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [
                 Map.merge(@base, %{
                   "key" => "power",
                   "value_kind" => "boolean",
                   "unit" => "none"
                 }),
                 Map.merge(@base, %{"key" => "brightness", "value_kind" => "fraction"}),
                 Map.merge(@base, %{
                   "key" => "colour_hsv",
                   "value_kind" => "hsv",
                   "unit" => "mdeg+ppm"
                 }),
                 Map.merge(@base, %{
                   "key" => "colour_temperature",
                   "value_kind" => "kelvin",
                   "unit" => "K",
                   "constraints" => %{"min" => 2_500, "max" => 9_000}
                 })
               ]
             })

    thing
  end

  defp report(thing, key, value, sequence, received_ms) do
    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => "light:desk",
          "capability_key" => key,
          "value" => value,
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "device:1",
          "source_sequence" => sequence,
          "boot_epoch" => "boot:1",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_000_000 + received_ms,
          "received_monotonic_ms" => received_ms
        },
        thing.capabilities[key]
      )

    report
  end
end
