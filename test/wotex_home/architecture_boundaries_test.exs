defmodule WotexHome.ArchitectureBoundariesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "the local socket is an Authority adapter, not a second application service" do
    source = File.read!(Path.join(@root, "lib/wotex_home/local_api/server.ex"))

    assert source =~ "alias WotexHome.Authority"
    refute source =~ "alias WotexHome.Durable.Store"
    refute source =~ "alias WotexHome.Lifx.CaptureSession"
    refute source =~ "alias WotexHome.Rules.CandidateReview"
    refute Regex.match?(~r/\bStore\./, source)
    refute Regex.match?(~r/\bCaptureSession\./, source)
    refute Regex.match?(~r/\bCandidateReview\./, source)
  end

  test "the trusted bootstrap command also enters through Authority" do
    source = File.read!(Path.join(@root, "lib/wotex_home/bootstrap.ex"))

    assert source =~ "alias WotexHome.Authority"
    refute source =~ "alias WotexHome.Durable.Store"
    refute Regex.match?(~r/\bStore\./, source)

    controller = File.read!(Path.join(@root, "bin/bootstrap_controller.exs"))
    assert controller =~ "WotexHome.Bootstrap"
    refute controller =~ "WotexHome.Durable.Store"
  end

  test "the LIFX read path receives reports or a commit capability instead of the Store" do
    source = File.read!(Path.join(@root, "lib/wotex_home/lifx/read_path.ex"))

    refute source =~ "alias WotexHome.Durable.Store"
    refute Regex.match?(~r/\bStore\./, source)
    assert source =~ "commit.(thing, reports)"
  end

  test "the LIFX capture owner has neither Store nor credential authority" do
    source = File.read!(Path.join(@root, "lib/wotex_home/lifx/capture_session.ex"))

    refute source =~ "alias WotexHome.Durable.Store"
    refute Regex.match?(~r/\bStore\./, source)
    refute source =~ "credential_hash"
    refute source =~ "{:credential"
    refute source =~ "commit.("
  end

  test "the LIFX power exchange receives narrow lifecycle capabilities instead of the Store" do
    source = File.read!(Path.join(@root, "lib/wotex_home/lifx/power_execution.ex"))

    refute source =~ "alias WotexHome.Durable.Store"
    refute Regex.match?(~r/\bStore\./, source)

    for capability <- ~w(claim handoff ack settle unknown) do
      assert source =~ "#{capability}:"
    end
  end

  test "Store collaborators cannot retain a database or become another writer" do
    for relative <- [
          "lib/wotex_home/durable/store/access.ex",
          "lib/wotex_home/durable/store/controller_writer.ex",
          "lib/wotex_home/durable/store/attempt_guard.ex",
          "lib/wotex_home/durable/store/causal_ledger.ex",
          "lib/wotex_home/durable/store/enrollment_writer.ex",
          "lib/wotex_home/durable/store/execution_writer.ex",
          "lib/wotex_home/durable/store/fact_read_model.ex",
          "lib/wotex_home/durable/store/sql.ex",
          "lib/wotex_home/durable/store/health_read_model.ex",
          "lib/wotex_home/durable/store/integrity.ex",
          "lib/wotex_home/durable/store/invariant_writer.ex",
          "lib/wotex_home/durable/store/rule_writer.ex",
          "lib/wotex_home/durable/store/journal.ex",
          "lib/wotex_home/durable/store/observation_codec.ex",
          "lib/wotex_home/durable/store/observation_writer.ex",
          "lib/wotex_home/durable/store/override_writer.ex",
          "lib/wotex_home/durable/store/principal_writer.ex",
          "lib/wotex_home/durable/store/qualification_writer.ex",
          "lib/wotex_home/durable/store/refresh_writer.ex",
          "lib/wotex_home/durable/store/request_invalidator.ex",
          "lib/wotex_home/durable/store/request_ledger.ex",
          "lib/wotex_home/durable/store/review_read_model.ex",
          "lib/wotex_home/durable/store/schema.ex",
          "lib/wotex_home/durable/store/state_read_model.ex"
        ] do
      source = File.read!(Path.join(@root, relative))

      refute source =~ "use GenServer"
      refute source =~ "Sqlite3.open"
      refute source =~ "Sqlite3.close"
      refute source =~ "Process."
      refute source =~ ":gen_tcp."
      refute source =~ ":gen_udp."
      refute source =~ ":socket."
      refute source =~ "WotexUdp.open"
      refute source =~ "Mint.HTTP.connect"
    end
  end

  test "wotex-home remains one Mix application with namespace boundaries" do
    mix_source = File.read!(Path.join(@root, "mix.exs"))

    assert mix_source =~ "app: :wotex_home"
    refute File.dir?(Path.join(@root, "apps"))
    refute File.dir?(Path.join(@root, "packages"))
  end

  test "the closed Home compiler emits data rather than executable or native source" do
    source = File.read!(Path.join(@root, "lib/wotex_home/rules/compiler.ex"))

    for forbidden <- [
          "Code.compile",
          "Code.eval",
          "String.to_atom",
          "System.cmd",
          "use GenServer",
          "Sqlite3.open",
          "Store.",
          "WotexUdp."
        ] do
      refute source =~ forbidden
    end

    sandbox = File.read!(Path.join(@root, "lib/wotex_home/rules/sandbox.ex"))
    assert sandbox =~ "Compiler.compile(rules)"
    assert sandbox =~ "Compiler.current(program, rules)"
    assert sandbox =~ "Compiler.evaluate(rule.predicate_code, facts)"
    refute sandbox =~ "Predicate.evaluate"
    screen = File.read!(Path.join(@root, "lib/wotex_home/verification/legacy_conflict.ex"))
    assert screen =~ "Compiler.compile(rules)"
    assert screen =~ "scope: :negative_state_conflict_only"
  end
end
