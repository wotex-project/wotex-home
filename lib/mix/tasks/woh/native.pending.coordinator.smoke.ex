defmodule Woh.Tool.NativePendingCoordinatorSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Frame, Server}

  def run(project) do
    root =
      Path.join(
        "/private/tmp",
        "woh-pending-coord-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "coordinator")

    try do
      sources =
        ~w(LocalHealthClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativePendingCodec NativePendingStorage NativePendingCoordinator NativePendingRecoveryOperations)

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-target",
          "arm64-apple-macos15.0",
          "-module-cache-path",
          Path.join(root, "cache"),
          "-framework",
          "SwiftUI"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [
            Path.join(project, "native/macos/Tests/NativePendingCoordinatorSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           :ok <- check(executable, private_directory(root, "lookup"), "lookup"),
           :ok <- check(executable, private_directory(root, "retry"), "retry"),
           :ok <- check(executable, private_directory(root, "recover-lookup"), "recover-lookup"),
           :ok <- check(executable, private_directory(root, "recover-retry"), "recover-retry"),
           :ok <- check(executable, private_directory(root, "recover-scope"), "recover-scope"),
           :ok <- check(executable, private_directory(root, "recover-confirm"), "recover-confirm"),
           :ok <- check(executable, private_directory(root, "publication"), "publication"),
           :ok <-
             run_fixture(
               executable,
               "/private/tmp/woh-inert-no-api.sock",
               private_directory(root, "phases"),
               "phases",
               JSON.encode!(%{
                 "original" => Base.url_encode64(:binary.copy(<<55>>, 32), padding: false),
                 "other" => Base.url_encode64(:binary.copy(<<56>>, 32), padding: false)
               }) <> "\n"
             ),
           do: :ok
    after
      File.rm_rf!(root)
    end
  end

  defp check(executable, directory, mode) do
    journal = private_directory(directory, "journal")
    {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))

    {:ok, thing} =
      WotexHome.Semantics.Thing.new(%{
        "id" => "light:pending-fixture",
        "role" => "Light",
        "profile_ref" => "lifx.fixture:1",
        "capabilities" => [
          %{
            "thing_id" => "light:pending-fixture",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "lifx.fixture:1",
            "evidence_ref" => "fixture:pending",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, original, _} =
      Store.provision_principal(
        store,
        "operator:pending-fixture",
        ["read", "rule:manage", "rule:review", "control:ordinary"],
        [
          thing.id
        ]
      )

    {:ok, other, _} =
      Store.provision_principal(
        store,
        "other:pending-fixture",
        ["read", "rule:manage", "rule:review", "control:ordinary"],
        [
          thing.id
        ]
      )

    authority = Authority.new(store: store)
    socket = Path.join(directory, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(directory, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)
    {:ok, evidence} = Agent.start_link(fn -> %{dropped: nil, requests: []} end)
    proxy = Task.async(fn -> proxy(listener, socket, evidence, journal) end)
    encoded = Base.url_encode64(original, padding: false)

    input =
      JSON.encode!(%{"original" => encoded, "other" => Base.url_encode64(other, padding: false)}) <>
        "\n"

    try do
      if mode == "publication" do
        with :ok <- run_fixture(executable, path, journal, "publication", input),
             %{dropped: nil, requests: requests} <- Agent.get(evidence, & &1),
             true <- Enum.map(requests, & &1["operation"]) == ["controller_identity"],
             {:ok, %{store_revision: 3, dispatch_enabled: false}} <- Store.health(store),
             :not_found <-
               Authority.rule_operation_status(
                 authority,
                 original,
                 1,
                 "rule:publication-original"
               ),
             do: :ok,
             else: (_ -> {:error, "unpublished original guard or mutation absence differed"})
      else
        with :ok <- run_fixture(executable, path, journal, "create", input),
             bytes <- File.read!(Path.join(journal, "native-pending-v1.json")),
             %{dropped: dropped, requests: first} when not is_nil(dropped) <-
               Agent.get(evidence, & &1),
             true <-
               Enum.map(first, & &1["operation"]) == [
                 "controller_identity",
                 "controller_identity",
                 "activate_rule"
               ],
             {:ok, %{store_revision: 4, dispatch_enabled: false}} <- Store.health(store),
             :ok <- run_fixture(executable, path, journal, mode, input),
             {:ok, %{store_revision: 4, dispatch_enabled: false}} <- Store.health(store),
             %{requests: requests} <- Agent.get(evidence, & &1),
             true <-
               Enum.count(requests, &(&1["operation"] == "activate_rule")) ==
                 if(String.ends_with?(mode, "retry"), do: 2, else: 1),
             true <-
               mode != "recover-scope" or
                 Enum.all?(
                   Enum.drop(requests, length(first)),
                   &(&1["operation"] == "controller_identity")
                 ),
             true <- not String.ends_with?(mode, "retry") or List.last(requests) == dropped,
             true <-
               Enum.all?(
                 Enum.filter(requests, &(&1["operation"] != "controller_identity")),
                 &(&1["credential"] == encoded)
               ),
             {:ok, _} <-
               Authority.rule_operation_status(authority, original, 1, "rule:pending-original"),
             :not_found <-
               Authority.rule_operation_status(authority, other, 1, "rule:pending-original"),
             true <- bytes != File.read!(Path.join(journal, "native-pending-v1.json")) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, "native journal context, publication or original receipt differed"}
        end
      end
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)
      for pid <- [evidence, server, store], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp run_fixture(executable, path, journal, mode, input) do
    with {:ok, output} <-
           Command.run(executable, [path, journal, mode], 16_384, 20_000, [], input),
         {:ok, %{"complete" => true}} <- JSON.decode(String.trim(output)),
         do: :ok,
         else: ({:ok, %{"complete" => false, "line" => line} = evidence} ->
                  {:error,
                   "#{mode} assertion #{line}: #{evidence["reason"] || "unexpected error"}"})
  end

  defp proxy(listener, socket, evidence, journal) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 10_000),
               true <- size in 1..65_536,
               {:ok, bytes} <- :gen_tcp.recv(peer, size, 10_000),
               {:ok, request} <- Frame.decode_request(bytes) do
            state = Agent.get(evidence, & &1)

            if request["operation"] == "activate_rule",
              do: File.read!(Path.join(journal, "native-pending-v1.json"))

            response =
              case Client.request(socket, request, 10_000) do
                {:ok, response} -> response
                _ -> nil
              end

            drop =
              is_nil(state.dropped) and request["operation"] == "activate_rule" and
                is_map(response) and response["outcome"] == "ok"

            Agent.update(evidence, fn state ->
              %{
                state
                | requests: state.requests ++ [request],
                  dropped: if(drop, do: request, else: state.dropped)
              }
            end)

            if not drop and is_map(response) do
              {:ok, frame} = Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
            end
          end
        after
          :gen_tcp.close(peer)
        end

        proxy(listener, socket, evidence, journal)

      {:error, _} ->
        :ok
    end
  end

  defp private_directory(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

defmodule Mix.Tasks.Woh.Native.Pending.Coordinator.Smoke do
  @moduledoc "Checks actual authenticated publication and original Store recovery across app processes; no Keychain, signing proof or hardware effects."
  @shortdoc "Check native pending coordinator against a real Store"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativePendingCoordinatorSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native pending coordinator original publication and process restart lookup/retry passed"
        )

      {:error, reason} ->
        Mix.raise("native pending coordinator smoke failed: #{inspect(reason)}")

      _ ->
        Mix.raise("native pending coordinator fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.pending.coordinator.smoke")
end
