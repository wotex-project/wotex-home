# Trusted development probe. Runs only in a fresh, network-disabled container.
# Synthetic maintenance credentials remain in service-owned private custody;
# exceptions and failed child output must never disclose them.
# Fixed failure-stage exit codes give bounded diagnostics without private tuples.
defmodule Woh.Native.LinuxUpdateFenceSmoke do
  @moduledoc false
  import Bitwise
  alias Woh.Tool.{Command, LinuxNativeBundle, LinuxServicePackage, ReleaseInventory}
  alias WotexHome.{Authority, CLI, Host}
  alias WotexHome.Durable.Store
  alias WotexHome.Host.UpdateFence
  alias WotexHome.LocalAPI.Client
  alias WotexHome.Recovery.PrivateFile

  @data "/var/lib/wotex-home"
  @runtime "/tmp/woh-fence-service-runtime"
  @begin_operation "begin:packaged-fence"
  @end_operation "end:packaged-fence"
  @socket @data <> "/ipc/home.sock"

  def run do
    Process.put(:probe_failure_stage, 11)
    Logger.configure(level: :emergency)
    Process.flag(:trap_exit, true)
    root = System.fetch_env!("WOTEX_HOME_RUNTIME_RELEASE")
    source = System.fetch_env!("WOTEX_HOME_EXPECT_SOURCE_REVISION")
    require!(File.regular?("/.dockerenv"))
    require!(:os.type() == {:unix, :linux} and not Node.alive?())
    require!(String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64"))
    {:ok, _} = ReleaseInventory.verify(root)
    {:ok, manifest} = LinuxServicePackage.verify(root)
    require!(manifest["source_revision"] == source and manifest["schema_version"] == 2)
    require!(String.starts_with?(to_string(:code.which(Host)), root <> "/lib/"))
    Process.put(:probe_failure_stage, 20)

    os = File.read!("/etc/os-release") |> String.split("\n")
    require!("ID=debian" in os and "VERSION_ID=\"13\"" in os)
    Process.put(:probe_failure_stage, 21)

    for tool <- ~w(elixir mix cc gcc clang readelf patchelf),
        do: require!(System.find_executable(tool) == nil)

    Process.put(:probe_failure_stage, 22)

    require!(Host.store() == nil and Host.lifx_capture() == nil)
    require!(not Host.authority().power_dispatch)

    for key <- ~w(WOTEX_HOME_DATA_DIR WOTEX_HOME_LIFX_INTERFACE),
        do: require!(System.get_env(key) == nil)

    for key <- [:data_dir, :lifx_capture_interface, :component_preview],
        do: require!(Application.get_env(:wotex_home, key) == nil)

    require!(not Application.get_env(:wotex_home, :schedule_delivery_enabled, false))

    for key <-
          ~w(WOTEX_HOME_INSTALL_LOCK_FD WOTEX_HOME_INSTALL_LOCK_PATH WOTEX_HOME_INSTALL_LOCK_OWNER),
        do: require!(System.get_env(key) == nil)

    Process.put(:probe_failure_stage, 23)

    case System.get_env("WOTEX_HOME_FENCE_PROBE_PHASE") do
      nil ->
        root_probe(root, manifest["artifact_id"], source)

      phase when phase in ["prepare", "refuse", "pending", "end", "retry", "restart"] ->
        service_probe(root, phase)

      _ ->
        require!(false)
    end
  rescue
    _ ->
      IO.puts(:stderr, "packaged update fence probe failed; private diagnostics withheld")
      System.halt(Process.get(:probe_failure_stage, 1))
  catch
    _, _ ->
      IO.puts(:stderr, "packaged update fence probe failed; private diagnostics withheld")
      System.halt(Process.get(:probe_failure_stage, 1))
  end

  defp root_probe(root, artifact, source) do
    require!(File.stat!("/proc/self").uid == 0)

    for path <- [@data, @runtime, Path.dirname(UpdateFence.path())],
        do: require!(File.lstat(path) == {:error, :enoent})

    File.mkdir!(Path.dirname(UpdateFence.path()))
    File.chmod!(Path.dirname(UpdateFence.path()), 0o755)

    for path <- [@data, @runtime] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
      {:ok, _} = Command.run("chown", ["211:211", path], 256, 5000)
    end

    "FENCE_PREPARED:1:3\n" = phase!(root, artifact, "prepare")

    guard = %{
      "schema_version" => 1,
      "scope" => "linux_release_update_guard",
      "owner_sha256" => String.duplicate("a", 64),
      "artifact_id" => artifact,
      "authority_epoch" => 1,
      "begin_revision" => 3,
      "state" => "pending"
    }

    for changed <- [
          %{guard | "artifact_id" => String.duplicate("b", 64)},
          %{guard | "authority_epoch" => 2},
          %{guard | "begin_revision" => 4}
        ] do
      publish!(changed)
      "FENCE_REFUSED\n" = phase!(root, artifact, "refuse")
    end

    publish!(guard)
    File.chmod!(UpdateFence.path(), 0o600)
    "FENCE_REFUSED\n" = phase!(root, artifact, "refuse")
    publish!(guard)
    "FENCE_PENDING_OK\n" = phase!(root, artifact, "pending")
    restart!(root, artifact, %{guard | "begin_revision" => 4})
    publish!(%{guard | "state" => "complete"})
    "FENCE_END_OK\n" = phase!(root, artifact, "end")
    publish!(guard)
    "FENCE_REFUSED\n" = phase!(root, artifact, "refuse")
    publish!(%{guard | "state" => "complete"})
    "FENCE_RETRY_OK\n" = phase!(root, artifact, "retry")
    {:ok, count} = ReleaseInventory.verify(root)

    IO.puts(
      "PACKAGED_UPDATE_FENCE_OK source=#{source} inventory=#{count}; " <>
        "no installed-service, coordinator, power-loss or physical qualification"
    )
  end

  defp phase!(root, artifact, phase) do
    IO.puts("PACKAGED_FENCE_PHASE_#{phase}_START")

    output =
      case Command.run("setpriv", child_args(root), 4096, 30_000, child_env(artifact, phase)) do
        {:ok, output} ->
          output

        {:error, reason} ->
          IO.puts(:stderr, "packaged fence child #{phase}: #{reason}")
          require!(false)
      end

    IO.puts("PACKAGED_FENCE_PHASE_#{phase}_OK")
    output
  end

  defp child_args(root),
    do: [
      "--reuid",
      "211",
      "--regid",
      "211",
      "--clear-groups",
      "--no-new-privs",
      Path.join(root, "bin/wotex_home"),
      "eval",
      "Code.eval_file(\"/trusted/update-fence-smoke.exs\")"
    ]

  defp child_env(artifact, phase),
    do: [
      {"RELEASE_TMP", @runtime},
      {"WOTEX_HOME_FENCE_PROBE_PHASE", phase},
      {"WOTEX_HOME_LINUX_ARTIFACT_ID", artifact},
      {"WOTEX_HOME_UPDATE_GUARD_PATH", UpdateFence.path()}
    ]

  defp publish!(guard) do
    File.write!(UpdateFence.path(), JSON.encode!(guard) <> "\n")
    File.chmod!(UpdateFence.path(), 0o644)
  end

  defp restart!(root, artifact, changed) do
    IO.puts("PACKAGED_FENCE_STORE_RESTART_START")
    Process.put(:probe_failure_stage, 50)

    port =
      Port.open({:spawn_executable, System.find_executable("setpriv")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: child_args(root),
        env:
          Enum.map(child_env(artifact, "restart"), fn {key, value} ->
            {String.to_charlist(key), String.to_charlist(value)}
          end)
      ])

    try do
      Process.put(:probe_failure_stage, 51)

      require!(
        await_line!(port, "", System.monotonic_time(:millisecond) + 30_000) ==
          "FENCE_RESTART_READY\n"
      )

      {:os_pid, pid} = Port.info(port, :os_pid)
      Process.put(:probe_failure_stage, 52)
      [beam] = Path.wildcard(Path.join(root, "erts-*/bin/beam.smp"))
      require!(File.read_link!("/proc/#{pid}/exe") == beam)
      Process.put(:probe_failure_stage, 53)
      publish!(changed)
      true = Port.command(port, "restart\n")
      Process.put(:probe_failure_stage, 54)

      require!(
        await_line!(port, "", System.monotonic_time(:millisecond) + 10_000) ==
          "FENCE_RESTART_REFUSED\n"
      )

      Process.put(:probe_failure_stage, 55)

      receive do
        {^port, {:exit_status, 0}} -> :ok
      after
        10_000 -> require!(false)
      end

      IO.puts("PACKAGED_FENCE_STORE_RESTART_OK")
    after
      if Port.info(port) != nil, do: Port.close(port)
    end
  end

  defp await_line!(port, bytes, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, next}} when byte_size(bytes) + byte_size(next) <= 4096 ->
        combined = bytes <> next

        if String.ends_with?(combined, "\n"),
          do: combined,
          else: await_line!(port, combined, deadline)

      {^port, _} ->
        require!(false)

      {:EXIT, ^port, _} ->
        require!(false)
    after
      remaining -> require!(false)
    end
  end

  defp service_probe(root, phase) do
    Process.put(:probe_failure_stage, 30)
    status = File.read!("/proc/self/status")
    require!(Regex.match?(~r/^Uid:\s+211\s+211\s+211\s+211$/m, status))
    require!(Regex.match?(~r/^Gid:\s+211\s+211\s+211\s+211$/m, status))
    require!(Regex.match?(~r/^Groups:[ \t]*$/m, status))
    require!(Regex.match?(~r/^CapEff:\s+0000000000000000$/m, status))
    Process.put(:probe_failure_stage, 31)
    {:ok, _} = WotexHome.Lifx.ProductRegistry.load_pinned()
    Process.put(:probe_failure_stage, 32)

    if phase == "refuse" do
      {:error, _} = Host.start_link(data_dir: @data)
      absent_consumers!()
      IO.puts("FENCE_REFUSED")
    else
      {:ok, host} = Host.start_link(data_dir: @data)
      Process.put(:probe_failure_stage, 33)

      try do
        ready!(root)
        Process.put(:probe_failure_stage, 34)
        service_phase!(phase, host)
      after
        if Process.alive?(host), do: Supervisor.stop(host, :normal, 10_000)
      end

      absent_consumers!()
    end

    {:ok, _} = ReleaseInventory.verify(root)
  end

  defp service_phase!("prepare", _host) do
    Process.put(:probe_failure_stage, 40)
    {:ok, credential, 1} = Authority.provision_maintenance(Host.authority())
    :ok = PrivateFile.write_credential(@data <> "/probe-credential", credential)
    Process.put(:probe_failure_stage, 41)
    receipt = receipt!(["maintenance-begin", "1", @begin_operation, "1"])
    require!(receipt["authority_epoch"] == 1 and receipt["revision"] == 3)
    :ok = PrivateFile.write(@data <> "/probe-begin", JSON.encode!(receipt), 4096)
    IO.puts("FENCE_PREPARED:1:3")
  end

  defp service_phase!(phase, host) do
    original = saved!("begin")
    require!(receipt!(["maintenance-operation-status", "1", @begin_operation]) == original)

    if phase in ["pending", "restart", "end"] do
      active!()
      response = request!(["maintenance-end", "1", @end_operation, "3", "3"])

      if phase == "end" do
        require!(response["outcome"] == "ok")

        :ok =
          PrivateFile.write(
            @data <> "/probe-end",
            JSON.encode!(response["maintenance_receipt"]),
            4096
          )

        normal!()
        IO.puts("FENCE_END_OK")
      else
        require!(
          response == %{
            "api_version" => 1,
            "outcome" => "error",
            "reason" => "release_update_active"
          }
        )

        active!()

        require!(
          request!(["maintenance-operation-status", "1", @end_operation]) ==
            %{"api_version" => 1, "outcome" => "not_found"}
        )

        if phase == "restart" do
          IO.puts("FENCE_RESTART_READY")
          require!(IO.gets("") == "restart\n")
          monitor = Process.monitor(host)
          Process.exit(Host.store(), :kill)

          receive do
            {:DOWN, ^monitor, :process, ^host, _} -> :ok
          after
            5000 -> require!(false)
          end

          absent_consumers!()
          IO.puts("FENCE_RESTART_REFUSED")
        else
          IO.puts("FENCE_PENDING_OK")
        end
      end
    else
      normal!()
      require!(receipt!(["maintenance-end", "1", @end_operation, "3", "3"]) == saved!("end"))
      normal!()
      IO.puts("FENCE_RETRY_OK")
    end

    # History survives every permitted boot, denial and exact retry.
    if Process.alive?(host),
      do: require!(receipt!(["maintenance-operation-status", "1", @begin_operation]) == original)
  end

  defp saved!(name) do
    {:ok, bytes} = PrivateFile.read(@data <> "/probe-" <> name, 4096)
    JSON.decode!(bytes)
  end

  defp receipt!(args) do
    response = request!(args)
    require!(response["outcome"] == "ok" and is_map(response["maintenance_receipt"]))
    response["maintenance_receipt"]
  end

  defp request!(args) do
    {:ok, credential} = PrivateFile.read_credential(@data <> "/probe-credential")
    {:ok, request} = CLI.build_request(args, Base.url_encode64(credential, padding: false))
    {:ok, response} = Client.request(@socket, request)
    response
  end

  defp update_status! do
    %{"api_version" => 1, "outcome" => "ok", "maintenance_update_status" => status} =
      request!(["maintenance-update-status"])

    require!(
      map_size(status) == 9 and status["store_schema_version"] == 28 and
        status["writable"] and status["update_fence_enabled"] and
        status["principal_id"] == "maintenance:local"
    )

    status
  end

  defp active! do
    status = update_status!()

    require!(
      status["state"] == "maintenance" and status["begin_revision"] == 3 and
        status["store_revision"] == 3 and status["authority_epoch"] == 1
    )
  end

  defp normal! do
    status = update_status!()

    require!(
      status["state"] == "normal" and status["begin_revision"] == 0 and
        status["store_revision"] == saved!("end")["revision"]
    )
  end

  defp ready!(root) do
    require!(File.exists?(@socket))
    {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
    require!(Host.lifx_capture() == nil)

    for {path, mode} <- [
          {@data, 0o700},
          {@data <> "/home.sqlite", 0o600},
          {Path.dirname(@socket), 0o700},
          {@socket, 0o600}
        ] do
      info = File.lstat!(path)
      require!(info.uid == 211 and info.gid == 211 and (info.mode &&& 0o7777) == mode)
    end

    maps = File.read!("/proc/self/maps")

    for provider <- LinuxNativeBundle.profile()["libraries"],
        do:
          require!(
            String.contains?(
              maps,
              Path.join(
                root,
                "native/linux-libraries/lib/" <> provider["library"]
              )
            )
          )
  end

  defp absent_consumers! do
    for name <- [
          WotexHome.Host.Store,
          WotexHome.Host.ProfileCustody,
          WotexHome.Host.ProfileReviews,
          WotexHome.Host.LifxPowerDelivery,
          WotexHome.Host.ScheduleDelivery,
          WotexHome.Host.LifxPowerSupervisor
        ],
        do: require!(Process.whereis(name) == nil)

    require!(not File.exists?(@socket))
    require!(File.regular?(@data <> "/home.sqlite"))
  end

  defp require!(true), do: :ok
  defp require!(_), do: raise("packaged fence assertion failed")
end

Woh.Native.LinuxUpdateFenceSmoke.run()
