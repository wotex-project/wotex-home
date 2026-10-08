defmodule WotexHome.Schedules.ClockOwner do
  @moduledoc "Private purpose-specific temporal source custody, bound to one actual Store boot. Never reads SQLite or owns an operator bearer."
  use GenServer
  alias WotexHome.Durable.Store
  alias WotexHome.Recovery.PrivateFile
  alias WotexHome.Schedules.{ClockCodec, ClockLease, Codec}
  @domain "wotex-home.schedule-clock-runtime.v1"
  @maximum 9_223_372_036_854_775_807

  def runtime_digest, do: WotexHome.RuntimeArtifacts.digest([:wotex_home], @domain)

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def request(server), do: GenServer.call(server, :request)

  def approve(server, digest, package),
    do: GenServer.call(server, {:approve, digest, package}, 10_000)

  def binding(server), do: GenServer.call(server, :binding)
  def current(server, context), do: GenServer.call(server, {:current, context}, 5_000)

  @impl true
  def init(options) do
    operator = options[:operator]
    store = GenServer.whereis(options[:store])
    root = options[:root]

    providers = %{
      monotonic: Keyword.get(options, :monotonic, fn -> System.monotonic_time(:millisecond) end),
      wall: Keyword.get(options, :wall, fn -> System.system_time(:millisecond) end),
      runtime: Keyword.get(options, :runtime, &runtime_digest/0)
    }

    with true <- is_pid(store) and is_pid(operator) and Process.alive?(operator),
         true <- Enum.all?(providers, fn {_, provider} -> is_function(provider, 0) end),
         {:ok, root_seal} <- root_seal(root),
         {:ok, names} <- File.ls(root),
         true <- length(names) < 64,
         {:ok, binding} <- Store.temporal_clock_binding(store),
         {:ok, policy_document, policy_seal} <-
           PrivateFile.read_sealed(options[:policy_file], 4_096),
         {:ok, policy} <- ClockCodec.decode_policy(policy_document),
         {:ok, runtime} <- providers.runtime.(),
         true <- runtime == binding.scope["runtime_digest"] and runtime == policy.runtime_digest,
         {:ok, started, wall} <- observation(providers, binding.monotonic_origin),
         input =
           Map.merge(binding.scope, %{
             "challenge_nonce" => random(),
             "source_id" => policy.source_id,
             "issuer_id" => policy.issuer_id,
             "issuer_generation" => policy.issuer_generation,
             "qualification_digest" => policy.qualification_digest,
             "policy_document_digest" => Codec.hash(policy_document)
           }),
         {:ok, document} <- ClockCodec.request_document(input),
         directory = Path.join(root, "temporal-" <> random()),
         :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         request_file = Path.join(directory, "request.json"),
         :ok <- PrivateFile.write(request_file, document, 4_096),
         {:ok, ^document, request_seal} <- PrivateFile.read_sealed(request_file, 4_096) do
      state = %{
        store: store,
        store_monitor: Process.monitor(store),
        operator: operator,
        operator_monitor: Process.monitor(operator),
        root: root,
        root_seal: root_seal,
        providers: providers,
        binding: binding,
        phase: :pending,
        directory: directory,
        request_file: request_file,
        document: document,
        digest: Codec.hash(document),
        policy: policy,
        policy_document: policy_document,
        seals: [policy_seal, request_seal],
        started: started,
        prior_monotonic: started,
        prior_wall: wall,
        initial_wall: wall,
        lease: nil,
        package: nil,
        timer: nil,
        timer_token: nil
      }

      {:ok, schedule(state)}
    else
      _ -> {:stop, :schedule_clock_custody_unavailable}
    end
  rescue
    _ -> {:stop, :schedule_clock_custody_unavailable}
  end

  @impl true
  def handle_call(:request, {caller, _}, %{operator: caller} = state) do
    state = check(state)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:approve, digest, package}, {caller, _}, %{operator: caller} = state) do
    state = check(state)

    case state do
      %{phase: :pending, digest: ^digest} ->
        with :ok <- custody(state),
             {:ok, received, _} <- observation(state.providers, state.binding.monotonic_origin),
             {:ok, lease} <-
               ClockLease.establish(
                 state.document,
                 state.policy_document,
                 package,
                 state.started,
                 received
               ),
             response_file = Path.join(state.directory, "response.json"),
             :ok <- PrivateFile.write(response_file, package, 4_096),
             {:ok, ^package, response_seal} <- PrivateFile.read_sealed(response_file, 4_096),
             ready = %{
               state
               | phase: :accepted,
                 lease: lease,
                 package: package,
                 seals: state.seals ++ [response_seal]
             },
             %{phase: :accepted} = ready <- check(ready) do
          {:reply, {:ok, summary(ready)}, schedule(ready)}
        else
          _ -> {:reply, {:error, :schedule_clock_response_unavailable}, expire(state)}
        end

      %{phase: :accepted, digest: ^digest, package: ^package} ->
        {:reply, {:ok, summary(state)}, state}

      %{phase: :expired} ->
        {:reply, {:error, :schedule_clock_expired}, state}

      _ ->
        {:reply, {:error, :schedule_clock_conflict}, state}
    end
  end

  def handle_call(:binding, {caller, _}, %{store: caller} = state) do
    state = check(state)

    result =
      if state.phase == :accepted,
        do: {:ok, state.binding},
        else: {:error, :schedule_clock_unavailable}

    {:reply, result, state}
  end

  def handle_call({:current, context}, {caller, _}, %{store: caller} = state) do
    state = check(state)

    result =
      with %{phase: :accepted} <- state,
           true <- Codec.exact?(context, [:scope, :now_ms]),
           true <- context.scope == state.binding.scope,
           {:ok, sample, _} <- ClockLease.current(state.lease, context.scope, context.now_ms),
           :ok <- custody(state),
           do: {:ok, sample},
           else: (_ -> {:error, :schedule_clock_unavailable})

    {:reply, result, if(match?({:ok, _}, result), do: state, else: expire(state))}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :schedule_clock_forbidden}, state}

  @impl true
  def handle_info({:expire, token}, %{timer_token: token} = state) do
    state = check(state)
    {:noreply, if(state.phase == :expired, do: state, else: schedule(state))}
  end

  def handle_info({:DOWN, reference, :process, _, _}, %{store_monitor: reference} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, reference, :process, _, _}, %{operator_monitor: reference} = state),
    do:
      {:noreply,
       if(state.phase == :pending,
         do: expire(%{state | operator: nil}),
         else: %{state | operator: nil}
       )}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_temporal_clock) |> Map.put(:message, :redacted)

  defp check(%{phase: :expired} = state), do: state

  defp check(state) do
    with :ok <- custody(state),
         {:ok, current, wall} <- observation(state.providers, state.binding.monotonic_origin),
         true <-
           ClockLease.continuous?(
             state.policy,
             state.prior_monotonic,
             state.prior_wall,
             current,
             wall
           ),
         true <-
           ClockLease.continuous?(state.policy, state.started, state.initial_wall, current, wall),
         true <-
           current >= state.started and current - state.started < state.policy.maximum_age_ms,
         true <-
           state.phase != :pending or current - state.started < state.policy.maximum_response_ms,
         :ok <- check_lease(state, current) do
      %{state | prior_monotonic: current, prior_wall: wall}
    else
      _ -> expire(state)
    end
  rescue
    _ -> expire(state)
  catch
    _, _ -> expire(state)
  end

  defp check_lease(%{phase: :pending}, _), do: :ok

  defp check_lease(state, current) do
    with {:ok, _, _} <- ClockLease.current(state.lease, state.binding.scope, current), do: :ok
  end

  defp custody(state) do
    with true <- Process.alive?(state.store),
         {:ok, seal} <- root_seal(state.root),
         true <- seal == state.root_seal,
         true <- Enum.all?(state.seals, &(PrivateFile.check(&1) == :ok)),
         {:ok, runtime} <- state.providers.runtime.(),
         true <- runtime == state.binding.scope["runtime_digest"],
         true <- Enum.all?(state.seals, &(PrivateFile.check(&1) == :ok)),
         {:ok, final_seal} <- root_seal(state.root),
         true <- final_seal == state.root_seal,
         do: :ok,
         else: (_ -> {:error, :schedule_clock_custody_unavailable})
  end

  defp observation(providers, origin) do
    monotonic = providers.monotonic.() - origin
    wall = providers.wall.()

    if Codec.integer?(monotonic, 0, @maximum - 600_600) and
         Codec.integer?(wall, -@maximum, @maximum),
       do: {:ok, monotonic, wall},
       else: {:error, :schedule_clock_discontinuous}
  end

  defp root_seal(path) do
    with true <- is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path,
         true <-
           Enum.all?(path |> Path.split() |> Enum.scan(&Path.join(&2, &1)), fn name ->
             match?({:ok, %{type: :directory}}, File.lstat(name))
           end),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700,
         do:
           {:ok,
            {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode}},
         else: (_ -> {:error, :schedule_clock_custody_unavailable})
  end

  defp expire(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | phase: :expired, lease: nil, timer: nil, timer_token: nil}
  end

  defp summary(state),
    do: %{
      state: state.phase,
      request_file: state.request_file,
      request_digest: state.digest,
      source_id: state.policy.source_id,
      clock_generation: state.binding.scope["clock_generation"],
      authority_granted: false
    }

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    token = make_ref()
    timer = Process.send_after(self(), {:expire, token}, 1_000)
    %{state | timer: timer, timer_token: token}
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
