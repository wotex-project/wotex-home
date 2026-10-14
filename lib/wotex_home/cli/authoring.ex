defmodule WotexHome.CLI.Authoring do
  @moduledoc false

  import Bitwise
  alias WotexHome.LocalAPI.Frame
  alias WotexHome.Profiles.{AuthoringObject, AuthoringReview, EnvelopeCodec}

  def multistep?([command | _]),
    do: command in ~w(authoring-object-import authoring-candidate-review)

  def multistep?(_), do: false

  def perform(socket, command, probe, send, read) do
    with {:ok, response} <- send.(socket, probe) do
      if response["outcome"] == "error" and response["reason"] == "authoring_upload_required" do
        with {:ok, bytes, purpose, field} <- payload(command, probe, read),
             {:ok, ref} <- upload(socket, probe["credential"], purpose, bytes, send),
             request = Map.put(probe, field, ref),
             result <- send.(socket, request) do
          case result do
            {:ok, response} ->
              if response["outcome"] != "error" or response["reason"] != "outcome_unknown",
                do: cleanup(socket, probe["credential"], ref, send)

              {:ok, request, response}

            error ->
              error
          end
        end
      else
        {:ok, probe, response}
      end
    end
  end

  defp payload(["authoring-object-import", _, path], request, read) do
    input = request["input"]
    expected = input["object"]

    with {:ok, bytes} <- read.(path, 1..expected["payload_bytes"], expected["payload_bytes"] + 1),
         {:ok, object} <- AuthoringObject.new(expected["kind"], bytes),
         {:ok, ^expected} <- AuthoringObject.summary(object),
         do: {:ok, bytes, "import_payload", "upload_ref"},
         else: (_ -> {:error, :invalid_authoring_payload_file})
  end

  defp payload(["authoring-candidate-review", path], request, read) do
    with {:ok, bytes} <- read.(path, 1..262_144, 262_145),
         {:ok, input} <- Frame.decode_document(bytes, 262_144),
         {:ok, canonical} <- AuthoringReview.encode(input),
         true <- sha(canonical) == request["input_sha256"],
         do: {:ok, canonical, "review_original", "input_ref"},
         else: (_ -> {:error, :invalid_authoring_original_file})
  end

  defp upload(socket, credential, purpose, bytes, send) do
    id = "upload:" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    input = %{
      "upload_id" => id,
      "purpose" => purpose,
      "payload_bytes" => byte_size(bytes),
      "payload_sha256" => sha(bytes)
    }

    request = Map.put(base(credential, "authoring_upload_begin"), "upload", input)
    result = send.(socket, request)

    result =
      case result do
        {:error, _} ->
          send.(socket, Map.put(base(credential, "authoring_upload_status"), "upload_id", id))

        other ->
          other
      end

    with {:ok, status} <- upload_response(result, input),
         true <- status["state"] == "uploading" and status["next_offset"] == 0,
         ref = Map.take(status, ~w(owner_epoch upload_id)),
         :ok <- chunks(socket, credential, ref, input, bytes, send) do
      {:ok, ref}
    else
      false -> {:error, :authoring_upload_unavailable}
      error -> error
    end
  end

  defp chunks(socket, credential, ref, input, bytes, send) do
    Enum.reduce_while(0..div(byte_size(bytes) - 1, 32_768), :ok, fn index, :ok ->
      offset = index * 32_768
      chunk = binary_part(bytes, offset, min(32_768, byte_size(bytes) - offset))

      request =
        Map.merge(base(credential, "authoring_upload_chunk"), %{
          "upload_ref" => ref,
          "offset" => offset,
          "chunk_base64" => Base.url_encode64(chunk, padding: false)
        })

      result = send.(socket, request)
      recovered = match?({:error, _}, result)

      result =
        case result do
          {:error, _} ->
            send.(
              socket,
              Map.put(base(credential, "authoring_upload_status"), "upload_id", ref["upload_id"])
            )

          other ->
            other
        end

      result =
        case upload_response(result, input) do
          {:ok, %{"next_offset" => ^offset, "state" => "uploading"} = status} when recovered ->
            # One exact retry after status proves the previous chunk was not retained.
            if status["owner_epoch"] == ref["owner_epoch"],
              do: upload_response(send.(socket, request), input),
              else: {:error, :authoring_upload_owner_changed}

          other ->
            other
        end

      case result do
        {:ok, status} ->
          expected_state =
            if offset + byte_size(chunk) == byte_size(bytes), do: "ready", else: "uploading"

          if status["owner_epoch"] == ref["owner_epoch"] and
               status["next_offset"] == offset + byte_size(chunk) and
               status["state"] == expected_state,
             do: {:cont, :ok},
             else: {:halt, {:error, :authoring_upload_unavailable}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp upload_response(
         {:ok, %{"api_version" => 1, "outcome" => "ok", "authoring_upload" => status} = response},
         input
       ) do
    if map_size(response) == 3 and
         EnvelopeCodec.keys?(
           status,
           ~w(format next_offset owner_epoch payload_bytes payload_sha256 purpose remaining_ms state upload_id)
         ) and
         Map.take(status, Map.keys(input)) == input and
         status["format"] == "home-authoring-upload-v1" and
         WotexHome.Profiles.AuthoringUpload.valid_ref?(
           Map.take(status, ~w(owner_epoch upload_id))
         ) and
         is_integer(status["next_offset"]) and status["next_offset"] in 0..input["payload_bytes"] and
         is_integer(status["remaining_ms"]) and status["remaining_ms"] in 0..60_000,
       do: {:ok, status},
       else: {:error, :invalid_authoring_upload_response}
  end

  defp upload_response({:ok, %{"outcome" => "error", "reason" => _}}, _),
    do: {:error, :authoring_upload_unavailable}

  defp upload_response({:ok, _}, _), do: {:error, :invalid_authoring_upload_response}
  defp upload_response(error, _), do: error

  defp cleanup(socket, credential, ref, send),
    do: send.(socket, Map.put(base(credential, "authoring_upload_cancel"), "upload_ref", ref))

  def write_object(response, destination) do
    with true <- EnvelopeCodec.keys?(response, ~w(api_version authoring_object outcome)),
         object = response["authoring_object"],
         true <- EnvelopeCodec.keys?(object, ~w(first_revision object payload_base64)),
         true <- is_integer(object["first_revision"]) and object["first_revision"] > 0,
         summary = object["object"],
         true <- AuthoringObject.valid_summary?(summary),
         encoded when is_binary(encoded) and byte_size(encoded) <= 349_526 <-
           object["payload_base64"],
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == encoded,
         {:ok, native} <- AuthoringObject.new(summary["kind"], bytes),
         {:ok, ^summary} <- AuthoringObject.summary(native),
         :ok <- write_new(destination, bytes) do
      {:ok,
       %{
         "outcome" => "ok",
         "object" => summary,
         "first_revision" => object["first_revision"],
         "output_file" => destination
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_authoring_object_response}
    end
  end

  defp write_new(path, bytes) do
    parent = Path.dirname(path)

    with true <- Path.type(path) == :absolute and byte_size(path) in 1..1024,
         :ok <- no_links(parent),
         {:ok, directory} <- File.lstat(parent),
         true <- directory.type == :directory,
         {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- output_identity(file, path, directory),
             :ok <- IO.binwrite(file, bytes),
             :ok <- :file.sync(file),
             :ok <- output_identity(file, path, directory),
             do: :ok
      after
        File.close(file)
      end
    else
      {:error, :eexist} -> {:error, :authoring_output_exists}
      _ -> {:error, :invalid_authoring_output_file}
    end
  end

  defp no_links("/"), do: :ok

  defp no_links(path) do
    with {:ok, %{type: :directory}} <- File.lstat(path),
         do: no_links(Path.dirname(path)),
         else: (_ -> {:error, :invalid_authoring_output_file})
  end

  defp output_identity(file, path, parent) do
    with {:ok, current} <- File.lstat(Path.dirname(path)),
         true <-
           {current.major_device, current.minor_device, current.inode} ==
             {parent.major_device, parent.minor_device, parent.inode},
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and (stat.mode &&& 0o777) == 0o600,
         {:ok, {:file_info, _, :regular, _, _, _, _, mode, 1, major, minor, inode, uid, _}} <-
           :file.read_file_info(file),
         true <-
           (mode &&& 0o777) == 0o600 and
             {major, minor, inode, uid} ==
               {stat.major_device, stat.minor_device, stat.inode, stat.uid},
         do: :ok,
         else: (_ -> {:error, :invalid_authoring_output_file})
  end

  defp base(credential, operation),
    do: %{"api_version" => 1, "operation" => operation, "credential" => credential}

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
