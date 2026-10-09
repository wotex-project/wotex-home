defmodule Woh.Tool.LinuxUpdate do
  @moduledoc false
  alias Woh.Tool.{LinuxUpdatePrepare, LinuxUpdateMaintenance, LinuxUpdateStop, LinuxUpdateSwitch}
  alias LinuxUpdateMaintenance.Error

  def run(release, manifest, pin, credential, options \\ []) do
    try do
      case Woh.Tool.LinuxUpdateCredential.decode(credential) do
        {:ok, ^credential} -> :ok
        _ -> refuse!(:update_credential_refused)
      end

      run!(release, manifest, pin, credential, options)
    rescue
      error in Error -> {:error, error.reason}
      _ -> {:error, :release_update_unavailable}
    end
  end

  defp run!(release, manifest, pin, credential, options) do
    {:ok, view} = need!(LinuxUpdatePrepare.inspect(release, manifest, pin, options))
    intent = List.last(view.journal["updates"])

    if intent == nil or (intent["phase"] == "complete" and intent["target"] != view.target) do
      need!(LinuxUpdatePrepare.plan(release, manifest, pin, credential, options))
      run!(release, manifest, pin, credential, options)
    else
      if intent["target"] != view.target, do: refuse!(:update_target_changed)
      nonce = intent["nonce"]

      case intent["phase"] do
        "planned" ->
          need!(LinuxUpdatePrepare.stage(nonce, release, manifest, pin, credential, options))
          run!(release, manifest, pin, credential, options)

        phase when phase in ~w(staged begin_recorded) ->
          need!(LinuxUpdateMaintenance.activate(nonce, credential, options))
          run!(release, manifest, pin, credential, options)

        phase when phase in ~w(maintenance_active fenced) ->
          need!(LinuxUpdateStop.run(nonce, credential, options))
          run!(release, manifest, pin, credential, options)

        phase when phase in ~w(stopped configuration_ready target_running selected complete) ->
          LinuxUpdateSwitch.run(nonce, credential, options)
      end
    end
  end

  defp need!({:ok, _} = result), do: result
  defp need!({:error, reason}), do: refuse!(reason)
  defp need!(_), do: refuse!(:release_update_unavailable)
  defp refuse!(reason), do: raise(Error, reason: reason)
end
