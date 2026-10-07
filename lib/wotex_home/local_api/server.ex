defmodule WotexHome.LocalAPI.Server do
  @moduledoc """
  Opt-in, private Unix socket for the local Home authority.

  Every connection carries one versioned length-framed JSON request. The wire
  exposes no provisioning, raw database or driver operation.
  The caller supplies a high-entropy credential issued by trusted local
  provisioning; the application authority derives its principal and policy
  from durable state.

  Start this server only under the opted-in `WotexHome.Host`. It checks the
  same-user peer, decodes one bounded frame, asks `WotexHome.Authority` for the
  requested read or held mutation, and closes the connection. With a separately enabled
  LIFX capture owner, an enrollment reviewer can request bounded discovery,
  identity interview and one-use enrollment through immutable host-packaged
  profile data. The caller cannot submit captured evidence or declarations.
  This server has no profile-qualification or device-command route.
  """

  use GenServer
  import Bitwise

  alias WotexHome.Authority
  alias WotexHome.Authority.ReviewGate
  alias WotexHome.Durable.Receipt
  alias WotexHome.LocalAPI.Frame
  alias WotexHome.LocalAPI.PeerIdentity
  alias WotexHome.Profiles.Wire

  @max_request_bytes 65_536
  @request_timeout_ms 5_000
  @review_timeout_ms 10_000
  @max_connections 32
  @mutation_operations [
    "submit",
    "cancel",
    "override_issue",
    "override_revoke",
    "record_rule_review",
    "admit_rule",
    "activate_rule",
    "begin_maintenance",
    "end_maintenance",
    "invoke_rule",
    "lifx_enroll",
    "lifx_rereview",
    "lifx_refresh",
    "profile_import",
    "profile_prepare",
    "profile_change",
    "profile_review_cancel",
    "profiles_collect"
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Execute one already-decoded request through the same adapter mapping used by
  the socket worker.

  This is the deterministic contract seam for hosts that cannot create local
  sockets (for example restricted build sandboxes). It performs no peer check
  and therefore is not an external endpoint.
  """
  @spec route(Authority.t(), map()) :: map()
  def route(%Authority{} = authority, %{"operation" => operation} = request)
      when operation in ["review_rules", "record_rule_review", "admit_rule"],
      do: dispatch_review(authority, request)

  def route(%Authority{} = authority, request) when is_map(request),
    do: dispatch(authority, request)

  @doc "Decode and encode one complete frame without opening a socket."
  @spec route_frame(Authority.t(), binary()) ::
          {:ok, binary()} | {:error, :response_too_large}
  def route_frame(%Authority{} = authority, <<size::unsigned-big-32, body::binary>>)
      when size == byte_size(body) do
    response =
      cond do
        size == 0 ->
          error(:invalid_request)

        size > @max_request_bytes ->
          error(:request_too_large)

        true ->
          case Frame.decode_request(body) do
            {:ok, request} -> route(authority, request)
            {:error, reason} -> error(reason)
          end
      end

    Frame.encode_response(response)
  end

  def route_frame(%Authority{}, _frame),
    do: Frame.encode_response(error(:invalid_request))

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :socket_path)

    with {:ok, authority, owned_review_gate} <- authority(opts),
         owner when is_pid(owner) <- Authority.owner(authority),
         true <- is_binary(path) and byte_size(path) > 0 and byte_size(path) <= 100,
         :ok <- private_directory(Path.dirname(path)),
         :ok <- stale_socket(path),
         {:ok, listener, owner_uid} <- open_listener(path) do
      Process.flag(:trap_exit, true)

      {acceptor, acceptor_ref} =
        spawn_monitor(fn -> accept_loop(listener, authority, owner_uid) end)

      owner_ref = Process.monitor(owner)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         acceptor_ref: acceptor_ref,
         owner_ref: owner_ref,
         owned_review_gate: owned_review_gate,
         path: path,
         authority: authority
       }}
    else
      false -> {:stop, :invalid_local_api_config}
      nil -> {:stop, :invalid_local_api_config}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp authority(opts) do
    authority =
      case Keyword.get(opts, :authority) do
        %Authority{} = authority -> authority
        nil -> Authority.new(store: Keyword.get(opts, :store))
        _ -> nil
      end

    case authority do
      %Authority{review_gate: nil} = authority ->
        case ReviewGate.start_link(limit: 2) do
          {:ok, gate} -> {:ok, Authority.with_review_gate(authority, gate), gate}
          {:error, reason} -> {:error, reason}
        end

      %Authority{} = authority ->
        {:ok, authority, nil}

      _ ->
        {:error, :invalid_local_api_config}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{acceptor_ref: ref} = state),
    do: {:stop, :listener_failed, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listener)
    Process.exit(state.acceptor, :shutdown)

    if is_pid(state.owned_review_gate) and Process.alive?(state.owned_review_gate),
      do: GenServer.stop(state.owned_review_gate, :normal)

    _ = File.rm(state.path)
    :ok
  end

  defp open_listener(path) do
    case :gen_tcp.listen(0, [
           :binary,
           {:ifaddr, {:local, String.to_charlist(path)}},
           {:active, false},
           {:backlog, 32}
         ]) do
      {:ok, listener} ->
        case {File.chmod(path, 0o600), File.lstat(path)} do
          {:ok, {:ok, %{type: :other, uid: uid, mode: mode}}}
          when is_integer(uid) and uid >= 0 and (mode &&& 0o170000) == 0o140000 and
                 (mode &&& 0o777) == 0o600 ->
            {:ok, listener, uid}

          _ ->
            _ = :gen_tcp.close(listener)
            _ = File.rm(path)
            {:error, :invalid_socket_path}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp private_directory(directory) do
    case File.lstat(directory) do
      {:error, :enoent} ->
        case File.mkdir(directory) do
          :ok ->
            case File.chmod(directory, 0o700) do
              :ok ->
                :ok

              _ ->
                _ = File.rmdir(directory)
                {:error, :invalid_socket_directory}
            end

          _ ->
            {:error, :invalid_socket_directory}
        end

      {:ok, stat} ->
        if stat.type == :directory and (stat.mode &&& 0o777) == 0o700,
          do: :ok,
          else: {:error, :invalid_socket_directory}

      _ ->
        {:error, :invalid_socket_directory}
    end
  end

  defp stale_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} when (stat.mode &&& 0o170000) == 0o140000 ->
        case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary], 100) do
          {:ok, socket} ->
            _ = :gen_tcp.close(socket)
            {:error, :already_running}

          {:error, _} ->
            case File.rm(path) do
              :ok -> :ok
              _ -> {:error, :invalid_socket_path}
            end
        end

      _ ->
        {:error, :invalid_socket_path}
    end
  end

  defp accept_loop(listener, authority, owner_uid) do
    Process.flag(:trap_exit, true)
    accept_loop(listener, authority, owner_uid, MapSet.new())
  end

  defp accept_loop(listener, authority, owner_uid, workers) do
    workers = drain_workers(workers)

    if MapSet.size(workers) >= @max_connections do
      receive do
        {:EXIT, worker, _reason} ->
          accept_loop(listener, authority, owner_uid, MapSet.delete(workers, worker))
      end
    else
      case :gen_tcp.accept(listener, 1_000) do
        {:ok, socket} ->
          worker =
            spawn_link(fn ->
              receive do
                :start ->
                  handle_socket(socket, authority, owner_uid)
                  _ = :gen_tcp.close(socket)
              end
            end)

          case :gen_tcp.controlling_process(socket, worker) do
            :ok ->
              send(worker, :start)
              accept_loop(listener, authority, owner_uid, MapSet.put(workers, worker))

            {:error, _reason} ->
              Process.exit(worker, :shutdown)
              _ = :gen_tcp.close(socket)
              accept_loop(listener, authority, owner_uid, workers)
          end

        {:error, :timeout} ->
          accept_loop(listener, authority, owner_uid, workers)

        {:error, :closed} ->
          :ok

        {:error, _reason} ->
          exit(:listener_failed)
      end
    end
  end

  defp drain_workers(workers) do
    receive do
      {:EXIT, worker, _reason} -> drain_workers(MapSet.delete(workers, worker))
    after
      0 -> workers
    end
  end

  defp handle_socket(socket, authority, owner_uid) do
    if PeerIdentity.verify(socket, owner_uid) == :ok,
      do: handle_verified_socket(socket, authority)
  end

  defp handle_verified_socket(socket, authority) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout_ms

    response =
      with {:ok, <<size::unsigned-big-32>>} <- :gen_tcp.recv(socket, 4, remaining(deadline)),
           true <- size > 0 and size <= @max_request_bytes,
           {:ok, body} <- :gen_tcp.recv(socket, size, remaining(deadline)),
           {:ok, request} <- Frame.decode_request(body) do
        dispatch_with_deadline(authority, request, deadline)
      else
        false -> error(:request_too_large)
        {:error, reason} when is_atom(reason) -> error(reason)
        _ -> error(:invalid_request)
      end

    _ = :inet.setopts(socket, send_timeout: 1_000)

    case Frame.encode_response(response) do
      {:ok, frame} -> :gen_tcp.send(socket, frame)
      {:error, _} -> :gen_tcp.send(socket, <<0, 0, 0, 0>>)
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp dispatch_with_deadline(authority, request, ordinary_deadline) do
    deadline =
      if request["operation"] in ["review_rules", "record_rule_review", "admit_rule"],
        do: System.monotonic_time(:millisecond) + @review_timeout_ms,
        else: ordinary_deadline

    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        response = route(authority, request)

        send(parent, {:dispatch_result, self(), response})
      end)

    receive do
      {:dispatch_result, ^worker, response} ->
        Process.demonitor(monitor, [:flush])
        response

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        if request["operation"] in @mutation_operations,
          do: error(:outcome_unknown),
          else: error(:operation_unavailable)
    after
      remaining(deadline) ->
        Process.exit(worker, :kill)

        if request["operation"] in @mutation_operations,
          do: error(:outcome_unknown),
          else: error(:request_timeout)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "rule_review_status",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation_id
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.rule_review_status(authority, credential, epoch, operation_id) do
      ok(%{"rule_review_receipt" => stringify_keys(receipt)})
    else
      {:error, :rule_review_not_found} -> %{"api_version" => 1, "outcome" => "not_found"}
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "health",
           "credential" => encoded
         } = request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, health} <- Authority.health(authority, credential) do
      ok(%{"health" => stringify_keys(health)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "controller_identity",
           "credential" => encoded
         } = request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, identity} <- Authority.controller_identity(authority, credential) do
      ok(%{"controller_identity" => stringify_keys(identity)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "lifx_refresh",
           "credential" => encoded,
           "thing_id" => thing_id
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded),
         {:ok, refresh} <- Authority.lifx_refresh(authority, credential, thing_id) do
      ok(%{
        "lifx_refresh" =>
          refresh
          |> stringify_keys()
          |> Map.update!("disposition", &Atom.to_string/1)
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => operation,
           "credential" => encoded,
           "session_ref" => session_ref,
           "candidate_ref" => candidate_ref,
           "profile_ref" => profile_ref,
           "thing_id" => thing_id,
           "review_ref" => review_ref
         } = request
       )
       when map_size(request) == 8 and operation in ["lifx_enroll", "lifx_rereview"] do
    with {:ok, credential} <- credential(encoded),
         {:ok, commit} <-
           dispatch_lifx_enrollment(
             authority,
             operation,
             credential,
             session_ref,
             candidate_ref,
             profile_ref,
             thing_id,
             review_ref
           ) do
      ok(%{
        "enrollment_commit" =>
          commit
          |> stringify_keys()
          |> Map.update!("mode", &Atom.to_string/1)
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "support_preview",
           "credential" => encoded
         } = request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, support} <- Authority.support_preview(authority, credential) do
      ok(%{"support" => support})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "enrollment_status",
           "credential" => encoded,
           "review_ref" => review_ref
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded) do
      case Authority.enrollment_status(authority, credential, review_ref) do
        {:ok, review} ->
          ok(%{
            "enrollment_review" =>
              review
              |> stringify_keys()
              |> Map.update!("state", &Atom.to_string/1)
          })

        :not_found ->
          %{"api_version" => 1, "outcome" => "not_found"}

        {:error, reason} ->
          error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{"api_version" => 1, "operation" => "lifx_discover", "credential" => encoded} =
           request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, session_ref, candidates} <- Authority.lifx_discover(authority, credential) do
      ok(%{
        "capture" => %{
          "session_ref" => session_ref,
          "candidates" =>
            Enum.map(candidates, fn candidate ->
              %{
                "candidate_ref" => candidate.raw_ref,
                "interface_id" => candidate.interface_id,
                "source_endpoint" => candidate.source_endpoint,
                "claimed_stable_id" => Map.get(candidate.claimed_identifiers, "stable_id"),
                "trust_class" => candidate.trust_class
              }
            end)
        }
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "lifx_interview",
           "credential" => encoded,
           "session_ref" => session_ref,
           "candidate_ref" => candidate_ref
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded),
         {:ok, interview, profiles} <-
           Authority.lifx_interview(authority, credential, session_ref, candidate_ref) do
      ok(%{
        "interview" => %{
          "candidate_ref" => interview.candidate_ref,
          "transport" => interview.transport,
          "manufacturer_reported" => interview.manufacturer,
          "model_reported" => interview.model,
          "firmware_reported" => interview.firmware,
          "stable_id_claim" => interview.stable_id,
          "packaged_profiles" =>
            Enum.map(profiles, fn profile ->
              profile
              |> stringify_keys()
              |> Map.update!("qualification_status", &Atom.to_string/1)
            end)
        }
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "submit",
           "credential" => encoded,
           "mutation" => input
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <- Authority.submit(authority, credential, input) do
      ok(%{"receipt" => receipt_map(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "overrides",
           "credential" => encoded,
           "target_ids" => target_ids
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded),
         {:ok, %{now_ms: now_ms, leases: leases, owned_operation_ids: owned_ids}} <-
           Authority.overrides(authority, credential, target_ids) do
      ok(%{
        "overrides" =>
          Enum.map(leases, fn lease ->
            %{
              "target_id" => lease.target_id,
              "operator_id" => lease.operator_id,
              "authority_epoch" => lease.authority_epoch,
              "basis_revision" => lease.basis_revision,
              "remaining_ms" => max(0, lease.expires_ms - now_ms),
              "operation_id" => Map.get(owned_ids, lease.target_id)
            }
          end)
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "override_issue",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation_id,
           "target_id" => target_id,
           "basis_revision" => basis_revision,
           "duration_ms" => duration_ms
         } = request
       )
       when map_size(request) == 8 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.override_issue(
             authority,
             credential,
             epoch,
             operation_id,
             target_id,
             basis_revision,
             duration_ms
           ) do
      ok(%{"override_receipt" => stringify_keys(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "override_status",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation_id
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded) do
      case Authority.override_status(authority, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"override_receipt" => stringify_keys(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "override_revoke",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation_id
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded) do
      case Authority.override_revoke(authority, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"override_receipt" => stringify_keys(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "events",
           "credential" => encoded,
           "after_revision" => after_revision,
           "page_size" => page_size
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded),
         {:ok, events} <- Authority.events(authority, credential, after_revision, page_size) do
      ok(%{"events" => stringify_keys(events)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "request_events",
           "credential" => encoded,
           "after_revision" => after_revision,
           "page_size" => page_size
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded),
         {:ok, events} <-
           Authority.request_events(authority, credential, after_revision, page_size) do
      ok(%{"request_events" => stringify_keys(events)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "history",
           "credential" => encoded,
           "thing_id" => thing_id,
           "capability_key" => capability_key,
           "watermark" => watermark,
           "after_revision" => after_revision,
           "page_size" => page_size
         } = request
       )
       when map_size(request) == 8 do
    with {:ok, credential} <- credential(encoded),
         {:ok, history} <-
           Authority.history(
             authority,
             credential,
             thing_id,
             capability_key,
             watermark,
             after_revision,
             page_size
           ) do
      ok(%{"history" => stringify_keys(history)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "catalogue",
           "credential" => encoded,
           "watermark" => watermark,
           "after" => after_id,
           "page_size" => page_size
         } = request
       )
       when map_size(request) == 6 do
    with {:ok, credential} <- credential(encoded),
         {:ok, catalogue} <-
           Authority.catalogue(authority, credential, watermark, after_id, page_size) do
      ok(%{"catalogue" => stringify_keys(catalogue)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "snapshot",
           "credential" => encoded,
           "watermark" => watermark,
           "after" => after_key,
           "page_size" => page_size
         } = request
       )
       when map_size(request) == 6 do
    with {:ok, credential} <- credential(encoded),
         {:ok, snapshot} <-
           Authority.snapshot(authority, credential, watermark, after_key, page_size) do
      ok(%{"snapshot" => stringify_keys(snapshot)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "status",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation_id
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded) do
      case Authority.request_status(authority, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"receipt" => receipt_map(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "cancel",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation_id
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded) do
      case Authority.cancel(authority, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"receipt" => receipt_map(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(_authority, %{"api_version" => version}) when version != 1,
    do: error(:unsupported_api_version)

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "activate_rule",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => expected,
           "admission_revision" => admission
         } = request
       )
       when map_size(request) == 7 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.activate_rule(authority, credential, epoch, operation, expected, admission) do
      ok(%{"rule_receipt" => stringify_keys(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "invoke_rule",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "rule_generation" => generation,
           "rule_id" => rule
         } = request
       )
       when map_size(request) == 7 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.invoke_rule(authority, credential, epoch, operation, generation, rule) do
      ok(%{"receipt" => receipt_map(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{"api_version" => 1, "operation" => "rule_status", "credential" => encoded} = request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, status} <- Authority.rule_status(authority, credential) do
      ok(%{"rule_status" => stringify_keys(status)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "rule_operation_status",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded) do
      case Authority.rule_operation_status(authority, credential, epoch, operation) do
        {:ok, receipt} -> ok(%{"rule_receipt" => stringify_keys(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "begin_maintenance",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => expected
         } = request
       )
       when map_size(request) == 6 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.begin_maintenance(authority, credential, epoch, operation, expected) do
      ok(%{"maintenance_receipt" => stringify_keys(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "end_maintenance",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => expected,
           "begin_revision" => begin_revision
         } = request
       )
       when map_size(request) == 7 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.end_maintenance(
             authority,
             credential,
             epoch,
             operation,
             expected,
             begin_revision
           ) do
      ok(%{"maintenance_receipt" => stringify_keys(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{"api_version" => 1, "operation" => "maintenance_status", "credential" => encoded} =
           request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, status} <- Authority.maintenance_status(authority, credential) do
      ok(%{"maintenance_status" => stringify_keys(status)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{
           "api_version" => 1,
           "operation" => "maintenance_operation_status",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded) do
      case Authority.maintenance_operation_status(authority, credential, epoch, operation) do
        {:ok, receipt} -> ok(%{"maintenance_receipt" => stringify_keys(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         authority,
         %{"api_version" => 1, "operation" => operation, "credential" => encoded} = request
       )
       when operation in [
              "profile_import",
              "profiles",
              "profile_target",
              "profile_prepare",
              "profile_change",
              "profile_operation_status",
              "profile_review_status",
              "profile_review_cancel",
              "profiles_collect"
            ] do
    fields =
      case operation do
        "profile_import" ->
          ["artifact_base64"]

        "profile_target" ->
          ["thing_id"]

        "profile_prepare" ->
          ["selection"]

        "profile_change" ->
          ["change"]

        "profile_operation_status" ->
          ["authority_epoch", "operation_id"]

        operation when operation in ["profile_review_status", "profile_review_cancel"] ->
          ["review_token"]

        _ ->
          []
      end

    with true <-
           Enum.sort(Map.keys(request)) ==
             Enum.sort(["api_version", "operation", "credential"] ++ fields),
         {:ok, credential} <- credential(encoded) do
      profile_result(profile_operation(authority, credential, operation, request))
    else
      false -> error(:unsupported_operation_or_fields)
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(_authority, _request), do: error(:unsupported_operation_or_fields)

  defp dispatch_lifx_enrollment(
         authority,
         "lifx_enroll",
         credential,
         session_ref,
         candidate_ref,
         profile_ref,
         thing_id,
         review_ref
       ),
       do:
         Authority.lifx_enroll(
           authority,
           credential,
           session_ref,
           candidate_ref,
           profile_ref,
           thing_id,
           review_ref
         )

  defp dispatch_lifx_enrollment(
         authority,
         "lifx_rereview",
         credential,
         session_ref,
         candidate_ref,
         profile_ref,
         thing_id,
         review_ref
       ),
       do:
         Authority.lifx_rereview(
           authority,
           credential,
           session_ref,
           candidate_ref,
           profile_ref,
           thing_id,
           review_ref
         )

  defp dispatch_review(
         authority,
         %{
           "api_version" => 1,
           "operation" => "review_rules",
           "credential" => encoded,
           "rules" => input
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded),
         {:ok, review, watermark} <- Authority.review_rules(authority, credential, input) do
      ok(%{
        "review" => %{
          "decision" => Atom.to_string(review.decision),
          "reason" => Atom.to_string(review.reason),
          "profile" => review.profile,
          "rule_digest" => review.rule_digest,
          "registry_digest" => review.registry_digest,
          "proposal_basis" => proposal_basis_map(review.proposal_basis),
          "watermark" => watermark
        }
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch_review(
         authority,
         %{
           "api_version" => 1,
           "operation" => "record_rule_review",
           "credential" => encoded,
           "rules" => rules,
           "authority_epoch" => epoch,
           "operation_id" => operation_id,
           "expected_revision" => expected
         } = request
       )
       when map_size(request) == 7 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.record_rule_review(
             authority,
             credential,
             epoch,
             operation_id,
             expected,
             rules
           ) do
      ok(%{"rule_review_receipt" => stringify_keys(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch_review(
         authority,
         %{
           "api_version" => 1,
           "operation" => "admit_rule",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => expected,
           "rules" => rules
         } = request
       )
       when map_size(request) == 7 do
    with {:ok, credential} <- credential(encoded),
         {:ok, receipt} <-
           Authority.admit_rule(authority, credential, epoch, operation, expected, rules) do
      ok(%{"rule_receipt" => stringify_keys(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch_review(authority, request), do: dispatch(authority, request)

  defp proposal_basis_map(nil), do: nil

  defp proposal_basis_map(basis) do
    %{
      "profile" => basis.profile,
      "scope" => Atom.to_string(basis.scope),
      "target_id" => basis.target_id,
      "rule_digest" => basis.rule_digest,
      "registry_digest" => basis.registry_digest,
      "runtime_digest" => basis.runtime_digest,
      "compiler_profile" => basis.compiler_profile,
      "source_digest" => basis.source_digest,
      "ir_digest" => basis.ir_digest,
      "obligations" => Enum.map(basis.obligations, &Atom.to_string/1)
    }
  end

  defp profile_operation(authority, credential, "profile_import", request) do
    with {:ok, bytes} <- Wire.decode_import(request["artifact_base64"]),
         {:ok, artifact} <- Authority.import_profile(authority, credential, bytes),
         do: {:ok, "profile_artifact", artifact}
  end

  defp profile_operation(authority, credential, "profiles", _),
    do: profile_body("profile_catalogue", Authority.profile_catalogue(authority, credential))

  defp profile_operation(authority, credential, "profile_target", request),
    do:
      profile_body(
        "profile_target",
        Authority.profile_target(authority, credential, request["thing_id"])
      )

  defp profile_operation(authority, credential, "profile_prepare", request) do
    case Authority.prepare_profile_selection(authority, credential, request["selection"]) do
      {:ok, :existing, receipt} -> {:ok, "profile_receipt", receipt}
      result -> profile_body("profile_review", result)
    end
  end

  defp profile_operation(authority, credential, "profile_change", request),
    do:
      profile_body(
        "profile_receipt",
        Authority.profile_change(authority, credential, request["change"])
      )

  defp profile_operation(authority, credential, "profile_operation_status", request),
    do:
      profile_body(
        "profile_receipt",
        Authority.profile_operation_status(
          authority,
          credential,
          request["authority_epoch"],
          request["operation_id"]
        )
      )

  defp profile_operation(authority, credential, "profile_review_status", request),
    do:
      profile_body(
        "profile_review",
        Authority.profile_review_status(authority, credential, request["review_token"])
      )

  defp profile_operation(authority, credential, "profile_review_cancel", request) do
    case Authority.cancel_profile_review(authority, credential, request["review_token"]) do
      :ok -> {:ok, "profile_review_cancelled", true}
      result -> result
    end
  end

  defp profile_operation(authority, credential, "profiles_collect", _),
    do: profile_body("profile_collection", Authority.collect_profiles(authority, credential))

  defp profile_body(key, {:ok, result}), do: {:ok, key, result}
  defp profile_body(_key, result), do: result
  defp profile_result({:ok, key, result}), do: ok(%{key => Wire.encode(result)})
  defp profile_result(:not_found), do: %{"api_version" => 1, "outcome" => "not_found"}
  defp profile_result({:error, reason}), do: error(reason)

  defp credential(encoded) when is_binary(encoded) and byte_size(encoded) <= 44 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, credential} when byte_size(credential) == 32 -> {:ok, credential}
      _ -> {:error, :invalid_credential}
    end
  end

  defp credential(_encoded), do: {:error, :invalid_credential}

  defp receipt_map(%Receipt{} = receipt) do
    %{
      "principal_id" => receipt.principal_id,
      "authority_epoch" => receipt.authority_epoch,
      "operation_id" => receipt.operation_id,
      "disposition" => Atom.to_string(receipt.disposition),
      "reason" => receipt.reason,
      "revision" => receipt.revision
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp ok(body), do: Map.merge(%{"api_version" => 1, "outcome" => "ok"}, body)

  defp error(reason),
    do: %{"api_version" => 1, "outcome" => "error", "reason" => Atom.to_string(reason)}
end
