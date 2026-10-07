defmodule WotexHome.AuthorityProfileReviewTest do
  use ExUnit.Case

  alias WotexHome.Authority
  alias WotexHome.Discovery.{Candidate, Interview}
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, ProfileCatalogue, Transport}
  alias WotexHome.Profiles.{Custody, ReviewSession}

  defmodule Peer do
    @behaviour Transport
    @impl true
    def send(_, _, request) do
      <<_::binary-size(4), source::little-32, target::binary-size(6), _::binary-size(9),
        sequence::8, _::64, type::little-16, _::16, _::binary>> = request

      serial = <<0xD0, 0x73, 0xD5, 0, 0, 1>>

      {reply_type, payload} =
        case type do
          2 -> {3, <<1, 56_700::little-32>>}
          32 -> {33, <<1::little-32, 22::little-32, 0::32>>}
          14 -> {15, <<1_700_000_000::little-64, 0::64, 22::little-16, 1::little-16>>}
        end

      target = if type == 2, do: serial, else: target
      size = 36 + byte_size(payload)

      reply =
        <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48,
          0::8, sequence::8, 0::64, reply_type::little-16, 0::16, payload::binary>>

      Process.put(:profile_review_peer, Process.get(:profile_review_peer, []) ++ [reply])
      :ok
    end

    @impl true
    def recv(_, _) do
      case Process.get(:profile_review_peer, []) do
        [reply | rest] ->
          Process.put(:profile_review_peer, rest)
          {:ok, "192.0.2.10:56700", reply}

        [] ->
          {:error, :timeout}
      end
    end
  end

  setup do
    temporary = System.tmp_dir!()

    temporary =
      if String.starts_with?(temporary, "/var/"), do: "/private" <> temporary, else: temporary

    directory =
      Path.join(temporary, "woh-profile-review-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    root = Path.join(directory, "profiles")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    custody = start_supervised!({Custody, root: root})

    store =
      start_supervised!(
        {Store, path: Path.join(directory, "home.sqlite"), profile_custody: custody}
      )

    {:ok, operator, _} =
      Store.provision_principal(store, "operator:review", ["profile:manage", "enroll:review"], [])

    {:ok, manager, _} = Store.provision_principal(store, "manager:review", ["profile:manage"], [])

    {:ok, maintainer, _} =
      Store.provision_principal(store, "maintainer:review", ["host:maintain"], [])

    {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:fixture")

    {:ok, candidate} =
      Candidate.new(%{
        "interface_id" => "en0",
        "transport" => "udp",
        "source_endpoint" => "192.0.2.10:56700",
        "receive_epoch" => "scan:initial",
        "received_monotonic_ms" => 10,
        "raw_ref" => "capture:initial",
        "claimed_identifiers" => %{"stable_id" => "lifx:d073d5000001"},
        "trust_class" => "untrusted_network"
      })

    {:ok, interview} =
      Interview.new(
        %{
          "candidate_ref" => candidate.raw_ref,
          "transport" => "udp",
          "manufacturer" => "lifx.vendor.1",
          "model" => "lifx.product.22",
          "firmware" => "1.22",
          "stable_id" => "lifx:d073d5000001"
        },
        candidate
      )

    selection = %{
      "operator_id" => "operator:review",
      "candidate_ref" => candidate.raw_ref,
      "stable_id" => interview.stable_id,
      "profile_ref" => package.thing.profile_ref,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:initial"
    }

    {:ok, binding_revision} =
      Store.commit_enrollment(
        store,
        operator,
        [candidate],
        interview,
        [package.profile],
        package.thing,
        selection
      )

    {:ok, scope} = IPv4Scope.new({192, 0, 2, 2}, 24)

    capture =
      start_supervised!(
        {CaptureSession, interface_id: "en0", scope: scope, transport: {Peer, :fixture}}
      )

    authority = Authority.new(store: store, profile_custody: custody, capture: capture)

    {:ok, digest} =
      Authority.stage_profile(
        authority,
        operator,
        File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))
      )

    {:ok, revision} = Store.revision(store)

    {:ok, _} =
      Authority.begin_maintenance(authority, maintainer, 1, "maintenance:review", revision)

    {:ok, revision} = Store.revision(store)

    {:ok, receipt} =
      Authority.profile_change(authority, operator, %{
        "action" => "approve",
        "authority_epoch" => 1,
        "operation_id" => "approval:review",
        "expected_revision" => revision,
        "artifact_digest" => digest,
        "expected_trust_revision" => 0
      })

    %{
      store: store,
      authority: authority,
      operator: operator,
      manager: manager,
      maintainer: maintainer,
      digest: digest,
      receipt: receipt,
      binding_revision: binding_revision,
      root: root,
      capture: capture
    }
  end

  test "fresh host evidence produces a bounded proposal without changing durable state", c do
    {input, session} = captured_input(c)
    {:ok, before_revision} = Store.revision(c.store)
    assert {:ok, review} = Authority.review_profile_selection(c.authority, c.operator, input)
    assert review.summary.current_profile_ref == "lifx.product-22:1.0.0"
    assert review.summary.proposed_profile_ref == "test.portable-light:1.0.0"
    assert review.basis["binding_revision"] == c.binding_revision
    assert review.basis["trust_revision"] == c.receipt.final_revision
    assert {:ok, ^before_revision} = Store.revision(c.store)

    assert {:error, :capture_missing} =
             CaptureSession.checkout_auto(c.capture, "operator:review", session)

    assert {:error, :profile_selection_unavailable} =
             Authority.profile_change(c.authority, c.operator, input)
  end

  test "pending preparation retry returns its original token without consuming another capture",
       c do
    reviews = start_supervised!({ReviewSession, custody: c.authority.profile_custody})
    authority = %{c.authority | profile_reviews: reviews}
    {input, session} = captured_input(c)
    {:ok, revision} = Store.revision(c.store)
    assert {:ok, held} = Authority.prepare_profile_selection(authority, c.operator, input)
    assert {:ok, again} = Authority.prepare_profile_selection(authority, c.operator, input)
    assert held.review_token == again.review_token
    assert again.remaining_ms <= held.remaining_ms

    assert {:error, :capture_missing} =
             CaptureSession.checkout_auto(c.capture, "operator:review", session)

    assert {:ok, ^revision} = Store.revision(c.store)
    assert :ok = ReviewSession.cancel(reviews, "operator:review", held.review_token)

    assert {:error, :profile_review_consumed} =
             Authority.prepare_profile_selection(authority, c.operator, input)
  end

  test "management alone cannot consume enrollment evidence", c do
    {input, session} = captured_input(c)

    assert {:error, :permission_denied} =
             Authority.review_profile_selection(c.authority, c.manager, input)

    assert {:ok, _} = CaptureSession.checkout_auto(c.capture, "operator:review", session)
  end

  test "a changed global basis is rejected before capture consumption", c do
    {input, session} = captured_input(c)
    assert {:ok, _, _} = Store.provision_principal(c.store, "reader:later", ["read"], [])

    assert {:error, :resnapshot_required} =
             Authority.review_profile_selection(c.authority, c.operator, input)

    assert {:ok, _} = CaptureSession.checkout_auto(c.capture, "operator:review", session)
  end

  test "all selection CAS fields fail closed on the actual Store boundary", c do
    input = input(c, "session:fixture", "capture:fixture")

    for {key, expected} <- [
          {"authority_epoch", :stale_authority_epoch},
          {"expected_trust_revision", :profile_trust_changed},
          {"expected_policy_generation", :profile_policy_changed},
          {"expected_resource_revision", :stale_resource_revision},
          {"expected_binding_revision", :stale_binding_revision},
          {"expected_selection_generation", :profile_selection_changed},
          {"expected_rule_generation", :stale_rule_generation}
        ] do
      assert {:error, ^expected} =
               Store.profile_selection_basis(
                 c.store,
                 c.operator,
                 Map.update!(input, key, &(&1 + 1))
               )
    end
  end

  test "missing approved bytes do not consume the one-use capture", c do
    {input, session} = captured_input(c)
    File.rm!(Path.join(c.root, c.digest <> ".json"))

    assert {:error, :profile_artifact_unavailable} =
             Authority.review_profile_selection(c.authority, c.operator, input)

    assert {:ok, _} = CaptureSession.checkout_auto(c.capture, "operator:review", session)
  end

  test "maintenance end leaves the catalogue inert and denies selection review", c do
    input = input(c, "session:fixture", "capture:fixture")

    {:ok, %{begin_revision: begin_revision}} =
      Authority.maintenance_status(c.authority, c.maintainer)

    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.end_maintenance(
               c.authority,
               c.maintainer,
               1,
               "maintenance:end:review",
               revision,
               begin_revision
             )

    input = input(c, input["session_ref"], input["candidate_ref"])

    assert {:error, :maintenance_required} =
             Store.profile_selection_basis(c.store, c.operator, input)
  end

  defp captured_input(c) do
    {:ok, session, [%{raw_ref: candidate}]} =
      Authority.lifx_discover(c.authority, c.operator)

    {:ok, _, _} = Authority.lifx_interview(c.authority, c.operator, session, candidate)
    {input(c, session, candidate), session}
  end

  defp input(c, session, candidate) do
    {:ok, %{store_revision: revision, policy_generation: policy}} =
      Authority.profile_catalogue(c.authority, c.operator)

    {:ok, %{rule_generation: generation}} = Store.health(c.store)

    %{
      "action" => "select",
      "authority_epoch" => 1,
      "operation_id" => "selection:review",
      "expected_revision" => revision,
      "artifact_digest" => c.digest,
      "expected_trust_revision" => c.receipt.final_revision,
      "target_id" => "light:fixture",
      "expected_resource_revision" => 0,
      "expected_binding_revision" => c.binding_revision,
      "expected_selection_generation" => 0,
      "expected_policy_generation" => policy,
      "expected_rule_generation" => generation,
      "session_ref" => session,
      "candidate_ref" => candidate,
      "review_ref" => "review:portable"
    }
  end
end
