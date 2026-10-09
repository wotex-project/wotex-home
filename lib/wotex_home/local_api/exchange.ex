defmodule WotexHome.LocalAPI.Exchange do
  @moduledoc "Shared bounded Authority dispatch; transport loss cannot orphan an adapter worker."
  alias WotexHome.Authority
  alias WotexHome.LocalAPI.Server

  @mutations ~w(submit cancel override_issue override_revoke record_rule_review admit_rule
    schedule_review schedule_admit schedule_activate schedule_suspend activate_rule
    begin_maintenance end_maintenance invoke_rule lifx_enroll lifx_rereview lifx_refresh
    profile_import profile_prepare profile_change profile_review_cancel profiles_collect)
  @reviews ~w(review_rules record_rule_review admit_rule schedule_review schedule_admit
    schedule_activate schedule_suspend)

  def perform(%Authority{} = authority, request, ordinary_deadline)
      when is_map(request) and is_integer(ordinary_deadline) do
    deadline =
      if request["operation"] in @reviews,
        do: System.monotonic_time(:millisecond) + 10_000,
        else: ordinary_deadline

    if remaining(deadline) == 0,
      do: failed(request, :request_timeout),
      else: dispatch(authority, request, deadline)
  end

  defp dispatch(authority, request, deadline) do
    parent = self()
    {guard, monitor} = spawn_monitor(fn -> supervise(parent, authority, request, deadline) end)

    receive do
      {:home_exchange_result, ^guard, response} ->
        Process.demonitor(monitor, [:flush])
        response

      {:DOWN, ^monitor, :process, ^guard, _} ->
        failed(request, :operation_unavailable)
    after
      remaining(deadline) ->
        Process.exit(guard, :kill)
        Process.demonitor(monitor, [:flush])
        failed(request, :request_timeout)
    end
  end

  defp supervise(parent, authority, request, deadline) do
    Process.flag(:trap_exit, true)
    parent_ref = Process.monitor(parent)
    guard = self()

    worker =
      spawn_link(fn ->
        result =
          try do
            {:ok, Server.route(authority, request)}
          rescue
            _ -> :failed
          catch
            _, _ -> :failed
          end

        send(guard, {:answer, self(), result})
      end)

    try do
      receive do
        {:answer, ^worker, {:ok, response}} ->
          send(parent, {:home_exchange_result, self(), response})

        {:answer, ^worker, :failed} ->
          send(parent, {:home_exchange_result, self(), failed(request, :operation_unavailable)})

        {:EXIT, ^worker, _} ->
          send(parent, {:home_exchange_result, self(), failed(request, :operation_unavailable)})

        {:DOWN, ^parent_ref, :process, ^parent, _} ->
          :ok
      after
        remaining(deadline) ->
          send(parent, {:home_exchange_result, self(), failed(request, :request_timeout)})
      end
    after
      Process.exit(worker, :kill)
      Process.demonitor(parent_ref, [:flush])
    end
  end

  defp failed(request, fallback) do
    reason = if request["operation"] in @mutations, do: :outcome_unknown, else: fallback
    %{"api_version" => 1, "outcome" => "error", "reason" => Atom.to_string(reason)}
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
