defmodule WotexHome.CLI do
  @moduledoc """
  Headless client for the private Home socket.

  The credential is read from a 0600 file, not a command-line argument. This
  client has no provisioning, profile-qualification or device command
  authority. Its opt-in LIFX enrollment command can select only a host-held
  capture and immutable packaged profile; it cannot supply evidence or a
  capability declaration. Its explicit LIFX refresh command supplies only an
  enrolled Home Thing ID; the host resolves current identity and routing.

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

  @usage "usage: wotex_home_cli --socket ABSOLUTE_PATH --credential-file ABSOLUTE_PATH COMMAND\ncommands: health | support-preview | support-write ABSOLUTE_PATH | receipt EPOCH OPERATION_ID | enrollment REVIEW_REF | lifx-discover | lifx-interview SESSION_REF CANDIDATE_REF | lifx-enroll SESSION_REF CANDIDATE_REF PROFILE_REF THING_ID REVIEW_REF | lifx-rereview SESSION_REF CANDIDATE_REF PROFILE_REF THING_ID REVIEW_REF | lifx-refresh THING_ID | overrides THING_ID | catalogue [WATERMARK AFTER_ID] | snapshot [WATERMARK AFTER_THING_ID AFTER_CAPABILITY_KEY] | events AFTER_REVISION | request-events AFTER_REVISION | history THING_ID CAPABILITY_KEY [WATERMARK AFTER_REVISION] | review-rules RULES_FILE | record-rule-review EPOCH OPERATION_ID EXPECTED_REVISION RULES_FILE | rule-review-status EPOCH OPERATION_ID | admit-rule EPOCH OPERATION_ID EXPECTED_REVISION RULES_FILE | activate-rule EPOCH OPERATION_ID EXPECTED_REVISION ADMISSION_REVISION | invoke-rule EPOCH OPERATION_ID GENERATION RULE_ID | rule-status | rule-operation-status EPOCH OPERATION_ID | submit MUTATION_FILE | cancel EPOCH OPERATION_ID | override-issue EPOCH OPERATION_ID THING_ID BASIS_REVISION DURATION_MS | override-status EPOCH OPERATION_ID | override-revoke EPOCH OPERATION_ID"

  @spec main([String.t()]) :: 0 | 1 | 2 | 3 | 4
  def main(["--help"]), do: usage(0)

  def main(argv) when is_list(argv) do
    with {:ok, socket, credential_file, command} <- options(argv),
         {:ok, credential} <- credential(credential_file),
         {:ok, request} <- build_request(command, credential),
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

  @doc "Builds one closed CLI request without opening the local socket."
  @spec build_request([String.t()], String.t()) :: {:ok, map()} | {:error, atom()}
  def build_request(command, credential) when is_list(command) and is_binary(credential),
    do: request(command, credential)

  def build_request(_, _), do: {:error, :usage}

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
      normalized = String.trim_trailing(encoded, "\n")

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

  defp request(["lifx-discover"], credential),
    do: {:ok, base("lifx_discover", credential)}

  defp request(["lifx-interview", session_ref, candidate_ref], credential) do
    if Id.valid?(session_ref) and Id.valid?(candidate_ref) do
      {:ok,
       base("lifx_interview", credential)
       |> Map.put("session_ref", session_ref)
       |> Map.put("candidate_ref", candidate_ref)}
    else
      {:error, :usage}
    end
  end

  defp request(
         [operation, session_ref, candidate_ref, profile_ref, thing_id, review_ref],
         credential
       )
       when operation in ["lifx-enroll", "lifx-rereview"] do
    if Enum.all?([session_ref, candidate_ref, profile_ref, thing_id, review_ref], &Id.valid?/1) do
      route = String.replace(operation, "-", "_")

      {:ok,
       base(route, credential)
       |> Map.merge(%{
         "session_ref" => session_ref,
         "candidate_ref" => candidate_ref,
         "profile_ref" => profile_ref,
         "thing_id" => thing_id,
         "review_ref" => review_ref
       })}
    else
      {:error, :usage}
    end
  end

  defp request(["lifx-refresh", thing_id], credential) do
    if Id.valid?(thing_id),
      do: {:ok, Map.put(base("lifx_refresh", credential), "thing_id", thing_id)},
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
    with {:ok, rules} <- rules_file(path) do
      {:ok, Map.put(base("review_rules", credential), "rules", rules)}
    end
  end

  defp request(["record-rule-review", epoch, operation_id, expected, path], credential) do
    with {:ok, request} <-
           operation_request("record_rule_review", epoch, operation_id, credential),
         {:ok, expected} <- epoch(expected),
         {:ok, rules} <- rules_file(path) do
      {:ok, request |> Map.put("expected_revision", expected) |> Map.put("rules", rules)}
    end
  end

  defp request(["rule-review-status", epoch, operation_id], credential),
    do: operation_request("rule_review_status", epoch, operation_id, credential)

  defp request(["admit-rule", epoch, operation_id, expected, path], credential) do
    with {:ok, request} <- operation_request("admit_rule", epoch, operation_id, credential),
         {:ok, expected} <- epoch(expected),
         {:ok, rules} <- rules_file(path) do
      {:ok, request |> Map.put("expected_revision", expected) |> Map.put("rules", rules)}
    end
  end

  defp request(["activate-rule", epoch, operation_id, expected, admission], credential) do
    with {:ok, request} <- operation_request("activate_rule", epoch, operation_id, credential),
         {:ok, expected} <- epoch(expected),
         {:ok, admission} <- epoch(admission) do
      {:ok,
       request
       |> Map.put("expected_revision", expected)
       |> Map.put("admission_revision", admission)}
    end
  end

  defp request(["invoke-rule", epoch, operation_id, generation, rule_id], credential) do
    with {:ok, request} <- operation_request("invoke_rule", epoch, operation_id, credential),
         {:ok, generation} <- epoch(generation),
         true <- Id.valid?(rule_id) do
      {:ok, request |> Map.put("rule_generation", generation) |> Map.put("rule_id", rule_id)}
    else
      _ -> {:error, :usage}
    end
  end

  defp request(["rule-status"], credential), do: {:ok, base("rule_status", credential)}

  defp request(["rule-operation-status", epoch, operation_id], credential),
    do: operation_request("rule_operation_status", epoch, operation_id, credential)

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

  defp rules_file(path) do
    with true <- path?(path, 1_024),
         {:ok, bytes} <- private_file(path, 1..65_536, 65_537),
         {:ok, %{"rules" => rules} = input} <- Frame.decode_request(bytes),
         true <- map_size(input) == 1 and is_list(rules) and length(rules) in 1..64,
         true <- Enum.all?(rules, &match?({:ok, _}, Rule.new(&1))) do
      {:ok, rules}
    else
      _ -> {:error, :invalid_rules_file}
    end
  end

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
    timeout =
      if request["operation"] in ["review_rules", "record_rule_review"], do: 15_000, else: 5_000

    case Client.request(socket, request, timeout) do
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
    case request["operation"] do
      operation when operation in ["lifx_enroll", "lifx_rereview"] ->
        IO.puts(
          :stderr,
          "home CLI outcome unknown; query enrollment #{request["review_ref"]} with the same credential"
        )

      "lifx_refresh" ->
        IO.puts(
          :stderr,
          "home CLI refresh outcome unknown; query snapshot for #{request["thing_id"]} with the same credential"
        )

      "record_rule_review" ->
        IO.puts(
          :stderr,
          "home CLI outcome unknown; query rule-review-status #{request_epoch(request)} #{request_id(request)} with the same credential"
        )

      operation when operation in ["admit_rule", "activate_rule"] ->
        IO.puts(
          :stderr,
          "home CLI outcome unknown; query rule-operation-status #{request_epoch(request)} #{request_id(request)} with the same credential"
        )

      operation ->
        recovery =
          if String.starts_with?(operation, "override"), do: "override-status", else: "receipt"

        IO.puts(
          :stderr,
          "home CLI outcome unknown; query #{recovery} #{request_epoch(request)} #{request_id(request)} with the same credential"
        )
    end
  end

  defp mutating?(%{"operation" => operation}),
    do:
      operation in [
        "submit",
        "cancel",
        "override_issue",
        "override_revoke",
        "record_rule_review",
        "admit_rule",
        "activate_rule",
        "invoke_rule",
        "lifx_enroll",
        "lifx_rereview",
        "lifx_refresh"
      ]

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
