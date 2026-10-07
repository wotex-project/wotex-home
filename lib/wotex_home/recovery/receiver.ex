defmodule WotexHome.Recovery.Receiver do
  @moduledoc "Timed foreground receiving exchange; keys and clock trust come only from private custody."
  alias WotexHome.Durable.Backup
  alias WotexHome.Profiles.Wire

  alias WotexHome.Recovery.{
    ClockOwner,
    Destination,
    IssuerPolicies,
    PrivateFile,
    TransferReviewCodec
  }

  def run(arguments, key, options \\ [])

  def run(
        [directory, archive, owner_file, clock_policy, issuers_file, review_root],
        key,
        options
      )
      when is_binary(key) and byte_size(key) == 32 do
    managed(fn ->
      with true <-
             Enum.all?(
               [directory, archive, owner_file, clock_policy, issuers_file, review_root],
               &canonical?/1
             ),
           true <- Enum.all?([owner_file, clock_policy, issuers_file], &outside?(&1, directory)),
           {:ok, _} <- Backup.retired_transfer_basis(archive, key),
           {:ok, issuers} <- IssuerPolicies.open(issuers_file),
           {:ok, io} <- io(options),
           {:ok, clock} <-
             ClockOwner.start_link(
               root: review_root,
               operator: self(),
               owner_file: owner_file,
               policy_file: clock_policy
             ) do
        Process.unlink(clock)

        try do
          with :ok <- clock_exchange(clock, io),
               {:ok, session} <-
                 Destination.start_link(
                   directory: directory,
                   review_root: review_root,
                   owner_file: owner_file,
                   archive_basis: fn -> Backup.retired_transfer_basis(archive, key) end,
                   issuer_policies: issuers,
                   clock: fn -> ClockOwner.current(clock) end,
                   ttl_ms: 600_000
                 ) do
            Process.unlink(session)

            try do
              transfer_exchange(session, clock, io)
            after
              stop(session, &Supervisor.stop/1)
            end
          end
        after
          stop(clock, &GenServer.stop/1)
        end
      else
        false -> {:error, :invalid_receiving_request}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :receiving_unavailable}
      end
    end)
  end

  def run(_, _, _), do: {:error, :invalid_receiving_request}

  def status([directory, owner_file, review_root, review_file]) do
    managed(fn ->
      with true <- Enum.all?([directory, owner_file, review_root, review_file], &canonical?/1),
           true <- outside?(owner_file, directory),
           {:ok, session} <-
             Destination.start_link(
               directory: directory,
               owner_file: owner_file,
               review_root: review_root,
               archive_basis: fn -> {:error, :archive_unavailable} end
             ) do
        Process.unlink(session)

        try do
          Destination.recover(session, review_file)
        after
          stop(session, &Supervisor.stop/1)
        end
      else
        false -> {:error, :invalid_receiving_request}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :receiving_unavailable}
      end
    end)
  end

  def status(_), do: {:error, :invalid_receiving_request}

  defp clock_exchange(clock, io) do
    requested_at = now()

    with {:ok, request} <- ClockOwner.request(clock),
         deadline = requested_at + request.response_remaining_ms,
         :ok <- emit(io, "clock_request", request),
         {:ok, ["clock-response.v1", digest, response_file]} <- input(io, deadline),
         true <- digest == request.request_digest and canonical?(response_file),
         {:ok, package} <- PrivateFile.read(response_file, 4_096),
         {:ok, _} <- ClockOwner.approve(clock, digest, package) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_receiving_input}
    end
  end

  defp transfer_exchange(session, clock, io) do
    requested_at = now()

    with {:ok, review} <- Destination.prepare(session),
         {:ok, document} <- PrivateFile.read(review.review_file, 4_096),
         {:ok, decoded} <- TransferReviewCodec.decode(document),
         %{confidence: :trusted, earliest_utc_ms: earliest} <- ClockOwner.current(clock),
         clock_requested_at = now(),
         {:ok, clock_status} <- ClockOwner.request(clock),
         deadline =
           min(
             requested_at + review.remaining_ms,
             clock_requested_at + clock_status.age_remaining_ms
           ),
         summary =
           Map.merge(review, %{
             issued_at_utc_ms: decoded["issued_at_utc_ms"],
             minimum_approval_delay_ms: max(decoded["issued_at_utc_ms"] - earliest, 0)
           }),
         :ok <- emit(io, "transfer_review", summary),
         {:ok, ["transfer-approval.v1", digest, isolation_file, operation]} <- input(io, deadline),
         true <- digest == review.review_digest and canonical?(isolation_file),
         {:ok, package} <- PrivateFile.read(isolation_file, 8_192),
         {:ok, _} <- Destination.approve(session, review.review_token, digest, package),
         {:ok, delivery} <- Destination.accept(session, review.review_file, operation) do
      {:ok, delivery}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_receiving_input}
    end
  end

  defp emit(io, phase, summary) do
    case io.write.(%{phase: phase, summary: summary}) do
      :ok -> :ok
      _ -> {:error, :receiving_output_unavailable}
    end
  end

  defp input(io, deadline) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, :receiving_input_timeout}
    else
      task = Task.async(io.read_line)
      result = Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill)

      case result do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) in 1..4_096 ->
          case bytes do
            <<document::binary-size(byte_size(bytes) - 1), "\n">> ->
              with {:ok, values} <- JSON.decode(document),
                   true <- JSON.encode!(values) == document,
                   do: {:ok, values},
                   else: (_ -> {:error, :invalid_receiving_input})

            _ ->
              {:error, :invalid_receiving_input}
          end

        {:ok, :eof} ->
          {:error, :receiving_input_eof}

        nil ->
          {:error, :receiving_input_timeout}

        _ ->
          {:error, :invalid_receiving_input}
      end
    end
  end

  defp io(options) do
    if is_list(options) and Keyword.keyword?(options) and
         Enum.all?(Keyword.keys(options), &(&1 in [:read_line, :write])) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) do
      read = Keyword.get(options, :read_line, fn -> line([], 0) end)

      write =
        Keyword.get(options, :write, fn value -> IO.puts(JSON.encode!(Wire.encode(value))) end)

      if is_function(read, 0) and is_function(write, 1),
        do: {:ok, %{read_line: read, write: write}},
        else: {:error, :invalid_receiving_io}
    else
      {:error, :invalid_receiving_io}
    end
  end

  defp line(_bytes, count) when count >= 4_096, do: :oversized

  defp line(bytes, count) do
    case IO.binread(:stdio, 1) do
      "\n" -> IO.iodata_to_binary(Enum.reverse(["\n" | bytes]))
      byte when is_binary(byte) -> line([byte | bytes], count + byte_size(byte))
      :eof -> :eof
      _ -> :unavailable
    end
  end

  defp outside?(path, directory),
    do:
      path != directory and
        not String.starts_with?(path, directory <> "/")

  defp canonical?(path),
    do: is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path

  defp now, do: System.monotonic_time(:millisecond)

  defp stop(pid, stop) do
    if Process.alive?(pid), do: stop.(pid)
  catch
    :exit, _ -> :ok
  end

  defp managed(callback) do
    previous = Process.flag(:trap_exit, true)

    try do
      callback.()
    rescue
      _ -> {:error, :receiving_unavailable}
    catch
      _, _ -> {:error, :receiving_unavailable}
    after
      Process.flag(:trap_exit, previous)
    end
  end
end
