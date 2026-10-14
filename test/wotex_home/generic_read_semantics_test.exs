defmodule WotexHome.GenericReadSemanticsTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Durable.{Registry, Store}
  alias WotexHome.Profiles.ReadDeclarationCodec
  alias WotexHome.Semantics.{Capability, Observation, ReadCapability, Thing, Value}

  defp vectors, do: JSON.decode!(File.read!("test/fixtures/profiles/generic-read-semantics.json"))

  defp rewritten(record, fun) do
    data = JSON.decode!(record["declaration_document"]) |> fun.()
    bytes = JSON.encode!(data)
    Map.merge(record, %{"declaration_document" => bytes, "declaration_sha256" => sha(bytes)})
  end

  defp sha(bytes),
    do:
      Base.encode16(:crypto.hash(:sha256, "wotex-home.external-read-declaration@1\n" <> bytes),
        case: :lower
      )

  for family <- ~w(temperature research multi) do
    @family family
    test "#{@family} exact retained Thing round-trips without an optional producer" do
      v = vectors()[@family]
      assert {:ok, thing} = Thing.new(v["thing"])
      assert {:ok, document} = Registry.encode_thing(thing)
      assert document == v["thing_document"]
      assert {:ok, ^thing} = Registry.decode_thing(document)

      for {_key, cap} <- thing.capabilities do
        assert %ReadCapability{} = cap
        assert ReadCapability.supports?(cap, "read")
        refute ReadCapability.supports?(cap, "write")
        refute ReadCapability.supports?(%{cap | operations: ["read", "write"]}, "read")
      end
    end
  end

  test "retained metadata rejects forged formats, hashes, duplicate JSON and resource excess" do
    record = vectors()["temperature"]["record"]

    for bad <- [
          Map.put(record, "extra", true),
          Map.put(record, "artifact_digest", String.duplicate("x", 64)),
          Map.put(record, "declaration_sha256", String.duplicate("0", 64)),
          Map.put(record, "declaration_document", record["declaration_document"] <> "\n")
        ] do
      assert {:error, :invalid_read_declaration_record} = ReadDeclarationCodec.decode(bad)
    end

    for fun <- [
          &Map.put(&1, "extra", true),
          &Map.put(&1, "operations", ["read", "write"]),
          &Map.put(&1, "risk_class", "trusted"),
          &Map.put(&1, "freshness_ms", 0),
          &Map.put(&1, "thing_id", "bad/id"),
          &Map.put(&1, "format", "wotex-home.external-read-declaration@2"),
          &Map.put(&1, "constraints", %{"min" => 1, "max" => 0}),
          &Map.put(&1, "unit", nil),
          &put_in(&1, ["semantic_ref", "version"], "01.0.0")
        ] do
      assert {:error, :invalid_read_declaration_record} =
               ReadDeclarationCodec.decode(rewritten(record, fun))
    end

    duplicate = ~s({"thing_id":"one","thing_id":"two"})

    assert {:error, :invalid_read_declaration_record} =
             ReadDeclarationCodec.decode(
               Map.merge(record, %{
                 "declaration_document" => duplicate,
                 "declaration_sha256" => sha(duplicate)
               })
             )

    assert {:error, :external_profile_limit} =
             ReadDeclarationCodec.decode(
               Map.put(record, "declaration_document", String.duplicate("x", 65537))
             )

    assert {:error, :external_profile_limit} =
             ReadDeclarationCodec.decode(
               rewritten(
                 record,
                 &put_in(&1, ["value_schema", "description"], String.duplicate("x", 4097))
               )
             )

    assert {:error, :external_profile_limit} =
             ReadDeclarationCodec.decode(
               rewritten(record, &put_in(&1, ["value_schema", "enum"], Enum.to_list(1..257)))
             )

    deep = Enum.reduce(1..8, true, fn _, acc -> [acc] end)

    assert {:error, :external_profile_limit} =
             ReadDeclarationCodec.decode(
               rewritten(record, &put_in(&1, ["value_schema", "extra"], deep))
             )
  end

  test "generic Thing identity, map keys, native fields and bounded channel sets are closed" do
    v = vectors()["temperature"]
    [record] = v["thing"]["capabilities"]

    for input <- [
          Map.put(v["thing"], "id", "sensor:other"),
          Map.put(v["thing"], "profile_ref", "external:" <> String.duplicate("0", 64)),
          Map.put(v["thing"], "capabilities", []),
          Map.put(v["thing"], "capabilities", [record, record]),
          Map.put(v["thing"], "capabilities", List.duplicate(record, 33)),
          Map.put(v["thing"], "role", "Light")
        ] do
      assert {:error, _} = Thing.new(input)
    end

    assert {:ok, thing} = Thing.new(v["thing"])
    {key, cap} = Enum.at(thing.capabilities, 0)

    for forged <- [
          %{thing | capabilities: %{"forged" => cap}},
          %{
            thing
            | capabilities: %{
                key => %{cap | risk_class: "ordinary", freshness_ms: cap.freshness_ms + 1}
              }
          },
          %{thing | capabilities: %{key => Map.put(cap, :extra, true)}}
        ] do
      assert {:error, :invalid_thing} = Registry.encode_thing(forged)
    end

    refute ReadCapability.supports?(Map.put(cap, :extra, true), "read")
  end

  test "legacy semantic value and observation constructors cannot accept generic read metadata" do
    record = vectors()["temperature"]["record"]
    assert {:ok, cap} = ReadCapability.new(record)
    assert {:error, _} = Capability.new(record)
    assert {:error, :invalid_value} = Value.new(%{"type" => "integer", "value" => 24000})
    assert {:error, :invalid_observation} = Observation.new(%{}, cap)
    assert {:ok, thing} = Thing.new(vectors()["temperature"]["thing"])

    assert {:error, :invalid_observation_batch} =
             WotexHome.Durable.Store.ObservationWriter.valid_batch(thing, [
               %Observation{
                 thing_id: thing.id,
                 capability_key: cap.key,
                 value: nil,
                 quality: "unknown",
                 trust: "synthetic_lab",
                 source_epoch: "source:1",
                 source_sequence: 1,
                 boot_epoch: "boot:1",
                 source_time_utc_ms: nil,
                 received_time_utc_ms: 1,
                 received_monotonic_ms: 1
               }
             ])
  end

  test "the shared Thing ceiling bounds a valid maximum-channel metadata set" do
    v = vectors()["temperature"]

    records =
      for n <- 1..32 do
        key =
          "channel:" <>
            String.pad_leading(Integer.to_string(n), 3, "0") <> String.duplicate("x", 100)

        # Canonical historical metadata isolates the total Thing byte limit;
        # it makes no additional producer/source acceptance claim.
        rewritten(v["record"], fn data ->
          data
          |> Map.put("capability_key", key)
          |> put_in(["value_schema", "description"], String.duplicate("x", 2000))
        end)
      end

    assert {:ok, thing} = Thing.new(%{v["thing"] | "capabilities" => records})
    assert {:error, :thing_too_large} = Registry.encode_thing(thing)
  end

  test "actual Store fixture enrollment and restart preserve generic declaration metadata" do
    root =
      Path.join(System.tmp_dir!(), "generic-enrollment-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!({Store, path: path})
    assert {:ok, thing} = Thing.new(vectors()["multi"]["thing"])
    assert {:ok, 1} = Store.enroll_thing(store, thing)
    stop_supervised(Store)
    store = start_supervised!({Store, path: path})
    assert {:ok, 1} = Store.revision(store)
    assert :ok = WotexHome.Durable.Store.Integrity.validate_snapshot(:sys.get_state(store).db)

    assert {:ok, rows} =
             WotexHome.Durable.Store.SQL.query(
               :sys.get_state(store).db,
               "SELECT document FROM enrolled_things"
             )

    assert [[document]] = rows
    assert document == vectors()["multi"]["thing_document"]
    assert {:ok, ^thing} = Registry.decode_thing(document)
    db = :sys.get_state(store).db

    assert {:error, :profile_selection_unavailable} =
             WotexHome.Durable.Store.ProfileGuard.current(db, thing, 0)

    assert {:error, :unsupported_fact} =
             WotexHome.Durable.Store.FactReadModel.project(
               db,
               [{thing.id, "sample"}],
               "store:1",
               1
             )

    {:ok, reader, revision} =
      Store.provision_principal(store, "reader:generic", ["read"], [thing.id])

    assert {:ok, view} =
             WotexHome.Authority.current_thing(
               WotexHome.Authority.new(store: store),
               reader,
               thing.id
             )

    assert Enum.all?(
             view.capabilities,
             &(&1.freshness == "profile_unavailable" and &1.current_value == nil and
                 &1.remaining_ms == 0 and &1.profile_status == "profile_selection_unavailable")
           )

    assert {:ok, ^revision} = Store.revision(store)
    {:ok, cap} = Thing.capability(thing, "sample")
    assert {:error, :invalid_observation} = Store.record(store, nil, cap)
    assert {:ok, ^revision} = Store.revision(store)

    {:ok, controller, revision} =
      Store.provision_principal(store, "controller:generic", ["read", "control:ordinary"], [
        thing.id
      ])

    {:ok, mutation} =
      WotexHome.Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "generic:write",
        "expected_revision" => 0,
        "target_id" => thing.id,
        "capability_key" => "sample",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:error, :profile_selection_unavailable} =
             Store.submit_request(store, controller, mutation)

    assert {:ok, ^revision} = Store.revision(store)
  end
end
