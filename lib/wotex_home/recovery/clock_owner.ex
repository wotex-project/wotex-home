defmodule WotexHome.Recovery.ClockOwner do
  @moduledoc "Original private signed UTC challenge with conservative monotonic bounds; no OS UTC."
  use GenServer
  import Bitwise
  alias WotexHome.Lifx.ProfileBasis
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Recovery.{ClockCodec, Owner, PrivateFile}
  @maximum 9_223_372_036_854_775_807

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def request(server), do: GenServer.call(server, :request)

  def approve(server, digest, package),
    do: GenServer.call(server, {:approve, digest, package}, 60_000)

  def current(server), do: GenServer.call(server, :current)

  @impl true
  def init(options) do
    operator = options[:operator]
    root = options[:root]
    runtime_provider = Keyword.get(options, :runtime, &ProfileBasis.runtime_digest/0)

    with true <- is_pid(operator) and Process.alive?(operator) and private_root?(root),
         true <- is_function(runtime_provider, 0),
         {:ok, names} <- File.ls(root),
         true <- length(names) < 64,
         {:ok, owner, owner_seal} <- Owner.read_sealed(options[:owner_file]),
         {:ok, policy_document, policy_seal} <-
           PrivateFile.read_sealed(options[:policy_file], 4_096),
         {:ok, policy} <- ClockCodec.decode_policy(policy_document),
         {:ok, runtime} <- runtime(runtime_provider),
         started = now(),
         challenge = "clock-challenge:" <> random(),
         request = %{
           "destination_owner_id" => owner.owner_id,
           "runtime_digest" => runtime,
           "challenge_id" => challenge,
           "issuer_id" => policy.issuer_id,
           "issuer_generation" => policy.generation,
           "policy_digest" => policy.policy_digest,
           "issuer_policy_digest" => Artifact.digest(policy_document)
         },
         {:ok, document} <- ClockCodec.request_document(request),
         directory = Path.join(root, "clock-" <> random()),
         :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         request_file = Path.join(directory, "clock-request.json"),
         :ok <- PrivateFile.write(request_file, document, 4_096),
         {:ok, ^document, request_seal} <- PrivateFile.read_sealed(request_file, 4_096),
         true <- now() < started + policy.maximum_response_ms do
      state = %{
        operator: operator,
        monitor: Process.monitor(operator),
        root: root,
        root_identity: identity(root),
        runtime_provider: runtime_provider,
        runtime: runtime,
        phase: :pending,
        directory: directory,
        request_file: request_file,
        document: document,
        digest: Artifact.digest(document),
        policy: policy,
        policy_document: policy_document,
        seals: [owner_seal, policy_seal, request_seal],
        started: started,
        response_deadline: started + policy.maximum_response_ms,
        age_deadline: started + policy.maximum_age_ms,
        received: nil,
        observed: nil,
        package: nil,
        timer: nil,
        timer_token: nil
      }

      {:ok, schedule(state)}
    else
      _ -> {:stop, :recovery_clock_custody_unavailable}
    end
  rescue
    _ -> {:stop, :recovery_clock_custody_unavailable}
  end

  @impl true
  def handle_call(:request, {caller, _}, %{operator: caller} = state) do
    state = expire(state)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:approve, digest, package}, {caller, _}, %{operator: caller} = state) do
    state = expire(state)
    received = now()

    case state do
      %{phase: :pending, digest: ^digest} ->
        with :ok <- custody(state),
             {:ok, parsed} <- ClockCodec.verify(package, state.document, state.policy_document),
             true <- received < state.response_deadline and received >= state.started,
             response_file = Path.join(state.directory, "clock-response.json"),
             :ok <- PrivateFile.write(response_file, package, 4_096),
             {:ok, ^package, response_seal} <- PrivateFile.read_sealed(response_file, 4_096),
             ready = %{
               state
               | phase: :accepted,
                 received: received,
                 observed: parsed.record["observed_utc_ms"],
                 package: package,
                 seals: state.seals ++ [response_seal]
             },
             {:ok, _} <- interval(ready),
             :ok <- custody(ready) do
          {:reply, {:ok, summary(ready)}, schedule(ready)}
        else
          _ ->
            {:reply, {:error, :recovery_clock_response_unavailable}, %{state | phase: :expired}}
        end

      %{phase: :accepted, digest: ^digest, package: ^package} ->
        case trusted_current(state) do
          {:ok, _} ->
            {:reply, {:ok, summary(state)}, state}

          _ ->
            {:reply, {:error, :recovery_clock_response_unavailable}, %{state | phase: :expired}}
        end

      %{phase: :expired} ->
        {:reply, {:error, :recovery_clock_expired}, state}

      _ ->
        {:reply, {:error, :recovery_clock_conflict}, state}
    end
  end

  def handle_call(:current, _from, state) do
    state = expire(state)

    case trusted_current(state) do
      {:ok, clock} ->
        {:reply, clock, state}

      _ ->
        {:reply, %{confidence: :unknown, now_utc_ms: 0},
         if(state.phase == :accepted, do: %{state | phase: :expired}, else: state)}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :recovery_clock_forbidden}, state}

  @impl true
  def handle_info({:expire, token}, %{timer_token: token} = state) do
    state = expire(state)
    {:noreply, if(state.phase != :expired, do: schedule(state), else: state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_recovery_clock) |> Map.put(:message, :redacted)

  defp trusted_current(%{phase: :accepted} = state) do
    with :ok <- custody(state),
         {:ok, clock} <- interval(state),
         :ok <- custody(state),
         do: {:ok, clock}
  end

  defp trusted_current(_), do: {:error, :recovery_clock_unavailable}

  defp interval(state) do
    current = now()
    earliest = state.observed + (current - state.received) - state.policy.maximum_error_ms
    latest = state.observed + (current - state.started) + state.policy.maximum_error_ms

    if current >= state.received and state.received >= state.started and
         current < state.age_deadline and earliest >= 0 and latest >= earliest and
         latest <= @maximum - 600_000,
       do: {:ok, %{confidence: :trusted, earliest_utc_ms: earliest, latest_utc_ms: latest}},
       else: {:error, :recovery_clock_unavailable}
  end

  defp custody(state) do
    with true <- private_root?(state.root) and identity(state.root) == state.root_identity,
         :ok <- check_seals(state.seals),
         {:ok, current_runtime} <- runtime(state.runtime_provider),
         true <- current_runtime == state.runtime,
         :ok <- check_seals(state.seals),
         true <- private_root?(state.root) and identity(state.root) == state.root_identity do
      :ok
    else
      _ -> {:error, :recovery_clock_custody_unavailable}
    end
  end

  defp check_seals(seals),
    do:
      Enum.reduce_while(seals, :ok, fn seal, :ok ->
        case PrivateFile.check(seal) do
          :ok -> {:cont, :ok}
          _ -> {:halt, {:error, :recovery_clock_custody_unavailable}}
        end
      end)

  defp expire(state) do
    current = now()

    if current < state.started or current >= state.age_deadline or
         (state.phase == :pending and current >= state.response_deadline),
       do: %{state | phase: :expired},
       else: state
  end

  defp summary(state),
    do: %{
      state: state.phase,
      request_file: state.request_file,
      request_digest: state.digest,
      issuer_id: state.policy.issuer_id,
      maximum_error_ms: state.policy.maximum_error_ms,
      response_remaining_ms: max(state.response_deadline - now(), 0),
      age_remaining_ms: max(state.age_deadline - now(), 0),
      authority_granted: false
    }

  defp schedule(state) do
    deadline = if state.phase == :pending, do: state.response_deadline, else: state.age_deadline
    if state.timer, do: Process.cancel_timer(state.timer)
    token = make_ref()
    timer = Process.send_after(self(), {:expire, token}, max(min(deadline - now(), 1_000), 1))
    %{state | timer: timer, timer_token: token}
  end

  defp runtime(provider) do
    case provider.() do
      {:ok, digest} = result ->
        if WotexHome.Profiles.Codec.digest?(digest),
          do: result,
          else: {:error, :recovery_clock_runtime_unavailable}

      _ ->
        {:error, :recovery_clock_runtime_unavailable}
    end
  rescue
    _ -> {:error, :recovery_clock_runtime_unavailable}
  catch
    _, _ -> {:error, :recovery_clock_runtime_unavailable}
  end

  defp private_root?(path) do
    is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path and
      Enum.all?(path |> Path.split() |> Enum.scan(&Path.join(&2, &1)), fn parent ->
        match?({:ok, %{type: :directory}}, File.lstat(parent))
      end) and
      case File.lstat(path) do
        {:ok, stat} -> band(stat.mode, 0o777) == 0o700
        _ -> false
      end
  end

  defp identity(path) do
    case File.lstat(path) do
      {:ok, stat} ->
        {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode}

      _ ->
        :unavailable
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp random, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
