defmodule WotexHome.Profiles.AuthoringImport do
  @moduledoc "Canonical inert inputs and receipts for original authoring-object imports."
  alias WotexHome.{Id, Profiles.AuthoringObject}
  alias WotexHome.Profiles.EnvelopeCodec
  @maximum 9_223_372_036_854_775_807
  @format "wotex-home.authoring-import.v1"

  def encode(data) do
    if EnvelopeCodec.keys?(data, ~w(authority_epoch expected_revision object operation_id)) and
         integer?(data["authority_epoch"], 1) and integer?(data["expected_revision"], 0) and
         Id.valid?(data["operation_id"]) and AuthoringObject.valid_summary?(data["object"]) do
      summary = data["object"]

      {:ok,
       JSON.encode!([
         @format,
         [
           data["authority_epoch"],
           data["operation_id"],
           data["expected_revision"],
           Enum.map(~w(kind object_digest payload_sha256 payload_bytes), &summary[&1])
         ]
       ])}
    else
      {:error, :invalid_authoring_import}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= 4096 do
    with {:ok, [@format, [epoch, operation, revision, [kind, digest, payload, size]]]} <-
           JSON.decode(bytes),
         data = %{
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => revision,
           "object" => %{
             "kind" => kind,
             "object_digest" => digest,
             "payload_sha256" => payload,
             "payload_bytes" => size
           }
         },
         {:ok, ^bytes} <- encode(data) do
      {:ok, data}
    else
      _ -> {:error, :invalid_authoring_import}
    end
  end

  def decode(_), do: {:error, :invalid_authoring_import}

  def receipt(data, first, revision) do
    Map.take(data, ~w(authority_epoch operation_id object))
    |> Map.merge(%{"first_revision" => first, "revision" => revision})
  end

  def encode_receipt(data) do
    if EnvelopeCodec.keys?(data, ~w(authority_epoch first_revision object operation_id revision)) and
         integer?(data["first_revision"], 1) and integer?(data["revision"], 1) and
         data["first_revision"] <= data["revision"] do
      input =
        Map.take(data, ~w(authority_epoch operation_id object)) |> Map.put("expected_revision", 0)

      with {:ok, document} <- encode(input),
           do: {:ok, JSON.encode!([document, data["first_revision"], data["revision"]])}
    else
      {:error, :invalid_authoring_import}
    end
  end

  def decode_receipt(bytes) when is_binary(bytes) and byte_size(bytes) <= 4096 do
    with {:ok, [input, first, revision]} <- JSON.decode(bytes),
         {:ok, input} <- decode(input),
         value = receipt(input, first, revision),
         {:ok, ^bytes} <- encode_receipt(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_authoring_import}
    end
  end

  def decode_receipt(_), do: {:error, :invalid_authoring_import}

  defp integer?(value, minimum), do: is_integer(value) and value >= minimum and value <= @maximum
end
