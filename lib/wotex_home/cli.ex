defmodule WotexHome.CLI do
  @moduledoc """
  Headless client for the private Home socket.

  The credential is read from a 0600 file, not a command-line argument. This
  client has no provisioning, enrollment-commit or device transport authority.

  `main/1` parses one command, sends a framed request to the selected Unix
  socket and prints a bounded result. Use the `receipt` command with the
  original operation ID after a lost mutation response; submitting a new ID
  can create a distinct request.
  """

  import Bitwise

  alias WotexHome.Durable.SupportExport
  alias WotexHome.Id
  alias WotexHome.LocalAPI.{Client, Frame}
  alias WotexHome.Mutation
  alias WotexHome.Rules.Rule

  @usage "usage: wotex_home_cli --socket ABSOLUTE_PATH --credential-file ABSOLUTE_PATH COMMAND\ncommands: health | support-preview | support-write ABSOLUTE_PATH | receipt EPOCH OPERATION_ID | enrollment REVIEW_REF | overrides THING_ID | catalogue [WATERMARK AFTER_ID] | snapshot [WATERMARK AFTER_THING_ID AFTER_CAPABILITY_KEY] | events AFTER_REVISION | request-events AFTER_REVISION | history THING_ID CAPABILITY_KEY [WATERMARK AFTER_REVISION] | review-rules RULES_FILE | submit MUTATION_FILE | cancel EPOCH OPERATION_ID | override-issue EPOCH OPERATION_ID THING_ID BASIS_REVISION DURATION_MS | override-status EPOCH OPERATION_ID | override-revoke EPOCH OPERATION_ID"

  @spec main([String.t()]) :: 0 | 1 | 2 | 3 | 4
  def main(["--help"]), do: usage(0)

  def main(argv) when is_list(argv) do
    with {:ok, socket, credential_file, command} <- options(argv),
         {:ok, credential} <- credential(credential_file),
         {:ok, request} <- request(command, credential),
         {:ok, response} <- send_request(socket, request) do
      respond(command, request, response)
    else
      {:error, :usage} ->
        usage(2)

      {:error, {:uncertain, request}} ->
        uncertainty_message(request)
        3

      {:error, reason} ->
        IO.puts(:stderr, "home CLI error: #{reason}")
        1
    end
  end

  def main(_argv), do: usage(2)

  defp respond(["support-write", destination], _request, %{
         "outcome" => "ok",
         "support" => summary
       }) do
    case SupportExport.write_preview(summary, destination) do
      {:ok, bytes} ->
        IO.puts(
          JSON.encode!(%{"outcome" => "ok", "support_file" => destination, "bytes" => bytes})
        )

        0

      {:error, reason} ->
        IO.puts(:stderr, "home CLI error: #{reason}")
        1
    end
  end

  defp respond(["support-write", _destination], _request, %{"outcome" => "ok"}) do
    IO.puts(:stderr, "home CLI error: invalid_support_response")
    1
  end

  defp respond(_command, request, response) do
    IO.puts(JSON.encode!(response))

    case response do
      %{"outcome" => "ok"} -> 0
      %{"outcome" => "not_found"} -> 4
      %{"outcome" => "error", "reason" => "outcome_unknown"} -> uncertain(request)
      _ -> 1
    end
  end

  defp usage(code) do
    IO.puts(if(code == 0, do: :stdio, else: :stderr), @usage)
    code
  end

  defp options(argv) do
    {opts, command, invalid} =
      OptionParser.parse(argv, strict: [socket: :string, credential_file: :string])

    socket = Keyword.get_values(opts, :socket)
    credential_file = Keyword.get_values(opts, :credential_file)

    if invalid == [] and length(socket) == 1 and length(credential_file) == 1 and
         path?(hd(socket), 100) and path?(hd(credential_file), 1_024) and command != [] do
      {:ok, hd(socket), hd(credential_file), command}
    else
      {:error, :usage}
    end
  end

  defp path?(path, max_bytes),
    do: is_binary(path) and byte_size(path) in 1..max_bytes and Path.type(path) == :absolute

  defp credential(path) do
    with {:ok, encoded} <- private_file(path, 43..45, 129) do
      normalized = if is_binary(encoded), do: String.trim_trailing(encoded, "\n"), else: ""

      with true <- byte_size(normalized) == 43 and String.valid?(normalized),
           {:ok, raw} <- Base.url_decode64(normalized, padding: false),
           true <-
             byte_size(raw) == 32 and
               Base.url_encode64(raw, padding: false) == normalized do
        {:ok, normalized}
      else
        _ -> {:error, :invalid_credential_file}
      end
    else
      _ -> {:error, :invalid_credential_file}
    end
  end

  defp private_file(path, sizes, read_limit) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size in sizes and (stat.mode &&& 0o777) == 0o600,
         {:ok, stream} <- File.open(path, [:read, :binary]) do
      try do
        if private_descriptor?(stream, stat) do
          case IO.binread(stream, read_limit) do
            bytes when is_binary(bytes) ->
              if byte_size(bytes) in sizes and private_descriptor?(stream, stat),
                do: {:ok, bytes},
                else: {:error, :invalid_private_file}

            _ ->
              {:error, :invalid_private_file}
          end
        else
          {:error, :invalid_private_file}
        end
      after
        File.close(stream)
      end
    else
      _ -> {:error, :invalid_private_file}
    end
  end

  defp private_descriptor?(stream, stat) do
    case :file.read_file_info(stream) do
      {:ok, {:file_info, size, :regular, _, _, _, _, mode, _, major, minor, inode, uid, _}} ->
        size == stat.size and (mode &&& 0o777) == 0o600 and
          {major, minor, inode, uid} ==
            {stat.major_device, stat.minor_device, stat.inode, stat.uid}

      _ ->
        false
    end
  end

  defp request(["health"], credential),
    do: {:ok, base("health", credential)}

  defp request(["support-preview"], credential),
    do: {:ok, base("support_preview", credential)}

  defp request(["support-write", destination], credential) do
    if path?(destination, 4_096),
      do: {:ok, base("support_preview", credential)},
      else: {:error, :usage}
  end

  defp request(["receipt", epoch, operation_id], credential) do
    with {:ok, epoch} <- epoch(epoch),
         true <- Id.valid?(operation_id) do
      {:ok,
       base("status", credential)
       |> Map.put("authority_epoch", epoch)
       |> Map.put("operation_id", operation_id)}
    else
      _ -> {:error, :usage}
    end
  end

  defp request(["enrollment", review_ref], credential) do
    if Id.valid?(review_ref),
      do: {:ok, Map.put(base("enrollment_status", credential), "review_ref", review_ref)},
      else: {:error, :usage}
  end

  defp request(["overrides", thing_id], credential) do
    if Id.valid?(thing_id),
      do: {:ok, Map.put(base("overrides", credential), "target_ids", [thing_id])},
      else: {:error, :usage}
  end

  defp request(["catalogue"], credential),
    do: {:ok, page_request("catalogue", credential, nil, nil, 10)}

  defp request(["catalogue", watermark, after_id], credential) do
    with {:ok, watermark} <- epoch(watermark),
         true <- Id.valid?(after_id) do
      {:ok, page_request("catalogue", credential, watermark, after_id, 10)}
    else
      _ -> {:error, :usage}
    end
  end

  defp request(["snapshot"], credential),
    do: {:ok, page_request("snapshot", credential, nil, nil, 100)}

  defp request(["snapshot", watermark, thing_id, capability_key], credential) do
    with {:ok, watermark} <- epoch(watermark),
         true <- Id.valid?(thing_id) and Id.valid?(capability_key) do
      after_key = %{"thing_id" => thing_id, "capability_key" => capability_key}
      {:ok, page_request("snapshot", credential, watermark, after_key, 100)}
    else
      _ -> {:error, :usage}
    end
  end

  defp request([operation, after_revision], credential)
       when operation in ["events", "request-events"] do
    with {:ok, after_revision} <- epoch(after_revision) do
      route = if operation == "request-events", do: "request_events", else: operation

      {:ok,
       base(route, credential)
       |> Map.put("after_revision", after_revision)
       |> Map.put("page_size", 100)}
    else
      _ -> {:error, :usage}
    end
  end

  defp request(["history", thing_id, capability_key], credential),
    do: history_request(thing_id, capability_key, nil, 0, credential)

  defp request(["history", thing_id, capability_key, watermark, after_revision], credential) do
    with {:ok, watermark} <- epoch(watermark),
         {:ok, after_revision} <- epoch(after_revision) do
      history_request(thing_id, capability_key, watermark, after_revision, credential)
    else
      _ -> {:error, :usage}
    end
  end

  defp request(["submit", path], credential) do
    with true <- path?(path, 1_024),
         {:ok, bytes} <- private_file(path, 1..65_536, 65_537),
         {:ok, input} <- Frame.decode_request(bytes),
         {:ok, _mutation} <- Mutation.new(input) do
      {:ok, Map.put(base("submit", credential), "mutation", input)}
    else
      false -> {:error, :usage}
      _ -> {:error, :invalid_mutation_file}
    end
  end

  defp request(["review-rules", path], credential) do
    with true <- path?(path, 1_024),
         {:ok, bytes} <- private_file(path, 1..65_536, 65_537),
         {:ok, %{"rules" => rules} = input} <- Frame.decode_request(bytes),
         true <- map_size(input) == 1 and is_list(rules) and length(rules) in 1..64,
         true <- Enum.all?(rules, &match?({:ok, _}, Rule.new(&1))) do
      {:ok, Map.put(base("review_rules", credential), "rules", rules)}
    else
      false -> {:error, :invalid_rules_file}
      _ -> {:error, :invalid_rules_file}
    end
  end

  defp request(["cancel", epoch, operation_id], credential),
    do: operation_request("cancel", epoch, operation_id, credential)

  defp request(["override-status", epoch, operation_id], credential),
    do: operation_request("override_status", epoch, operation_id, credential)

  defp request(["override-revoke", epoch, operation_id], credential),
    do: operation_request("override_revoke", epoch, operation_id, credential)

  defp request(
         ["override-issue", epoch, operation_id, thing_id, basis_revision, duration_ms],
         credential
       ) do
    with {:ok, epoch} <- epoch(epoch),
         true <- Id.valid?(operation_id) and Id.valid?(thing_id),
         {:ok, basis_revision} <- epoch(basis_revision),
         {:ok, duration_ms} <- epoch(duration_ms),
         true <- duration_ms in 1..900_000 do
      {:ok,
       base("override_issue", credential)
       |> Map.merge(%{
         "authority_epoch" => epoch,
         "operation_id" => operation_id,
         "target_id" => thing_id,
         "basis_revision" => basis_revision,
         "duration_ms" => duration_ms
       })}
    else
      _ -> {:error, :usage}
    end
  end

  defp request(_command, _credential), do: {:error, :usage}

  defp page_request(operation, credential, watermark, after_key, page_size) do
    base(operation, credential)
    |> Map.put("watermark", watermark)
    |> Map.put("after", after_key)
    |> Map.put("page_size", page_size)
  end

  defp history_request(thing_id, capability_key, watermark, after_revision, credential) do
    if Id.valid?(thing_id) and Id.valid?(capability_key) do
      {:ok,
       base("history", credential)
       |> Map.merge(%{
         "thing_id" => thing_id,
         "capability_key" => capability_key,
         "watermark" => watermark,
         "after_revision" => after_revision,
         "page_size" => 100
       })}
    else
      {:error, :usage}
    end
  end

  defp operation_request(operation, epoch, operation_id, credential) do
    with {:ok, epoch} <- epoch(epoch),
         true <- Id.valid?(operation_id) do
      {:ok,
       base(operation, credential)
       |> Map.put("authority_epoch", epoch)
       |> Map.put("operation_id", operation_id)}
    else
      _ -> {:error, :usage}
    end
  end

  defp send_request(socket, request) do
    case Client.request(socket, request) do
      {:ok, _response} = success ->
        success

      {:error, reason}
      when reason in [:timeout, :socket_unavailable, :invalid_response, :response_too_large] ->
        if mutating?(request),
          do: {:error, {:uncertain, request}},
          else: {:error, reason}

      error ->
        error
    end
  end

  defp uncertain(request) do
    if mutating?(request) do
      uncertainty_message(request)
      3
    else
      1
    end
  end

  defp uncertainty_message(request) do
    recovery =
      if String.starts_with?(request["operation"], "override"),
        do: "override-status",
        else: "receipt"

    IO.puts(
      :stderr,
      "home CLI outcome unknown; query #{recovery} #{request_epoch(request)} #{request_id(request)} with the same credential"
    )
  end

  defp mutating?(%{"operation" => operation}),
    do: operation in ["submit", "cancel", "override_issue", "override_revoke"]

  defp request_epoch(%{"mutation" => mutation}), do: mutation["authority_epoch"]
  defp request_epoch(request), do: request["authority_epoch"]
  defp request_id(%{"mutation" => mutation}), do: mutation["operation_id"]
  defp request_id(request), do: request["operation_id"]

  defp base(operation, credential),
    do: %{"api_version" => 1, "operation" => operation, "credential" => credential}

  defp epoch(text) when is_binary(text) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 and value <= 9_223_372_036_854_775_807 -> {:ok, value}
      _ -> {:error, :invalid_epoch}
    end
  end
end
