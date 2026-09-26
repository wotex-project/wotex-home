defmodule WotexHome.Bootstrap do
  @moduledoc """
  Trusted one-time development bootstrap for a read-only health credential.

  Run inside the opted-in local host process or a foreground Mix run with the
  private data directory selected. This is not a socket route or installer.
  The caller prints the returned secret directly to an operator terminal and
  imports it into the native app's Keychain view.
  """

  alias WotexHome.Durable.Store
  alias WotexHome.Host

  @principal_id "diagnostics:local"

  @spec issue_diagnostic_credential() :: {:ok, String.t()} | {:error, atom()}
  def issue_diagnostic_credential do
    case Host.store() do
      pid when is_pid(pid) ->
        case Store.provision_principal(pid, @principal_id, ["read"], []) do
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
