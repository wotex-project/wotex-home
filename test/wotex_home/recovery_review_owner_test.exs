defmodule WotexHome.RecoveryReviewOwnerTest do
  use ExUnit.Case
  alias WotexHome.Profiles.Artifact

  alias WotexHome.Recovery.{
    DomainCodec,
    IsolationDecision,
    Owner,
    PrivateFile,
    ReviewOwner,
    TransferAcceptanceCodec,
    TransferReviewCodec
  }

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-recovery-review-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    reviews = Path.join(root, "reviews")
    File.mkdir!(reviews)
    File.chmod!(reviews, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    owner_file = Path.join(root, "owner.json")
    {:ok, owner} = Owner.create(owner_file)

    transport = [
      "lifx-direct-power-v1",
      "udp",
      "no_authenticated_radio_state",
      "profile:fixture",
      "lifx:d073d5000001",
      "vendor:fixture",
      "model:fixture",
      "1.22",
      "compiled",
      digest("c")
    ]

    identity = [
      4,
      "light:fixture",
      "lifx:d073d5000001",
      digest("d"),
      2,
      "candidate:fixture",
      "review:fixture",
      "legacy_tofu",
      "qualification:fixture",
      "operator:source",
      "profile:fixture",
      "vendor:fixture",
      "model:fixture",
      "1.22"
    ]

    binding = Enum.map([1, 2, 3, 5, 6, 7, 8, 9, 10, 0, 4], &Enum.at(identity, &1))

    record = [
      "light:fixture",
      "active",
      "profile:fixture",
      0,
      digest("e"),
      [["power", ["read", "write"], "ordinary", "boolean", "none"]],
      binding,
      [[identity, transport]],
      [],
      transport
    ]

    document =
      JSON.encode!([
        "wotex-home.controller-domains.v2",
        digest("f"),
        [3, 3, 0, 0, 0, 0, 0],
        [record]
      ])

    {:ok, decoded} = DomainCodec.decode(document)

    basis = %{
      retirement_receipt: %{
        "deployment_id" => digest("1"),
        "source_owner_id" => digest("2"),
        "destination_owner_id" => owner.owner_id,
        "authority_epoch" => 1,
        "revision" => 19
      },
      source_maintenance_revision: 10,
      source_rule_generation: 2,
      archive_digest: digest("4"),
      snapshot_digest: digest("5"),
      domains: Map.delete(decoded, :version)
    }

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      public_key: public,
      generation: 1,
      method: "physical_disconnection",
      procedure_ref: "procedure:fixture",
      policy_digest: digest("a"),
      counter_state: "no_radio_state"
    }

    providers =
      start_supervised!(
        {Agent,
         fn ->
           %{
             basis: {:ok, basis},
             runtime: {:ok, digest("6")},
             clock: %{confidence: :trusted, now_utc_ms: 1_000},
             trust: %{"issuer:fixture" => policy}
           }
         end}
      )

    operator = self()

    options = [
      root: reviews,
      owner_file: owner_file,
      operator: operator,
      archive_basis: fn -> Agent.get(providers, & &1.basis) end,
      issuer_policies: fn -> Agent.get(providers, & &1.trust) end,
      clock: fn -> Agent.get(providers, & &1.clock) end,
      runtime: fn -> Agent.get(providers, & &1.runtime) end
    ]

    actor = spawn_link(fn -> actor_loop() end)
    on_exit(fn -> if Process.alive?(actor), do: Process.exit(actor, :kill) end)

    %{
      root: root,
      reviews: reviews,
      owner_file: owner_file,
      owner: owner,
      providers: providers,
      options: options,
      private: private,
      policy: policy,
      actor: actor
    }
  end

  test "private review publishes fixed recovery custody and only its bound Store may consume it",
       c do
    owner = start_supervised!({ReviewOwner, c.options})
    assert :ok = ReviewOwner.bind_store(owner, c.actor)
    assert {:ok, pending} = ReviewOwner.prepare(owner)
    assert pending.state == :pending and pending.new_control_grants == false
    assert pending.permissions == ["read", "host:maintain", "profile:manage", "enroll:review"]
    {:ok, credential} = PrivateFile.read_credential(pending.credential_file)
    assert {:ok, review} = TransferReviewCodec.decode(File.read!(pending.review_file))
    assert review["credential_hash"] == Artifact.digest(credential)
    refute inspect(pending) =~ Base.url_encode64(credential, padding: false)
    {package, input} = approval(c, pending)

    assert {:ok, %{state: :approved}} =
             ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

    assert {:ok, %{state: :approved}} =
             ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

    assert {:error, :recovery_review_forbidden} =
             ReviewOwner.checkout(owner, pending.review_token, input)

    assert {:ok, material} =
             as_actor(c.actor, fn -> ReviewOwner.checkout(owner, pending.review_token, input) end)

    assert material.review_document == File.read!(pending.review_file)
    assert material.domain_document == File.read!(pending.domain_file)

    assert {:ok, isolated, policy} =
             as_actor(c.actor, fn -> ReviewOwner.guard(owner, pending.review_token) end)

    assert isolated.package_bytes == package
    assert {:ok, _, _} = TransferAcceptanceCodec.historical_issuer(policy)
    assert :ok = as_actor(c.actor, fn -> ReviewOwner.finish(owner, pending.review_token) end)
    assert :not_found = ReviewOwner.status(owner, pending.review_token)

    assert {:error, :recovery_review_consumed} =
             as_actor(c.actor, fn -> ReviewOwner.checkout(owner, pending.review_token, input) end)

    assert File.exists?(pending.credential_file)
  end

  test "unconfigured trusted time and issuer keys cannot authorize review acceptance", c do
    owner = start_supervised!({ReviewOwner, Keyword.drop(c.options, [:clock, :issuer_policies])})
    assert {:error, :isolation_clock_unavailable} = ReviewOwner.prepare(owner)
    assert File.ls!(c.reviews) == []
    stop_supervised(ReviewOwner)
    owner = start_supervised!({ReviewOwner, Keyword.delete(c.options, :issuer_policies)})
    {:ok, pending} = ReviewOwner.prepare(owner)
    {package, _} = approval(c, pending)

    assert {:error, :isolation_trust_unavailable} =
             ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

    assert {:error, :recovery_review_consumed} = ReviewOwner.cancel(owner, pending.review_token)
  end

  test "other callers cannot prepare, approve, inspect, bind, cancel or check out custody", c do
    owner = start_supervised!({ReviewOwner, c.options})
    {:ok, pending} = ReviewOwner.prepare(owner)
    {package, input} = approval(c, pending)

    for call <- [
          fn -> ReviewOwner.prepare(owner) end,
          fn -> ReviewOwner.status(owner, pending.review_token) end,
          fn -> ReviewOwner.bind_store(owner, self()) end,
          fn ->
            ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)
          end,
          fn -> ReviewOwner.cancel(owner, pending.review_token) end,
          fn -> ReviewOwner.checkout(owner, pending.review_token, input) end
        ] do
      assert {:error, :recovery_review_forbidden} = Task.async(call) |> Task.await()
    end

    assert {:ok, %{state: :pending}} = ReviewOwner.status(owner, pending.review_token)
  end

  test "original monotonic expiry is not refreshed by status and files cannot restore a challenge",
       c do
    owner = start_supervised!({ReviewOwner, Keyword.put(c.options, :ttl_ms, 100)})
    {:ok, pending} = ReviewOwner.prepare(owner)
    {package, input} = approval(c, pending)
    assert :ok = ReviewOwner.bind_store(owner, c.actor)
    assert {:ok, _} = ReviewOwner.status(owner, pending.review_token)
    Process.sleep(120)
    assert :not_found = ReviewOwner.status(owner, pending.review_token)

    assert {:error, :recovery_review_consumed} =
             ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

    stop_supervised(ReviewOwner)
    owner = start_supervised!({ReviewOwner, c.options})
    assert :ok = ReviewOwner.bind_store(owner, c.actor)

    assert {:error, :recovery_review_missing} =
             as_actor(c.actor, fn -> ReviewOwner.checkout(owner, pending.review_token, input) end)

    assert File.exists?(pending.review_file)
  end

  test "each source, runtime, trusted clock and current issuer substitution refuses the guard",
       c do
    owner = start_supervised!({ReviewOwner, c.options})
    assert :ok = ReviewOwner.bind_store(owner, c.actor)

    for changed <- [:basis, :runtime, :clock, :trust] do
      {:ok, pending} = ReviewOwner.prepare(owner)
      {package, input} = approval(c, pending)

      assert {:ok, _} =
               ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

      assert {:ok, _} =
               as_actor(c.actor, fn ->
                 ReviewOwner.checkout(owner, pending.review_token, input)
               end)

      original = Agent.get(c.providers, &Map.fetch!(&1, changed))

      replacement =
        case changed do
          :basis -> {:ok, %{elem(original, 1) | archive_digest: digest("b")}}
          :runtime -> {:ok, digest("b")}
          :clock -> %{confidence: :unknown, now_utc_ms: 1_000}
          :trust -> %{}
        end

      Agent.update(c.providers, &Map.put(&1, changed, replacement))

      assert {:error, _} =
               as_actor(c.actor, fn -> ReviewOwner.guard(owner, pending.review_token) end)

      Agent.update(c.providers, &Map.put(&1, changed, original))
      assert :ok = as_actor(c.actor, fn -> ReviewOwner.finish(owner, pending.review_token) end)
    end
  end

  test "identical-byte private file replacement refuses both approval and checked-out guard", c do
    owner = start_supervised!({ReviewOwner, c.options})
    assert :ok = ReviewOwner.bind_store(owner, c.actor)

    for kind <- [:review_file, :domain_file, :credential_file] do
      {:ok, pending} = ReviewOwner.prepare(owner)
      {package, input} = approval(c, pending)

      assert {:ok, _} =
               ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

      assert {:ok, _} =
               as_actor(c.actor, fn ->
                 ReviewOwner.checkout(owner, pending.review_token, input)
               end)

      path = pending[kind]
      bytes = File.read!(path)
      File.rename!(path, path <> ".original")
      File.write!(path, bytes)
      File.chmod!(path, if(kind == :credential_file, do: 0o600, else: 0o400))

      assert {:error, :private_custody_unavailable} =
               as_actor(c.actor, fn -> ReviewOwner.guard(owner, pending.review_token) end)

      assert :ok = as_actor(c.actor, fn -> ReviewOwner.finish(owner, pending.review_token) end)
    end
  end

  test "finite pending capacity rejects excess while cancellation never reopens the token", c do
    owner = start_supervised!({ReviewOwner, c.options})

    entries =
      for _ <- 1..8 do
        {:ok, entry} = ReviewOwner.prepare(owner)
        entry
      end

    assert {:error, :recovery_review_unavailable} = ReviewOwner.prepare(owner)
    first = hd(entries)
    assert :ok = ReviewOwner.cancel(owner, first.review_token)
    assert {:error, :recovery_review_consumed} = ReviewOwner.cancel(owner, first.review_token)
    assert {:ok, _} = ReviewOwner.prepare(owner)
    assert File.ls!(c.reviews) |> length() == 9
  end

  test "owner and Store death discard transient authority and status formatting redacts material",
       c do
    owner =
      start_supervised!(Supervisor.child_spec({ReviewOwner, c.options}, restart: :temporary))

    {:ok, pending} = ReviewOwner.prepare(owner)
    {:ok, credential} = PrivateFile.read_credential(pending.credential_file)
    formatted = inspect(:sys.get_status(owner))
    refute formatted =~ Base.url_encode64(credential, padding: false)
    refute formatted =~ "lifx:d073d5000001"
    assert formatted =~ "private_recovery_custody"
    assert :ok = ReviewOwner.bind_store(owner, c.actor)
    ref = Process.monitor(owner)
    Process.exit(c.actor, :normal)
    send(c.actor, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 1_000
    assert File.exists?(pending.credential_file)
  end

  test "malformed source context and replaced owner identity cannot create an accepted challenge",
       c do
    owner = start_supervised!({ReviewOwner, c.options})
    original = Agent.get(c.providers, & &1.basis)

    for malformed <- [nil, %{}, %{domains: nil}] do
      Agent.update(c.providers, &Map.put(&1, :basis, {:ok, malformed}))
      assert {:error, :recovery_review_unavailable} = ReviewOwner.prepare(owner)
      assert Process.alive?(owner)
      assert File.ls!(c.reviews) == []
    end

    Agent.update(c.providers, &Map.put(&1, :basis, original))
    {:ok, pending} = ReviewOwner.prepare(owner)
    {package, _} = approval(c, pending)
    bytes = File.read!(c.owner_file)
    File.rename!(c.owner_file, c.owner_file <> ".original")
    assert :ok = PrivateFile.write(c.owner_file, bytes, 128)

    assert {:error, :private_custody_unavailable} =
             ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

    assert :not_found = ReviewOwner.status(owner, pending.review_token)
  end

  test "approval conflicts, copied package changes and root replacement cannot renew a challenge",
       c do
    owner = start_supervised!({ReviewOwner, c.options})
    assert :ok = ReviewOwner.bind_store(owner, c.actor)
    {:ok, pending} = ReviewOwner.prepare(owner)
    {package, input} = approval(c, pending)

    assert {:error, :recovery_review_conflict} =
             ReviewOwner.approve(owner, pending.review_token, digest("a"), package)

    assert {:ok, %{state: :pending}} = ReviewOwner.status(owner, pending.review_token)

    assert {:ok, _} =
             ReviewOwner.approve(owner, pending.review_token, pending.review_digest, package)

    assert {:error, :recovery_review_conflict} =
             ReviewOwner.approve(
               owner,
               pending.review_token,
               pending.review_digest,
               " " <> package
             )

    assert {:ok, _} =
             as_actor(c.actor, fn -> ReviewOwner.checkout(owner, pending.review_token, input) end)

    signed_file = Path.join(Path.dirname(pending.review_file), "isolation.json")
    File.chmod!(signed_file, 0o600)
    File.write!(signed_file, " " <> package)
    File.chmod!(signed_file, 0o400)

    assert {:error, _} =
             as_actor(c.actor, fn -> ReviewOwner.guard(owner, pending.review_token) end)

    assert :ok = as_actor(c.actor, fn -> ReviewOwner.finish(owner, pending.review_token) end)
    File.rename!(c.reviews, c.reviews <> ".original")
    File.mkdir!(c.reviews)
    File.chmod!(c.reviews, 0o700)
    assert {:error, :recovery_review_unavailable} = ReviewOwner.prepare(owner)
  end

  defp approval(c, pending) do
    {:ok, review} = TransferReviewCodec.decode(File.read!(pending.review_file))
    {:ok, scope} = TransferReviewCodec.isolation_scope(review)

    decision =
      Map.merge(scope, %{
        "format" => "wotex-home.controller-isolation.v1",
        "method" => c.policy.method,
        "procedure_ref" => c.policy.procedure_ref,
        "issuer_id" => "issuer:fixture",
        "issuer_generation" => 1,
        "isolation_policy_digest" => c.policy.policy_digest,
        "issued_at_utc_ms" => review["issued_at_utc_ms"],
        "expires_at_utc_ms" => review["expires_at_utc_ms"]
      })

    {:ok, payload} = IsolationDecision.signing_payload(decision)

    {:ok, package} =
      IsolationDecision.encode(
        decision,
        :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519])
      )

    {:ok, input} =
      TransferAcceptanceCodec.encode("operation", %{
        "principal_id" => review["principal_id"],
        "source_epoch" => review["source_epoch"],
        "operation_id" => "accept:original",
        "retirement_revision" => review["retirement_revision"],
        "destination_owner_id" => review["destination_owner_id"],
        "review_digest" => pending.review_digest,
        "isolation_package_digest" => Artifact.digest(package)
      })

    {package, input}
  end

  defp as_actor(actor, fun) do
    ref = make_ref()
    send(actor, {:call, self(), ref, fun})

    receive do
      {^ref, result} -> result
    after
      5_000 -> flunk("private Store actor did not reply")
    end
  end

  defp actor_loop do
    receive do
      {:call, parent, ref, fun} ->
        send(parent, {ref, fun.()})
        actor_loop()

      :stop ->
        :ok
    end
  end

  defp digest(value), do: String.duplicate(value, 64)
end
