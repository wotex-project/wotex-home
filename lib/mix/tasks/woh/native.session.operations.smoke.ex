defmodule Woh.Tool.NativeSessionOperationsSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Semantics.Thing

  @modes ~w(power-lookup power-retry cancel-lookup cancel-retry override-lookup override-retry revoke-lookup revoke-retry rule-lookup rule-retry power-unsubmitted override-unsubmitted rule-unsubmitted)

  def run(project) do
    root =
      Path.join(
        "/private/tmp",
        "woh-session-ops-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "operations")

    try do
      sources =
        ~w(LocalHealthClient NativeHealthViewModel NativeSetupWire SignedSetupPeer NativeCoreConnection NativeSetupSocket NativeBrokerClient NativeSetupPanel)

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
          "Security",
          "-framework",
          "SwiftUI",
          "-framework",
          "CryptoKit"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [
            Path.join(project, "native/macos/Tests/LiveSessionOperationsSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(executable, root, mode) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp check(executable, root, mode) do
    directory = Path.join(root, mode)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:session-fixture",
        "role" => "Light",
        "profile_ref" => "lifx.fixture:1",
        "capabilities" => [
          %{
            "thing_id" => "light:session-fixture",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "lifx.fixture:1",
            "evidence_ref" => "fixture:session",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, _} = Store.enroll_thing(store, thing)
    permissions = ["read", "control:ordinary", "rule:manage", "rule:review"]

    {:ok, operator, _} =
      Store.provision_principal(store, "operator:session-fixture", permissions, [thing.id])

    {:ok, reader, _} =
      Store.provision_principal(store, "replacement:session-fixture", permissions, [thing.id])

    authority = Authority.new(store: store)
    socket = Path.join(directory, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(directory, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)
    {:ok, evidence} = Agent.start_link(fn -> %{dropped: nil, revision: nil, after_drop: []} end)
    proxy = Task.async(fn -> proxy(listener, socket, mode, evidence, store) end)
    encoded = Base.url_encode64(operator, padding: false)

    input =
      JSON.encode!(%{
        "operator" => encoded,
        "reader" => Base.url_encode64(reader, padding: false)
      }) <> "\n"

    try do
      with {:ok, output} <- Command.run(executable, [path, mode], 16_384, 30_000, [], input),
           {:ok, %{"complete" => true, "operation" => operation}} <-
             JSON.decode(String.trim(output)),
           %{dropped: dropped, revision: revision, after_drop: requests}
           when not is_nil(dropped) and requests != [] <- Agent.get(evidence, & &1),
           true <- Enum.all?(requests, &(&1["credential"] == encoded)),
           true <- String.ends_with?(mode, "lookup") or List.last(requests) == dropped,
           {:ok, %{store_revision: final, writable: true, dispatch_enabled: false}} <-
             Store.health(store),
           true <- final == revision + if(String.ends_with?(mode, "unsubmitted"), do: 1, else: 0),
           {:ok, _} <- original_receipt(authority, operator, mode, operation),
           :not_found <- original_receipt(authority, reader, mode, operation) do
        :ok
      else
        {:ok, %{"complete" => false, "line" => line}} ->
          {:error, "native fixture assertion at line #{line}"}

        {:error, reason} ->
          {:error, inspect(reason)}

        _ ->
          {:error, "native pending state, original frame or immutable Store receipt differed"}
      end
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)

      Enum.each([evidence, server, store], fn pid ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  defp original_receipt(authority, credential, mode, operation) do
    cond do
      String.starts_with?(mode, "rule") ->
        Authority.rule_operation_status(authority, credential, 1, operation)

      String.starts_with?(mode, "override") or String.starts_with?(mode, "revoke") ->
        Authority.override_status(authority, credential, 1, operation)

      true ->
        Authority.request_status(authority, credential, 1, operation)
    end
  end

  # Only discard a response after the real private Authority route has returned.
  # No receipt, grant, signing proof, Keychain success or device result is invented.
  defp proxy(listener, socket, mode, evidence, store) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 10_000),
               true <- size in 1..65_536,
               {:ok, bytes} <- :gen_tcp.recv(peer, size, 10_000),
               {:ok, request} <- Frame.decode_request(bytes) do
            expected =
              case hd(String.split(mode, "-")) do
                "power" -> "submit"
                "cancel" -> "cancel"
                "override" -> "override_issue"
                "revoke" -> "override_revoke"
                "rule" -> "activate_rule"
              end

            state = Agent.get(evidence, & &1)

            unsent =
              is_nil(state.dropped) and String.ends_with?(mode, "unsubmitted") and
                request["operation"] == expected

            response =
              if unsent do
                nil
              else
                case Client.request(socket, request, 10_000) do
                  {:ok, result} -> result
                  _ -> nil
                end
              end

            drop =
              is_nil(state.dropped) and request["operation"] == expected and
                (unsent or (is_map(response) and response["outcome"] == "ok"))

            cond do
              drop ->
                {:ok, %{store_revision: revision}} = Store.health(store)
                Agent.update(evidence, &%{&1 | dropped: request, revision: revision})

              not is_nil(state.dropped) ->
                Agent.update(evidence, &%{&1 | after_drop: &1.after_drop ++ [request]})

              true ->
                :ok
            end

            if not drop and is_map(response) do
              {:ok, frame} = Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
            end
          end
        after
          :gen_tcp.close(peer)
        end

        proxy(listener, socket, mode, evidence, store)

      {:error, _} ->
        :ok
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Session.Operations.Smoke do
  @moduledoc "Checks actual native pending operations against a private Store after lost replies and credential replacement; no Keychain, signed custody or hardware qualification."
  @shortdoc "Check original native session operations"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeSessionOperationsSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native session operations passed thirteen live lost-reply/credential-replacement workflows"
        )

      {:error, reason} ->
        Mix.raise("native session operations failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.session.operations.smoke")
end
