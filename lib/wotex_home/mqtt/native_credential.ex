defmodule WotexHome.MQTT.NativeCredential do
  @moduledoc """
  Holds one source-bound, single-use broker credential for native startup.

  `start_link/3` takes the selected raw source SHA-256, its private-file seal and
  a `{:password, username, password}` tuple. It revalidates the credential and
  returns `{:ok, capability}` for a linked owner that monitors its creating
  process. The decoded pair remains in that owner for at most 30 seconds or one
  successful resolution. Inspection and process diagnostics redact the secret.

  `matches?/3` compares a capability with the supplied source digest and seal,
  returning a boolean. `check/1` returns `:ok` only while its original token,
  digest and seal match the owner's live, unconsumed state. Neither operation
  reads the source file: `WotexHome.Host.MQTTConfiguration` owns actual sealed
  file and prepared-basis revalidation.

  `resolve/1` returns the bare `{:password, username, password}` tuple once and
  clears the retained pair. Invalid, consumed, expired or unavailable custody
  returns `{:error, :mqtt_native_credential_unavailable}`. Check and resolve calls
  have a one-second timeout. `stop/1` idempotently retires the owner; creator loss
  or expiry also clears its custody. Checking never renews the lifetime.

  The capability travels only through trusted native startup and Host arguments,
  never Store, application environment, backups or public request fields. It
  establishes no OS signing evidence, Keychain authorization or device authority.
  """

  use GenServer
  alias WotexHome.MQTT.Credential
  alias WotexHome.Recovery.PrivateFile
  @enforce_keys [:owner, :token, :sha256, :seal]
  @derive {Inspect, only: []}
  defstruct @enforce_keys

  def start_link(sha256, %PrivateFile.Seal{} = seal, {:password, user, password} = credential)
      when is_binary(sha256) and is_binary(user) and is_binary(password) do
    token = make_ref()
    parent = self()

    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256),
         {:ok, ^credential} <-
           Credential.decode(
             JSON.encode!(%{
               "format" => "wotex-home.mqtt-credential@1",
               "username" => user,
               "password_base64" => Base.encode64(password)
             })
           ),
         {:ok, owner} <-
           GenServer.start_link(__MODULE__, {parent, token, sha256, seal, credential}) do
      {:ok, %__MODULE__{owner: owner, token: token, sha256: sha256, seal: seal}}
    else
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  end

  def start_link(_, _, _), do: unavailable()
  def matches?(%__MODULE__{sha256: sha256, seal: seal} = cap, sha256, seal), do: check(cap) == :ok
  def matches?(_, _, _), do: false
  def check(cap), do: call(cap, :check)
  def resolve(cap), do: call(cap, :resolve)

  def stop(%__MODULE__{owner: owner}) do
    GenServer.stop(owner, :normal, 1000)
  catch
    :exit, _ -> :ok
  end

  def stop(_), do: :ok

  defp call(%__MODULE__{owner: owner, token: token, sha256: sha, seal: seal}, operation) do
    GenServer.call(owner, {operation, token, sha, seal}, 1000)
  catch
    :exit, _ -> unavailable()
  end

  defp call(_, _), do: unavailable()

  @impl true
  def init({parent, token, sha, seal, credential}) do
    monitor = Process.monitor(parent)
    Process.send_after(self(), :expire, 30_000)

    {:ok,
     %{
       token: token,
       sha: sha,
       seal: seal,
       parent: monitor,
       credential: credential,
       deadline: now() + 30_000
     }}
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_native_mqtt_credential)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :mqtt_native_credential_unavailable)

  @impl true
  def handle_call(
        {:check, token, sha, seal},
        _,
        %{token: token, sha: sha, seal: seal, credential: credential} = state
      ) do
    {:reply, if(credential != nil and now() < state.deadline, do: :ok, else: unavailable()),
     state}
  end

  def handle_call(
        {:resolve, token, sha, seal},
        _,
        %{token: token, sha: sha, seal: seal, credential: credential} = state
      ) do
    result = if credential != nil and now() < state.deadline, do: credential, else: unavailable()
    {:reply, result, %{state | credential: nil}}
  end

  def handle_call(_, _, state), do: {:reply, unavailable(), state}
  @impl true
  def handle_info(:expire, state), do: {:stop, :normal, %{state | credential: nil}}

  def handle_info({:DOWN, monitor, :process, _, _}, %{parent: monitor} = state),
    do: {:stop, :normal, %{state | credential: nil}}

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def handle_cast(_, state), do: {:noreply, state}
  defp now, do: System.monotonic_time(:millisecond)
  defp unavailable, do: {:error, :mqtt_native_credential_unavailable}
end
