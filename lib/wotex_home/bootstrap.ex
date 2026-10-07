defmodule WotexHome.Bootstrap do
  @moduledoc """
  Trusted development bootstrap for diagnostic, controller, maintenance and profile credentials.

  Run inside the opted-in local host process or a foreground Mix run with the
  private data directory selected. This is not a socket route or installer.
  The caller prints the returned secret directly to an operator terminal and
  imports it into the native app's Keychain view.

  `issue_diagnostic_credential/0` creates a scoped principal for local health
  inspection. `issue_controller_credential/2` creates a named controller only
  after its first Thing exists. `extend_controller_credential/2` adds one later
  Thing while replacing the old credential in the same transaction. Run these
  only during trusted setup and protect the returned value immediately.
  """

  alias WotexHome.Authority
  alias WotexHome.Host

  @spec issue_diagnostic_credential() :: {:ok, String.t()} | {:error, atom()}
  def issue_diagnostic_credential do
    authority = Host.authority()

    case Authority.owner(authority) do
      pid when is_pid(pid) ->
        case Authority.provision_diagnostic(authority) do
          {:ok, credential, _revision} ->
            {:ok, Base.url_encode64(credential, padding: false)}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :host_unavailable}
    end
  end

  @spec issue_controller_credential(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def issue_controller_credential(principal_id, thing_id),
    do: provision(&Authority.provision_controller(&1, principal_id, thing_id))

  @spec extend_controller_credential(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def extend_controller_credential(principal_id, thing_id),
    do: provision(&Authority.grant_target_and_rotate(&1, principal_id, thing_id))

  @doc "Creates the fixed maintenance principal once without device-control permission."
  def issue_maintenance_credential, do: provision(&Authority.provision_maintenance/1)

  @doc "Separate one-time source-transfer setup; no maintenance or target grants."
  def issue_transfer_credential, do: provision(&Authority.provision_transfer/1)

  @doc "Explicit management and enrollment-review setup, with no control or target grants."
  def issue_profile_operator_credential, do: provision(&Authority.provision_profile_operator/1)

  @doc "Preserves the separate management-only setup."
  def issue_profile_manager_credential, do: provision(&Authority.provision_profile_manager/1)

  defp provision(operation) do
    authority = Host.authority()

    case Authority.owner(authority) do
      pid when is_pid(pid) ->
        case operation.(authority) do
          {:ok, credential, _revision} ->
            {:ok, Base.url_encode64(credential, padding: false)}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :host_unavailable}
    end
  end
end
