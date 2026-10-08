defmodule Woh.Tool.NativeQuickBarSmoke do
  @moduledoc false
  alias Woh.Tool.Command
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  alias WotexHome.Semantics.{Observation, Thing}
  @principal "operator:menu-fixture"
  @target "light:menu-fixture"
  @modes ~w(on off lost-lookup lost-retry ambiguous-lookup publication changed-custody read-only empty-scope busy-inspection pending-rule wake-read first-refused import import-failed)

  def run(project) do
    root =
      directory("/private/tmp", "qb-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")

    executable = Path.join(root, "quick-bar")
    preview = Path.join(project, "_build/native/quick-bar")
    File.mkdir_p!(Path.dirname(preview))

    try do
      # Compile the production surface/model closure. The only omitted source
      # owns the app entry point and is separately checked by app assembly.
      sources =
        Path.wildcard(Path.join(project, "native/macos/Sources/*.swift"))
        |> Enum.reject(&(Path.basename(&1) == "WotexHomeApp.swift"))

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-target",
          "arm64-apple-macos15.0",
          "-module-cache-path",
          Path.join(root, "cache")
        ] ++
          Enum.flat_map(
            ~w(SwiftUI AppKit Security LocalAuthentication CryptoKit ServiceManagement),
            &["-framework", &1]
          ) ++
          sources ++
          [Path.join(project, "native/macos/Tests/HomeQuickBarSmoke.swift"), "-o", executable]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 180_000) do
        Enum.reduce_while(@modes, :ok, fn mode, :ok ->
          case check(executable, directory(root, mode), mode, preview) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{mode}: #{reason}"}}
          end
        end)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp check(executable, root, mode, preview) do
    journal = directory(root, "journal")
    {:ok, store} = Store.start_link(path: Path.join(root, "home.sqlite"))
    {:ok, thing} = thing(mode)
    {:ok, 1} = Store.enroll_thing(store, thing)

    permissions =
      if mode == "empty-scope", do: ["read"], else: ~w(read rule:manage control:ordinary)

    targets = if mode == "empty-scope", do: [], else: [thing.id]
    {:ok, original, 2} = Store.provision_principal(store, @principal, permissions, targets)

    {:ok, other, 3} =
      Store.provision_principal(store, "other:menu-fixture", permissions, [thing.id])

    capability = thing.capabilities["power"]

    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => @target,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false},
          "quality" => "reported",
          "trust" => "synthetic_lab",
          "source_epoch" => "source:menu-fixture",
          "source_sequence" => 1,
          "boot_epoch" => "adapter:menu-fixture",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_700_000_000_000,
          "received_monotonic_ms" => 999_999_999
        },
        capability
      )

    {:ok, 4} = Store.record(store, report, capability)
    authority = Authority.new(store: store)
    socket = Path.join(root, "home.sock")
    {:ok, server} = Server.start_link(authority: authority, socket_path: socket)
    path = Path.join(root, "proxy.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)

    {:ok, evidence} =
      Agent.start_link(fn -> %{requests: [], first: nil, altered: false, error: false} end)

    proxy = Task.async(fn -> proxy(listener, socket, journal, store, evidence, mode) end)

    input =
      JSON.encode!(%{
        "original" => Base.url_encode64(original, padding: false),
        "other" => Base.url_encode64(other, padding: false)
      }) <> "\n"

    try do
      create_mode =
        cond do
          String.starts_with?(mode, "lost-") -> "lost-create"
          mode == "ambiguous-lookup" -> "ambiguous-create"
          true -> mode
        end

      with :ok <- fixture(executable, path, journal, create_mode, preview, input),
           :ok <- restoration(executable, path, journal, mode, preview, input),
           %{error: false} = state <- Agent.get(evidence, & &1),
           :ok <- expected(state, store, authority, original, other, journal, mode) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, "fixture scope, publication, receipt or counter differed"}
      end
    after
      :gen_tcp.close(listener)
      Task.shutdown(proxy, :brutal_kill)
      for pid <- [evidence, server, store], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp restoration(executable, path, journal, mode, preview, input)
       when mode in ~w(lost-lookup lost-retry ambiguous-lookup) do
    restored = if mode == "lost-retry", do: "restore-retry", else: "restore-lookup"
    fixture(executable, path, journal, restored, preview, input)
  end

  defp restoration(_, _, _, _, _, _), do: :ok

  defp expected(state, store, authority, original, other, journal, mode) do
    power = Enum.filter(state.requests, &(&1["operation"] == "submit"))

    count =
      cond do
        mode == "lost-retry" -> 2
        mode in ~w(on off lost-lookup ambiguous-lookup publication first-refused) -> 1
        true -> 0
      end

    held = if count > 0 and mode != "first-refused", do: 1, else: 0
    revision = if held == 1 or mode == "first-refused", do: 5, else: 4

    with true <- length(power) == count,
         true <- Enum.all?(power, &(&1 == state.first)),
         true <-
           Enum.all?(
             state.requests,
             &(&1["operation"] in ~w(health catalogue snapshot overrides controller_identity thing_current submit status))
           ),
         true <-
           Enum.all?(
             state.requests,
             &(&1["credential"] == Base.url_encode64(original, padding: false))
           ),
         {:ok,
          %{
            store_revision: ^revision,
            dispatch_enabled: false,
            held_requests: ^held,
            queued_requests: 0,
            claimed_requests: 0,
            unknown_outcomes: 0
          }} <- Store.health(store),
         :ok <- receipt(authority, original, other, state.first, mode),
         :ok <- journal(journal, mode, held) do
      :ok
    else
      _ -> {:error, "publication/identity/receipt/counter closure did not hold"}
    end
  end

  defp receipt(_authority, _original, _other, nil, _mode), do: :ok
  defp receipt(_authority, _original, _other, _request, "first-refused"), do: :ok

  defp receipt(authority, original, other, request, _mode) do
    mutation = request["mutation"]

    with {:ok, %{disposition: :held, revision: 5}} <-
           Authority.request_status(authority, original, 1, mutation["operation_id"]),
         :not_found <- Authority.request_status(authority, other, 1, mutation["operation_id"]),
         do: :ok
  end

  defp journal(path, "pending-rule", 0) do
    case JSON.decode!(File.read!(Path.join(path, "native-pending-v1.json"))) do
      [
        "wotex-home.native-pending.v1",
        1,
        [["rule", _, _, ["activate_rule", "rule:menu-fence", 4, 0], ["pending"]]]
      ] ->
        :ok

      _ ->
        {:error, "another-category original was not retained"}
    end
  end

  defp journal(path, mode, held) do
    file = Path.join(path, "native-pending-v1.json")

    if held == 1 or mode == "first-refused" do
      if JSON.decode!(File.read!(file)) == ["wotex-home.native-pending.v1", 2, []],
        do: :ok,
        else: {:error, "confirmed original not resolved"}
    else
      if not File.exists?(file), do: :ok, else: {:error, "guard created an unexpected original"}
    end
  end

  defp fixture(executable, path, journal, mode, preview, input) do
    case Command.run(executable, [path, journal, mode, preview], 16_384, 30_000, [], input) do
      {:ok, output} ->
        case JSON.decode(String.trim(output)) do
          {:ok, %{"complete" => true}} -> :ok
          {:ok, %{"line" => line}} -> {:error, "native assertion #{line}"}
          _ -> {:error, "native fixture did not complete"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proxy(listener, socket, journal, store, evidence, mode) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, peer} ->
        try do
          case exchange(peer, socket, journal, store, evidence, mode) do
            :ok -> :ok
            _ -> Agent.update(evidence, &%{&1 | error: true})
          end
        after
          :gen_tcp.close(peer)
        end

        proxy(listener, socket, journal, store, evidence, mode)

      {:error, _} ->
        :ok
    end
  end

  defp exchange(peer, socket, journal, store, evidence, mode) do
    with {:ok, <<size::32>>} <- :gen_tcp.recv(peer, 4, 10_000),
         true <- size in 1..65_536,
         {:ok, bytes} <- :gen_tcp.recv(peer, size, 10_000),
         {:ok, request} <- Frame.decode_request(bytes),
         :ok <- publication(journal, store, request) do
      state = Agent.get(evidence, & &1)
      mutation = request["operation"] == "submit"

      if mutation and mode == "first-refused",
        do: {:ok, _} = Store.revoke_principal(store, @principal)

      response =
        case Client.request(socket, request, 10_000) do
          {:ok, result} -> result
          _ -> nil
        end

      alter =
        mutation and not state.altered and mode in ~w(lost-lookup lost-retry ambiguous-lookup)

      Agent.update(evidence, fn s ->
        %{
          s
          | requests: s.requests ++ [request],
            first: if(mutation, do: s.first || request, else: s.first),
            altered: s.altered or alter
        }
      end)

      cond do
        alter and String.starts_with?(mode, "lost-") ->
          :ok

        alter ->
          send_frame(peer, %{
            "api_version" => 1,
            "outcome" => "error",
            "reason" => "store_unavailable"
          })

        is_map(response) ->
          send_frame(peer, response)

        true ->
          {:error, :forward_failed}
      end
    end
  end

  defp send_frame(peer, response) do
    with {:ok, frame} <- Frame.encode_response(response), do: :gen_tcp.send(peer, frame)
  end

  defp publication(journal, store, %{
         "operation" => "submit",
         "credential" => encoded,
         "mutation" => mutation
       }) do
    with {:ok, raw} <- File.read(Path.join(journal, "native-pending-v1.json")),
         [
           "wotex-home.native-pending.v1",
           revision,
           [
             [
               "power",
               [deployment, owner, 1, @principal],
               ["manual", verifier],
               ["submit", operation, @target, 0, on],
               ["pending"]
             ]
           ]
         ] <- JSON.decode!(raw),
         true <- revision > 0,
         {:ok, identity} <- Store.native_setup_identity(store),
         true <- deployment == identity["deployment_id"] and owner == identity["owner_id"],
         {:ok, credential} <- Base.url_decode64(encoded, padding: false),
         true <- verifier == WotexHome.Schedules.Codec.hash(credential),
         true <-
           mutation == %{
             "api_version" => 1,
             "operation_id" => operation,
             "authority_epoch" => 1,
             "expected_revision" => 0,
             "target_id" => @target,
             "capability_key" => "power",
             "value" => %{"type" => "boolean", "value" => on}
           },
         do: :ok
  end

  defp publication(_, _, _), do: :ok

  defp thing(mode) do
    Thing.new(%{
      "id" => @target,
      "role" => "Light",
      "profile_ref" => "fixture:menu:1",
      "capabilities" => [
        %{
          "thing_id" => @target,
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => if(mode == "read-only", do: ["read"], else: ["read", "write"]),
          "risk_class" => "ordinary",
          "profile_ref" => "fixture:menu:1",
          "evidence_ref" => "fixture:menu",
          "freshness_ms" => 5_000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    })
  end

  defp directory(parent, name) do
    path = Path.join(parent, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

defmodule Mix.Tasks.Woh.Native.Quick.Bar.Smoke do
  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Check shared native menu-bar controls and original recovery"
  def run([]) do
    case Woh.Tool.NativeQuickBarSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native quick bar fifteen private-Store workflows passed")
      {:error, reason} -> Mix.raise("native quick bar smoke failed: #{inspect(reason)}")
      _ -> Mix.raise("native quick bar fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.quick.bar.smoke")
end
