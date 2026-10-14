defmodule WotexHome.Profiles.ExternalInspection do
  @moduledoc "Closed producer-independent originals for inert external profile inspection."
  alias WotexHome.{Id, Profiles.AuthoringWire, Profiles.EnvelopeCodec}
  @maximum 9_223_372_036_854_775_807
  @format "wotex-home.external-inspection.v1"
  @receipt ~w(authority_epoch operation_id revision input_sha256 reader_basis_sha256 result_sha256 capture_digest envelope_sha256 home_consumption)

  @doc "Encodes the shared closed typed object selection without an inspection original."
  def encode_objects(objects) do
    with true <- EnvelopeCodec.keys?(objects, ~w(definitions envelope_ref profile)),
         true <- handle?(objects["envelope_ref"]) and document?(objects["profile"]),
         :ok <- documents(objects["definitions"]),
         do:
           {:ok,
            [
              handle(objects["envelope_ref"]),
              document(objects["profile"]),
              Enum.map(objects["definitions"], &document/1)
            ]},
         else: (
           false -> invalid()
           error -> error
         )
  end

  @doc "Decodes the same shared object shape, retaining reference order and handles."
  def decode_objects([envelope, profile, definitions]) do
    with {:ok, envelope} <- native_handle(envelope),
         {:ok, profile} <- native_document(profile),
         {:ok, definitions} <- native_documents(definitions),
         objects = %{
           "envelope_ref" => envelope,
           "profile" => profile,
           "definitions" => definitions
         },
         {:ok, _} <- encode_objects(objects),
         do: {:ok, objects}
  end

  def decode_objects(_), do: invalid()

  def encode_result(data) do
    with true <- EnvelopeCodec.keys?(data, ~w(capture_digest envelope format reader_basis_sha256)),
         true <-
           data["format"] == "wotex-home.external-inspection-result@1" and
             EnvelopeCodec.digest?(data["reader_basis_sha256"]) and
             EnvelopeCodec.digest?(data["capture_digest"]),
         true <-
           data["envelope"] != nil and WotexHome.Profiles.EnvelopeSummary.valid?(data["envelope"]),
         do:
           sized(
             JSON.encode!([
               data["format"],
               [data["reader_basis_sha256"], data["capture_digest"]],
               WotexHome.Profiles.EnvelopeSummary.values(data["envelope"])
             ]),
             32768
           ),
         else: (_ -> invalid())
  end

  def decode_result(bytes) do
    with {:ok, ["wotex-home.external-inspection-result@1", [basis, capture], envelope]} <-
           wire(bytes, 32768),
         {:ok, envelope} <- WotexHome.Profiles.EnvelopeSummary.from_wire(envelope),
         data = %{
           "format" => "wotex-home.external-inspection-result@1",
           "reader_basis_sha256" => basis,
           "capture_digest" => capture,
           "envelope" => envelope
         },
         {:ok, ^bytes} <- encode_result(data),
         do: {:ok, data},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def encode(input) do
    with true <-
           EnvelopeCodec.keys?(
             input,
             ~w(authority_epoch expected_revision inspection operation_id)
           ),
         true <-
           int?(input["authority_epoch"], 1) and int?(input["expected_revision"], 0) and
             Id.valid?(input["operation_id"]),
         i = input["inspection"],
         true <- EnvelopeCodec.keys?(i, ~w(definitions envelope_ref profile reader_basis_sha256)),
         true <-
           EnvelopeCodec.digest?(i["reader_basis_sha256"]) and handle?(i["envelope_ref"]) and
             document?(i["profile"]),
         :ok <- documents(i["definitions"]),
         bytes =
           JSON.encode!([
             @format,
             [
               input["authority_epoch"],
               input["operation_id"],
               input["expected_revision"],
               [
                 i["reader_basis_sha256"],
                 handle(i["envelope_ref"]),
                 document(i["profile"]),
                 Enum.map(i["definitions"], &document/1)
               ]
             ]
           ]),
         do: sized(bytes, 16384),
         else: (
           false -> invalid()
           error -> error
         )
  end

  def decode(bytes) do
    with {:ok, [@format, [epoch, operation, revision, [basis, envelope, profile, definitions]]]} <-
           wire(bytes, 16384),
         {:ok, envelope} <- native_handle(envelope),
         {:ok, profile} <- native_document(profile),
         {:ok, definitions} <- native_documents(definitions),
         input = %{
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => revision,
           "inspection" => %{
             "reader_basis_sha256" => basis,
             "envelope_ref" => envelope,
             "profile" => profile,
             "definitions" => definitions
           }
         },
         {:ok, ^bytes} <- encode(input),
         do: {:ok, input},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def encode_receipt(input) do
    with true <- EnvelopeCodec.keys?(input, Enum.sort(@receipt)),
         true <-
           int?(input["authority_epoch"], 1) and int?(input["revision"], 1) and
             Id.valid?(input["operation_id"]),
         true <-
           Enum.all?(
             ~w(input_sha256 reader_basis_sha256 result_sha256 capture_digest envelope_sha256),
             &EnvelopeCodec.digest?(input[&1])
           ) and input["home_consumption"] == "matched",
         do: {:ok, JSON.encode!(Enum.map(@receipt, &input[&1]))},
         else: (_ -> invalid())
  end

  def decode_receipt(bytes) do
    with {:ok, values} <- wire(bytes, 4096),
         true <- match?([_, _, _, _, _, _, _, _, _], values),
         data = Map.new(Enum.zip(@receipt, values)),
         {:ok, ^bytes} <- encode_receipt(data),
         do: {:ok, data},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  defp documents(values) do
    with :ok <- bounded(values, 32),
         true <- Enum.all?(values, &document?/1),
         true <- EnvelopeCodec.references?(Enum.map(values, & &1["reference"])),
         digests = Enum.map(values, & &1["object_ref"]["object_digest"]),
         true <- length(Enum.uniq(digests)) == length(digests),
         do: :ok,
         else: (
           false -> invalid()
           error -> error
         )
  end

  defp document?(data),
    do:
      EnvelopeCodec.keys?(data, ~w(object_ref reference)) and
        EnvelopeCodec.reference?(data["reference"]) and handle?(data["object_ref"])

  defp handle?(data),
    do:
      EnvelopeCodec.keys?(data, ~w(first_revision object_digest)) and
        EnvelopeCodec.digest?(data["object_digest"]) and int?(data["first_revision"], 1)

  defp document(data),
    do: [Enum.map(~w(id version sha256), &data["reference"][&1]), handle(data["object_ref"])]

  defp handle(data), do: [data["object_digest"], data["first_revision"]]

  defp native_document([[id, version, sha], handle]) do
    with {:ok, handle} <- native_handle(handle),
         do:
           {:ok,
            %{
              "reference" => %{"id" => id, "version" => version, "sha256" => sha},
              "object_ref" => handle
            }}
  end

  defp native_document(_), do: invalid()

  defp native_handle([digest, revision]),
    do: {:ok, %{"object_digest" => digest, "first_revision" => revision}}

  defp native_handle(_), do: invalid()

  defp native_documents(values) do
    with :ok <- bounded(values, 32) do
      Enum.reduce_while(values, {:ok, []}, fn input, {:ok, values} ->
        case native_document(input) do
          {:ok, value} -> {:cont, {:ok, [value | values]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    end
  end

  defp wire(bytes, maximum) do
    case AuthoringWire.decode(bytes, maximum) do
      {:ok, _} = result -> result
      {:error, :authoring_limit} -> {:error, :external_profile_limit}
      _ -> invalid()
    end
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :external_profile_limit}
  defp bounded([_ | t], n), do: bounded(t, n - 1)
  defp bounded(_, _), do: invalid()
  defp int?(value, minimum), do: is_integer(value) and value in minimum..@maximum

  defp sized(bytes, max),
    do: if(byte_size(bytes) <= max, do: {:ok, bytes}, else: {:error, :external_profile_limit})

  defp invalid, do: {:error, :invalid_external_inspection}
end
