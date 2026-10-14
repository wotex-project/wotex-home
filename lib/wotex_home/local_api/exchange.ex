defmodule WotexHome.LocalAPI.Exchange do
  @moduledoc """
  Runs bounded decoded API operations through Authority with transport-loss cleanup.

  `perform/3` receives an Authority value, closed request and ordinary monotonic
  deadline. It selects the operation's bounded execution window and coordinates
  the owning adapter worker so a disconnected transport cannot orphan work.
  Requests continue to use Authority's authentication and durable original IDs.

  Exchange completion is not a claim that every submitted mutation committed or
  that a command physically succeeded. Lost replies require original receipt
  lookup; adapters receive no Store connection or additional authority.
  """

  alias WotexHome.Authority
  alias WotexHome.LocalAPI.Server

  @mutations ~w(submit cancel override_issue override_revoke record_rule_review admit_rule
    schedule_review schedule_admit schedule_activate schedule_suspend activate_rule
    begin_maintenance end_maintenance invoke_rule lifx_enroll lifx_rereview lifx_refresh
    profile_import profile_prepare profile_change profile_review_cancel profiles_collect
    external_profile_inspect external_trust_change external_target_change
    authoring_object_import authoring_candidate_assess authoring_candidate_review
    authoring_generation_prepare authoring_generation_start authoring_generation_cancel)
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
    probe? =
      (request["operation"] == "authoring_object_import" and Map.has_key?(request, "upload_ref") and
         request["upload_ref"] == nil) or
        (request["operation"] == "authoring_candidate_review" and
           Map.has_key?(request, "input_ref") and request["input_ref"] == nil)

    reason =
      if request["operation"] in @mutations and not probe?, do: :outcome_unknown, else: fallback

    %{"api_version" => 1, "outcome" => "error", "reason" => Atom.to_string(reason)}
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
