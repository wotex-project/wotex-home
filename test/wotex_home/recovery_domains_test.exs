Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))

defmodule WotexHome.RecoveryDomainsTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, RecoveryDomains}
  alias WotexHome.Lifx.{ProfileBasis, ProfileCatalogue}
  alias WotexHome.Profiles.{Artifact, Custody, Review, ReviewSession}
  alias WotexHome.Semantics.{Observation, Thing}

  setup do
    fixture = WotexHome.Test.PortableProfileFixture.context()
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-domains-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    profiles = Path.join(root, "profiles")
    File.mkdir!(profiles)
    File.chmod!(profiles, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    store =
      start_supervised!(
        {Store,
         path: Path.join(root, "home.sqlite"),
         name: __MODULE__.Store,
         profile_custody: __MODULE__.Custody,
         profile_reviews: __MODULE__.Reviews}
      )

    custody =
      start_supervised!({Custody, root: profiles, name: __MODULE__.Custody, store_owner: store})

    reviews = start_supervised!({ReviewSession, custody: custody, name: __MODULE__.Reviews})
    authority = Authority.new(store: store, profile_custody: custody, profile_reviews: reviews)

    {:ok, operator, 1} =
      Store.provision_principal(
        store,
        "operator:fixture",
        ["enroll:review", "profile:manage"],
        []
      )

    {:ok, maintainer, 2} = Authority.provision_maintenance(authority)
    {:ok, transfer, 3} = Authority.provision_transfer(authority)

    %{
      root: root,
      fixture: fixture,
      store: store,
      custody: custody,
      reviews: reviews,
      authority: authority,
      operator: operator,
      maintainer: maintainer,
      transfer: transfer,
      archive: Path.join(root, "retired.woh"),
      key: :crypto.strong_rand_bytes(32)
    }
  end

  test "complete compiled identity binds the whole Thing and classifies only its known software dependency",
       c do
    enroll_compiled(c)
    basis = retire(c)
    domains = basis.domains
    assert domains.domain_count == 1 and domains.counter_state == "no_radio_state"
    assert domains.counter_state_digest == nil
    assert domains.domain_digest == Artifact.digest(domains.document)

    assert {:ok, ["wotex-home.controller-domains.v2", logical, [3, 3, 0, 0, 0, 0, 0], [record]]} =
             JSON.decode(domains.document)

    assert logical == basis.logical_snapshot_digest

    assert [
             "light:fixture",
             "active",
             "lifx.product-22:1.0.0",
             0,
             _,
             [["power", ["read", "write"], "ordinary", "boolean", "none"]],
             binding,
             [identity],
             [],
             transport
           ] = record

    assert length(binding) == 11 and length(hd(identity)) == 14
    assert transport == List.last(identity)

    assert [
             "lifx-direct-power-v1",
             "udp",
             "no_authenticated_radio_state",
             _,
             "lifx:d073d5000001",
             "lifx.vendor.1",
             "lifx.product.22",
             "1.22",
             "compiled",
             catalogue
           ] = transport

    assert catalogue == ProfileCatalogue.digest()
    assert {:ok, %{dispatch_enabled: false, writable: false}} = Store.health(c.store)

    destination = Path.join(c.root, "staged")
    {:ok, _} = Backup.stage_profile_restore(c.archive, c.key, destination)

    with_copy(File.read!(Path.join(destination, "home.sqlite")), fn db ->
      assert {:ok, ^domains} = RecoveryDomains.derive(db, :quarantine)
    end)
  end

  test "empty and unbound named declarations remain unknown instead of inferred counter absence",
       c do
    basis = retire(c)
    assert basis.domains.domain_count == 0 and basis.domains.counter_state == "unknown"
    assert {:ok, [_, _, _, []]} = JSON.decode(basis.domains.document)
  end

  test "a LIFX-looking profile and writable role without identity records remains unknown", c do
    assert {:ok, _} = Store.enroll_thing(c.store, c.fixture.current)
    basis = retire(c)
    assert basis.domains.domain_count == 1 and basis.domains.counter_state == "unknown"

    assert {:ok, [_, _, _, [[_, _, _, _, _, _, nil, [], [], ["unknown"]]]]} =
             JSON.decode(basis.domains.document)
  end

  test "revoked and read-only domains cannot disappear from complete isolation scope", c do
    enroll_compiled(c)
    assert {:ok, _} = Store.revoke_thing(c.store, "light:fixture")

    assert {:ok, smoke} =
             Thing.new(%{
               "id" => "sensor:fixture",
               "role" => "SmokeDetector",
               "profile_ref" => "aqara.fixture:1.0.0",
               "capabilities" => [
                 %{
                   "thing_id" => "sensor:fixture",
                   "role" => "SmokeDetector",
                   "key" => "smoke_state",
                   "value_kind" => "smoke_state",
                   "unit" => "none",
                   "operations" => ["read"],
                   "risk_class" => "sensitive",
                   "profile_ref" => "aqara.fixture:1.0.0",
                   "evidence_ref" => "cohort:fixture",
                   "freshness_ms" => 5_000,
                   "constraints" => %{},
                   "extensions" => %{}
                 }
               ]
             })

    assert {:ok, _} = Store.enroll_thing(c.store, smoke)
    basis = retire(c)
    assert basis.domains.domain_count == 2 and basis.domains.counter_state == "unknown"
    assert {:ok, [_, _, _, [light, sensor]]} = JSON.decode(basis.domains.document)
    assert Enum.take(light, 2) == ["light:fixture", "revoked"]
    refute List.last(light) == ["unknown"]
    assert Enum.at(sensor, 5) == [["smoke_state", ["read"], "sensitive", "smoke_state", "none"]]
    assert List.last(sensor) == ["unknown"]
  end

  test "superseded compiled identity and selected then revoked portable history all remain covered",
       c do
    enroll_compiled(c)
    begin_maintenance(c)
    {:ok, raw} = Custody.stage(c.custody, c.fixture.artifact.bytes)
    {:ok, revision} = Store.revision(c.store)

    {:ok, approval} =
      Store.profile_change(c.store, c.operator, %{
        "action" => "approve",
        "authority_epoch" => 1,
        "operation_id" => "profile:approve",
        "expected_revision" => revision,
        "artifact_digest" => raw,
        "expected_trust_revision" => 0
      })

    {:ok, %{rule_generation: generation}} = Store.health(c.store)

    input = %{
      c.fixture.input
      | "expected_revision" => approval.final_revision,
        "expected_trust_revision" => approval.final_revision,
        "expected_binding_revision" => 4,
        "expected_rule_generation" => generation
    }

    {:ok, :new, basis} = Store.profile_selection_basis(c.store, c.operator, input)
    {:ok, runtime} = ProfileBasis.runtime_digest()
    {:ok, review} = Review.new(basis, c.fixture.artifact, c.fixture.evidence, input, runtime)
    {:ok, _} = ReviewSession.hold(c.reviews, "operator:fixture", review)
    {:ok, selected} = Store.profile_change(c.store, c.operator, input)

    {:ok, revoked} =
      Store.profile_change(c.store, c.operator, %{
        "action" => "revoke_selection",
        "authority_epoch" => 1,
        "operation_id" => "profile:withdraw",
        "expected_revision" => selected.final_revision,
        "artifact_digest" => raw,
        "expected_trust_revision" => approval.final_revision,
        "target_id" => "light:fixture",
        "expected_resource_revision" => 1,
        "expected_selection_generation" => 1
      })

    assert revoked.changed_targets == 1
    transfer = retire(c)
    assert transfer.domains.counter_state == "no_radio_state"
    assert {:ok, [_, _, _, [record]]} = JSON.decode(transfer.domains.document)
    assert length(Enum.at(record, 7)) == 2
    assert [first, second] = Enum.at(record, 8)
    assert Enum.at(first, 2) == "selected" and Enum.at(second, 2) == "revoked"

    for selection <- [first, second] do
      assert Enum.at(selection, 3) == raw
      assert Enum.at(List.last(selection), 8) == "portable"
      assert List.last(List.last(selection)) == c.fixture.artifact.projection_digest
    end
  end

  test "supported historical legacy metadata does not become complete from a stable name", c do
    enroll_compiled(c)
    retire(c)
    bytes = source_database(c.archive, c.key)

    with_copy(bytes, fn db ->
      assert :ok =
               Sqlite3.execute(
                 db,
                 "UPDATE enrollment_bindings SET digest_version=1; UPDATE enrollment_review_history SET digest_version=1,manufacturer=NULL,model=NULL,firmware=NULL"
               )

      assert :ok = Integrity.validate_snapshot(db)
      assert {:ok, domains} = RecoveryDomains.derive(db, :source)
      assert domains.domain_count == 1 and domains.counter_state == "unknown"
    end)
  end

  test "retained observations without a declaration stay in the complete domain set", c do
    enroll_compiled(c)
    record(c)
    retire(c)

    with_copy(source_database(c.archive, c.key), fn db ->
      assert :ok =
               Sqlite3.execute(
                 db,
                 "UPDATE journal SET thing_id='sensor:unresolved'; UPDATE observation_current SET thing_id='sensor:unresolved'"
               )

      assert :ok = Integrity.validate_snapshot(db)
      assert {:ok, domains} = RecoveryDomains.derive(db, :source)
      assert domains.domain_count == 2 and domains.counter_state == "unknown"
      assert {:ok, [_, _, _, [light, unresolved]]} = JSON.decode(domains.document)
      refute List.last(light) == ["unknown"]

      assert unresolved == [
               "sensor:unresolved",
               "unresolved",
               nil,
               nil,
               nil,
               [],
               nil,
               [],
               [],
               ["unknown"]
             ]
    end)
  end

  test "an unsupported historical protocol trace prevents counter absence on a known current Thing",
       c do
    enroll_compiled(c)
    record(c)
    retire(c)

    with_copy(source_database(c.archive, c.key), fn db ->
      assert :ok =
               Sqlite3.execute(
                 db,
                 "UPDATE journal SET profile_ref='unknown:transport'; UPDATE observation_current SET profile_ref='unknown:transport'"
               )

      assert :ok = Integrity.validate_snapshot(db)
      assert {:ok, domains} = RecoveryDomains.derive(db, :source)
      assert domains.domain_count == 1 and domains.counter_state == "unknown"
      assert {:ok, [_, _, _, [record]]} = JSON.decode(domains.document)
      assert List.last(record) == ["unknown"]
    end)
  end

  test "v2 signed domain commitment includes every source authority row without principal filtering",
       c do
    enroll_compiled(c)

    {:ok, controller, _} =
      Store.provision_principal(c.store, "controller:other", ["read", "control:ordinary"], [
        "light:fixture"
      ])

    {:ok, _, _} = Store.provision_principal(c.store, "reader:revoked", ["read"], [])
    {:ok, _} = Store.revoke_principal(c.store, "reader:revoked")
    record(c)
    {:ok, observed} = Store.revision(c.store)

    assert {:ok, _} =
             Store.authorize_source_epoch(
               c.store,
               "light:fixture",
               "power",
               "device:fixture",
               "device:replacement",
               observed
             )

    assert {:ok, _, _} =
             Store.issue_override_lease_live(c.store, controller, "light:fixture", 1, 0, 60_000)

    basis = retire(c)

    assert basis.domains.source_counts == %{
             principal_rows: 5,
             active_principal_rows: 4,
             qualified_profile_heads: 0,
             current_observation_rows: 1,
             target_grant_rows: 1,
             source_grant_rows: 1,
             override_lease_rows: 1
           }

    assert {:ok, ["wotex-home.controller-domains.v2", _, [5, 4, 0, 1, 1, 1, 1], [_]]} =
             JSON.decode(basis.domains.document)

    assert basis.domains.counter_state == "no_radio_state"
    assert basis.domains.domain_digest == Artifact.digest(basis.domains.document)
    destination = Path.join(c.root, "staged-counts")
    {:ok, _} = Backup.stage_profile_restore(c.archive, c.key, destination)

    with_copy(File.read!(Path.join(destination, "home.sqlite")), fn db ->
      assert {:ok, domains} = RecoveryDomains.derive(db, :quarantine)
      assert domains == basis.domains
    end)
  end

  for count <- [64, 65] do
    @tag domain_count: count
    test "complete domain capacity #{count} never truncates retained Things", c do
      for index <- 1..c.domain_count do
        {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:#{index}")
        assert {:ok, _} = Store.enroll_thing(c.store, package.thing)
      end

      retire_source(c)

      if c.domain_count == 64 do
        assert {:ok, basis} = Backup.retired_transfer_basis(c.archive, c.key)
        assert basis.domains.domain_count == 64 and basis.domains.counter_state == "unknown"
      else
        assert {:ok, _} = Backup.verify(c.archive, c.key)

        assert {:error, :retired_archive_required} =
                 Backup.retired_transfer_basis(c.archive, c.key)
      end
    end
  end

  defp enroll_compiled(c) do
    {:ok, package} = ProfileCatalogue.fetch(c.fixture.current.profile_ref, c.fixture.current.id)
    interview = c.fixture.evidence.interview

    selection = %{
      "operator_id" => "operator:fixture",
      "candidate_ref" => interview.candidate_ref,
      "stable_id" => interview.stable_id,
      "profile_ref" => c.fixture.current.profile_ref,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:compiled"
    }

    assert {:ok, 4} =
             Store.commit_enrollment(
               c.store,
               c.operator,
               c.fixture.evidence.candidates,
               interview,
               [package.profile],
               c.fixture.current,
               selection
             )
  end

  defp record(c) do
    capability = c.fixture.current.capabilities["power"]

    {:ok, observation} =
      Observation.new(
        %{
          "thing_id" => "light:fixture",
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "device:fixture",
          "source_sequence" => 1,
          "boot_epoch" => "boot:fixture",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_000_000,
          "received_monotonic_ms" => 100
        },
        capability
      )

    assert {:ok, _} = Store.record(c.store, observation, capability)
  end

  defp begin_maintenance(c) do
    {:ok, status} = Store.maintenance_status(c.store, c.maintainer)

    if status.state == :normal do
      {:ok, revision} = Store.revision(c.store)

      assert {:ok, _} =
               Store.begin_maintenance(c.store, c.maintainer, 1, "maintenance:source", revision)
    end
  end

  defp retire_source(c) do
    begin_maintenance(c)
    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.retire_controller(c.authority, c.transfer, %{
               "authority_epoch" => 1,
               "operation_id" => "retire:source",
               "expected_revision" => revision,
               "destination_owner_id" => String.duplicate("a", 64)
             })

    assert {:ok, _} = Authority.export_retired_profile_backup(c.authority, c.archive, c.key)
  end

  defp retire(c) do
    retire_source(c)
    {:ok, basis} = Backup.retired_transfer_basis(c.archive, c.key)
    basis
  end

  defp with_copy(bytes, function) do
    {:ok, db} = Sqlite3.open(":memory:")

    try do
      :ok = Sqlite3.deserialize(db, "main", bytes)
      function.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp source_database(path, key) do
    <<"WOHBK2\0", revision::64, epoch::64, nonce::binary-size(12), size::32, rest::binary>> =
      File.read!(path)

    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = rest
    header = <<"WOHBK2\0", revision::64, epoch::64, nonce::binary-size(12), size::32>>

    {:ok, database, _} =
      WotexHome.Profiles.Archive.decode(
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, header, tag, false)
      )

    database
  end
end
