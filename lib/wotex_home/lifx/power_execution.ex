defmodule WotexHome.Lifx.PowerExecution do
  @moduledoc """
  Bounded direct-power exchange through caller-supplied authority capabilities.

  The caller owns the datagram transport and supplies five narrow durable
  operations: claim, handoff, ACK, readback settlement and unknown settlement.
  This module never receives a Store reference. It constructs the set packet
  before handoff, sends only after the handoff commits, treats an ACK as an
  intermediate state and always uses a separate correlated readback.

  Direct-power v1 fixes transition duration to zero. A fade is not part of the
  Store's sealed Boolean intent or its immediate readback qualification.
  """

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Durable.Receipt
  alias WotexHome.Lifx.{Ledger, PowerClaim, PowerSession, Transport}

  @max_datagrams 16
  @max_i64 9_223_372_036_854_775_807
  @required_hooks ~w(claim handoff ack settle unknown)a
  @required_options ~w(transport clock source_epoch source_sequence boot_epoch ack_timeout_ms read_timeout_ms duration_ms)a

  @type hooks :: %{
          required(:claim) => (String.t(), non_neg_integer() ->
                                 {:ok, PowerClaim.t()} | {:error, atom()}),
          required(:handoff) => (PowerClaim.t(), non_neg_integer() ->
                                   {:ok, Receipt.t()} | {:error, atom()}),
          required(:ack) => (PowerClaim.t() -> {:ok, Receipt.t()} | {:error, atom()}),
          required(:settle) => (PowerClaim.t(), WotexHome.Semantics.Observation.t() ->
                                  {:ok, Receipt.t()} | {:error, atom()}),
          required(:unknown) => (PowerClaim.t(), atom() -> {:ok, Receipt.t()} | {:error, atom()})
        }

  @spec run(hooks(), Candidate.t(), binary(), Ledger.t(), keyword()) ::
          {:ok, Receipt.t(), Ledger.t()} | {:error, atom(), Ledger.t()}
  def run(hooks, %Candidate{} = candidate, target, %Ledger{} = ledger, opts)
      when is_map(hooks) and is_binary(target) and is_list(opts) do
    with :ok <- valid_hooks(hooks),
         {:ok, config} <- options(opts),
         :ok <- Transport.check(config.transport, candidate.source_endpoint, :unicast),
         {:ok, {claim_ms, _claim_utc_ms}} <- time(config.clock),
         {:ok, %PowerClaim{} = claim} <- safe_call(hooks.claim, [config.boot_epoch, claim_ms]),
         :ok <- claim_matches(claim, candidate, config.boot_epoch),
         {:ok, session} <-
           PowerSession.new(candidate, target, claim.thing, claim.mutation, config.duration_ms),
         {:ok, set_packet, session, ledger} <-
           PowerSession.issue_set(session, ledger, claim_ms, config.ack_timeout_ms),
         {:ok, {handoff_ms, _handoff_utc_ms}} <- time(config.clock),
         {:ok, %Receipt{disposition: :dispatching}} <-
           safe_call(hooks.handoff, [claim, handoff_ms]) do
      execute_handed_off(
        hooks,
        claim,
        session,
        ledger,
        candidate.source_endpoint,
        set_packet,
        config
      )
    else
      {:error, reason} when is_atom(reason) -> {:error, reason, ledger}
      _ -> {:error, :invalid_power_execution, ledger}
    end
  end

  def run(_hooks, _candidate, _target, %Ledger{} = ledger, _opts),
    do: {:error, :invalid_power_execution, ledger}

  defp execute_handed_off(hooks, claim, session, ledger, endpoint, set_packet, config) do
    case send_packet(config.transport, endpoint, set_packet) do
      :ok ->
        {session, ledger} = await_ack(hooks, claim, session, ledger, config)
        issue_readback(hooks, claim, session, ledger, endpoint, config)

      {:error, reason} ->
        settle_unknown(hooks, claim, unknown_send_reason(reason, :set), ledger)
    end
  rescue
    _ -> settle_unknown(hooks, claim, :invalid_transport_result, ledger)
  catch
    _, _ -> settle_unknown(hooks, claim, :invalid_transport_result, ledger)
  end

  defp await_ack(hooks, claim, session, ledger, config) do
    started = System.monotonic_time(:millisecond)
    await_ack(hooks, claim, session, ledger, config, started, 0)
  end

  defp await_ack(_hooks, _claim, session, ledger, config, started, seen)
       when seen >= @max_datagrams do
    _ = {config, started}
    {session, ledger}
  end

  defp await_ack(hooks, claim, session, ledger, config, started, seen) do
    remaining = remaining(config.ack_timeout_ms, started)

    if remaining <= 0 do
      {session, ledger}
    else
      case receive_packet(config.transport, remaining) do
        {:ok, endpoint, bytes} ->
          case time(config.clock) do
            {:ok, {now_ms, _utc_ms}} ->
              case PowerSession.accept_ack(session, ledger, endpoint, bytes, now_ms) do
                {:ok, acknowledged, next_ledger} ->
                  case safe_call(hooks.ack, [claim]) do
                    {:ok, %Receipt{disposition: :protocol_accepted}} ->
                      {acknowledged, next_ledger}

                    _ ->
                      {session, ledger}
                  end

                {:error, _reason, next_ledger} ->
                  await_ack(hooks, claim, session, next_ledger, config, started, seen + 1)
              end

            {:error, _reason} ->
              {session, ledger}
          end

        {:error, :timeout} ->
          {session, ledger}

        {:error, _reason} ->
          {session, ledger}
      end
    end
  end

  defp issue_readback(hooks, claim, session, ledger, endpoint, config) do
    with {:ok, {issued_ms, _issued_utc_ms}} <- time(config.clock),
         {:ok, read_packet, session, ledger} <-
           PowerSession.issue_read(session, ledger, issued_ms, config.read_timeout_ms) do
      case send_packet(config.transport, endpoint, read_packet) do
        :ok ->
          await_readback(hooks, claim, session, ledger, config, issued_ms)

        {:error, reason} ->
          settle_unknown(hooks, claim, unknown_send_reason(reason, :read), ledger)
      end
    else
      {:error, _reason} -> settle_unknown(hooks, claim, :clock_unavailable, ledger)
    end
  end

  defp await_readback(hooks, claim, session, ledger, config, issued_ms) do
    started = System.monotonic_time(:millisecond)
    await_readback(hooks, claim, session, ledger, config, issued_ms, started, 0)
  end

  defp await_readback(hooks, claim, _session, ledger, _config, _issued_ms, _started, seen)
       when seen >= @max_datagrams,
       do: settle_unknown(hooks, claim, :datagram_budget_exhausted, ledger)

  defp await_readback(hooks, claim, session, ledger, config, issued_ms, started, seen) do
    remaining = remaining(config.read_timeout_ms, started)

    cond do
      remaining <= 0 ->
        settle_unknown(hooks, claim, :readback_timeout, ledger)

      true ->
        case receive_packet(config.transport, remaining) do
          {:ok, endpoint, bytes} ->
            accept_readback_datagram(
              hooks,
              claim,
              session,
              ledger,
              config,
              issued_ms,
              started,
              seen,
              endpoint,
              bytes
            )

          {:error, :timeout} ->
            settle_unknown(hooks, claim, :readback_timeout, ledger)

          {:error, :invalid_transport_result} ->
            settle_unknown(hooks, claim, :invalid_transport_result, ledger)

          {:error, _reason} ->
            settle_unknown(hooks, claim, :transport_unavailable, ledger)
        end
    end
  end

  defp accept_readback_datagram(
         hooks,
         claim,
         session,
         ledger,
         config,
         issued_ms,
         started,
         seen,
         endpoint,
         bytes
       ) do
    with {:ok, {received_ms, received_utc_ms}} <- time(config.clock),
         true <- received_ms >= issued_ms do
      metadata = %{
        "source_epoch" => config.source_epoch,
        "source_sequence" => config.source_sequence,
        "boot_epoch" => config.boot_epoch,
        "received_time_utc_ms" => received_utc_ms,
        "received_monotonic_ms" => received_ms
      }

      case PowerSession.accept_read(
             session,
             ledger,
             endpoint,
             bytes,
             received_ms,
             metadata
           ) do
        {:ok, _comparison, observation, _completed, next_ledger} ->
          case safe_call(hooks.settle, [claim, observation]) do
            {:ok, %Receipt{disposition: disposition} = receipt}
            when disposition in [:observed, :contradicted] ->
              {:ok, receipt, next_ledger}

            {:error, reason} ->
              {:error, reason, next_ledger}

            _ ->
              {:error, :invalid_settlement_result, next_ledger}
          end

        {:error, _reason, next_ledger} ->
          {session, next_ledger} =
            maybe_accept_late_ack(
              hooks,
              claim,
              session,
              next_ledger,
              endpoint,
              bytes,
              received_ms
            )

          await_readback(
            hooks,
            claim,
            session,
            next_ledger,
            config,
            issued_ms,
            started,
            seen + 1
          )
      end
    else
      _ -> settle_unknown(hooks, claim, :clock_unavailable, ledger)
    end
  end

  defp maybe_accept_late_ack(hooks, claim, session, ledger, endpoint, bytes, now_ms) do
    if session.acknowledged? do
      {session, ledger}
    else
      case PowerSession.accept_ack(session, ledger, endpoint, bytes, now_ms) do
        {:ok, acknowledged, next_ledger} ->
          case safe_call(hooks.ack, [claim]) do
            {:ok, %Receipt{disposition: :protocol_accepted}} -> {acknowledged, next_ledger}
            _ -> {session, ledger}
          end

        {:error, _reason, next_ledger} ->
          {session, next_ledger}
      end
    end
  end

  defp settle_unknown(hooks, claim, reason, ledger) do
    case safe_call(hooks.unknown, [claim, reason]) do
      {:ok, %Receipt{disposition: :outcome_unknown} = receipt} ->
        {:ok, receipt, ledger}

      {:error, failure} ->
        {:error, failure, ledger}

      _ ->
        {:error, :invalid_settlement_result, ledger}
    end
  end

  defp claim_matches(%PowerClaim{} = claim, %Candidate{} = candidate, boot_epoch) do
    if claim.boot_epoch == boot_epoch and
         candidate.transport == "udp" and
         candidate.claimed_identifiers["stable_id"] == claim.stable_id do
      :ok
    else
      {:error, :claim_candidate_mismatch}
    end
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == Enum.sort(@required_options) do
      config = Map.new(opts)

      if valid_transport?(config.transport) and is_function(config.clock, 0) and
           WotexHome.Id.valid?(config.source_epoch) and
           WotexHome.Id.valid?(config.boot_epoch) and
           valid_u64?(config.source_sequence) and config.ack_timeout_ms in 1..5_000 and
           config.read_timeout_ms in 1..5_000 and config.duration_ms === 0 do
        {:ok, config}
      else
        {:error, :invalid_power_execution}
      end
    else
      {:error, :invalid_power_execution}
    end
  end

  defp valid_hooks(hooks) when map_size(hooks) == length(@required_hooks) do
    arities = %{claim: 2, handoff: 2, ack: 1, settle: 2, unknown: 2}

    if Enum.all?(@required_hooks, fn key ->
         case Map.fetch(hooks, key) do
           {:ok, function} -> is_function(function, Map.fetch!(arities, key))
           :error -> false
         end
       end),
       do: :ok,
       else: {:error, :invalid_power_execution}
  end

  defp valid_hooks(_hooks), do: {:error, :invalid_power_execution}

  defp valid_transport?({module, _handle}) when is_atom(module),
    do: function_exported?(module, :send, 3) and function_exported?(module, :recv, 2)

  defp valid_transport?(_transport), do: false

  defp valid_u64?(value), do: is_integer(value) and value >= 0 and value <= @max_i64

  defp time(clock) do
    case safe_clock(clock) do
      {monotonic_ms, utc_ms} ->
        if valid_u64?(monotonic_ms) and valid_u64?(utc_ms),
          do: {:ok, {monotonic_ms, utc_ms}},
          else: {:error, :clock_unavailable}

      _ ->
        {:error, :clock_unavailable}
    end
  end

  defp safe_clock(clock) do
    clock.()
  rescue
    _ -> :invalid
  catch
    _, _ -> :invalid
  end

  defp send_packet({transport, handle}, endpoint, packet),
    do: call_transport_send(transport, handle, endpoint, packet)

  defp receive_packet({transport, handle}, timeout_ms) do
    case transport.recv(handle, timeout_ms) do
      {:ok, endpoint, bytes} when is_binary(endpoint) and is_binary(bytes) ->
        {:ok, endpoint, bytes}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :invalid_transport_result}
    end
  rescue
    _ -> {:error, :transport_unavailable}
  catch
    _, _ -> {:error, :transport_unavailable}
  end

  defp call_transport_send(transport, handle, endpoint, packet) do
    case transport.send(handle, endpoint, packet) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_transport_result}
    end
  rescue
    _ -> {:error, :transport_unavailable}
  catch
    _, _ -> {:error, :transport_unavailable}
  end

  defp unknown_send_reason(:invalid_transport_result, _phase), do: :invalid_transport_result
  defp unknown_send_reason(:transport_unavailable, _phase), do: :transport_unavailable
  defp unknown_send_reason(_reason, :set), do: :set_send_uncertain
  defp unknown_send_reason(_reason, :read), do: :read_send_uncertain

  defp remaining(timeout_ms, started),
    do: timeout_ms - (System.monotonic_time(:millisecond) - started)

  defp safe_call(function, arguments) do
    apply(function, arguments)
  rescue
    _ -> {:error, :settlement_unavailable}
  catch
    _, _ -> {:error, :settlement_unavailable}
  end
end
