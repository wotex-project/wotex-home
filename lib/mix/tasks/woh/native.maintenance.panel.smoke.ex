defmodule Woh.Tool.NativeMaintenancePanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Frame, Server}

  @modes ~w(begin-lookup begin-retry end-lookup end-retry begin-unsubmitted end-unsubmitted begin-refused end-refused begin-changed end-changed begin-first-refused end-first-refused)
  @principal "maintainer:panel-fixture"

  def run(project) do
    root =
      private_directory(
        "/private/tmp",
        "woh-maint-panel-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    executable = Path.join(root, "maintenance-panel")
    preview = Path.join(project, "_build/native/maintenance-panel-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    try do
      sources =
        ~w(LocalHealthClient NativeSetupWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativePendingCodec NativePendingStorage NativePendingCoordinator HostMaintenancePanel)

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
          "SwiftUI",
          "-framework",
          "Security",
          "-framework",
          "CryptoKit"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [
            Path.join(project, "native/macos/Tests/LiveMaintenancePanelSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(executable, private_directory(root, mode), mode, preview) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp check(executable, directory, mode, preview) do
    journal = private_directory(directory, "journal")
    {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))
    {:ok, original, 1} = Store.provision_principal(store, @principal, ["host:maintain"], [])

    {:ok, other, 2} =
      Store.provision_principal(store, "other:panel-fixture", ["host:maintain"], [])

    authority = Authority.new(store: store)

    if String.starts_with?(mode, "end-"),
      do: {:ok, _} = Authority.begin_maintenance(authority, original, 1, "maintenance:seed", 2)

    {:ok, baseline} = Store.revision(store)
    socket = Path.join(directory, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(directory, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    {:ok, evidence} =
      Agent.start_link(fn -> %{first: nil, dropped: nil, response: nil, requests: []} end)

    proxy = Task.async(fn -> proxy(listener, socket, journal, store, evidence, mode) end)
    encoded = Base.url_encode64(original, padding: false)

    input =
      JSON.encode!(%{"original" => encoded, "other" => Base.url_encode64(other, padding: false)}) <>
        "\n"

    try do
      with {:ok, output} <-
             Command.run(executable, [path, mode, journal, preview], 16_384, 30_000, [], input),
           {:ok, %{"complete" => true, "operation" => operation}} <-
             JSON.decode(String.trim(output)),
           state <- Agent.get(evidence, & &1),
           :ok <-
             verify(state, mode, baseline, store, authority, original, other, encoded, operation) do
        :ok
      else
        {:ok, %{"complete" => false, "line" => line}} -> {:error, "fixture assertion #{line}"}
        {:error, reason} -> {:error, inspect(reason)}
        _ -> {:error, "original maintenance publication or result differed"}
      end
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)
      for pid <- [evidence, server, store], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp verify(state, mode, baseline, store, authority, original, other, encoded, operation) do
    {:ok, final} = Store.revision(store)
    effects = if String.starts_with?(mode, "begin-"), do: 2, else: 1

    mutations =
      Enum.filter(state.requests, &(&1["operation"] in ["begin_maintenance", "end_maintenance"]))

    original_requests = Enum.filter(state.requests, &(&1["operation"] != "maintenance_status"))

    cond do
      String.ends_with?(mode, "changed") ->
        if final == baseline and state.first == nil and original_requests == [],
          do: :ok,
          else: {:error, "changed capture sent a request"}

      String.ends_with?(mode, "first-refused") ->
        if final == baseline + 1 and state.dropped == nil and length(mutations) == 1 and
             state.response["outcome"] == "error",
           do: :ok,
           else: {:error, "definite first refusal changed maintenance"}

      true ->
        revoked = String.ends_with?(mode, "refused")

        expected_count =
          cond do
            revoked -> 3
            String.ends_with?(mode, "lookup") -> 1
            true -> 2
          end

        receipt = Authority.maintenance_operation_status(authority, original, 1, operation)

        with true <- final == baseline + effects + if(revoked, do: 1, else: 0),
             true <- state.dropped != nil and length(mutations) == expected_count,
             true <- Enum.all?(mutations, &(&1 == state.dropped)),
             true <- Enum.all?(original_requests, &(&1["credential"] == encoded)),
             true <-
               if(revoked, do: match?({:error, _}, receipt), else: match?({:ok, _}, receipt)),
             :not_found <- Authority.maintenance_operation_status(authority, other, 1, operation),
             do: :ok,
             else: (_ ->
                      {:error,
                       "receipt identity, revision, exact retry or original credential differed"})
    end
  end

  defp verify_journal(journal, request) do
    input =
      [request["operation"], request["operation_id"], request["expected_revision"]] ++
        if(request["operation"] == "end_maintenance", do: [request["begin_revision"]], else: [])

    with {:ok,
          [
            "wotex-home.native-pending.v1",
            _,
            [["maintenance", [_, _, 1, @principal], ["manual", verifier], ^input, ["pending"]]]
          ]} <-
           JSON.decode(File.read!(Path.join(journal, "native-pending-v1.json"))),
         {:ok, bytes} <- Base.url_decode64(request["credential"], padding: false),
         true <- verifier == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) do
      :ok
    else
      _ -> raise "original journal did not precede maintenance"
    end
  end

  defp proxy(listener, socket, journal, store, evidence, mode) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 10_000),
               true <- size in 1..65_536,
               {:ok, bytes} <- :gen_tcp.recv(peer, size, 10_000),
               {:ok, request} <- Frame.decode_request(bytes) do
            state = Agent.get(evidence, & &1)
            mutation = request["operation"] in ["begin_maintenance", "end_maintenance"]
            first = mutation and state.first == nil
            if mutation, do: verify_journal(journal, request)
            first_refused = first and String.ends_with?(mode, "first-refused")
            if first_refused, do: {:ok, _} = Store.revoke_principal(store, @principal)
            unsent = first and String.ends_with?(mode, "unsubmitted")

            response =
              if unsent,
                do: nil,
                else:
                  (case Client.request(socket, request, 10_000) do
                     {:ok, response} -> response
                     _ -> nil
                   end)

            drop =
              first and not first_refused and
                (unsent or (is_map(response) and response["outcome"] == "ok"))

            if drop and String.ends_with?(mode, "refused"),
              do: {:ok, _} = Store.revoke_principal(store, @principal)

            Agent.update(evidence, fn state ->
              %{
                state
                | requests: state.requests ++ [request],
                  first: if(first, do: request, else: state.first),
                  dropped: if(drop, do: request, else: state.dropped),
                  response: if(first, do: response, else: state.response)
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

        proxy(listener, socket, journal, store, evidence, mode)

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

defmodule Mix.Tasks.Woh.Native.Maintenance.Panel.Smoke do
  @moduledoc "Checks native maintenance journal composition against an actual private Store; no Keychain, signed custody or hardware effects."
  @shortdoc "Check original maintenance panel operations"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeMaintenancePanelSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native maintenance panel passed twelve real Store original journal/recovery workflows"
        )

      {:error, reason} ->
        Mix.raise("native maintenance panel smoke failed: #{inspect(reason)}")

      _ ->
        Mix.raise("native maintenance panel fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.maintenance.panel.smoke")
end
