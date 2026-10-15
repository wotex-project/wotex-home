defmodule WotexHome.MQTT.Credential do
  @moduledoc """
  Seals one private broker credential without retaining its decoded secret.

  `filename/0` names `mqtt-credential-v1.json` under the canonical private data
  root. `decode/1` accepts at most 8,192 bytes with exactly `format`, `username`
  and `password_base64`; the format is `wotex-home.mqtt-credential@1`. The username
  has 1 to 128 UTF-8 bytes without NUL. Canonical standard-base64 password text
  decodes to 1 to 4,096 binary bytes. Success is
  `{:ok, {:password, username, password}}`; invalid documents return
  `{:error, :invalid_mqtt_credential}`. Do not log or retain this decoded result
  in Host configuration.

  `load/1` requires a mode-0400, single-link document under the private root and
  returns `{:ok, reference}` or `{:error, :mqtt_credential_unavailable}`. The
  reference retains the file seal and raw-byte hash, omits the decoded secret,
  and has redacted inspection. `resolve/1` rechecks both identity and identical
  bytes before returning the bare `{:password, username, password}` tuple to
  TLS connection setup. Drift returns `{:error, :mqtt_credential_changed}`;
  `check/1` performs the same validation but returns `:ok` on success.

  `publish/3` validates an explicit private source and installs its exact bytes
  without replacement, returning `{:ok, %{installed: true}}`. An identical-byte
  retry succeeds; different existing bytes return
  `{:error, :mqtt_credential_exists}`. Custody/publication failures return
  `{:error, :mqtt_credential_unavailable}`. It creates no root, broker connection
  or Store record and returns no credential digest or secret metadata.

  These references are local broker custody, not device authority or operator
  bearers. They remain outside Store/profile backups and remote authoring input;
  changing a file does not replace credentials in an already running connection.
  """

  alias WotexHome.Profiles.{AuthoringProducer, EnvelopeCodec}
  alias WotexHome.Recovery.PrivateFile
  @filename "mqtt-credential-v1.json"
  @maximum 8192
  @enforce_keys [:seal, :sha256]
  @derive {Inspect, only: []}
  defstruct @enforce_keys

  def filename, do: @filename

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum do
    with {:ok, data} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [
               bytes,
               [
                 max_bytes: @maximum,
                 max_depth: 2,
                 max_nodes: 8,
                 max_collection_size: 3,
                 max_string_bytes: 5464
               ]
             ],
             :invalid_mqtt_credential
           ),
         true <- EnvelopeCodec.keys?(data, ~w(format password_base64 username)),
         true <- data["format"] == "wotex-home.mqtt-credential@1",
         user = data["username"],
         true <-
           is_binary(user) and byte_size(user) in 1..128 and String.valid?(user) and
             not String.contains?(user, <<0>>),
         {:ok, password} <- base64(data["password_base64"]),
         true <- byte_size(password) in 1..4096,
         do: {:ok, {:password, user, password}},
         else: (_ -> {:error, :invalid_mqtt_credential})
  end

  def decode(_), do: {:error, :invalid_mqtt_credential}

  def load(root) when is_binary(root) do
    with {:ok, bytes, seal} <- PrivateFile.read_sealed(Path.join(root, @filename), @maximum),
         {:ok, _} <- decode(bytes),
         do: {:ok, %__MODULE__{seal: seal, sha256: AuthoringProducer.sha(bytes)}},
         else: (_ -> {:error, :mqtt_credential_unavailable})
  end

  def load(_), do: {:error, :mqtt_credential_unavailable}

  def resolve(%__MODULE__{seal: seal, sha256: sha}) do
    with %PrivateFile.Seal{} <- seal,
         {:ok, bytes, ^seal} <- PrivateFile.read_sealed(seal.path, @maximum),
         true <- AuthoringProducer.sha(bytes) == sha,
         {:ok, credential} <- decode(bytes),
         do: credential,
         else: (_ -> {:error, :mqtt_credential_changed})
  end

  def resolve(_), do: {:error, :mqtt_credential_changed}

  def check(reference) do
    case resolve(reference) do
      {:password, _, _} -> :ok
      _ -> {:error, :mqtt_credential_changed}
    end
  end

  def publish(root, source, sync \\ &:file.sync/1) do
    with {:ok, _} <- PrivateFile.directory_witness(root),
         {:ok, bytes, seal} <- PrivateFile.read_sealed(source, @maximum),
         {:ok, _} <- decode(bytes),
         {:ok, ^bytes, ^seal} <- PrivateFile.read_sealed(source, @maximum),
         :ok <- write(Path.join(root, @filename), bytes, sync),
         do: {:ok, %{installed: true}},
         else: (
           {:error, :invalid_mqtt_credential} = error -> error
           {:error, :mqtt_credential_exists} = error -> error
           _ -> {:error, :mqtt_credential_unavailable}
         )
  end

  defp write(path, bytes, sync) do
    case PrivateFile.write(path, bytes, @maximum, sync) do
      {:error, :private_custody_exists} ->
        case PrivateFile.read(path, @maximum) do
          {:ok, ^bytes} -> :ok
          {:ok, _} -> {:error, :mqtt_credential_exists}
          _ -> {:error, :mqtt_credential_unavailable}
        end

      result ->
        result
    end
  end

  defp base64(value) when is_binary(value) do
    with {:ok, decoded} <- Base.decode64(value),
         true <- Base.encode64(decoded) == value,
         do: {:ok, decoded},
         else: (_ -> :invalid)
  end

  defp base64(_), do: :invalid
end
