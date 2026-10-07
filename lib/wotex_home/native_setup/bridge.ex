defmodule WotexHome.NativeSetup.Bridge do
  @moduledoc "Finite verifier-only setup frames on the trusted parent's private IO device."
  alias WotexHome.Authority
  alias WotexHome.NativeSetup.Codec
  @timeout 5_000
  @maximum 4_096

  def run(%Authority{} = authority, device \\ :stdio) do
    case Authority.owner(authority) do
      owner when is_pid(owner) ->
        monitor = Process.monitor(owner)

        context = %{
          authority: %{authority | store: owner},
          owner: owner,
          monitor: monitor,
          device: device
        }

        try do
          loop(context)
        after
          Process.demonitor(monitor, [:flush])
        end

      _ ->
        {:error, :native_setup_unavailable}
    end
  end

  defp loop(context) do
    case frame(context) do
      {:ok, kind, input, deadline} ->
        case operation(context, kind, input, deadline) do
          {:ok, response_kind, value, terminal} ->
            case reply(context, response_kind, value, deadline) do
              :ok when not terminal -> loop(context)
              :ok -> {:error, :native_setup_unavailable}
              error -> error
            end

          {:error, reason} ->
            _ = reply(context, "error", %{"reason" => Atom.to_string(reason)}, deadline)
            {:error, reason}
        end

      :eof ->
        :ok

      {:invalid, deadline} ->
        _ = reply(context, "error", %{"reason" => "invalid_native_setup_record"}, deadline)
        {:error, :invalid_native_setup_record}

      error ->
        error
    end
  end

  defp frame(context) do
    case work(context, :infinity, fn -> {IO.binread(context.device, 1), now()} end) do
      {:ok, {first, received}} when is_binary(first) and byte_size(first) == 1 ->
        deadline = received + @timeout

        with {:ok, rest} <- read(context, 3, deadline),
             <<size::unsigned-big-32>> = first <> rest,
             true <- size in 1..@maximum,
             {:ok, body} <- read(context, size, deadline),
             {:ok, kind, value} <- request(body),
             :ok <- fresh_deadline(deadline) do
          {:ok, kind, value, deadline}
        else
          false -> {:invalid, deadline}
          :eof -> {:error, :channel_closed}
          {:error, :invalid_native_setup_record} -> {:invalid, deadline}
          error -> error
        end

      {:ok, {:eof, _}} ->
        :eof

      {:ok, _} ->
        {:error, :channel_closed}

      error ->
        error
    end
  end

  defp request(body) do
    case Codec.decode("identity_request", body) do
      {:ok, value} ->
        {:ok, "identity", value}

      _ ->
        case Codec.decode("ensure", body) do
          {:ok, value} -> {:ok, "ensure", value}
          _ -> {:error, :invalid_native_setup_record}
        end
    end
  end

  defp read(context, size, deadline) do
    case work(context, deadline, fn -> IO.binread(context.device, size) end) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == size -> {:ok, bytes}
      {:ok, :eof} -> :eof
      {:ok, _} -> {:error, :channel_closed}
      error -> error
    end
  end

  defp operation(context, kind, value, deadline) do
    callback = fn ->
      if kind == "identity",
        do: Authority.native_setup_identity(context.authority),
        else: Authority.ensure_native_principal(context.authority, value)
    end

    case work(context, deadline, callback) do
      {:ok, {:ok, result}} ->
        {:ok, if(kind == "identity", do: "identity", else: "ensured"), result, false}

      {:ok, {:error, reason}} when reason in [:native_owner_changed, :native_custody_conflict] ->
        {:ok, "error", %{"reason" => Atom.to_string(reason)}, false}

      {:error, :frame_timeout} ->
        {:error, :outcome_unknown}

      {:ok, {:error, :outcome_unknown}} ->
        {:error, :outcome_unknown}

      {:error, :core_owner_lost} = error ->
        error

      _ ->
        {:ok, "error", %{"reason" => "native_setup_unavailable"}, true}
    end
  end

  defp reply(context, kind, value, deadline) do
    with {:ok, body} <- Codec.encode(kind, value),
         true <- byte_size(body) in 1..@maximum,
         {:ok, :ok} <-
           work(context, deadline, fn ->
             IO.binwrite(context.device, <<byte_size(body)::unsigned-big-32, body::binary>>)
           end) do
      :ok
    else
      {:error, :core_owner_lost} = error -> error
      {:error, :frame_timeout} = error -> error
      _ -> {:error, :channel_closed}
    end
  end

  # A single worker owns each blocking IO/decision. It is always reaped before
  # the next one starts. The pinned Store's DOWN ends even an idle first read.
  defp work(context, deadline, callback) do
    if Process.alive?(context.owner) and fresh?(deadline) do
      parent = self()
      tag = make_ref()

      {worker, monitor} =
        spawn_monitor(fn ->
          result =
            try do
              callback.()
            rescue
              _ -> :unavailable
            catch
              :exit, {:timeout, _} -> {:error, :outcome_unknown}
              _, _ -> :unavailable
            end

          send(parent, {tag, result})
        end)

      await(context, worker, monitor, tag, deadline)
    else
      if Process.alive?(context.owner),
        do: {:error, :frame_timeout},
        else: {:error, :core_owner_lost}
    end
  end

  defp await(context, worker, monitor, tag, deadline) do
    owner_monitor = context.monitor

    receive do
      {^tag, value} ->
        reap(worker, monitor)

        cond do
          not Process.alive?(context.owner) -> {:error, :core_owner_lost}
          not fresh?(deadline) -> {:error, :frame_timeout}
          true -> {:ok, value}
        end

      {:DOWN, ^owner_monitor, :process, _, _} ->
        reap(worker, monitor)
        {:error, :core_owner_lost}

      {:DOWN, ^monitor, :process, ^worker, _} ->
        {:error, :channel_closed}
    after
      remaining(deadline) ->
        reap(worker, monitor)
        {:error, :frame_timeout}
    end
  end

  defp reap(worker, monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp fresh?(:infinity), do: true
  defp fresh?(deadline), do: now() < deadline

  defp fresh_deadline(deadline),
    do: if(fresh?(deadline), do: :ok, else: {:error, :frame_timeout})

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end
