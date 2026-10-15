defmodule WotexHome.Profiles.AuthoringUpload do
  @moduledoc """
  Holds bounded transient authoring bytes for one actor and authority epoch.

  The upload owner accepts ordered chunks for an exact declared size, digest
  and purpose. Import payloads have a 262,144-byte ceiling; review originals
  have a 131,072-byte ceiling. Checkout lends complete bytes to the owning
  application operation, while finish, cancellation and expiry retire transient
  use. Status refers to the original upload identity.

  Uploads contain no operator bearer or SQLite handle. Their owner epoch and
  leases are process-local, so an owner restart cannot resurrect an earlier
  upload reference. Durable import/review receipts are owned separately by Store.
  """

  use GenServer
  alias WotexHome.{Id, Profiles.EnvelopeCodec}
  @chunk 32_768
  @terminal ~w(consumed cancelled expired invalid)

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @doc "Checks the exact Store process bound to this transient owner."
  def bound_owner(server, owner), do: GenServer.call(server, {:bound_owner, owner})

  def begin(server, scope, input), do: call(server, {:begin, scope, input})

  def append(server, scope, ref, offset, bytes),
    do: call(server, {:append, scope, ref, offset, bytes})

  def status(server, scope, id), do: call(server, {:status, scope, id})
  def cancel(server, scope, ref), do: call(server, {:cancel, scope, ref})
  def checkout(server, scope, ref, purpose), do: call(server, {:checkout, scope, ref, purpose})
  def finish(server, token), do: call(server, {:finish, token})

  def valid_input?(input) do
    EnvelopeCodec.keys?(input, ~w(payload_bytes payload_sha256 purpose upload_id)) and
      Id.valid?(input["upload_id"]) and EnvelopeCodec.digest?(input["payload_sha256"]) and
      is_integer(input["payload_bytes"]) and input["payload_bytes"] > 0 and
      case input["purpose"] do
        "import_payload" -> input["payload_bytes"] <= 262_144
        "review_original" -> input["payload_bytes"] <= 131_072
        _ -> false
      end
  end

  def valid_ref?(ref),
    do:
      EnvelopeCodec.keys?(ref, ~w(owner_epoch upload_id)) and Id.valid?(ref["upload_id"]) and
        is_binary(ref["owner_epoch"]) and Regex.match?(~r/\A[0-9a-f]{32}\z/, ref["owner_epoch"])

  @impl true
  def init(options) do
    owner = options[:store_owner]
    limit = Keyword.get(options, :limit, 16)
    bytes = Keyword.get(options, :byte_limit, 4_194_304)
    originals = Keyword.get(options, :original_limit, 1024)
    ttl = Keyword.get(options, :ttl_ms, 60_000)

    if is_pid(owner) and Process.alive?(owner) and is_integer(limit) and limit in 1..16 and
         is_integer(bytes) and bytes in 1..4_194_304 and is_integer(originals) and
         originals in 1..1024 and
         is_integer(ttl) and ttl in 100..60_000 do
      Process.send_after(self(), :expire, min(ttl, 1000))

      {:ok,
       %{
         owner: owner,
         owner_ref: Process.monitor(owner),
         epoch: random(),
         limit: limit,
         byte_limit: bytes,
         original_limit: originals,
         ttl: ttl,
         entries: %{}
       }}
    else
      {:stop, :invalid_authoring_upload_config}
    end
  end

  @impl true
  def handle_call(message, from, state), do: dispatch(message, from, expire(state))

  defp dispatch({:bound_owner, owner}, _, state) do
    result =
      if owner == state.owner and Process.alive?(owner),
        do: :ok,
        else: {:error, :authoring_upload_owner_changed}

    {:reply, result, state}
  end

  defp dispatch({:begin, scope, input}, _, state) do
    if valid_scope?(scope) and valid_input?(input) do
      key = key(scope, input["upload_id"])

      case state.entries[key] do
        nil ->
          active = Enum.filter(Map.values(state.entries), &(&1.body != nil))

          if map_size(state.entries) < state.original_limit and length(active) < state.limit and
               Enum.sum(Enum.map(active, & &1.input["payload_bytes"])) + input["payload_bytes"] <=
                 state.byte_limit do
            entry = %{
              input: input,
              body: "",
              offset: 0,
              chunks: %{},
              state: "uploading",
              expires: now() + state.ttl,
              caller: nil,
              monitor: nil,
              token: nil
            }

            {:reply, {:ok, summary(state, entry)}, put_entry(state, key, entry)}
          else
            {:reply, {:error, :authoring_upload_capacity}, state}
          end

        %{input: ^input} = entry ->
          {:reply, {:ok, summary(state, entry)}, state}

        _ ->
          {:reply, {:error, :authoring_upload_conflict}, state}
      end
    else
      {:reply, {:error, :invalid_authoring_upload}, state}
    end
  end

  defp dispatch({:status, scope, id}, _, state) do
    if valid_scope?(scope) and Id.valid?(id) do
      case state.entries[key(scope, id)] do
        nil -> {:reply, :not_found, state}
        entry -> {:reply, {:ok, summary(state, entry)}, state}
      end
    else
      {:reply, {:error, :invalid_authoring_upload}, state}
    end
  end

  defp dispatch({:append, scope, ref, offset, bytes}, _, state) do
    with {:ok, key, entry} <- lookup(state, scope, ref),
         true <-
           is_integer(offset) and offset >= 0 and rem(offset, @chunk) == 0 and
             is_binary(bytes) and
             byte_size(bytes) == min(@chunk, entry.input["payload_bytes"] - offset) and
             byte_size(bytes) > 0 do
      digest = sha(bytes)

      cond do
        offset < entry.offset and entry.chunks[offset] == digest ->
          {:reply, {:ok, summary(state, entry)}, state}

        offset < entry.offset ->
          {:reply, {:error, :authoring_upload_conflict}, state}

        entry.state != "uploading" ->
          {:reply, {:error, :authoring_upload_unavailable}, state}

        offset != entry.offset ->
          {:reply, {:error, :authoring_upload_offset_mismatch}, state}

        true ->
          body = entry.body <> bytes

          entry = %{
            entry
            | body: body,
              offset: offset + byte_size(bytes),
              chunks: Map.put(entry.chunks, offset, digest)
          }

          entry =
            if entry.offset == entry.input["payload_bytes"] do
              if sha(body) == entry.input["payload_sha256"],
                do: %{entry | state: "ready"},
                else: %{entry | state: "invalid", body: nil}
            else
              entry
            end

          result =
            if entry.state == "invalid",
              do: {:error, :authoring_upload_digest_mismatch},
              else: {:ok, summary(state, entry)}

          {:reply, result, put_entry(state, key, entry)}
      end
    else
      false -> {:reply, {:error, :invalid_authoring_upload_chunk}, state}
      error -> {:reply, error, state}
    end
  end

  defp dispatch({:cancel, scope, ref}, _, state) do
    with {:ok, key, entry} <- lookup(state, scope, ref) do
      if entry.state == "checked_out" do
        {:reply, {:error, :authoring_upload_checked_out}, state}
      else
        entry =
          if entry.state in @terminal, do: entry, else: %{entry | state: "cancelled", body: nil}

        {:reply, {:ok, summary(state, entry)}, put_entry(state, key, entry)}
      end
    else
      error -> {:reply, error, state}
    end
  end

  defp dispatch({:checkout, scope, ref, purpose}, {caller, _}, state) do
    with {:ok, key, entry} <- lookup(state, scope, ref),
         true <- entry.input["purpose"] == purpose,
         true <- entry.state == "ready" do
      token = make_ref()

      entry = %{
        entry
        | state: "checked_out",
          caller: caller,
          monitor: Process.monitor(caller),
          token: token
      }

      {:reply, {:ok, %{bytes: entry.body, token: token}}, put_entry(state, key, entry)}
    else
      false -> {:reply, {:error, :authoring_upload_unavailable}, state}
      error -> {:reply, error, state}
    end
  end

  defp dispatch({:finish, token}, {caller, _}, state) do
    case Enum.find(state.entries, fn {_, entry} ->
           entry.token == token and entry.caller == caller
         end) do
      {key, entry} ->
        entry = release(entry, if(entry.state == "expired", do: "expired", else: "consumed"))
        {:reply, :ok, put_entry(state, key, entry)}

      _ ->
        {:reply, {:error, :invalid_authoring_upload_checkout}, state}
    end
  end

  defp dispatch(_, _, state), do: {:reply, {:error, :invalid_authoring_upload}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    entries =
      Map.new(state.entries, fn {key, entry} ->
        {key, if(entry.monitor == ref, do: release(entry, "consumed"), else: entry)}
      end)

    {:noreply, %{state | entries: entries}}
  end

  def handle_info(:expire, state) do
    Process.send_after(self(), :expire, min(state.ttl, 1000))
    {:noreply, expire(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_authoring_uploads) |> Map.put(:message, :redacted)

  defp expire(state) do
    instant = now()

    entries =
      Map.new(state.entries, fn {key, entry} ->
        {key,
         if(entry.state not in @terminal and instant >= entry.expires,
           do: %{entry | state: "expired", body: nil},
           else: entry
         )}
      end)

    %{state | entries: entries}
  end

  defp lookup(state, scope, ref) do
    cond do
      not valid_scope?(scope) or not valid_ref?(ref) ->
        {:error, :invalid_authoring_upload_reference}

      ref["owner_epoch"] != state.epoch ->
        {:error, :authoring_upload_owner_changed}

      true ->
        key = key(scope, ref["upload_id"])

        case state.entries[key] do
          nil -> :not_found
          entry -> {:ok, key, entry}
        end
    end
  end

  defp summary(state, entry),
    do:
      Map.merge(entry.input, %{
        "format" => "home-authoring-upload-v1",
        "owner_epoch" => state.epoch,
        "next_offset" => entry.offset,
        "state" => entry.state,
        "remaining_ms" => if(entry.state in @terminal, do: 0, else: max(0, entry.expires - now()))
      })

  defp release(entry, state) do
    if entry.monitor, do: Process.demonitor(entry.monitor, [:flush])
    %{entry | body: nil, state: state, caller: nil, monitor: nil, token: nil}
  end

  defp valid_scope?(scope),
    do:
      EnvelopeCodec.keys?(scope, ~w(authority_epoch principal_id)) and
        Id.valid?(scope["principal_id"]) and is_integer(scope["authority_epoch"]) and
        scope["authority_epoch"] in 1..9_223_372_036_854_775_807

  defp key(scope, id), do: {scope["principal_id"], scope["authority_epoch"], id}
  defp put_entry(state, key, entry), do: %{state | entries: Map.put(state.entries, key, entry)}
  defp now, do: System.monotonic_time(:millisecond)
  defp random, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, _ -> {:error, :authoring_upload_unavailable}
  end
end
