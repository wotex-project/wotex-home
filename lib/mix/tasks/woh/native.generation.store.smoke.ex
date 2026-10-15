defmodule Woh.Tool.NativeGenerationStoreSmoke.Provider do
  @moduledoc false

  use GenServer

  def init({draft, invalid_first}),
    do: {:ok, %{draft: draft, calls: 0, invalid_first: invalid_first}}

  def handle_call(:calls, _, state), do: {:reply, state.calls, state}

  def handle_call({:generate_profile, _document, _maximum}, _, state) do
    Process.sleep(500)
    draft = if state.invalid_first && state.calls == 0, do: "{}", else: state.draft
    {:reply, {:ok, draft}, %{state | calls: state.calls + 1}}
  end
end

defmodule Woh.Tool.NativeGenerationStoreSmoke do
  @moduledoc false

  alias Woh.Tool.Command
  alias WotexHome.{Authority, Durable.Store, LocalAPI.Server}
  alias WotexHome.LocalAPI.{Client, Frame}

  alias WotexHome.Profiles.{
    AuthoringContract,
    AuthoringObject,
    Custody,
    GenerationPolicy,
    GenerationProvider,
    ProducerIdentity
  }

  def run(executable, root, flow \\ false) do
    for family <- ~w(temperature research),
        scenario <- if(flow, do: ["complete"], else: ~w(complete restart)) do
      directory = Path.join(root, "s-" <> family <> "-" <> scenario)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)

      for child <- ~w(profiles journal) do
        File.mkdir!(Path.join(directory, child))
        File.chmod!(Path.join(directory, child), 0o700)
      end

      {:ok, provider_pid} =
        GenServer.start_link(
          __MODULE__.Provider,
          {fixture("authoring-mechanics")[family]["draft_bytes"], flow}
        )

      policy_input = fixture("generation-preparations")[family]["policy"]
      {:ok, policy} = GenerationPolicy.new(policy_input)
      {:ok, provider} = GenerationProvider.new(policy_input["provider"], provider_pid)
      {:ok, producer} = ProducerIdentity.current()

      installed =
        fixture(family)
        |> Map.take(~w(bindings contracts home_contracts))
        |> Map.put("producer", producer)

      {:ok, contract} =
        AuthoringContract.export(installed, fixture("authoring-mechanics")[family]["limits"])

      store_options =
        [
          path: Path.join(directory, "home.sqlite"),
          profile_custody: __MODULE__.Custody,
          authoring_contract: contract,
          generation_policies: [policy],
          generation_providers: [provider]
        ]

      {:ok, store} = Store.start_link(store_options)

      {:ok, custody} =
        Custody.start_link(
          root: Path.join(directory, "profiles"),
          store_owner: store,
          name: __MODULE__.Custody
        )

      socket = Path.join(directory, "home.sock")

      {:ok, server} =
        Server.start_link(authority: Authority.new(store: store), socket_path: socket)

      proxy_path = Path.join(directory, "proxy.sock")

      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          ifaddr: {:local, String.to_charlist(proxy_path)}
        ])

      File.chmod!(proxy_path, 0o600)

      {:ok, evidence} =
        Agent.start_link(fn -> %{dropped: MapSet.new(), mutations: %{}, raced: false} end)

      proxy =
        Task.async(fn ->
          proxy(
            listener,
            socket,
            evidence,
            Path.join(directory, "journal"),
            store,
            scenario == "complete" && !flow,
            flow
          )
        end)

      try do
        {:ok, credential, 1} =
          Store.provision_principal(store, "author:fixture", ["profile:manage"], [])

        for n <- 2..6,
            do: {:ok, _, ^n} = Store.provision_principal(store, "reader:#{n}", ["read"], [])

        objects = fixture("generation-inputs")[family]["objects"]
        source = Enum.find(objects, &(&1["kind"] == "source"))
        import_object(store, credential, source, 6, "source:native")
        {:ok, _, 8} = Store.provision_principal(store, "reader:8", ["read"], [])
        example = Enum.find(objects, &(&1["kind"] == "fixture"))
        import_object(store, credential, example, 8, "fixture:native")

        input = %{
          "credential" => Base.encode64(credential),
          "preparation" => fixture("generation-preparations")[family]["request"],
          "journal" => Path.join(directory, "journal")
        }

        case Command.run_diagnostic(
               executable,
               [
                 if(flow,
                   do: "--flow",
                   else: if(scenario == "restart", do: "--start-only", else: "--store")
                 ),
                 proxy_path
               ],
               16_384,
               if(flow, do: 30_000, else: 15_000),
               JSON.encode!(input) <> "\n"
             ) do
          {:ok, output} ->
            expected =
              cond do
                flow ->
                  "native generation first decisions, publication, repair, manual assessment and cancellation passed"

                scenario == "restart" ->
                  "native generation restart reservation retained"

                true ->
                  "native generation Store original publication, candidate and cancellation passed"
              end

            unless String.trim(output) == expected,
              do: Mix.raise("native generation Store fixture did not complete")

          {:error, reason} ->
            Mix.shell().error(reason)
            Mix.raise("native generation Store fixture failed")
        end

        if scenario == "restart" do
          for pid <- [server, custody, store], do: GenServer.stop(pid)
          {:ok, restarted} = Store.start_link(store_options)

          {:ok, restarted_custody} =
            Custody.start_link(
              root: Path.join(directory, "profiles"),
              store_owner: restarted,
              name: __MODULE__.Custody
            )

          {:ok, restarted_server} =
            Server.start_link(authority: Authority.new(store: restarted), socket_path: socket)

          try do
            {:ok, before} = Store.revision(restarted)

            case Command.run_diagnostic(
                   executable,
                   ["--restart", proxy_path],
                   16_384,
                   15_000,
                   JSON.encode!(input) <> "\n"
                 ) do
              {:ok, output} ->
                unless String.trim(output) ==
                         "native generation restart unknown original recovered without resuming provider",
                       do: Mix.raise("native generation restart fixture did not complete")

              {:error, reason} ->
                Mix.shell().error(reason)
                Mix.raise("native generation restart fixture failed")
            end

            {:ok, ^before} = Store.revision(restarted)
            {:ok, %{dispatch_enabled: false}} = Store.health(restarted)
          after
            for pid <- [restarted_server, restarted_custody, restarted],
                Process.alive?(pid),
                do: GenServer.stop(pid)
          end
        end

        unless GenServer.call(provider_pid, :calls) == if(flow, do: 2, else: 1),
          do: Mix.raise("native generation replay called its provider")

        state = Agent.get(evidence, & &1)

        unless MapSet.size(state.dropped) == if(flow, do: 3, else: 2) &&
                 Enum.all?(state.mutations, fn {_, count} -> count == 1 end),
               do: Mix.raise("native generation lost-reply recovery repeated a mutation")

        if scenario == "complete" && !flow && !state.raced,
          do: Mix.raise("native generation queued-result race did not execute")

        if scenario == "complete", do: {:ok, %{dispatch_enabled: false}} = Store.health(store)
      rescue
        error ->
          line =
            case __STACKTRACE__ do
              [{_module, _function, _arity, location} | _] -> location[:line]
              _ -> 0
            end

          Mix.raise(
            "native generation Store boundary check failed (#{error.__struct__}, line #{line})"
          )
      after
        :gen_tcp.close(listener)
        Task.shutdown(proxy, :brutal_kill)
        if Process.alive?(evidence), do: Agent.stop(evidence)

        for pid <- [server, custody, store, provider_pid],
            Process.alive?(pid),
            do: GenServer.stop(pid)
      end
    end

    :ok
  end

  defp proxy(listener, socket, evidence, journal, store, race?, workspace?) do
    case :gen_tcp.accept(listener, 20_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 5_000),
               true <- size in 1..65_536,
               {:ok, bytes} <- :gen_tcp.recv(peer, size, 5_000),
               {:ok, request} <- Frame.decode_request(bytes) do
            operation = request["operation"]
            mutation = operation in ~w(authoring_generation_prepare authoring_generation_start)
            workspace_path = Path.join(journal, "native-generation-workspace-v1.json")

            cancellation =
              operation == "authoring_generation_cancel" && workspace?

            if cancellation do
              ["wotex-home.native-generation-workspace.v1", _, workspaces] =
                JSON.decode!(File.read!(workspace_path))

              unless Enum.any?(workspaces, fn [_, _, _, root, _, intent] ->
                       intent && String.contains?(root, request["operation_id"])
                     end),
                     do: Mix.raise("native generation cancellation preceded retained intent")
            end

            if mutation do
              codec =
                if operation == "authoring_generation_prepare",
                  do: WotexHome.Profiles.GenerationPreparation,
                  else: WotexHome.Profiles.GenerationAttempt

              {:ok, original} = codec.encode(request["input"])

              ["wotex-home.native-pending.v7", _, entries] =
                JSON.decode!(File.read!(Path.join(journal, "native-pending-v1.json")))

              unless Enum.any?(entries, fn [category, _, _, input, _] ->
                       category == "generation" && Enum.at(input, 2) == original
                     end),
                     do: Mix.raise("native generation mutation preceded original publication")

              if workspace? do
                ["wotex-home.native-generation-workspace.v1", _, workspaces] =
                  JSON.decode!(File.read!(workspace_path))

                unless Enum.any?(workspaces, fn [_, _, _, root, attempts, _] ->
                         original == root || original in attempts
                       end),
                       do: Mix.raise("native generation mutation preceded workspace publication")
              end
            end

            current = Agent.get(evidence, & &1)

            if race? && operation == "authoring_generation_attempt_status" &&
                 MapSet.member?(current.dropped, "authoring_generation_start") && !current.raced do
              :ok = :sys.suspend(store)
              Agent.update(evidence, &%{&1 | raced: true})

              spawn(fn ->
                Process.sleep(750)
                :sys.resume(store)
              end)
            end

            read_failure =
              if operation in ~w(authoring_generation_status authoring_generation_attempt_status),
                do: File.read(Path.join(journal, "generation-read-failure")),
                else: {:error, :enoent}

            response =
              case read_failure do
                {:ok, "read"} ->
                  nil

                {:ok, "malformed"} ->
                  %{"api_version" => 1, "outcome" => "ok", "authoring_generation" => %{}}

                _ ->
                  case Client.request(socket, request, 5_000) do
                    {:ok, value} -> value
                    _ -> nil
                  end
              end

            drop =
              (mutation || cancellation) && is_map(response) && response["outcome"] == "ok" &&
                !MapSet.member?(Agent.get(evidence, & &1.dropped), operation)

            if mutation || cancellation do
              key =
                {operation,
                 if(mutation, do: request["input"]["operation_id"], else: request["operation_id"])}

              Agent.update(evidence, fn state ->
                %{
                  state
                  | dropped:
                      if(drop, do: MapSet.put(state.dropped, operation), else: state.dropped),
                    mutations: Map.update(state.mutations, key, 1, &(&1 + 1))
                }
              end)
            end

            if !drop && is_map(response) do
              {:ok, frame} = Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
            end
          end
        after
          :gen_tcp.close(peer)
        end

        proxy(listener, socket, evidence, journal, store, race?, workspace?)

      _ ->
        :ok
    end
  end

  defp import_object(store, credential, row, revision, operation) do
    payload = Base.decode64!(row["payload_base64"])
    {:ok, object} = AuthoringObject.new(row["kind"], payload)
    {:ok, summary} = AuthoringObject.summary(object)

    input = %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "object" => summary
    }

    {:ok, receipt} = Store.import_authoring_object(store, credential, input, payload)

    unless receipt["first_revision"] == row["reference"]["first_revision"],
      do: Mix.raise("native source reference drifted")
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))
end
