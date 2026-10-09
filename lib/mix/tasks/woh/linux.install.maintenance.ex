defmodule Woh.Tool.LinuxInstallMaintenance do
  @moduledoc false

  alias Woh.Tool.{LinuxInstallFiles, LinuxUpdateProcess}
  alias WotexHome.{CLI, Id}
  alias WotexHome.LocalAPI.Frame

  @maximum 9_223_372_036_854_775_807
  @status_keys ~w(authority_epoch store_revision rule_generation begin_revision state)
  @update_keys @status_keys ++ ~w(principal_id store_schema_version writable update_fence_enabled)
  @receipt_keys ~w(principal_id authority_epoch operation_id action begin_revision revision rule_generation affected_requests unknown_outcomes state)

  # The caller retains the original operation before begin. No credential is
  # provisioned, printed, persisted or passed in tool arguments/environment.
  # Ending maintenance remains a separate, explicitly authenticated operation.
  def request(
        uid,
        socket,
        command,
        credential,
        tool \\ LinuxInstallFiles.packaged_tool(),
        expected \\ nil
      ) do
    case request_peer(uid, socket, command, credential, tool, expected) do
      {:ok, result, _peer_pid} -> {:ok, result}
      {:not_found, _peer_pid} -> :not_found
      other -> other
    end
  end

  def request_peer(
        uid,
        socket,
        command,
        credential,
        tool \\ LinuxInstallFiles.packaged_tool(),
        expected \\ nil
      ) do
    with true <- is_integer(uid) and uid in 100..999,
         true <- path?(socket),
         true <- command?(command),
         true <- credential?(credential),
         true <-
           expected == nil or
             (match?({:ok, _}, LinuxUpdateProcess.retain(expected)) and expected.account_id == uid),
         {:ok, request} <- CLI.build_request(command, credential),
         {:ok, frame} <- Frame.encode_request(request),
         {:ok, <<peer_pid::unsigned-big-32, body::binary>>} <-
           LinuxInstallFiles.maintenance(uid, socket, frame, tool, expected),
         true <- peer_pid in 1..2_147_483_647,
         {:ok, response} <- Frame.decode_response(body) do
      case decode_response(response, request) do
        {:ok, result} -> {:ok, result, peer_pid}
        :not_found -> {:not_found, peer_pid}
        other -> other
      end
    else
      false -> {:error, :invalid_maintenance_client_input}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :maintenance_client_unavailable}
    end
  end

  def decode_response(%{"api_version" => 1, "outcome" => "not_found"} = response, request)
      when map_size(response) == 2 do
    if request["operation"] == "maintenance_operation_status",
      do: :not_found,
      else: {:error, :invalid_maintenance_response}
  end

  def decode_response(
        %{"api_version" => 1, "outcome" => "error", "reason" => reason} = response,
        _request
      )
      when map_size(response) == 3 and is_binary(reason) do
    if Regex.match?(~r/\A[a-z_]{1,80}\z/, reason),
      do: {:error, {:maintenance_refused, reason}},
      else: {:error, :invalid_maintenance_response}
  end

  def decode_response(
        %{"api_version" => 1, "outcome" => "ok", "maintenance_status" => status} = response,
        %{"operation" => "maintenance_status"}
      )
      when map_size(response) == 3 and is_map(status) do
    if keys?(status, @status_keys) and positive?(status["authority_epoch"]) and
         integer?(status["store_revision"]) and integer?(status["rule_generation"]) and
         integer?(status["begin_revision"]) and
         status["begin_revision"] <= status["store_revision"] and
         ((status["state"] == "normal" and status["begin_revision"] == 0) or
            (status["state"] == "maintenance" and status["begin_revision"] > 0)),
       do: {:ok, status},
       else: {:error, :invalid_maintenance_response}
  end

  def decode_response(
        %{"api_version" => 1, "outcome" => "ok", "maintenance_update_status" => status} = response,
        %{"operation" => "maintenance_update_status"}
      )
      when map_size(response) == 3 and is_map(status) do
    base = Map.take(status, @status_keys)
    base_response = %{"api_version" => 1, "outcome" => "ok", "maintenance_status" => base}

    with true <-
           keys?(status, @update_keys) and Id.valid?(status["principal_id"]) and
             positive?(status["store_schema_version"]) and is_boolean(status["writable"]) and
             is_boolean(status["update_fence_enabled"]),
         {:ok, _} <- decode_response(base_response, %{"operation" => "maintenance_status"}) do
      {:ok, status}
    else
      _ -> {:error, :invalid_maintenance_response}
    end
  end

  def decode_response(
        %{"api_version" => 1, "outcome" => "ok", "maintenance_receipt" => receipt} = response,
        %{"operation" => operation} = request
      )
      when map_size(response) == 3 and is_map(receipt) and
             operation in ["begin_maintenance", "maintenance_operation_status"] do
    if keys?(receipt, @receipt_keys) and Id.valid?(receipt["principal_id"]) and
         receipt["authority_epoch"] == request["authority_epoch"] and
         receipt["operation_id"] == request["operation_id"] and
         positive?(receipt["authority_epoch"]) and Id.valid?(receipt["operation_id"]) and
         receipt["action"] == "begin" and receipt["state"] == "maintenance" and
         positive?(receipt["revision"]) and receipt["begin_revision"] == receipt["revision"] and
         positive?(receipt["rule_generation"]) and integer?(receipt["affected_requests"]) and
         integer?(receipt["unknown_outcomes"]) and
         receipt["unknown_outcomes"] <= receipt["affected_requests"] and
         (operation != "begin_maintenance" or receipt["revision"] > request["expected_revision"]),
       do: {:ok, receipt},
       else: {:error, :invalid_maintenance_response}
  end

  def decode_response(_response, _request), do: {:error, :invalid_maintenance_response}

  defp keys?(value, keys), do: MapSet.new(Map.keys(value)) == MapSet.new(keys)
  defp integer?(value), do: is_integer(value) and value in 0..@maximum
  defp positive?(value), do: integer?(value) and value > 0

  defp credential?(encoded) when is_binary(encoded) and byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> byte_size(raw) == 32 and Base.url_encode64(raw, padding: false) == encoded
      _ -> false
    end
  end

  defp credential?(_), do: false

  defp path?(path) when is_binary(path) and byte_size(path) in 1..100,
    do:
      Regex.match?(~r/\A\/(?:[A-Za-z0-9_+@.-]+\/)*[A-Za-z0-9_+@.-]+\z/, path) and
        not Enum.any?(Path.split(path), &(&1 in [".", ".."]))

  defp path?(_), do: false
  defp command?(["maintenance-status"]), do: true
  defp command?(["maintenance-update-status"]), do: true
  defp command?(["maintenance-operation-status", _, _]), do: true
  defp command?(["maintenance-begin", _, _, _]), do: true
  defp command?(_), do: false
end
