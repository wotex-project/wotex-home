Code.require_file("../support/controller_tls_fixture.exs", __DIR__)

defmodule WotexHome.ControllerPairingReviewTest do
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.ControllerConnections.{Codec, PairingReview, ReviewCodec}
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.TestSupport.ControllerTLSFixture, as: Peer

  setup_all do
    root = Path.join(System.tmp_dir!(), "woh-review-cert-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    fixture = Peer.create(root)
    template = Peer.invitation(fixture, 49_999) |> Map.drop(~w(invitation_id bootstrap_secret))
    %{template: template}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "woh-pairing-review-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    reviews = start_supervised!({PairingReview, store_owner: store})
    authority = Authority.new(store: store, pairing_reviews: reviews)
    %{store: store, reviews: reviews, authority: authority, path: path}
  end

  test "Authority supplies a live read-only scope; absent or different owner refuses", c do
    assert {:ok, scope} = Authority.pairing_setup_context(c.authority)
    assert ReviewCodec.scope?(scope)
    assert scope["expected_revision"] == 0
    assert scope["authority_epoch"] == 1
    assert scope["store_boot"] == :sys.get_state(c.store).clock_epoch
    assert {:ok, ^scope} = Authority.pairing_setup_context(c.authority)
    assert {:ok, 0} = Store.revision(c.store)
    assert {:ok, [[0]]} = SQL.query(db(c.store), "SELECT COUNT(*) FROM principals")
    assert {:ok, [[0]]} = SQL.query(db(c.store), "SELECT COUNT(*) FROM authority_journal")

    assert {:error, :pairing_unavailable} =
             Authority.pairing_open(Authority.new(store: c.store), c.template)

    other = start_supervised!({Store, path: c.path <> ".other"}, id: :other_store)
    wrong = %{c.authority | store: other}
    assert {:error, :pairing_unavailable} = Authority.pairing_open(wrong, c.template)
    assert {:error, :pairing_unavailable} = PairingReview.bound_owner(c.reviews, other)
  end

  test "opening generates fresh private material and stores only its verifier", c do
    {admin, invitation, request} = open(c)
    assert {:ok, _} = Codec.encode("invitation", invitation)
    assert {:ok, secret} = Base.url_decode64(invitation["bootstrap_secret"], padding: false)
    assert byte_size(secret) == 32
    state = :sys.get_state(c.reviews)
    assert state.window.verifier == :crypto.hash(:sha256, secret)
    private = :erlang.term_to_binary(state)
    refute :binary.match(private, invitation["bootstrap_secret"]) != :nomatch
    refute :binary.match(private, secret) != :nomatch
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)

    assert {:ok, [%{reference: ^ref, original: original, phase: :pending, approval: nil}]} =
             Authority.pairing_pending(c.authority, admin)

    assert original["client_label"] == request["client_label"]
    assert {:ok, original["request_digest"]} == Codec.request_digest(request)
    refute Map.has_key?(original, "bootstrap_secret")
    refute Map.has_key?(original, "credential")
    assert :ok = Authority.pairing_close(c.authority, admin)
    assert :sys.get_state(c.reviews).window == nil
    {next_admin, next, _} = open(c)
    refute next["invitation_id"] == invitation["invitation_id"]
    refute next["bootstrap_secret"] == invitation["bootstrap_secret"]
    assert {:error, :pairing_unavailable} = Authority.pairing_close(c.authority, admin)
    assert :ok = Authority.pairing_close(c.authority, next_admin)
    assert {:ok, 0} = Store.revision(c.store)
  end

  test "current local approval binds the complete original and exact default access", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:error, :confirmation_denied} = PairingReview.checkout(c.reviews, request)
    assert {:ok, _, 1} = Authority.provision_diagnostic(c.authority)
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
    assert approval["expected_revision"] == 1
    assert Map.take(approval, ~w(permissions target_ids)) == Codec.default_access()
    assert approval["client_label"] == request["client_label"]
    assert {:ok, approval["request_digest"]} == Codec.request_digest(request)

    assert {:ok, [%{phase: :approved, approval: ^approval}]} =
             Authority.pairing_pending(c.authority, admin)

    assert {:error, :confirmation_denied} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:ok, checkout, ^approval} = PairingReview.checkout(c.reviews, request)
    assert :ok = PairingReview.guard(c.reviews, checkout, approval)
    assert {:error, :confirmation_denied} = PairingReview.checkout(c.reviews, request)
    assert {:ok, [%{phase: :checked_out}]} = Authority.pairing_pending(c.authority, admin)
    assert :ok = PairingReview.finish(c.reviews, checkout)
    assert {:error, :pairing_closed} = PairingReview.guard(c.reviews, checkout, approval)
    assert {:ok, 1} = Store.revision(c.store)
    assert {:ok, [[1]]} = SQL.query(db(c.store), "SELECT COUNT(*) FROM principals")
    assert :ok = Integrity.validate_snapshot(db(c.store))
  end

  test "only explicit trusted access can widen the default; request cannot nominate it", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    access = %{"permissions" => ["control:ordinary", "read"], "target_ids" => ["light:one"]}
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref, access)
    assert Map.take(approval, ~w(permissions target_ids)) == access
    assert {:ok, 0} = Store.revision(c.store)
    assert {:ok, [[0]]} = SQL.query(db(c.store), "SELECT COUNT(*) FROM principal_targets")
    assert :ok = Authority.pairing_close(c.authority, admin)

    for field <- ~w(role permissions target_ids declaration credential authority_epoch) do
      {admin, _, request} = open(c)

      assert {:error, :invitation_unavailable} =
               Authority.pairing_prepare(c.authority, admin, Map.put(request, field, "control"))

      assert {:ok, []} = Authority.pairing_pending(c.authority, admin)
      assert :ok = Authority.pairing_close(c.authority, admin)
    end
  end

  test "approval rejects different boot, owner, deployment, epoch, revision and admin", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, scope} = Authority.pairing_setup_context(c.authority)

    for {field, changed} <- [
          {"store_boot", "boot:" <> String.duplicate("f", 32)},
          {"deployment_id", String.duplicate("f", 64)},
          {"owner_id", String.duplicate("f", 64)},
          {"authority_epoch", 2},
          {"expected_revision", -1}
        ] do
      assert {:error, :confirmation_denied} =
               PairingReview.approve(c.reviews, admin, ref, Map.put(scope, field, changed))
    end

    for bad_admin <- [make_ref(), "admin", nil] do
      assert {:error, :confirmation_denied} =
               PairingReview.approve(c.reviews, bad_admin, ref, scope)

      assert {:error, :pairing_unavailable} = PairingReview.pending(c.reviews, bad_admin)
      assert {:error, :pairing_unavailable} = PairingReview.close(c.reviews, bad_admin)
    end

    for invalid <- [
          %{"permissions" => ["control:ordinary"], "target_ids" => []},
          %{"permissions" => ["read", "read"], "target_ids" => []},
          %{"permissions" => ["read"], "target_ids" => ["light:one" | :improper]},
          %{"permissions" => ["host:transfer", "read"], "target_ids" => []}
        ] do
      assert {:error, :confirmation_denied} =
               PairingReview.approve(c.reviews, admin, ref, scope, invalid)
    end

    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)
  end

  test "a lower revision than opening cannot be approved", c do
    assert {:ok, _, 1} = Authority.provision_diagnostic(c.authority)
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, scope} = Authority.pairing_setup_context(c.authority)

    assert {:error, :confirmation_denied} =
             PairingReview.approve(c.reviews, admin, ref, %{scope | "expected_revision" => 0})
  end

  test "changed original cannot check out an approved request", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)

    for {field, value} <- [
          {"client_id", String.duplicate("f", 64)},
          {"request_id", String.duplicate("f", 64)},
          {"client_label", "other client"}
        ] do
      assert {:error, :confirmation_denied} =
               PairingReview.checkout(c.reviews, Map.put(request, field, value))
    end

    assert {:ok, checkout, ^approval} = PairingReview.checkout(c.reviews, request)

    for {field, changed} <- [
          {"request_digest", String.duplicate("f", 64)},
          {"expected_revision", 1},
          {"permissions", ["enroll:review"]},
          {"target_ids", ["light:one"]}
        ] do
      assert {:error, :pairing_unavailable} =
               PairingReview.guard(c.reviews, checkout, Map.put(approval, field, changed))
    end

    assert {:error, :pairing_unavailable} = PairingReview.guard(c.reviews, make_ref(), approval)
    assert :ok = PairingReview.guard(c.reviews, checkout, approval)
  end

  test "denial tombstones the exact original without poisoning another candidate", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)
    assert :ok = Authority.pairing_deny(c.authority, admin, ref)
    assert {:error, :confirmation_denied} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:error, :confirmation_denied} = PairingReview.checkout(c.reviews, request)
    assert {:error, :confirmation_denied} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:ok, []} = Authority.pairing_pending(c.authority, admin)
    next = %{request | "request_id" => id(77)}
    assert {:ok, next_ref} = Authority.pairing_prepare(c.authority, admin, next)
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, next_ref)
  end

  test "there is one finite window and at most eight pending clients", c do
    {admin, _, request} = open(c)
    assert {:error, :pairing_busy} = Authority.pairing_open(c.authority, c.template)

    refs =
      for n <- 1..8 do
        changed = %{request | "client_id" => id(n), "request_id" => id(n + 32)}
        assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, changed)
        assert {:ok, ^ref} = Authority.pairing_prepare(c.authority, admin, changed)
        {ref, changed}
      end

    assert {:ok, rows} = Authority.pairing_pending(c.authority, admin)
    assert length(rows) == 8

    assert {:error, :pairing_busy} =
             Authority.pairing_prepare(c.authority, admin, %{request | "client_id" => id(99)})

    [{ref, first}, {second, _} | _] = refs

    assert {:error, :pairing_busy} =
             Authority.pairing_prepare(c.authority, admin, %{first | "request_id" => id(100)})

    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:error, :confirmation_denied} = Authority.pairing_approve(c.authority, admin, second)
    assert :ok = Authority.pairing_deny(c.authority, admin, ref)
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, second)
  end

  test "candidate replacement never refunds the 32-entry bound", c do
    {admin, _, request} = open(c)

    for n <- 1..32 do
      changed = %{request | "client_id" => id(n), "request_id" => id(n)}
      assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, changed)
      assert :ok = Authority.pairing_deny(c.authority, admin, ref)
    end

    assert {:ok, []} = Authority.pairing_pending(c.authority, admin)
    assert :sys.get_state(c.reviews).window.attempts == 32
    assert MapSet.size(:sys.get_state(c.reviews).window.rejected) == 32

    assert {:error, :pairing_busy} =
             Authority.pairing_prepare(c.authority, admin, %{request | "client_id" => id(99)})
  end

  test "failed authentication has bounded backoff and never creates a candidate", c do
    {admin, _, request} = open(c)

    wrong = %{
      request
      | "bootstrap_secret" => Base.url_encode64(:binary.copy(<<0>>, 32), padding: false)
    }

    assert {:error, :invitation_unavailable} = PairingReview.offer(c.reviews, wrong)
    assert {:error, :pairing_busy} = PairingReview.offer(c.reviews, request)
    assert {:ok, []} = Authority.pairing_pending(c.authority, admin)
    Process.sleep(260)
    assert {:ok, _} = Authority.pairing_prepare(c.authority, admin, request)
    # Advance only the trusted private fixture's backoff, keeping the real
    # authentication path. No test clock or limiter reset is a product option.
    for n <- 2..32 do
      :sys.replace_state(c.reviews, fn s ->
        put_in(s.window.backoff, System.monotonic_time(:millisecond) - 1)
      end)

      assert {:error, :invitation_unavailable} = PairingReview.offer(c.reviews, wrong)

      if n < 32 do
        state = :sys.get_state(c.reviews)
        assert state.window.failures == n
        remaining = state.window.backoff - System.monotonic_time(:millisecond)
        assert remaining > 0 and remaining <= 8_000
      end
    end

    assert :sys.get_state(c.reviews).window == nil
    assert {:error, :pairing_unavailable} = PairingReview.offer(c.reviews, request)
  end

  test "old invitations, different controllers and malformed secrets cannot authenticate", c do
    for {field, value} <- [
          {"controller_id", String.duplicate("f", 64)},
          {"invitation_id", String.duplicate("f", 64)},
          {"bootstrap_secret", "secret"},
          {"client_label", "\u202e"}
        ] do
      {admin, _, request} = open(c)

      assert {:error, :invitation_unavailable} =
               PairingReview.offer(c.reviews, Map.put(request, field, value))

      assert :ok = Authority.pairing_close(c.authority, admin)
    end

    {admin, _, old} = open(c)
    assert :ok = Authority.pairing_close(c.authority, admin)
    {_, _, _} = open(c)
    assert {:error, :invitation_unavailable} = PairingReview.offer(c.reviews, old)
  end

  test "an offered request is bound to its live worker and not another connection", c do
    {admin, _, request} = open(c)
    worker = worker(c.reviews, request)
    assert_receive {^worker, {:offer, {:ok, ref}}}
    assert {:error, :pairing_busy} = PairingReview.offer(c.reviews, request)
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
    assert_receive {^worker, {:notice, {:controller_pairing_review, ^ref, :approved}}}
    assert {:error, :confirmation_denied} = PairingReview.checkout(c.reviews, request)
    send(worker, :checkout)
    assert_receive {^worker, {:checkout, {:ok, checkout, ^approval}}}
    assert :ok = PairingReview.guard(c.reviews, checkout, approval)
    assert {:error, :pairing_unavailable} = PairingReview.finish(c.reviews, checkout)
    send(worker, {:finish, checkout})
    assert_receive {^worker, {:finish, :ok}}
    assert {:error, :pairing_closed} = PairingReview.guard(c.reviews, checkout, approval)
  end

  test "parallel offers admit exactly eight workers and one checkout", c do
    {admin, _, request} = open(c)

    workers =
      for n <- 1..16,
          do: worker(c.reviews, %{request | "client_id" => id(n), "request_id" => id(n + 16)})

    results =
      for _ <- workers do
        assert_receive {pid, {:offer, result}}
        {pid, result}
      end

    accepted = Enum.filter(results, &match?({_, {:ok, _}}, &1))
    assert length(accepted) == 8
    assert Enum.count(results, &match?({_, {:error, :pairing_busy}}, &1)) == 8
    [{pid, {:ok, ref}} | _] = accepted
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
    send(pid, :checkout)
    assert_receive {^pid, {:checkout, {:ok, checkout, ^approval}}}

    for {other, {:ok, _}} <- accepted, other != pid do
      send(other, :checkout)
      assert_receive {^other, {:checkout, {:error, :confirmation_denied}}}
    end

    assert :ok = PairingReview.guard(c.reviews, checkout, approval)
  end

  test "preconfirmation attaches to exactly one network worker", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
    worker = worker(c.reviews, request)
    assert_receive {^worker, {:offer, {:ok, ^ref}}}
    assert {:error, :pairing_busy} = PairingReview.offer(c.reviews, request)
    send(worker, :checkout)
    assert_receive {^worker, {:checkout, {:ok, checkout, ^approval}}}
    assert :ok = PairingReview.guard(c.reviews, checkout, approval)
    assert {:error, :confirmation_denied} = Authority.pairing_deny(c.authority, admin, ref)
    assert :ok = Authority.pairing_close(c.authority, admin)
    assert {:error, :pairing_closed} = PairingReview.guard(c.reviews, checkout, approval)
  end

  test "unapproved worker loss drops only that pending entry", c do
    {admin, _, request} = open(c)
    worker = worker(c.reviews, request)
    assert_receive {^worker, {:offer, {:ok, ref}}}

    assert {:ok, other} =
             Authority.pairing_prepare(c.authority, admin, %{request | "client_id" => id(99)})

    kill(worker)

    assert eventually(fn ->
             case Authority.pairing_pending(c.authority, admin) do
               {:ok, [%{reference: ^other, phase: :pending, approval: nil}]} -> true
               _ -> false
             end
           end)

    assert {:error, :confirmation_denied} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, other)
  end

  test "selected worker loss closes approval immediately and cannot refund checkout", c do
    {admin, _, request} = open(c)
    worker = worker(c.reviews, request)
    assert_receive {^worker, {:offer, {:ok, ref}}}
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
    send(worker, :checkout)
    assert_receive {^worker, {:checkout, {:ok, checkout, ^approval}}}
    :sys.suspend(c.reviews)
    kill(worker)
    delay_down(c.reviews, worker, :sys.get_state(c.reviews).window.offers[ref].monitor)
    :sys.resume(c.reviews)
    assert {:error, :pairing_closed} = PairingReview.guard(c.reviews, checkout, approval)
    assert {:error, :pairing_closed} = PairingReview.checkout(c.reviews, request)
    assert :sys.get_state(c.reviews).window == nil
    assert {:ok, 0} = Store.revision(c.store)
  end

  test "trusted opening process loss closes the unattended window", c do
    parent = self()

    opener =
      spawn(fn ->
        result = Authority.pairing_open(c.authority, c.template)
        send(parent, {self(), result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {^opener, {:ok, admin, invitation}}
    on_exit(fn -> if Process.alive?(opener), do: Process.exit(opener, :kill) end)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request(invitation))
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)
    :sys.suspend(c.reviews)
    kill(opener)
    delay_down(c.reviews, opener, :sys.get_state(c.reviews).window.admin_monitor)
    :sys.resume(c.reviews)
    assert {:error, :pairing_closed} = PairingReview.checkout(c.reviews, request(invitation))
    assert :sys.get_state(c.reviews).window == nil
  end

  test "Store restart changes boot scope and old review never rebinds", c do
    {admin, _, request} = open(c)
    assert {:ok, old} = Authority.pairing_setup_context(c.authority)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:ok, checkout, ^approval} = PairingReview.checkout(c.reviews, request)
    :sys.suspend(c.reviews)
    GenServer.stop(c.store)
    delay_down(c.reviews, c.store, :sys.get_state(c.reviews).owner_monitor)
    :sys.resume(c.reviews)
    assert {:error, :pairing_unavailable} = PairingReview.guard(c.reviews, checkout, approval)
    assert {:error, :pairing_unavailable} = PairingReview.open(c.reviews, c.template, old)
    next = start_supervised!({Store, path: c.path}, id: :restarted_store)
    next_authority = %{c.authority | store: next}
    assert {:ok, scope} = Authority.pairing_setup_context(next_authority)
    refute scope["store_boot"] == old["store_boot"]
    assert Map.drop(scope, ["store_boot"]) == Map.drop(old, ["store_boot"])
    assert {:error, :pairing_unavailable} = Authority.pairing_open(next_authority, c.template)
    fresh = start_supervised!({PairingReview, store_owner: next}, id: :restarted_review)

    assert {:ok, _, _} =
             Authority.pairing_open(%{next_authority | pairing_reviews: fresh}, c.template)
  end

  test "review restart loses all approval and old invitations", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)
    GenServer.stop(c.reviews)
    next = start_supervised!({PairingReview, store_owner: c.store}, id: :new_review)
    assert {:error, :pairing_closed} = PairingReview.checkout(next, request)
    assert {:error, :pairing_unavailable} = PairingReview.pending(next, admin)
    assert {:ok, scope} = Authority.pairing_setup_context(c.authority)
    assert {:ok, _, _} = PairingReview.open(next, c.template, scope)
    assert {:error, :invitation_unavailable} = PairingReview.offer(next, request)
  end

  test "actual expiry cleans the window and rejects all previously checked-out approval", c do
    {admin, _, request} = open(c, 150)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:ok, checkout, ^approval} = PairingReview.checkout(c.reviews, request)
    Process.sleep(170)
    assert :sys.get_state(c.reviews).window == nil
    assert {:error, :pairing_expired} = PairingReview.guard(c.reviews, checkout, approval)
    assert {:error, :pairing_expired} = PairingReview.checkout(c.reviews, request)
    assert {:error, :pairing_unavailable} = Authority.pairing_pending(c.authority, admin)
    assert {:ok, 0} = Store.revision(c.store)
  end

  test "clock rollback, forward suspension and clock disagreement can only refuse", c do
    for change <- [
          fn w -> %{w | opened: System.monotonic_time(:millisecond) + 100} end,
          fn w -> %{w | expires: System.monotonic_time(:millisecond) - 1} end,
          fn w -> %{w | wall: System.os_time(:millisecond) + 100} end,
          fn w -> %{w | wall: System.os_time(:millisecond) - 300_001} end,
          fn w -> %{w | wall: w.wall - 500} end
        ] do
      {admin, _, request} = open(c)
      assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
      assert {:ok, approval} = Authority.pairing_approve(c.authority, admin, ref)
      assert {:ok, checkout, ^approval} = PairingReview.checkout(c.reviews, request)
      :sys.replace_state(c.reviews, fn s -> %{s | window: change.(s.window)} end)
      assert {:error, :pairing_expired} = PairingReview.guard(c.reviews, checkout, approval)
      assert :sys.get_state(c.reviews).window == nil
    end
  end

  test "maintenance, damage and read-only state prevent scope and approval", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, manager, 1} = Authority.provision_maintenance(c.authority)
    assert {:ok, _} = Store.begin_maintenance(c.store, manager, 1, "maint:pairing", 1)
    assert {:error, :maintenance_active} = Authority.pairing_setup_context(c.authority)
    assert {:error, :maintenance_active} = Authority.pairing_approve(c.authority, admin, ref)
    assert :ok = Authority.pairing_close(c.authority, admin)
    assert {:error, :maintenance_active} = Authority.pairing_open(c.authority, c.template)

    assert {:ok, _} =
             SQL.query(db(c.store), "UPDATE meta SET value=-1 WHERE key='maintenance_revision'")

    assert {:error, :corrupt_maintenance} = Authority.pairing_setup_context(c.authority)
    refute :sys.get_state(c.store).writable
    assert {:error, :store_unavailable} = Authority.pairing_setup_context(c.authority)
  end

  test "retired authority and damaged controller history cannot open or approve", c do
    {admin, _, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, transfer, 1} = Authority.provision_transfer(c.authority)
    assert {:ok, manager, 2} = Authority.provision_maintenance(c.authority)

    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, manager, 1, "maint:pairing:retire", 2)

    assert {:ok, _} =
             Store.retire_controller(c.store, transfer, %{
               "authority_epoch" => 1,
               "operation_id" => "retire:pairing",
               "expected_revision" => barrier.revision,
               "destination_owner_id" => String.duplicate("a", 64)
             })

    assert {:error, :source_retired} = Authority.pairing_setup_context(c.authority)
    assert {:error, :source_retired} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:error, :source_retired} = Authority.pairing_open(c.authority, c.template)
    assert :ok = Authority.pairing_close(c.authority, admin)

    assert {:ok, _} =
             SQL.query(db(c.store), "UPDATE controller_identity SET owner_id=?", [
               String.duplicate("f", 64)
             ])

    assert {:error, :corrupt_controller_history} = Authority.pairing_setup_context(c.authority)
  end

  test "invalid public setup identity cannot reopen a chosen invitation or secret", c do
    assert {:ok, scope} = Authority.pairing_setup_context(c.authority)

    for template <- [
          nil,
          %{},
          Map.put(c.template, "invitation_id", id(1)),
          Map.put(c.template, "bootstrap_secret", "chosen"),
          Map.put(c.template, "trust_anchor", "YWJj"),
          Map.put(c.template, "endpoint", ["ipv4", "127.0.0.1", 443])
        ] do
      assert {:error, :pairing_unavailable} = PairingReview.open(c.reviews, template, scope)
    end

    for duration <- [0, -1, 300_001, nil, 1.0] do
      assert {:error, :pairing_unavailable} =
               PairingReview.open(c.reviews, c.template, scope, duration)
    end

    assert :sys.get_state(c.reviews).window == nil
  end

  test "standard OTP status and pending summaries exclude secret custody", c do
    {admin, invitation, request} = open(c)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)
    assert {:ok, rows} = Authority.pairing_pending(c.authority, admin)
    summaries = :erlang.term_to_binary(rows)
    state = :erlang.term_to_binary(:sys.get_state(c.reviews))

    for secret <- [
          invitation["bootstrap_secret"],
          Base.url_decode64!(invitation["bootstrap_secret"], padding: false)
        ] do
      assert :binary.match(summaries, secret) == :nomatch
      assert :binary.match(state, secret) == :nomatch
    end

    status = inspect(:sys.get_status(c.reviews), limit: :infinity)
    assert status =~ "private_controller_pairing_review"
    refute status =~ invitation["bootstrap_secret"]
    refute status =~ request["client_label"]
  end

  defp open(c, duration \\ 300_000) do
    assert {:ok, admin, invitation} = Authority.pairing_open(c.authority, c.template, duration)
    {admin, invitation, request(invitation)}
  end

  defp request(invitation),
    do:
      Peer.request()
      |> Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)))

  defp id(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")
  defp db(store), do: :sys.get_state(store).db

  defp worker(reviews, request) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {self(), {:offer, PairingReview.offer(reviews, request)}})
        worker_loop(parent, reviews, request)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp worker_loop(parent, reviews, request) do
    receive do
      :checkout ->
        send(parent, {self(), {:checkout, PairingReview.checkout(reviews, request)}})
        worker_loop(parent, reviews, request)

      {:finish, ref} ->
        send(parent, {self(), {:finish, PairingReview.finish(reviews, ref)}})
        worker_loop(parent, reviews, request)

      notice ->
        send(parent, {self(), {:notice, notice}})
        worker_loop(parent, reviews, request)
    end
  end

  defp kill(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
  end

  # Simulate delayed monitor delivery without changing the approval or owner
  # liveness. The next ordinary guard must inspect the actual dead PID itself.
  defp delay_down(reviews, pid, monitor) do
    :sys.replace_state(reviews, fn state ->
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> state
      after
        1_000 -> raise "fixture monitor was not delivered"
      end
    end)
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
