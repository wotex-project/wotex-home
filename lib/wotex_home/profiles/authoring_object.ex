defmodule WotexHome.Profiles.AuthoringObject do
  @moduledoc """
  An inert tagged custody frame preserving exact original authoring bytes.

  Kind and payload digest are verified storage data, never document validation,
  attribution, admission or physical qualification. V1 profiles remain separate.
  """

  alias WotexHome.Profiles.EnvelopeCodec

  @kinds %{
    "source" => {1, 262_144},
    "draft" => {2, 262_144},
    "bundle" => {3, 262_144},
    "fixture" => {4, 65_536},
    "contract" => {5, 262_144},
    "envelope" => {6, 65_536},
    "profile" => {7, 65_536},
    "definition" => {8, 65_536}
  }
  @fields [:bytes, :digest, :kind, :payload, :payload_sha256]
  @enforce_keys @fields
  defstruct @fields

  @doc "The greatest complete frame size, including its 42-byte header."
  def max_bytes, do: 262_186

  @doc "Constructs a kind-bound frame from nonempty original bytes."
  def new(kind, payload) when is_binary(kind) and byte_size(kind) <= 10 and is_binary(payload) do
    case @kinds[kind] do
      {tag, ceiling} when byte_size(payload) > 0 and byte_size(payload) <= ceiling ->
        raw = :crypto.hash(:sha256, payload)

        bytes =
          <<"WOHA", 1, tag, byte_size(payload)::unsigned-big-32, raw::binary-size(32),
            payload::binary>>

        {:ok,
         %__MODULE__{
           bytes: bytes,
           digest: sha(bytes),
           kind: kind,
           payload: payload,
           payload_sha256: Base.encode16(raw, case: :lower)
         }}

      _ ->
        {:error, :invalid_authoring_object}
    end
  end

  def new(_, _), do: {:error, :invalid_authoring_object}

  @doc "Checks an exact complete frame; unknown/trailing/changed bytes refuse."
  def parse(
        <<"WOHA", 1, tag, size::unsigned-big-32, digest::binary-size(32), payload::binary>> =
          bytes
      )
      when byte_size(bytes) <= 262_186 and byte_size(payload) == size do
    with {kind, _} <- Enum.find(@kinds, fn {_, {installed, _}} -> tag == installed end),
         true <- :crypto.hash(:sha256, payload) == digest,
         {:ok, value} <- new(kind, payload) do
      {:ok, value}
    else
      _ -> {:error, :invalid_authoring_object}
    end
  end

  def parse(_), do: {:error, :invalid_authoring_object}

  @doc "Revalidates exact native fields before returning a payload-free storage summary."
  def summary(%__MODULE__{} = value) when map_size(value) == 6 do
    with {:ok, rebuilt} <- parse(value.bytes), true <- rebuilt == value do
      {:ok,
       %{
         "kind" => value.kind,
         "object_digest" => value.digest,
         "payload_sha256" => value.payload_sha256,
         "payload_bytes" => byte_size(value.payload)
       }}
    else
      _ -> {:error, :invalid_authoring_object}
    end
  end

  def summary(_), do: {:error, :invalid_authoring_object}

  @doc "Checks a closed summary before a custody export, without inferring payload custody."
  def valid_summary?(data) do
    if EnvelopeCodec.keys?(data, ~w(kind object_digest payload_bytes payload_sha256)) and
         is_binary(data["kind"]) and byte_size(data["kind"]) <= 10 do
      case @kinds[data["kind"]] do
        {_, ceiling} ->
          EnvelopeCodec.digest?(data["object_digest"]) and
            EnvelopeCodec.digest?(data["payload_sha256"]) and is_integer(data["payload_bytes"]) and
            data["payload_bytes"] in 1..ceiling

        _ ->
          false
      end
    else
      false
    end
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
