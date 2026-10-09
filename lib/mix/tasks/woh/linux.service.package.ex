defmodule Woh.Tool.LinuxServicePackage do
  @moduledoc false

  alias Woh.Tool.{Json, ReleaseInventory}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @profile_path Path.expand("../../../../native/linux/service-profile-arm64.json", __DIR__)
  @external_resource @profile_path
  @profile @profile_path |> File.read!() |> JSON.decode!()
  @directory "native/linux-service"
  @manifest @directory <> "/manifest.json"
  @reports ~w(release-inventory.json release-components.json release.spdx.json)
  @unit "etc/systemd/system/wotex-home.service"
  @journal "etc/systemd/journald@wotex-home.conf"
  @budget "etc/systemd/system/systemd-journald@wotex-home.service.d/home-budget.conf"
  @mount "etc/systemd/system/run-wotexhomejournal.mount"

  def profile, do: @profile
  def directory, do: @directory
  def component, do: "linux-service-config-1"

  # Emits inert regular payload files only. No account, unit, directory, log
  # namespace or service registration is created on the host.
  def assemble(release, revision) do
    root = Path.expand(release)
    require_revision!(revision)

    for relative <- @reports ++ [@directory] do
      ensure!(
        File.lstat(Path.join(root, relative)) == {:error, :enoent},
        "refuse issued release or existing Linux service configuration"
      )
    end

    artifact = artifact_id!(root, revision)
    files = files(artifact)
    destination = Path.join(root, @directory)
    File.mkdir_p!(Path.dirname(destination))
    File.mkdir!(destination)

    for {relative, bytes} <- files do
      write!(Path.join(destination, relative), bytes)
    end

    report = report(revision, artifact, files)
    write!(Path.join(root, @manifest), JSON.encode!(report) <> "\n")
    verify_payload(root)
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "cannot package Linux service: #{Exception.message(error)}"}
  end

  def verify(release) do
    with {:ok, _} <- ReleaseInventory.verify(release),
         {:ok, saved} <- Json.read(Path.join(release, ReleaseInventory.manifest()), 2_000_000),
         {:ok, report} <- verify_payload(release),
         true <- saved["source_revision"] == report["source_revision"],
         {:ok, _} <- ReleaseInventory.verify(release) do
      {:ok, report}
    else
      false -> {:error, "Linux service source differs from issued inventory"}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_payload(release) do
    root = Path.expand(release)

    {:ok, saved} = checked_json!(Path.join(root, @manifest))
    ensure!(is_map(saved), "invalid Linux service manifest")
    require_revision!(saved["source_revision"])
    artifact = artifact_id!(root, saved["source_revision"])
    expected_files = files(artifact)

    ensure!(
      saved == report(saved["source_revision"], artifact, expected_files),
      "Linux service profile or payload identity differs"
    )

    {:ok, entries} = checked_entries!(root)

    service_entries =
      entries |> Enum.filter(&String.starts_with?(&1["path"], @directory <> "/"))

    expected_paths = [@manifest | Enum.map(expected_files, &(@directory <> "/" <> elem(&1, 0)))]

    ensure!(
      Enum.map(service_entries, & &1["path"]) == Enum.sort(expected_paths),
      "Linux service file set differs"
    )

    for {relative, bytes} <- expected_files do
      path = @directory <> "/" <> relative
      entry = Enum.find(service_entries, &(&1["path"] == path))

      ensure!(
        entry["sha256"] == digest(bytes) and entry["mode"] == 0o644,
        "Linux service configuration differs: #{relative}"
      )
    end

    manifest_entry = Enum.find(service_entries, &(&1["path"] == @manifest))
    ensure!(manifest_entry["mode"] == 0o644, "Linux service manifest mode differs")
    {:ok, saved}
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "cannot verify Linux service: #{Exception.message(error)}"}
  end

  def files(artifact) do
    ensure!(
      is_binary(artifact) and Regex.match?(~r/\A[0-9a-f]{64}\z/, artifact),
      "invalid artifact id"
    )

    profile = @profile
    main = profile["main_limits"]
    journal = profile["journal_limits"]
    release = Path.join(profile["release_parent"], artifact)

    unit = """
    [Unit]
    Description=WoTEx Home local controller
    BindsTo=systemd-journald@wotex-home.service
    After=network.target systemd-journald@wotex-home.service
    StartLimitIntervalSec=#{main["start_limit_interval_seconds"]}s
    StartLimitBurst=#{main["start_limit_burst"]}

    [Service]
    Type=exec
    User=#{profile["account"]}
    Group=#{profile["group"]}
    WorkingDirectory=#{profile["state_directory"]}
    ExecStart=#{release}/bin/wotex_home start
    Environment=WOTEX_HOME_DATA_DIR=#{profile["state_directory"]}
    Environment=RELEASE_TMP=#{profile["runtime_directory"]}
    Environment=ERL_CRASH_DUMP=/dev/null
    Environment="ERL_FLAGS=#{profile["erl_flags"]}"
    StateDirectory=wotex-home
    StateDirectoryMode=0700
    RuntimeDirectory=wotex-home
    RuntimeDirectoryMode=0700
    UMask=0077
    Restart=on-failure
    RestartSec=#{main["restart_delay_seconds"]}s
    TimeoutStopSec=#{main["stop_timeout_seconds"]}s
    KillMode=mixed
    KillSignal=SIGTERM
    SendSIGKILL=yes
    OOMPolicy=stop
    CPUAccounting=yes
    CPUQuota=#{main["cpu_quota_percent"]}%
    MemoryAccounting=yes
    MemoryHigh=#{main["memory_high_bytes"]}
    MemoryMax=#{main["memory_max_bytes"]}
    MemorySwapMax=#{main["memory_swap_max_bytes"]}
    TasksAccounting=yes
    TasksMax=#{main["tasks_max"]}
    LimitNOFILE=#{main["nofile"]}
    LimitCORE=#{main["core_bytes"]}
    NoNewPrivileges=yes
    ProtectSystem=strict
    ProtectHome=yes
    PrivateTmp=yes
    PrivateDevices=yes
    ProtectKernelTunables=yes
    ProtectKernelModules=yes
    ProtectKernelLogs=yes
    ProtectControlGroups=yes
    ProtectClock=yes
    RestrictSUIDSGID=yes
    RestrictRealtime=yes
    LockPersonality=yes
    CapabilityBoundingSet=
    AmbientCapabilities=
    RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
    DevicePolicy=closed
    StandardInput=null
    StandardOutput=journal
    StandardError=journal
    LogNamespace=#{profile["journal_namespace"]}
    LogRateLimitIntervalSec=#{journal["rate_interval_seconds"]}s
    LogRateLimitBurst=#{journal["rate_burst"]}

    [Install]
    WantedBy=multi-user.target
    """

    logging = """
    [Journal]
    Storage=volatile
    ReadKMsg=no
    ForwardToSyslog=no
    ForwardToKMsg=no
    ForwardToConsole=no
    ForwardToWall=no
    RuntimeMaxUse=#{journal["retained_bytes"]}
    RuntimeMaxFileSize=#{journal["file_bytes"]}
    RateLimitIntervalSec=#{journal["rate_interval_seconds"]}s
    RateLimitBurst=#{journal["rate_burst"]}
    """

    budget = """
    [Unit]
    Requires=run-wotexhomejournal.mount
    After=run-wotexhomejournal.mount
    StartLimitIntervalSec=#{main["start_limit_interval_seconds"]}s
    StartLimitBurst=#{main["start_limit_burst"]}

    [Service]
    LogsDirectory=
    BindPaths=#{profile["journal_mount_directory"]}:/run/log/journal
    Restart=on-failure
    RestartSec=#{main["restart_delay_seconds"]}s
    TimeoutStopSec=#{main["stop_timeout_seconds"]}s
    OOMPolicy=stop
    CPUAccounting=yes
    CPUQuota=#{journal["cpu_quota_percent"]}%
    MemoryAccounting=yes
    MemoryMax=#{journal["memory_max_bytes"]}
    MemorySwapMax=#{journal["memory_swap_max_bytes"]}
    TasksAccounting=yes
    TasksMax=#{journal["tasks_max"]}
    LimitNOFILE=#{journal["nofile"]}
    LimitCORE=0
    """

    mount = """
    [Unit]
    Description=WoTEx Home volatile journal storage
    Before=systemd-journald@wotex-home.service

    [Mount]
    What=tmpfs
    Where=#{profile["journal_mount_directory"]}
    Type=tmpfs
    Options=rw,nosuid,nodev,noexec,size=#{journal["tmpfs_bytes"]},mode=0750
    DirectoryMode=0750
    """

    %{@unit => unit, @journal => logging, @budget => budget, @mount => mount}
  end

  defp report(revision, artifact, files) do
    %{
      "schema_version" => 1,
      "scope" => "inert_linux_service_configuration",
      "source_revision" => revision,
      "artifact_id" => artifact,
      "profile" => @profile,
      "files" => Map.new(files, fn {path, bytes} -> {path, digest(bytes)} end),
      "registration" => "not_performed_by_packaging",
      "artifact_authenticity" => "not_established",
      "license_review" => "unresolved"
    }
  end

  defp artifact_id!(root, revision) do
    {:ok, entries} = checked_entries!(root)

    payload =
      entries
      |> Enum.reject(fn entry ->
        entry["path"] in @reports or String.starts_with?(entry["path"], @directory <> "/")
      end)

    ensure!(payload != [], "Linux service requires a nonempty core payload")
    # Arrays give the digest a fixed field order. Service files and final
    # reports are excluded, avoiding a self-referential installation path.
    descriptor = Enum.map(payload, &[&1["path"], &1["mode"], &1["size"], &1["sha256"]])
    digest(JSON.encode!([revision, descriptor]))
  end

  defp checked_entries!(root) do
    case ReleaseInventory.entries(root) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> fail!(reason)
    end
  end

  defp checked_json!(path) do
    case Json.read(path, 65_536) do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> fail!(reason)
    end
  end

  defp write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o644)
  end

  defp require_revision!(revision) do
    ensure!(
      is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
      "invalid Linux service source revision"
    )
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp ensure!(true, _reason), do: :ok
  defp ensure!(_, reason), do: fail!(reason)
  defp fail!(reason), do: raise(Error, message: reason)
end

defmodule Mix.Tasks.Woh.Linux.Service.Package do
  @moduledoc "Verify inert Linux service configuration in an inventoried release."
  @shortdoc "Verify the packaged Linux service configuration"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(["verify", release]) do
    case Woh.Tool.LinuxServicePackage.verify(release) do
      {:ok, report} ->
        Mix.shell().info(
          "verified inert Linux service configuration #{report["artifact_id"]}; " <>
            "no installed-host qualification"
        )

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.linux.service.package verify RELEASE_PATH")
end
