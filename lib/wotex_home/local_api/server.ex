defmodule WotexHome.LocalAPI.Server do
  @moduledoc """
  Opt-in, private Unix socket for the local Home authority.

  Every connection carries one versioned length-framed JSON request. The wire
  exposes no provisioning, raw database, rule activation or driver operation.
  The caller supplies a high-entropy credential issued by trusted local
  provisioning; the Store derives its principal and policy from durable state.

  Start this server only under the opted-in `WotexHome.Host`. It checks the
  same-user peer, decodes one bounded frame, asks the Store for the requested
  read or held mutation, and closes the connection. With a separately enabled
  LIFX capture owner, an enrollment reviewer can request bounded discovery
  and identity interview. Those responses remain untrusted device claims;
  this server has no enrollment commit or device command route.
  """

  use GenServer
  import Bitwise

  alias WotexHome.Durable.{Receipt, Store, SupportExport}
  alias WotexHome.LocalAPI.Frame
  alias WotexHome.LocalAPI.PeerIdentity
  alias WotexHome.Lifx.CaptureSession
  alias WotexHome.Mutation
  alias WotexHome.Rules.{CandidateReview, Rule}

  @max_request_bytes 65_536
  @request_timeout_ms 5_000
  @review_timeout_ms 10_000
  @max_connections 32
  @max_reviews 2

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :socket_path)
    store = resolve_store(Keyword.get(opts, :store))

    with true <- is_binary(path) and byte_size(path) > 0 and byte_size(path) <= 100,
         true <- is_pid(store) and Process.alive?(store),
         :ok <- private_directory(Path.dirname(path)),
         :ok <- stale_socket(path),
         {:ok, listener, owner_uid} <- open_listener(path) do
      Process.flag(:trap_exit, true)
      gate = self()

      {acceptor, acceptor_ref} =
        spawn_monitor(fn -> accept_loop(listener, store, gate, owner_uid) end)

      store_ref = Process.monitor(store)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         acceptor_ref: acceptor_ref,
         store_ref: store_ref,
         path: path,
         reviewers: %{}
       }}
    else
      false -> {:stop, :invalid_local_api_config}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve_store(pid) when is_pid(pid), do: pid
  defp resolve_store(name) when is_atom(name) and not is_nil(name), do: Process.whereis(name)
  defp resolve_store(_store), do: nil

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{store_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{acceptor_ref: ref} = state),
    do: {:stop, :listener_failed, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    reviewers =
      case Map.fetch(state.reviewers, pid) do
        {:ok, ^ref} -> Map.delete(state.reviewers, pid)
        _ -> state.reviewers
      end

    {:noreply, %{state | reviewers: reviewers}}
  end

  @impl true
  def handle_call(:acquire_review, {pid, _tag}, state) do
    if map_size(state.reviewers) < @max_reviews and not Map.has_key?(state.reviewers, pid) do
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | reviewers: Map.put(state.reviewers, pid, ref)}}
    else
      {:reply, {:error, :review_capacity}, state}
    end
  end

  def handle_call(:release_review, {pid, _tag}, state) do
    {ref, reviewers} = Map.pop(state.reviewers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | reviewers: reviewers}}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listener)
    Process.exit(state.acceptor, :shutdown)
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

  defp accept_loop(listener, store, gate, owner_uid) do
    Process.flag(:trap_exit, true)
    accept_loop(listener, store, gate, owner_uid, MapSet.new())
  end

  defp accept_loop(listener, store, gate, owner_uid, workers) do
    workers = drain_workers(workers)

    if MapSet.size(workers) >= @max_connections do
      receive do
        {:EXIT, worker, _reason} ->
          accept_loop(listener, store, gate, owner_uid, MapSet.delete(workers, worker))
      end
    else
      case :gen_tcp.accept(listener, 1_000) do
        {:ok, socket} ->
          worker =
            spawn_link(fn ->
              receive do
                :start ->
                  handle_socket(socket, store, gate, owner_uid)
                  _ = :gen_tcp.close(socket)
              end
            end)

          case :gen_tcp.controlling_process(socket, worker) do
            :ok ->
              send(worker, :start)
              accept_loop(listener, store, gate, owner_uid, MapSet.put(workers, worker))

            {:error, _reason} ->
              Process.exit(worker, :shutdown)
              _ = :gen_tcp.close(socket)
              accept_loop(listener, store, gate, owner_uid, workers)
          end

        {:error, :timeout} ->
          accept_loop(listener, store, gate, owner_uid, workers)

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

  defp handle_socket(socket, store, gate, owner_uid) do
    if PeerIdentity.verify(socket, owner_uid) == :ok,
      do: handle_verified_socket(socket, store, gate)
  end

  defp handle_verified_socket(socket, store, gate) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout_ms

    response =
      with {:ok, <<size::unsigned-big-32>>} <- :gen_tcp.recv(socket, 4, remaining(deadline)),
           true <- size > 0 and size <= @max_request_bytes,
           {:ok, body} <- :gen_tcp.recv(socket, size, remaining(deadline)),
           {:ok, request} <- Frame.decode_request(body) do
        dispatch_with_deadline(store, gate, request, deadline)
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

  defp dispatch_with_deadline(store, gate, request, ordinary_deadline) do
    deadline =
      if request["operation"] == "review_rules",
        do: System.monotonic_time(:millisecond) + @review_timeout_ms,
        else: ordinary_deadline

    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        response =
          case request do
            %{"operation" => "review_rules"} -> dispatch_review(store, gate, request)
            _ -> dispatch(store, request)
          end

        send(parent, {:dispatch_result, self(), response})
      end)

    receive do
      {:dispatch_result, ^worker, response} ->
        Process.demonitor(monitor, [:flush])
        response

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        if request["operation"] in ["submit", "cancel", "override_issue", "override_revoke"],
          do: error(:outcome_unknown),
          else: error(:operation_unavailable)
    after
      remaining(deadline) ->
        Process.exit(worker, :kill)

        if request["operation"] in ["submit", "cancel", "override_issue", "override_revoke"],
          do: error(:outcome_unknown),
          else: error(:request_timeout)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "health",
           "credential" => encoded
         } = request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, health} <- Store.authorized_health(store, credential) do
      ok(%{"health" => stringify_keys(health)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "support_preview",
           "credential" => encoded
         } = request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, support} <- SupportExport.preview(store, credential) do
      ok(%{"support" => support})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "enrollment_status",
           "credential" => encoded,
           "review_ref" => review_ref
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded) do
      case Store.enrollment_review_status(store, credential, review_ref) do
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
         store,
         %{"api_version" => 1, "operation" => "lifx_discover", "credential" => encoded} =
           request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, operator_id} <- Store.authorize_capture(store, credential),
         {:ok, capture} <- capture_owner(),
         {:ok, session_ref, candidates} <- CaptureSession.discover_auto(capture, operator_id) do
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
         store,
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
         {:ok, operator_id} <- Store.authorize_capture(store, credential),
         {:ok, capture} <- capture_owner(),
         {:ok, interview} <-
           CaptureSession.interview_auto(capture, operator_id, session_ref, candidate_ref) do
      ok(%{
        "interview" => %{
          "candidate_ref" => interview.candidate_ref,
          "transport" => interview.transport,
          "manufacturer_reported" => interview.manufacturer,
          "model_reported" => interview.model,
          "firmware_reported" => interview.firmware,
          "stable_id_claim" => interview.stable_id
        }
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "submit",
           "credential" => encoded,
           "mutation" => input
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded),
         {:ok, mutation} <- Mutation.new(input),
         {:ok, receipt} <- Store.submit_request(store, credential, mutation) do
      ok(%{"receipt" => receipt_map(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
           Store.override_snapshot_live(store, credential, target_ids) do
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
         store,
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
           Store.issue_override_operation_live(
             store,
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
         store,
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
      case Store.override_operation_status_live(store, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"override_receipt" => stringify_keys(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
      case Store.revoke_override_operation_live(store, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"override_receipt" => stringify_keys(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
         {:ok, events} <- Store.events_page(store, credential, after_revision, page_size) do
      ok(%{"events" => stringify_keys(events)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
           Store.request_events_page(store, credential, after_revision, page_size) do
      ok(%{"request_events" => stringify_keys(events)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
           Store.history_page(
             store,
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
         store,
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
           Store.catalogue_page(store, credential, watermark, after_id, page_size) do
      ok(%{"catalogue" => stringify_keys(catalogue)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
           Store.snapshot_page(store, credential, watermark, after_key, page_size) do
      ok(%{"snapshot" => stringify_keys(snapshot)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
      case Store.request_status(store, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"receipt" => receipt_map(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
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
      case Store.cancel_request(store, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"receipt" => receipt_map(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(_store, %{"api_version" => version}) when version != 1,
    do: error(:unsupported_api_version)

  defp dispatch(_store, _request), do: error(:unsupported_operation_or_fields)

  defp capture_owner do
    case WotexHome.Host.lifx_capture() do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :capture_unavailable}

      _ ->
        {:error, :capture_unavailable}
    end
  end

  defp dispatch_review(
         store,
         gate,
         %{
           "api_version" => 1,
           "operation" => "review_rules",
           "credential" => encoded,
           "rules" => input
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded),
         {:ok, rules} <- decode_rules(input),
         {:ok, things, watermark} <- Store.review_inputs(store, credential),
         :ok <- GenServer.call(gate, :acquire_review) do
      try do
        with {:ok, review} <- CandidateReview.review(rules, things),
             :ok <- Store.review_current(store, credential, watermark) do
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
      after
        :ok = GenServer.call(gate, :release_review)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch_review(store, _gate, request), do: dispatch(store, request)

  defp proposal_basis_map(nil), do: nil

  defp proposal_basis_map(basis) do
    %{
      "profile" => basis.profile,
      "scope" => Atom.to_string(basis.scope),
      "target_id" => basis.target_id,
      "rule_digest" => basis.rule_digest,
      "registry_digest" => basis.registry_digest,
      "runtime_digest" => basis.runtime_digest,
      "obligations" => Enum.map(basis.obligations, &Atom.to_string/1)
    }
  end

  defp credential(encoded) when is_binary(encoded) and byte_size(encoded) <= 44 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, credential} when byte_size(credential) == 32 -> {:ok, credential}
      _ -> {:error, :invalid_credential}
    end
  end

  defp credential(_encoded), do: {:error, :invalid_credential}

  defp decode_rules(input) when is_list(input) and length(input) in 1..64 do
    Enum.reduce_while(input, {:ok, []}, fn raw, {:ok, rules} ->
      case Rule.new(raw) do
        {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  defp decode_rules(_input), do: {:error, :invalid_rule_set}

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
