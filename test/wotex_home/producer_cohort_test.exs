defmodule WotexHome.ProducerCohortTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias Wotex.Profiles.{Artifacts, Contract, Draft, Validation}

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/" <> name <> ".json"))

  test "ordinary locked producer sources match every declared pin" do
    for {app, ref} <- WotexHome.MixProject.source_pins() do
      assert {revision, 0} =
               System.cmd("git", ["-C", "deps/" <> Atom.to_string(app), "rev-parse", "HEAD"])

      assert String.trim(revision) == ref

      assert Code.ensure_loaded?(
               case app do
                 :wotex -> Wotex.JSON
                 :wotex_runtime -> Wotex.Runtime
                 :wotex_profiles -> Wotex.Profiles.Contract
                 :wotex_binding_mqtt -> Wotex.Binding.MQTT.JSONProjection
                 :wotex_continuum -> WotexContinuum
                 :wotex_routines -> Wotex.Routines.Civil
                 :ex_booking -> ExBooking.RRule
                 :wotex_udp -> Wotex.UDP
                 :cowlib -> :cow_http_struct_hd
               end
             )
    end
  end

  test "locked MQTT producer preserves exact values and retained metadata under the Home OTP lane" do
    alias Wotex.Binding.MQTT.{Delivery, JSONProjection}
    alias Wotex.Runtime.Codec.JSON, as: ExactJSON

    {:ok, delivery} =
      Delivery.new(~s({"a":9007199254740993.1,"b":18446744073709551615}),
        topic: "samples/value",
        qos: 2,
        retain: true
      )

    for {path, expected} <- [
          {["a"], %{"type" => "decimal", "coefficient" => "90071992547409931", "exponent" => -1}},
          {["b"], %{"type" => "uint", "value" => "18446744073709551615"}}
        ] do
      selector = %{"topic" => "samples/value", "path" => path}
      assert :ok = JSONProjection.validate_selector(selector)

      assert {:ok, ^expected, %{topic: "samples/value", qos: 2, retained: true}} =
               JSONProjection.project(delivery, selector)
    end

    assert {:error, :unsupported_value} = ExactJSON.decode("1e32768")
    token = "1e" <> String.duplicate("0", 126)
    assert {:ok, %{"coefficient" => "1", "exponent" => 0}} = ExactJSON.decode(token)
    assert {:error, :output_limit} = ExactJSON.decode(token <> "0")
    {:ok, invalid} = Delivery.new("private-canary invalid JSON", topic: "other/value")
    assert :ignore = JSONProjection.project(invalid, %{"topic" => "samples/value", "path" => []})

    assert {:error, %Wotex.Binding.MQTT.Error{code: :json_invalid_input, details: %{}} = error} =
             JSONProjection.project(invalid, %{"topic" => "other/value", "path" => []})

    refute inspect(error) =~ "private-canary"
  end

  test "firmware and root lockfiles retain the same exact owned cohort" do
    root = Mix.Dep.Lock.read("mix.lock")
    firmware = Mix.Dep.Lock.read("native/nerves/mix.lock")

    for app <- [
          :wotex,
          :wotex_runtime,
          :wotex_profiles,
          :wotex_binding_mqtt,
          :wotex_continuum,
          :wotex_routines,
          :ex_booking,
          :wotex_udp
        ] do
      ref = WotexHome.MixProject.source_pins()[app]
      assert {:git, _, ^ref, _} = root[app]
      assert root[app] == firmware[app]
    end

    for app <- [:emqtt, :cowlib, :gun, :getopt, :quicer, :snabbkaffe],
        do: assert(root[app] == firmware[app])

    assert {:hex, :emqtt, "1.16.1", _, _, _, _, _} = root[:emqtt]
    deps = WotexHome.MixProject.project()[:deps]
    assert {:emqtt, "== 1.16.1", emqtt_options} = List.keyfind(deps, :emqtt, 0)
    assert emqtt_options[:system_env] == [{"BUILD_WITHOUT_QUIC", "1"}]
    assert {:quicer, "== 0.2.15", quic_options} = List.keyfind(deps, :quicer, 0)
    assert quic_options == [compile: false, app: false, runtime: false, override: true]
  end

  test "ordinary public profile producers match two independent contract and bundle byte vectors" do
    for family <- ~w(temperature research) do
      v = fixture(family)
      expected = fixture("authoring-mechanics")[family]

      {:ok, contract} =
        Contract.export(v["bindings"], v["contracts"], expected["limits"], Artifacts.current())

      assert {:ok, identity} = Contract.identity(contract)
      assert identity == expected["contract_sha256"]
      assert {:ok, encoded} = Contract.encode(contract)

      assert :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower) ==
               expected["contract_raw_sha256"]

      assert {:ok, finalized} = Draft.finalize(expected["draft_bytes"], contract)
      assert finalized.bundle_sha256 == expected["bundle_sha256"]
      assert {:ok, report} = Validation.check(finalized.bundle_bytes, contract, nil)
      assert {:ok, result} = Wotex.Profiles.ValidationReport.to_map(report, contract)
      assert result["disposition"] == "compatible" and result["capture_status"] == "not_supplied"
      assert {:ok, invalid} = Draft.finalize("{", contract)
      assert invalid.__struct__ == Wotex.Profiles.ValidationReport
    end
  end

  test "original occurrences are available with explicit UTC basis and no installed clock" do
    assert {:ok, page} =
             ExBooking.RRule.occurrences("FREQ=DAILY;COUNT=1", ~U[2026-07-13 06:00:00Z],
               from: ~U[2026-07-13 05:55:00Z],
               until: ~U[2026-07-13 07:00:00Z],
               time_zone_database: Calendar.UTCOnlyTimeZoneDatabase,
               time_zone_basis: "utc-v1"
             )

    assert [occurrence] = page.occurrences
    assert occurrence.starts_at == ~U[2026-07-13 06:00:00Z]

    assert {:error, _} =
             ExBooking.RRule.occurrences("FREQ=DAILY;COUNT=1", ~U[2026-07-13 06:00:00Z],
               from: ~U[2026-07-13 05:55:00Z],
               until: ~U[2026-07-13 07:00:00Z],
               time_zone_database: nil,
               time_zone_basis: "utc-v1"
             )

    assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase
    assert Application.get_env(:wotex_home, :lifx_power_dispatch_enabled, false) == false
    assert Application.get_env(:wotex_home, :schedule_delivery_enabled, false) == false
  end

  test "public reader and value APIs preserve independent report values and provenance" do
    for family <- ~w(temperature research) do
      v = fixture(family)
      limits = v["reader_limits"]
      {:ok, bytes} = Wotex.JSON.encode(v["profile"])
      assert {:ok, profile} = Wotex.Profiles.Profile.parse(bytes, limits)

      definitions =
        for definition <- v["definitions"] do
          {:ok, bytes} = Wotex.JSON.encode(definition)
          {:ok, parsed} = Wotex.Profiles.Definition.parse(bytes, limits)
          parsed
        end

      closure = Map.put(Map.take(v, ~w(bindings contracts)), "definitions", definitions)

      assert {:ok, projection} =
               Wotex.Profiles.Compiler.compile(profile, closure, v["capture"], limits)

      for vector <- fixture("authoring-fixtures")[family]["fixtures"] do
        assert {:ok, proposal} =
                 Wotex.Profiles.Interpreter.project(projection, vector["report"], limits)

        assert {:ok, checked} = Wotex.Profiles.Proposal.to_map(proposal, limits)

        assert Map.take(checked, Map.keys(vector["expected"])) == vector["expected"]
      end

      report = hd(fixture("authoring-fixtures")[family]["fixtures"])["report"]

      assert {:error, _} =
               Wotex.Profiles.Interpreter.project(
                 projection,
                 Map.put(report, "capture_epoch", "changed"),
                 limits
               )
    end
  end

  test "fresh runtime artifact inventories cover the actual adopted producer applications" do
    applications = [:wotex, :wotex_runtime, :wotex_profiles, :ex_booking]
    assert {:ok, manifest} = WotexHome.RuntimeArtifacts.manifest(applications)
    assert length(manifest) == 4

    assert {:ok, digest} =
             WotexHome.RuntimeArtifacts.digest(applications, "producer-adoption-test")

    assert is_binary(digest) and byte_size(digest) == 64
    assert {:ok, ^manifest} = WotexHome.RuntimeArtifacts.manifest(applications)
  end
end
