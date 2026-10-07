defmodule WotexHome.Recovery.ReviewOwner do
  @moduledoc "Private one-use recovery challenges; no Store handle, transport or default trust."
  use GenServer
  import Bitwise
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Profiles.Archive
  alias WotexHome.Lifx.ProfileBasis

  alias WotexHome.Recovery.{
    DomainCodec,
    IsolationDecision,
    Owner,
    PrivateFile,
    TransferAcceptanceCodec,
    TransferReviewCodec
  }

  @permissions "[\"read\",\"host:maintain\",\"profile:manage\",\"enroll:review\"]"
  @maximum 9_223_372_036_854_775_807

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def bind_store(server, store), do: GenServer.call(server, {:bind_store, store})
  def prepare(server), do: GenServer.call(server, :prepare, 60_000)
  def status(server, token), do: GenServer.call(server, {:status, token})

  def approve(server, token, digest, package),
    do: GenServer.call(server, {:approve, token, digest, package}, 60_000)

  def cancel(server, token), do: GenServer.call(server, {:cancel, token})

  def checkout(server, token, input),
    do: GenServer.call(server, {:checkout, token, input}, 60_000)

  def guard(server, token), do: GenServer.call(server, {:guard, token}, 60_000)
  def finish(server, token), do: GenServer.call(server, {:finish, token})

  @impl true
  def init(options) do
    operator = options[:operator]
    ttl = Keyword.get(options, :ttl_ms, 60_000)
    loader = options[:archive_basis]
    trust = Keyword.get(options, :issuer_policies, fn -> %{} end)
    clock = Keyword.get(options, :clock, fn -> %{confidence: :unknown, now_utc_ms: 0} end)
    runtime = Keyword.get(options, :runtime, &ProfileBasis.runtime_digest/0)
    root = options[:root]
    owner_file = options[:owner_file]
    profiles = options[:profile_root]

    if is_pid(operator) and Process.alive?(operator) and is_integer(ttl) and ttl in 100..600_000 and
         Enum.all?([loader, trust, clock, runtime], &is_function(&1, 0)) and private_root?(root) and
         is_binary(owner_file) and (is_nil(profiles) or private_root?(profiles)) do
      timer = Process.send_after(self(), :expire, min(ttl, 1_000))

      {:ok,
       %{
         operator: operator,
         operator_monitor: Process.monitor(operator),
         store: nil,
         store_monitor: nil,
         root: root,
         root_identity: root_identity(root),
         owner_file: owner_file,
         profiles: profiles,
         profiles_identity: if(profiles, do: root_identity(profiles)),
         ttl: ttl,
         loader: loader,
         trust: trust,
         clock: clock,
         runtime: runtime,
         entries: %{},
         consumed: MapSet.new(),
         timer: timer
       }}
    else
      {:stop, :invalid_recovery_review_owner}
    end
  end

  @impl true
  def handle_call({:bind_store, store}, {caller, _}, %{operator: caller, store: nil} = state) do
    if is_pid(store) and store != caller and Process.alive?(store),
      do: {:reply, :ok, %{state | store: store, store_monitor: Process.monitor(store)}},
      else: {:reply, {:error, :invalid_recovery_store_owner}, state}
  end

  def handle_call(:prepare, {caller, _}, %{operator: caller} = state) do
    state = expire(state)

    with true <-
           private_root?(state.root) and root_identity(state.root) == state.root_identity,
         true <-
           map_size(state.entries) < 8 and
             map_size(state.entries) + MapSet.size(state.consumed) < 64,
         {:ok, names} <- File.ls(state.root),
         true <- length(names) < 64,
         {:ok, basis} <- invoke(state.loader),
         {:ok, %{version: 2, counter_state: "no_radio_state"} = domains} <-
           DomainCodec.decode(basis.domains.document),
         true <- Map.delete(domains, :version) == basis.domains,
         {:ok, profile_seals} <- profile_custody(state, basis),
         true <-
           domains.source_counts.principal_rows < 64 and
             domains.source_counts.qualified_profile_heads <= 64 and
             domains.source_counts.override_lease_rows <= 64,
         {:ok, owner, owner_seal} <- Owner.read_sealed(state.owner_file),
         true <- owner.owner_id == basis.retirement_receipt["destination_owner_id"],
         {:ok, runtime} <- invoke(state.runtime),
         {:ok, utc} <- trusted_time(state.clock),
         token = "transfer-review:" <> random(),
         principal = "recovery:" <> random(),
         credential = :crypto.strong_rand_bytes(32),
         review = review(basis, owner, runtime, token, principal, credential, utc, state.ttl),
         {:ok, document} <- TransferReviewCodec.encode(review),
         {:ok, _} <- TransferReviewCodec.isolation_scope(review),
         deadline = now() + state.ttl,
         {:ok, entry} <-
           publish(
             state,
             basis,
             review,
             document,
             credential,
             [owner_seal | profile_seals],
             deadline
           ) do
      if now() < deadline do
        {:reply, {:ok, summary(entry)}, put_in(state.entries[token], entry)}
      else
        {:reply, {:error, :recovery_review_expired},
         %{state | consumed: MapSet.put(state.consumed, token)}}
      end
    else
      false -> {:reply, {:error, :recovery_review_unavailable}, state}
      {:error, reason} when is_atom(reason) -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :recovery_review_unavailable}, state}
    end
  rescue
    _ -> {:reply, {:error, :recovery_review_unavailable}, state}
  end

  def handle_call({:status, token}, {caller, _}, %{operator: caller} = state) do
    state = expire(state)

    result =
      case state.entries[token] do
        nil -> :not_found
        entry -> {:ok, summary(entry)}
      end

    {:reply, result, state}
  end

  def handle_call({:approve, token, digest, package}, {caller, _}, %{operator: caller} = state) do
    state = expire(state)

    case state.entries[token] do
      %{phase: :pending, review_digest: ^digest} = entry ->
        with {:ok, isolated, policy} <- current(state, entry, package),
             :ok <-
               PrivateFile.write(Path.join(entry.directory, "isolation.json"), package, 8_192),
             :ok <-
               PrivateFile.write(
                 Path.join(entry.directory, "issuer-policy.json"),
                 policy,
                 4_096
               ),
             {:ok, ^package, package_seal} <-
               PrivateFile.read_sealed(Path.join(entry.directory, "isolation.json"), 8_192),
             {:ok, ^policy, policy_seal} <-
               PrivateFile.read_sealed(Path.join(entry.directory, "issuer-policy.json"), 4_096) do
          ready =
            Map.merge(entry, %{
              phase: :approved,
              package: package,
              package_seal: package_seal,
              policy: policy,
              policy_seal: policy_seal,
              isolated: isolated
            })

          {:reply, {:ok, summary(ready)}, put_in(state.entries[token], ready)}
        else
          {:error, reason} when is_atom(reason) ->
            {:reply, {:error, reason}, consume(state, token)}

          _ ->
            {:reply, {:error, :recovery_review_unavailable}, consume(state, token)}
        end

      %{phase: :approved, review_digest: ^digest, package: ^package} = entry ->
        with {:ok, _, _} <- current(state, entry, package),
             do: {:reply, {:ok, summary(entry)}, state},
             else: (_ ->
                      {:reply, {:error, :recovery_review_unavailable}, consume(state, token)})

      nil ->
        {:reply, missing(state, token), state}

      _ ->
        {:reply, {:error, :recovery_review_conflict}, state}
    end
  end

  def handle_call({:cancel, token}, {caller, _}, %{operator: caller} = state) do
    if Map.has_key?(state.entries, token),
      do: {:reply, :ok, consume(state, token)},
      else: {:reply, missing(state, token), state}
  end

  def handle_call({:checkout, token, input}, {caller, _}, %{store: caller} = state) do
    state = expire(state)

    case state.entries[token] do
      %{phase: :approved} = entry ->
        with {:ok, operation} <- TransferAcceptanceCodec.decode("operation", input),
             true <-
               Enum.all?(
                 ~w(principal_id source_epoch retirement_revision destination_owner_id),
                 &(operation[&1] == entry.review[&1])
               ),
             true <-
               operation["review_digest"] == entry.review_digest and
                 operation["isolation_package_digest"] == entry.isolated.package_digest,
             {:ok, _, _} <- current(state, entry, entry.package) do
          checked = Map.merge(entry, %{phase: :checked_out, input_document: input})
          material = %{review_document: entry.document, domain_document: entry.domain_document}
          {:reply, {:ok, material}, put_in(state.entries[token], checked)}
        else
          _ -> {:reply, {:error, :recovery_review_conflict}, consume(state, token)}
        end

      nil ->
        {:reply, missing(state, token), state}

      _ ->
        {:reply, {:error, :recovery_review_consumed}, state}
    end
  end

  def handle_call({:guard, token}, {caller, _}, %{store: caller} = state) do
    case state.entries[token] do
      %{phase: :checked_out} = entry -> {:reply, current(state, entry, entry.package), state}
      _ -> {:reply, {:error, :recovery_review_consumed}, state}
    end
  end

  def handle_call({:finish, token}, {caller, _}, %{store: caller} = state) do
    case state.entries[token] do
      %{phase: :checked_out} -> {:reply, :ok, consume(state, token)}
      _ -> {:reply, {:error, :recovery_review_consumed}, state}
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :recovery_review_forbidden}, state}

  @impl true
  def handle_info(:expire, state) do
    timer = Process.send_after(self(), :expire, min(state.ttl, 1_000))
    {:noreply, %{expire(state) | timer: timer}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state)
      when ref == state.operator_monitor or ref == state.store_monitor,
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_recovery_custody) |> Map.put(:message, :redacted)

  defp publish(state, basis, review, document, credential, original_seals, deadline) do
    directory = Path.join(state.root, "review-" <> random())

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         review_file = Path.join(directory, "review.json"),
         domain_file = Path.join(directory, "domains.json"),
         credential_file = Path.join(directory, "credential"),
         :ok <- PrivateFile.write_credential(credential_file, credential),
         :ok <- PrivateFile.write(review_file, document, 4_096),
         :ok <- PrivateFile.write(domain_file, basis.domains.document, 4_194_304),
         {:ok, ^document, review_seal} <- PrivateFile.read_sealed(review_file, 4_096),
         {:ok, domain, domain_seal} <- PrivateFile.read_sealed(domain_file, 4_194_304),
         true <- domain == basis.domains.document,
         {:ok, ^credential, credential_seal} <-
           PrivateFile.read_credential_sealed(credential_file) do
      {:ok,
       %{
         phase: :pending,
         token: review["challenge_id"],
         directory: directory,
         review_file: review_file,
         domain_file: domain_file,
         credential_file: credential_file,
         review: review,
         document: document,
         domain_document: domain,
         review_digest: Artifact.digest(document),
         basis_digest: fingerprint(basis),
         seals: original_seals ++ [review_seal, domain_seal, credential_seal],
         deadline: deadline
       }}
    else
      _ -> {:error, :private_custody_unavailable}
    end
  end

  defp current(state, entry, package) do
    with true <- now() < entry.deadline,
         true <- private_root?(state.root) and root_identity(state.root) == state.root_identity,
         :ok <- check_seals(entry.seals),
         {:ok, document} <- PrivateFile.read(entry.review_file, 4_096),
         true <- document == entry.document,
         {:ok, domain} <- PrivateFile.read(entry.domain_file, 4_194_304),
         true <- domain == entry.domain_document,
         {:ok, credential} <- PrivateFile.read_credential(entry.credential_file),
         true <- Artifact.digest(credential) == entry.review["credential_hash"],
         {:ok, owner} <- Owner.read(state.owner_file),
         true <-
           owner.owner_id == entry.review["destination_owner_id"] and
             owner.owner_custody_digest == entry.review["owner_custody_digest"],
         {:ok, basis} <- invoke(state.loader),
         true <- fingerprint(basis) == entry.basis_digest,
         {:ok, _} <- profile_custody(state, basis),
         {:ok, runtime} <- invoke(state.runtime),
         true <- runtime == entry.review["runtime_digest"],
         {:ok, scope} <- TransferReviewCodec.isolation_scope(entry.review),
         {:ok, {earliest, latest}} <- trusted_time(state.clock),
         true <-
           earliest >= entry.review["issued_at_utc_ms"] and
             latest < entry.review["expires_at_utc_ms"],
         issuers <- invoke_value(state.trust),
         {:ok, isolated} <-
           IsolationDecision.verify(package, scope, issuers, %{
             confidence: :trusted,
             now_utc_ms: earliest
           }),
         {:ok, ^isolated} <-
           IsolationDecision.verify(package, scope, issuers, %{
             confidence: :trusted,
             now_utc_ms: latest
           }),
         {:ok, _} <- DomainCodec.acceptance_basis(domain, isolated.decision["method"]),
         true <-
           isolated.decision["issued_at_utc_ms"] >= entry.review["issued_at_utc_ms"] and
             isolated.decision["expires_at_utc_ms"] <= entry.review["expires_at_utc_ms"],
         {:ok, policy} <-
           TransferAcceptanceCodec.policy_document(
             isolated.decision["issuer_id"],
             issuers[isolated.decision["issuer_id"]]
           ),
         :ok <- original_approval(entry, package, isolated, policy),
         :ok <- check_seals(entry.seals),
         true <- private_root?(state.root) and root_identity(state.root) == state.root_identity,
         {:ok, _} <- profile_custody(state, basis),
         true <- now() < entry.deadline do
      {:ok, isolated, policy}
    else
      false -> {:error, :recovery_review_changed_or_expired}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :recovery_review_unavailable}
    end
  rescue
    _ -> {:error, :recovery_review_unavailable}
  end

  defp check_seals(seals),
    do:
      Enum.reduce_while(seals, :ok, fn seal, :ok ->
        case PrivateFile.check(seal) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp original_approval(%{phase: :pending}, _, _, _), do: :ok

  defp original_approval(entry, package, isolated, policy) do
    with true <-
           entry.package == package and entry.isolated == isolated and entry.policy == policy,
         :ok <- PrivateFile.check(entry.package_seal),
         :ok <- PrivateFile.check(entry.policy_seal),
         {:ok, ^package} <-
           PrivateFile.read(Path.join(entry.directory, "isolation.json"), 8_192),
         {:ok, ^policy} <-
           PrivateFile.read(Path.join(entry.directory, "issuer-policy.json"), 4_096),
         do: :ok,
         else: (_ -> {:error, :recovery_review_changed_or_expired})
  end

  defp review(basis, owner, runtime, token, principal, credential, {earliest, latest}, ttl) do
    source = basis.retirement_receipt

    %{
      "deployment_id" => source["deployment_id"],
      "source_owner_id" => source["source_owner_id"],
      "destination_owner_id" => owner.owner_id,
      "source_epoch" => source["authority_epoch"],
      "retirement_revision" => source["revision"],
      "source_maintenance_revision" => basis.source_maintenance_revision,
      "source_rule_generation" => basis.source_rule_generation,
      "archive_digest" => basis.archive_digest,
      "snapshot_digest" => basis.snapshot_digest,
      "runtime_digest" => runtime,
      "owner_custody_digest" => owner.owner_custody_digest,
      "challenge_id" => token,
      "principal_id" => principal,
      "credential_hash" => Artifact.digest(credential),
      "permissions_document" => @permissions,
      "domain_digest" => basis.domains.domain_digest,
      "domain_count" => basis.domains.domain_count,
      "counter_state" => basis.domains.counter_state,
      "counter_state_digest" => basis.domains.counter_state_digest,
      "issued_at_utc_ms" => latest,
      "expires_at_utc_ms" => earliest + ttl
    }
  end

  defp profile_custody(%{profiles: nil}, %{profile_artifacts: []}), do: {:ok, []}

  defp profile_custody(state, %{profile_artifacts: expected}) when is_binary(state.profiles) do
    with :ok <- Archive.validate_commitments(expected),
         true <-
           private_root?(state.profiles) and
             root_identity(state.profiles) == state.profiles_identity,
         {:ok, names} <- File.ls(state.profiles),
         true <- Enum.sort(names) == Enum.map(expected, &(&1.artifact_digest <> ".json")),
         {:ok, objects, seals} <-
           Enum.reduce_while(expected, {:ok, [], []}, fn commitment, {:ok, objects, seals} ->
             path = Path.join(state.profiles, commitment.artifact_digest <> ".json")

             case PrivateFile.read_sealed(path, 32_768) do
               {:ok, bytes, seal} ->
                 {:cont, {:ok, objects ++ [Map.put(commitment, :bytes, bytes)], seals ++ [seal]}}

               _ ->
                 {:halt, {:error, :destination_profile_custody_unavailable}}
             end
           end),
         :ok <- Archive.validate(expected, objects) do
      {:ok, seals}
    else
      _ -> {:error, :destination_profile_custody_unavailable}
    end
  end

  defp profile_custody(_, _), do: {:error, :destination_profile_custody_unavailable}

  defp summary(entry),
    do: %{
      review_token: entry.token,
      state: entry.phase,
      review_digest: entry.review_digest,
      review_file: entry.review_file,
      domain_file: entry.domain_file,
      credential_file: entry.credential_file,
      principal_id: entry.review["principal_id"],
      destination_owner_id: entry.review["destination_owner_id"],
      source_epoch: entry.review["source_epoch"],
      retirement_revision: entry.review["retirement_revision"],
      domain_count: entry.review["domain_count"],
      counter_state: entry.review["counter_state"],
      permissions: JSON.decode!(entry.review["permissions_document"]),
      new_control_grants: false,
      expires_at_utc_ms: entry.review["expires_at_utc_ms"],
      remaining_ms: max(entry.deadline - now(), 0)
    }

  defp expire(state),
    do:
      Enum.reduce(state.entries, state, fn {token, entry}, acc ->
        if now() >= entry.deadline, do: consume(acc, token), else: acc
      end)

  defp consume(state, token),
    do: %{
      state
      | entries: Map.delete(state.entries, token),
        consumed: MapSet.put(state.consumed, token)
    }

  defp missing(state, token),
    do:
      if(MapSet.member?(state.consumed, token),
        do: {:error, :recovery_review_consumed},
        else: {:error, :recovery_review_missing}
      )

  defp now, do: System.monotonic_time(:millisecond)
  defp random, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp fingerprint(basis),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(basis, [:deterministic]))

  defp trusted_time(provider) do
    case invoke_value(provider) do
      %{confidence: :trusted, now_utc_ms: utc} = value
      when map_size(value) == 2 and is_integer(utc) and utc >= 0 and utc <= @maximum - 600_000 ->
        {:ok, {utc, utc}}

      %{confidence: :trusted, earliest_utc_ms: earliest, latest_utc_ms: latest} = value
      when map_size(value) == 3 and is_integer(earliest) and is_integer(latest) and
             earliest >= 0 and latest >= earliest and latest <= @maximum - 600_000 ->
        {:ok, {earliest, latest}}

      _ ->
        {:error, :isolation_clock_unavailable}
    end
  end

  defp invoke(provider) do
    case invoke_value(provider) do
      {:ok, _} = value -> value
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :recovery_context_unavailable}
    end
  end

  defp invoke_value(provider) do
    provider.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp private_root?(path) do
    is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path and
      path
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.all?(fn parent ->
        case File.lstat(parent) do
          {:ok, %{type: :directory}} -> true
          _ -> false
        end
      end) and
      case File.lstat(path) do
        {:ok, stat} -> band(stat.mode, 0o777) == 0o700
        _ -> false
      end
  end

  defp root_identity(path) do
    case File.lstat(path) do
      {:ok, stat} ->
        {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode}

      _ ->
        :unavailable
    end
  end
end
