defmodule WotexHome.LifxEnrollmentAPITest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, Transport}
  alias WotexHome.LocalAPI.{Frame, Server}
  alias WotexHome.Semantics.Observation

  @profile_ref "lifx.product-27:1.0.0"
  @thing_id "light:bedroom"

  defmodule ScriptedTransport do
    @moduledoc false

    @behaviour Transport

    @impl true
    def send(handle, _endpoint, packet) do
      pending = Process.get(:enrollment_api_packets, [])
      Process.put(:enrollment_api_packets, pending ++ [{handle, packet}])
      :ok
    end

    @impl true
    def recv(_handle, _timeout_ms) do
      case Process.get(:enrollment_api_packets, []) do
        [{handle, packet} | rest] ->
          Process.put(:enrollment_api_packets, rest)

          case packet_type(packet) do
            2 ->
              target =
                if handle == :wrong_identity,
                  do: <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x38>>,
                  else: <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

              {:ok, "192.168.1.10:56700", response(packet, 3, <<1, 56_700::little-32>>, target)}

            32 ->
              {:ok, "192.168.1.10:56700",
               response(packet, 33, <<1::little-32, 27::little-32, 0::32>>)}

            14 ->
              {:ok, "192.168.1.10:56700",
               response(
                 packet,
                 15,
                 <<1_700_000_000::little-64, 0::64, 60::little-16, 3::little-16>>
               )}

            101 ->
              {:ok, "192.168.1.10:56700", response(packet, 107, light_state())}

            _ ->
              {:error, :unexpected_request}
          end

        [] ->
          {:error, :timeout}
      end
    end

    defp packet_type(<<_::binary-size(32), type::little-16, _::binary>>), do: type

    defp light_state do
      <<0::little-16, 0::little-16, 65_535::little-16, 3_500::little-16, 0::16, 65_535::little-16,
        "Bedroom", 0::size(25)-unit(8), 0::64>>
    end

    defp response(request, type, payload, selected_target \\ nil) do
      <<_::binary-size(4), source::little-32, target::binary-size(6), _::binary-size(9),
        sequence::8, _::binary>> = request

      target = selected_target || target
      size = 36 + byte_size(payload)

      <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
        sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
    end
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "woh-enrollment-api-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    store =
      start_supervised!(
        Supervisor.child_spec({Store, path: Path.join(directory, "home.sqlite")},
          restart: :temporary
        )
      )

    assert {:ok, reviewer, 1} =
             Store.provision_principal(store, "operator:1", ["enroll:review"], [])

    assert {:ok, other, 2} =
             Store.provision_principal(store, "operator:2", ["enroll:review"], [])

    {:ok,
     store: store,
     path: Path.join(directory, "home.sqlite"),
     reviewer: encode(reviewer),
     other: encode(other)}
  end

  test "one-use host evidence and packaged data are the only enrollment inputs", context do
    {authority, capture} = authority(context.store)
    on_exit(fn -> if Process.alive?(capture), do: GenServer.stop(capture) end)

    {session_ref, candidate_ref} = complete_capture(authority, context.reviewer)
    request = enrollment_request(context.reviewer, session_ref, candidate_ref, "review:initial")

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             Server.route(authority, Map.put(request, "candidate", %{}))

    assert %{"outcome" => "error", "reason" => "capture_missing"} =
             Server.route(authority, %{request | "credential" => context.other})

    assert %{"outcome" => "error", "reason" => "unsupported_profile"} =
             Server.route(authority, %{request | "profile_ref" => "lifx.caller:1"})

    assert %{
             "outcome" => "ok",
             "enrollment_commit" => %{
               "mode" => "enroll",
               "review_ref" => "review:initial",
               "thing_id" => @thing_id,
               "profile_ref" => @profile_ref,
               "revision" => 3,
               "catalogue_digest" => digest
             }
           } = route_frame(authority, request)

    assert byte_size(digest) == 64

    assert %{"outcome" => "error", "reason" => "capture_missing"} =
             Server.route(authority, request)

    assert %{
             "outcome" => "ok",
             "enrollment_review" => %{
               "state" => "current",
               "thing_id" => @thing_id,
               "review_revision" => 3,
               "binding_revision" => 3
             }
           } =
             Server.route(authority, %{
               "api_version" => 1,
               "operation" => "enrollment_status",
               "credential" => context.reviewer,
               "review_ref" => "review:initial"
             })
  end

  test "a fresh host capture can re-review only the same enrolled declaration", context do
    {initial_authority, initial_capture} = authority(context.store)
    {session_ref, candidate_ref} = complete_capture(initial_authority, context.reviewer)

    assert %{"outcome" => "ok"} =
             Server.route(
               initial_authority,
               enrollment_request(context.reviewer, session_ref, candidate_ref, "review:initial")
             )

    :ok = GenServer.stop(initial_capture)

    {next_authority, next_capture} = authority(context.store)
    on_exit(fn -> if Process.alive?(next_capture), do: GenServer.stop(next_capture) end)
    {next_session, next_candidate} = complete_capture(next_authority, context.reviewer)

    request =
      enrollment_request(context.reviewer, next_session, next_candidate, "review:fresh")
      |> Map.put("operation", "lifx_rereview")

    assert %{
             "outcome" => "ok",
             "enrollment_commit" => %{
               "mode" => "rereview",
               "revision" => 4,
               "review_ref" => "review:fresh"
             }
           } = Server.route(next_authority, request)

    assert %{"enrollment_review" => %{"state" => "superseded"}} =
             enrollment_status(next_authority, context.reviewer, "review:initial")

    assert %{"enrollment_review" => %{"state" => "current", "binding_revision" => 4}} =
             enrollment_status(next_authority, context.reviewer, "review:fresh")
  end

  test "a granted controller refreshes only the enrolled stable identity", context do
    {authority, capture} = authority(context.store)
    on_exit(fn -> if Process.alive?(capture), do: GenServer.stop(capture) end)

    {session_ref, candidate_ref} = complete_capture(authority, context.reviewer)

    assert %{"outcome" => "ok"} =
             Server.route(
               authority,
               enrollment_request(context.reviewer, session_ref, candidate_ref, "review:refresh")
             )

    assert {:ok, controller, 4} =
             Store.provision_principal(
               context.store,
               "controller:1",
               ["read", "control:ordinary"],
               [@thing_id]
             )

    assert {:ok, basis} =
             Store.lifx_refresh_basis(context.store, controller, @thing_id)

    assert {:ok, stale_report} =
             Observation.new(
               %{
                 "thing_id" => @thing_id,
                 "capability_key" => "power",
                 "value" => %{"type" => "boolean", "value" => false},
                 "quality" => "reported",
                 "trust" => "unauthenticated_local",
                 "source_epoch" => "boot:stale",
                 "source_sequence" => 0,
                 "boot_epoch" => "boot:stale",
                 "source_time_utc_ms" => nil,
                 "received_time_utc_ms" => 1,
                 "received_monotonic_ms" => 1
               },
               basis.thing.capabilities["power"]
             )

    assert {:ok, replacement, 5} =
             Store.rotate_principal_credential(context.store, "controller:1")

    assert {:error, :unauthorized} =
             Store.commit_lifx_refresh(
               context.store,
               controller,
               basis.stable_id,
               basis.binding_revision,
               basis.resource_revision,
               basis.thing,
               [stale_report]
             )

    assert {:ok, stale_binding_basis} =
             Store.lifx_refresh_basis(context.store, replacement, @thing_id)

    {rereview_session, rereview_candidate} = complete_capture(authority, context.reviewer)

    assert %{"outcome" => "ok", "enrollment_commit" => %{"revision" => 6}} =
             enrollment_request(
               context.reviewer,
               rereview_session,
               rereview_candidate,
               "review:refresh-2"
             )
             |> Map.put("operation", "lifx_rereview")
             |> then(&Server.route(authority, &1))

    assert {:error, :stale_refresh_basis} =
             Store.commit_lifx_refresh(
               context.store,
               replacement,
               stale_binding_basis.stable_id,
               stale_binding_basis.binding_revision,
               stale_binding_basis.resource_revision,
               stale_binding_basis.thing,
               [stale_report]
             )

    request = %{
      "api_version" => 1,
      "operation" => "lifx_refresh",
      "credential" => encode(replacement),
      "thing_id" => @thing_id
    }

    assert %{
             "outcome" => "error",
             "reason" => "unsupported_operation_or_fields"
           } = Server.route(authority, Map.put(request, "endpoint", "192.168.1.99:56700"))

    assert %{"outcome" => "error", "reason" => "permission_denied"} =
             Server.route(authority, %{request | "credential" => context.reviewer})

    assert %{
             "outcome" => "ok",
             "lifx_refresh" => %{
               "thing_id" => @thing_id,
               "disposition" => "ok",
               "capability_keys" => ["power"],
               "revisions" => [7]
             }
           } = route_frame(authority, request)

    assert {:ok, observation, 7} = Store.current(context.store, @thing_id, "power")
    assert observation.value.data == true
    assert observation.trust == "unauthenticated_local"
    {:ok, receipt_db} = Exqlite.Sqlite3.open(context.path, mode: :readonly)

    {:ok, [[7, receipt_epoch, receipt_ms]]} =
      WotexHome.Durable.Store.SQL.query(
        receipt_db,
        "SELECT revision, received_store_boot_epoch, received_store_monotonic_ms FROM observation_current"
      )

    assert receipt_epoch == :sys.get_state(context.store).clock_epoch and is_integer(receipt_ms)

    {:ok, [[7, ^receipt_epoch, ^receipt_ms]]} =
      WotexHome.Durable.Store.SQL.query(
        receipt_db,
        "SELECT revision, received_store_boot_epoch, received_store_monotonic_ms FROM journal WHERE revision=7"
      )

    assert :ok = Store.validate_snapshot(receipt_db)
    :ok = Exqlite.Sqlite3.close(receipt_db)

    assert %{"outcome" => "ok", "capture" => %{}} =
             Server.route(authority, %{
               "api_version" => 1,
               "operation" => "lifx_discover",
               "credential" => context.reviewer
             })

    assert %{"outcome" => "error", "reason" => "capture_busy"} =
             Server.route(authority, request)

    assert {:ok, _unchanged, 7} = Store.current(context.store, @thing_id, "power")

    :ok = GenServer.stop(capture)
    {wrong_authority, wrong_capture} = authority(context.store, :wrong_identity)
    on_exit(fn -> if Process.alive?(wrong_capture), do: GenServer.stop(wrong_capture) end)

    assert %{"outcome" => "error", "reason" => "device_unavailable"} =
             Server.route(wrong_authority, request)

    assert {:ok, _unchanged, 7} = Store.current(context.store, @thing_id, "power")
    :ok = GenServer.stop(wrong_capture)

    {restarted_authority, restarted_capture} = authority(context.store)
    on_exit(fn -> if Process.alive?(restarted_capture), do: GenServer.stop(restarted_capture) end)

    assert %{
             "outcome" => "ok",
             "lifx_refresh" => %{"disposition" => "ok", "revisions" => [8]}
           } = Server.route(restarted_authority, request)

    assert {:ok, restarted_observation, 8} =
             Store.current(context.store, @thing_id, "power")

    assert restarted_observation.source_epoch != observation.source_epoch
    assert restarted_observation.source_sequence == 0
  end

  defp authority(store, transport_handle \\ :fixture) do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)

    assert {:ok, capture} =
             CaptureSession.start_link(
               interface_id: "en0",
               scope: scope,
               transport: {ScriptedTransport, transport_handle}
             )

    {Authority.new(store: store, capture: capture, review_gate: nil), capture}
  end

  defp complete_capture(authority, credential) do
    assert %{
             "outcome" => "ok",
             "capture" => %{
               "session_ref" => session_ref,
               "candidates" => [%{"candidate_ref" => candidate_ref}]
             }
           } =
             Server.route(authority, %{
               "api_version" => 1,
               "operation" => "lifx_discover",
               "credential" => credential
             })

    assert %{
             "outcome" => "ok",
             "interview" => %{
               "candidate_ref" => ^candidate_ref,
               "packaged_profiles" => [
                 %{
                   "profile_ref" => @profile_ref,
                   "capability_keys" => ["power"],
                   "qualification_status" => "pending_physical_evidence"
                 }
               ]
             }
           } =
             Server.route(authority, %{
               "api_version" => 1,
               "operation" => "lifx_interview",
               "credential" => credential,
               "session_ref" => session_ref,
               "candidate_ref" => candidate_ref
             })

    {session_ref, candidate_ref}
  end

  defp enrollment_request(credential, session_ref, candidate_ref, review_ref) do
    %{
      "api_version" => 1,
      "operation" => "lifx_enroll",
      "credential" => credential,
      "session_ref" => session_ref,
      "candidate_ref" => candidate_ref,
      "profile_ref" => @profile_ref,
      "thing_id" => @thing_id,
      "review_ref" => review_ref
    }
  end

  defp enrollment_status(authority, credential, review_ref) do
    Server.route(authority, %{
      "api_version" => 1,
      "operation" => "enrollment_status",
      "credential" => credential,
      "review_ref" => review_ref
    })
  end

  defp route_frame(authority, request) do
    assert {:ok, request_frame} = Frame.encode_request(request)

    assert {:ok, <<size::unsigned-big-32, body::binary-size(size)>>} =
             Server.route_frame(authority, request_frame)

    assert {:ok, response} = Frame.decode_response(body)
    response
  end

  defp encode(credential), do: Base.url_encode64(credential, padding: false)
end
