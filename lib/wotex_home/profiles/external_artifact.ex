defmodule WotexHome.Profiles.ExternalArtifact do
  @moduledoc """
  Encodes exact raw profile-closure manifests without a producer dependency.

  The manifest retains an envelope, profile and definition object set with exact
  object/payload digests and typed references. `identity/1` hashes the canonical
  manifest, while `decode/1` requires byte-for-byte canonical reconstruction.

  The identity is suitable for retained correspondence and local digest approval.
  It does not prove that the referenced bytes remain in custody, establish
  current trust or grant target-selection authority.
  """

  alias WotexHome.{Id, Profiles.AuthoringWire, Profiles.EnvelopeCodec}
  @format "wotex-home.external-artifact@1"

  def encode(data) do
    with true <- EnvelopeCodec.keys?(data, ~w(format id objects version)),
         true <-
           data["format"] == @format and Id.valid?(data["id"]) and
             EnvelopeCodec.version?(data["version"]),
         :ok <- objects(data["objects"]),
         bytes =
           JSON.encode!([
             @format,
             data["id"],
             data["version"],
             Enum.map(data["objects"], &object_values/1)
           ]),
         do: sized(bytes),
         else: (
           false -> invalid()
           error -> error
         )
  end

  def decode(bytes) do
    with {:ok, [@format, id, version, objects]} <- wire(bytes),
         :ok <- bounded(objects, 34),
         true <- Enum.all?(objects, &match?([_, _, _, _, _], &1)),
         {:ok, objects} <- native_objects(objects),
         data = %{"format" => @format, "id" => id, "version" => version, "objects" => objects},
         {:ok, ^bytes} <- encode(data),
         do: {:ok, data},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def identity(data) do
    with {:ok, _} <- encode(data),
         do:
           {:ok,
            sha(@format <> "\n" <> JSON.encode!(Enum.map(data["objects"], &object_values/1)))}
  end

  defp objects(values) do
    with :ok <- bounded(values, 34),
         [envelope, profile | definitions] <- values,
         true <-
           object?(envelope, "envelope") and object?(profile, "profile") and
             Enum.all?(definitions, &object?(&1, "definition")),
         true <- EnvelopeCodec.references?(Enum.map(definitions, & &1["reference"])),
         digests = Enum.map(values, & &1["object_digest"]),
         true <- length(Enum.uniq(digests)) == length(digests),
         :ok <- sizes(envelope, profile, definitions),
         do: :ok,
         else: (
           false -> invalid()
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  defp object?(data, kind),
    do:
      EnvelopeCodec.keys?(data, ~w(kind object_digest payload_bytes payload_sha256 reference)) and
        data["kind"] == kind and
        Enum.all?(~w(object_digest payload_sha256), &EnvelopeCodec.digest?(data[&1])) and
        is_integer(data["payload_bytes"]) and data["payload_bytes"] > 0 and
        if(kind == "envelope",
          do: data["reference"] == nil,
          else: EnvelopeCodec.reference?(data["reference"])
        )

  defp sizes(envelope, profile, definitions) do
    if Enum.all?([envelope, profile | definitions], &(&1["payload_bytes"] <= 65536)) and
         Enum.sum(Enum.map([profile | definitions], & &1["payload_bytes"])) <= 262_144,
       do: :ok,
       else: {:error, :external_profile_limit}
  end

  defp object_values(d),
    do: [
      d["kind"],
      reference_values(d["reference"]),
      d["object_digest"],
      d["payload_sha256"],
      d["payload_bytes"]
    ]

  defp reference_values(nil), do: nil
  defp reference_values(r), do: Enum.map(~w(id version sha256), &r[&1])

  defp native_objects(values) do
    Enum.reduce_while(values, {:ok, []}, fn [kind, ref, digest, sha, bytes], {:ok, acc} ->
      case native_reference(ref) do
        {:ok, ref} ->
          {:cont,
           {:ok,
            [
              %{
                "kind" => kind,
                "reference" => ref,
                "object_digest" => digest,
                "payload_sha256" => sha,
                "payload_bytes" => bytes
              }
              | acc
            ]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp native_reference(nil), do: {:ok, nil}

  defp native_reference([id, version, sha]),
    do: {:ok, %{"id" => id, "version" => version, "sha256" => sha}}

  defp native_reference(_), do: invalid()

  defp wire(bytes) do
    case AuthoringWire.decode(bytes, 32768) do
      {:ok, _} = result -> result
      {:error, :authoring_limit} -> {:error, :external_profile_limit}
      _ -> invalid()
    end
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :external_profile_limit}
  defp bounded([_ | t], n), do: bounded(t, n - 1)
  defp bounded(_, _), do: invalid()

  defp sized(bytes),
    do: if(byte_size(bytes) <= 32768, do: {:ok, bytes}, else: {:error, :external_profile_limit})

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp invalid, do: {:error, :invalid_external_artifact}
end
