Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))

defmodule WotexHome.PortableProfileReviewSessionTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{Custody, Operation, Review, ReviewSession}

  setup do
    c = WotexHome.Test.PortableProfileFixture.context()
    temporary = System.tmp_dir!()

    temporary =
      if String.starts_with?(temporary, "/var/"), do: "/private" <> temporary, else: temporary

    root =
      Path.join(temporary, "woh-review-session-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody = start_supervised!({Custody, root: root, store_owner: self()})
    {:ok, _} = Custody.stage(custody, c.artifact.bytes)
    {:ok, review} = Review.new(c.basis, c.artifact, c.evidence, c.input, c.runtime)
    %{custody: custody, review: review, principal: c.basis["principal_id"], context: c}
  end

  test "exact pending retry retains its token, deadline and protected bytes", c do
    owner = start_supervised!({ReviewSession, custody: c.custody})
    assert {:ok, first} = ReviewSession.hold(owner, c.principal, c.review)
    assert {:ok, again} = ReviewSession.hold(owner, c.principal, c.review)
    assert first.review_token == again.review_token and again.remaining_ms <= first.remaining_ms
    assert again.review_digest == c.review.digest
    refute Map.has_key?(again.basis, "stable_id")
    assert {:ok, %{removed_objects: 0, lease_count: count}} = inventory_collect(c.custody)
    assert count == 1
    assert :ok = ReviewSession.cancel(owner, c.principal, first.review_token)
    assert {:ok, %{removed_objects: 1}} = Custody.collect(c.custody, [])
  end

  test "status, conflict, cancellation and checkout stay principal-private", c do
    owner = start_supervised!({ReviewSession, custody: c.custody})
    {:ok, held} = ReviewSession.hold(owner, c.principal, c.review)
    assert :not_found = ReviewSession.status(owner, "operator:other", held.review_token)
    assert :not_found = ReviewSession.cancel(owner, "operator:other", held.review_token)

    assert {:error, :profile_review_missing} =
             ReviewSession.checkout(
               owner,
               "operator:other",
               held.review_token,
               c.review.input_document
             )

    assert {:error, :profile_review_conflict} =
             ReviewSession.checkout(
               owner,
               c.principal,
               held.review_token,
               c.review.input_document <> " "
             )

    assert {:ok, %{state: :pending}} = ReviewSession.status(owner, c.principal, held.review_token)

    assert {:error, :invalid_profile_review} =
             ReviewSession.hold(owner, "operator:other", c.review)
  end

  test "checkout is one-use and only its live caller can finish", c do
    owner = start_supervised!({ReviewSession, custody: c.custody})
    {:ok, held} = ReviewSession.hold(owner, c.principal, c.review)

    assert {:ok, %{review: review, deadline: deadline}} =
             ReviewSession.checkout(
               owner,
               c.principal,
               held.review_token,
               c.review.input_document
             )

    assert review == c.review and deadline <= c.review.capture_deadline

    assert {:error, :profile_review_consumed} =
             ReviewSession.checkout(
               owner,
               c.principal,
               held.review_token,
               c.review.input_document
             )

    assert {:error, :profile_review_busy} =
             ReviewSession.cancel(owner, c.principal, held.review_token)

    assert {:error, :invalid_profile_review_owner} =
             Task.async(fn -> ReviewSession.finish(owner, held.review_token) end) |> Task.await()

    assert {:ok, %{removed_objects: 0}} = Custody.collect(c.custody, [])
    assert :ok = ReviewSession.finish(owner, held.review_token)

    assert {:error, :profile_review_consumed} = ReviewSession.hold(owner, c.principal, c.review)

    assert {:error, :profile_review_missing} =
             ReviewSession.checkout(
               owner,
               c.principal,
               held.review_token,
               c.review.input_document
             )

    assert {:ok, %{removed_objects: 1}} = Custody.collect(c.custody, [])
  end

  test "pending expiry cannot renew a capture and checked-out work retains its lease", c do
    owner = start_supervised!({ReviewSession, custody: c.custody, ttl_ms: 100})
    {:ok, held} = ReviewSession.hold(owner, c.principal, c.review)
    Process.sleep(110)
    assert :not_found = ReviewSession.status(owner, c.principal, held.review_token)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    expired = %{c.context.evidence | expires_at: System.monotonic_time(:millisecond) - 1}

    {:ok, review} =
      Review.new(c.context.basis, c.context.artifact, expired, c.context.input, c.context.runtime)

    assert {:error, :profile_review_expired} = ReviewSession.hold(owner, c.principal, review)
    assert {:error, :profile_review_consumed} = ReviewSession.hold(owner, c.principal, c.review)
    review = fresh_review(c.context, "selection:after-expiry", "session:after-expiry")
    {:ok, held} = ReviewSession.hold(owner, c.principal, review)

    {:ok, _} =
      ReviewSession.checkout(owner, c.principal, held.review_token, review.input_document)

    Process.sleep(110)

    assert {:ok, %{state: :checked_out, remaining_ms: 0}} =
             ReviewSession.status(owner, c.principal, held.review_token)

    assert {:ok, %{removed_objects: 0}} = Custody.collect(c.custody, [])
    assert :ok = ReviewSession.finish(owner, held.review_token)
  end

  test "caller death releases a checked-out proposal without another effect opportunity", c do
    owner = start_supervised!({ReviewSession, custody: c.custody})
    {:ok, held} = ReviewSession.hold(owner, c.principal, c.review)

    task =
      Task.async(fn ->
        ReviewSession.checkout(owner, c.principal, held.review_token, c.review.input_document)
      end)

    assert {:ok, _} = Task.await(task)

    assert :not_found =
             await_removed(
               owner,
               c.principal,
               held.review_token,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "object and encoded-term quotas reject new proposals while exact retries work", c do
    owner = start_supervised!({ReviewSession, custody: c.custody, limit: 1})
    {:ok, held} = ReviewSession.hold(owner, c.principal, c.review)
    another = fresh_review(c.context, "selection:other", "session:other")
    assert {:error, :profile_review_capacity} = ReviewSession.hold(owner, c.principal, another)
    assert {:ok, %{review_token: token}} = ReviewSession.hold(owner, c.principal, c.review)
    assert token == held.review_token
    stop_supervised(ReviewSession)
    owner = start_supervised!({ReviewSession, custody: c.custody, max_bytes: 1})
    assert {:error, :profile_review_capacity} = ReviewSession.hold(owner, c.principal, c.review)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
  end

  test "forged proposal fields and changed canonical input fail before custody", c do
    owner = start_supervised!({ReviewSession, custody: c.custody})

    assert {:error, :invalid_profile_review} =
             ReviewSession.hold(owner, c.principal, %{
               c.review
               | digest: String.duplicate("0", 64)
             })

    {:ok, held} = ReviewSession.hold(owner, c.principal, c.review)
    ctx = c.context

    {:ok, changed} =
      Review.new(
        ctx.basis,
        ctx.artifact,
        ctx.evidence,
        Map.put(ctx.input, "review_ref", "review:changed"),
        ctx.runtime
      )

    assert {:error, :profile_review_conflict} = ReviewSession.hold(owner, c.principal, changed)

    assert {:ok, %{review_token: token}} =
             ReviewSession.status(owner, c.principal, held.review_token)

    assert token == held.review_token
    {:ok, input} = Operation.decode(c.review.input_document)
    assert input["operation_id"] == ctx.input["operation_id"]
  end

  test "review-owner restart discards pending proposals and releases all bytes", c do
    owner = start_supervised!({ReviewSession, custody: c.custody})
    {:ok, held} = ReviewSession.hold(owner, c.principal, c.review)
    stop_supervised(ReviewSession)
    owner = start_supervised!({ReviewSession, custody: c.custody})
    assert :not_found = ReviewSession.status(owner, c.principal, held.review_token)
    assert {:ok, %{lease_count: 0}} = Custody.inventory(c.custody)
    assert {:ok, %{removed_objects: 1}} = Custody.collect(c.custody, [])
  end

  defp await_removed(owner, principal, token, deadline) do
    case ReviewSession.status(owner, principal, token) do
      :not_found ->
        :not_found

      present ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          await_removed(owner, principal, token, deadline)
        else
          present
        end
    end
  end

  defp inventory_collect(custody) do
    {:ok, inventory} = Custody.inventory(custody)
    {:ok, collected} = Custody.collect(custody, [])
    {:ok, Map.merge(inventory, collected)}
  end

  defp fresh_review(ctx, operation, session) do
    input = ctx.input |> Map.put("operation_id", operation) |> Map.put("session_ref", session)

    evidence = %{
      ctx.evidence
      | ref: session,
        expires_at: System.monotonic_time(:millisecond) + 60_000
    }

    {:ok, review} = Review.new(ctx.basis, ctx.artifact, evidence, input, ctx.runtime)
    review
  end
end
