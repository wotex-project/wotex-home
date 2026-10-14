defmodule WotexHome.Profiles.OpenAIAdapter do
  @moduledoc """
  Owns remote draft-generation channels with explicit private credential custody.

  Trusted native composition first calls `identity/3` with provider ID, exact
  model ID and a checked `WotexHome.Profiles.OpenAIEndpoint`. The resulting
  remote provider identity binds the endpoint/trust and compiled adapter cohort.
  `start_link/1` requires that exact provider, endpoint, credential-file path,
  maximum output tokens, timeout and concurrency; a registered local name is
  optional. Tokens are 1–65,536, timeout is 1–30,000 milliseconds and concurrency
  is 1–16. The sealed mode-0400 key is private startup input, never an API field.

  `capability/1` returns a checked live
  `WotexHome.Profiles.GenerationProvider` for
  `WotexHome.Host.GenerationInstallation`, without credentials or routing data.
  Each Store-reserved `{:generate_profile, document, output_bytes}` call performs
  one tool-free HTTPS exchange and returns exact draft bytes within the supplied
  ceiling. Exhausted concurrency or changed credential custody refuses before
  opening another channel.

  Caller loss, deadline or adapter death closes the original channel without
  retry, key rotation or automatic repair. Diagnostic state is redacted.
  Returned drafts remain proposals for the actual WPF finalizer and current
  Store guards; neither a response nor the capability grants source review,
  profile approval or device-effect authority.
  """

  use GenServer, restart: :temporary
  alias WotexHome.Id

  alias WotexHome.Profiles.{
    AuthoringProducer,
    GenerationProvider,
    OpenAIEndpoint,
    OpenAIHTTPS,
    OpenAIWire
  }

  alias WotexHome.Recovery.PrivateFile

  @modules [__MODULE__, OpenAIEndpoint, OpenAIHTTPS, OpenAIWire]
  @keys [:concurrency, :credential_file, :endpoint, :max_output_tokens, :provider, :timeout_ms]

  @doc "Identifies the exact installed code and endpoint cohort for an explicit model."
  def identity(id, model, endpoint) do
    with true <- Id.valid?(id) and Id.valid?(model),
         :ok <- OpenAIEndpoint.validate(endpoint),
         {:ok, code} <- code_identity() do
      {:ok,
       %{
         "id" => id,
         "model_id" => model,
         "locality" => "remote",
         "adapter_sha256" =>
           AuthoringProducer.sha(
             "wotex-home.openai-adapter@1\n" <> JSON.encode!([endpoint.sha256, code])
           )
       }}
    else
      _ -> invalid()
    end
  end

  @doc "Starts one explicit temporary adapter after validating policy identity and private key."
  def start_link(options) do
    with {:ok, prepared} <- prepare(options),
         do: GenServer.start_link(__MODULE__, prepared, Keyword.take(options, [:name]))
  end

  @doc "Returns the checked live local capability without credentials or private routing."
  def capability(server) do
    GenServer.call(server, :capability, 5000)
  catch
    :exit, _ -> {:error, :generation_unavailable}
  end

  defp prepare(options) do
    with true <- bounded?(options, 7) and Keyword.keyword?(options),
         names = Keyword.keys(options),
         true <-
           length(names) == length(Enum.uniq(names)) and Enum.sort(names -- [:name]) == @keys,
         input = Map.new(Keyword.delete(options, :name)),
         true <-
           not Keyword.has_key?(options, :name) or
             (is_atom(options[:name]) and options[:name] not in [nil, true, false]),
         %{"id" => id, "model_id" => model} <- input.provider,
         {:ok, actual} <- identity(id, model, input.endpoint),
         true <- actual == input.provider,
         true <- is_integer(input.max_output_tokens) and input.max_output_tokens in 1..65536,
         true <- is_integer(input.timeout_ms) and input.timeout_ms in 1..30000,
         true <- is_integer(input.concurrency) and input.concurrency in 1..16,
         {:ok, key, seal} <- credential(input.credential_file) do
      {:ok, Map.merge(input, %{key: key, seal: seal, jobs: %{}})}
    else
      {:error, :openai_credential_unavailable} = error -> error
      _ -> invalid()
    end
  end

  @impl true
  def init(input) do
    Process.flag(:trap_exit, true)
    {:ok, input}
  end

  @impl true
  def handle_call(:capability, _, state),
    do: {:reply, GenerationProvider.new(state.provider, self()), state}

  def handle_call({:generate_profile, document, ceiling}, from, state) do
    with true <- is_integer(ceiling) and ceiling in 1..262_144,
         true <- map_size(state.jobs) < state.concurrency,
         {:ok, body} <-
           OpenAIWire.request(document, state.provider["model_id"], state.max_output_tokens),
         {:ok, key, seal} <- credential(state.credential_file),
         true <- key == state.key and seal == state.seal do
      parent = self()
      token = make_ref()
      endpoint = state.endpoint
      model = state.provider["model_id"]
      timeout = state.timeout_ms
      owner_monitor = Process.monitor(elem(from, 0))

      {worker, monitor} =
        :erlang.spawn_opt(
          fn ->
            result = exchange(endpoint, key, body, model, ceiling, timeout)
            send(parent, {:openai_result, self(), token, result})
          end,
          [:link, :monitor]
        )

      timer = Process.send_after(self(), {:openai_deadline, token}, timeout)

      job = %{
        from: from,
        worker: worker,
        monitor: monitor,
        owner_monitor: owner_monitor,
        timer: timer
      }

      {:noreply, %{state | jobs: Map.put(state.jobs, token, job)}}
    else
      {:error, :invalid_response} -> {:reply, {:error, :invalid_response}, state}
      _ -> {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :unavailable}, state}

  @impl true
  def handle_info({:openai_result, worker, token, result}, state) do
    case state.jobs[token] do
      %{worker: ^worker} = job ->
        GenServer.reply(job.from, result)
        {:noreply, retire(state, token)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:openai_deadline, token}, state) do
    if job = state.jobs[token], do: GenServer.reply(job.from, {:error, :deadline_expired})
    {:noreply, retire(state, token)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Enum.find(state.jobs, fn {_, job} -> ref in [job.monitor, job.owner_monitor] end) do
      {token, %{monitor: ^ref} = job} ->
        GenServer.reply(job.from, {:error, :unknown})
        {:noreply, retire(state, token)}

      {token, _} ->
        {:noreply, retire(state, token)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.jobs, fn {token, _} -> retire(state, token) end)
    :ok
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_openai_adapter)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)

  defp retire(state, token) do
    case Map.pop(state.jobs, token) do
      {nil, _} ->
        state

      {job, remaining} ->
        Process.cancel_timer(job.timer)
        Process.demonitor(job.monitor, [:flush])
        Process.demonitor(job.owner_monitor, [:flush])
        if Process.alive?(job.worker), do: Process.exit(job.worker, :kill)
        %{state | jobs: remaining}
    end
  end

  defp exchange(endpoint, key, body, model, ceiling, timeout) do
    with {:ok, response} <- OpenAIHTTPS.post(endpoint, key, body, timeout),
         do: OpenAIWire.response(response, model, ceiling)
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  defp credential(path) do
    with {:ok, bytes, seal} <- PrivateFile.read_sealed(path, 4097),
         key = String.trim_trailing(bytes, "\n"),
         true <- bytes == key or bytes == key <> "\n",
         true <- byte_size(key) in 16..4096 and Regex.match?(~r/\Ask-[A-Za-z0-9_-]+\z/, key),
         do: {:ok, key, seal},
         else: (_ -> {:error, :openai_credential_unavailable})
  end

  defp code_identity do
    Enum.reduce_while(@modules, {:ok, []}, fn module, {:ok, acc} ->
      with {:module, ^module} <- Code.ensure_loaded(module),
           {^module, bytes, _} <- :code.get_object_code(module),
           {:ok, {^module, md5}} <- :beam_lib.md5(bytes),
           true <- md5 == module.module_info(:md5) do
        {:cont, {:ok, [[Atom.to_string(module), AuthoringProducer.sha(bytes)] | acc]}}
      else
        _ -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort(entries)}
      error -> error
    end
  end

  defp invalid, do: {:error, :invalid_openai_adapter}
  defp bounded?([], _), do: true
  defp bounded?([_ | _], 0), do: false
  defp bounded?([_ | rest], count), do: bounded?(rest, count - 1)
  defp bounded?(_, _), do: false
end
