defmodule Woh.Tool.LinuxInstaller do
  @moduledoc false
  import Bitwise

  alias Woh.Tool.{
    Json,
    LinuxInstallFiles,
    LinuxInstallHost,
    LinuxInstallPreflight,
    LinuxServicePackage,
    ReleaseBootstrap,
    ReleaseInventory
  }

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @phases ~w(claimed accounts_pending accounts_ready configuration_pending configuration_ready registration_pending installed uninstall_pending uninstall_stopped uninstalled)
  @setup_phases ~w(claimed accounts_pending accounts_ready configuration_pending configuration_ready registration_pending installed)
  @maximum_generation 9_223_372_036_854_775_807
  @owner_keys ~w(schema_version scope installation_id source_revision artifact_id bootstrap_sha256 profile account_id configuration)

  # Backend/root/tool overrides are for private mechanism fixtures. The shipped
  # CLI has no such options and always uses the real host and fixed root.
  def run(action, release, manifest, pin, options \\ []) do
    context = %{
      root: Keyword.get(options, :root, "/"),
      host: Keyword.get(options, :host, LinuxInstallHost),
      tool: Keyword.get(options, :tool, LinuxInstallFiles.packaged_tool()),
      fixture: Keyword.get(options, :fixture, false)
    }

    try do
      ensure!(action in [:install, :uninstall], "unknown installer action")

      unless context.fixture,
        do:
          require_ok!(
            LinuxInstallFiles.assert_lock(context.tool),
            "installer lock retention unavailable"
          )

      require_ok!(ReleaseBootstrap.verify(release, manifest, pin), "bootstrap payload differs")
      {:ok, report} = require_ok!(LinuxServicePackage.verify(release), "service package differs")
      {:ok, snapshot} = require_ok!(context.host.snapshot(), "host observations unavailable")
      require_ok!(LinuxInstallPreflight.check_cohort(snapshot), "host cohort refused")
      base = path(context, "/opt/wotex-home")

      {owner, owner_bytes, state, state_bytes} =
        case File.lstat(base) do
          {:error, :enoent} ->
            ensure!(action == :install, "no owned installation to uninstall")

            require_ok!(
              LinuxInstallPreflight.plan(report, snapshot),
              "initial ownership preflight refused"
            )

            {:ok, id} =
              require_ok!(context.host.choose_account_id(), "system account identity unavailable")

            ensure!(is_integer(id) and id in 100..999, "system account ID outside bounded range")
            claim!(context, release, manifest, pin, report, id)

          {:ok, _} ->
            load!(context, report, pin)

          _ ->
            fail!("installation namespace unavailable")
        end

      validate_release!(context, owner)
      validate_host!(context, owner)

      require_ok!(
        LinuxInstallFiles.sync(base, owner_bytes, context.tool),
        "retained namespace sync failed"
      )

      if action == :uninstall do
        uninstall!(context, owner, owner_bytes, state, state_bytes)
      else
        install!(context, owner, owner_bytes, state, state_bytes)
      end
    rescue
      error in Error ->
        {:error, error.message}

      error in File.Error ->
        {:error, "installer filesystem operation failed: #{Exception.message(error)}"}

      _error in [ArgumentError, MatchError] ->
        {:error, "installer input or retained record is malformed"}
    end
  end

  defp claim!(context, release, manifest, pin, report, id) do
    installation = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    owner = %{
      "schema_version" => 1,
      "scope" => "linux_initial_installation",
      "installation_id" => installation,
      "source_revision" => report["source_revision"],
      "artifact_id" => report["artifact_id"],
      "bootstrap_sha256" => pin,
      "profile" => report["profile"],
      "account_id" => id,
      "configuration" =>
        Map.new(report["files"], fn {relative, sha} -> {"/" <> relative, sha} end)
    }

    owner_bytes = JSON.encode!(owner) <> "\n"

    state = %{
      "schema_version" => 1,
      "owner_sha256" => LinuxInstallFiles.digest(owner_bytes),
      "generation" => 0,
      "uninstall_from" => nil,
      "phase" => "claimed"
    }

    state_bytes = JSON.encode!(state) <> "\n"
    staging = path(context, "/opt/.wotex-home-stage-" <> installation)
    mkdir!(context, staging, 0o700, 0, 0)
    namespace = Path.join(staging, "namespace")
    mkdir!(context, namespace, 0o755, 0, 0)
    mkdir!(context, Path.join(namespace, ".installer"), 0o700, 0, 0)
    write!(context, Path.join(namespace, ".installer/owner.json"), owner_bytes, nil)
    write!(context, Path.join(namespace, ".installer/state.json"), state_bytes, nil)
    mkdir!(context, Path.join(namespace, "releases"), 0o755, 0, 0)
    destination = Path.join(namespace, "releases/" <> owner["artifact_id"])

    require_ok!(
      LinuxInstallFiles.bootstrap(release, manifest, pin, destination, context.tool),
      "verified release copy failed"
    )

    require_ok!(ReleaseInventory.verify(destination), "staged inventory differs")
    make_traversable!(destination)
    require_ok!(LinuxServicePackage.verify(destination), "staged service profile differs")

    require_ok!(
      LinuxInstallFiles.publish(
        namespace,
        path(context, "/opt/wotex-home"),
        owner_bytes,
        context.tool
      ),
      "namespace publication refused"
    )

    # Only this newly created empty staging parent is removed. A crash leaves
    # the marked/inert source or the complete published namespace identifiable.
    File.rmdir(staging)
    {owner, owner_bytes, state, state_bytes}
  end

  defp load!(context, report, pin) do
    private_directory!(path(context, "/opt/wotex-home"), 0, 0o755)
    private_directory!(path(context, "/opt/wotex-home/.installer"), 0, 0o700)
    owner_path = path(context, "/opt/wotex-home/.installer/owner.json")
    state_path = path(context, "/opt/wotex-home/.installer/state.json")
    owner_bytes = owned_bytes!(owner_path, 0o600)
    state_bytes = owned_bytes!(state_path, 0o600)
    {:ok, owner} = require_ok!(Json.read(owner_path, 65_536), "owner record unavailable")
    {:ok, state} = require_ok!(Json.read(state_path, 65_536), "installer state unavailable")

    ensure!(
      is_map(owner) and MapSet.new(Map.keys(owner)) == MapSet.new(@owner_keys),
      "owner record shape differs"
    )

    ensure!(
      owner["schema_version"] == 1 and owner["scope"] == "linux_initial_installation" and
        hex?(owner["installation_id"], 64) and is_integer(owner["account_id"]) and
        owner["account_id"] in 100..999,
      "owner identity differs"
    )

    ensure!(
      owner["source_revision"] == report["source_revision"] and
        owner["artifact_id"] == report["artifact_id"] and
        owner["bootstrap_sha256"] == pin and owner["profile"] == LinuxServicePackage.profile() and
        owner["configuration"] ==
          Map.new(report["files"], fn {relative, sha} -> {"/" <> relative, sha} end),
      "existing installation differs; an update requires the maintenance/recovery workflow"
    )

    ensure!(
      is_map(state) and
        MapSet.new(Map.keys(state)) ==
          MapSet.new(~w(schema_version owner_sha256 generation phase uninstall_from)) and
        state["schema_version"] == 1 and
        state["owner_sha256"] == LinuxInstallFiles.digest(owner_bytes) and
        is_integer(state["generation"]) and state["generation"] in 0..@maximum_generation and
        state["phase"] in @phases and
        if(state["phase"] in @setup_phases,
          do: state["uninstall_from"] == nil,
          else: state["uninstall_from"] in @setup_phases
        ),
      "installer state shape or ownership differs"
    )

    {owner, owner_bytes, state, state_bytes}
  end

  defp install!(context, owner, owner_bytes, state, bytes) do
    ensure!(
      state["phase"] not in ["uninstall_pending", "uninstall_stopped"],
      "finish interrupted uninstall before reinstalling"
    )

    {state, bytes} =
      if state["phase"] == "uninstalled",
        do: transition!(context, %{state | "uninstall_from" => nil}, bytes, "accounts_pending"),
        else: {state, bytes}

    {state, bytes} =
      if state["phase"] == "claimed",
        do: transition!(context, state, bytes, "accounts_pending"),
        else: {state, bytes}

    {state, bytes} =
      if state["phase"] == "accounts_pending" do
        accounts!(context, owner)
        transition!(context, state, bytes, "accounts_ready")
      else
        verify_accounts!(context, owner)
        {state, bytes}
      end

    {state, bytes} =
      if state["phase"] == "accounts_ready",
        do: transition!(context, state, bytes, "configuration_pending"),
        else: {state, bytes}

    {state, bytes} =
      if state["phase"] == "configuration_pending" do
        ensure_state_directory!(context, owner)
        configuration!(context, owner, :create)

        require_ok!(
          context.host.verify_units(context.root),
          "service parser refused configuration"
        )

        transition!(context, state, bytes, "configuration_ready")
      else
        verify_state_directory!(context, owner)
        configuration!(context, owner, :verify)
        {state, bytes}
      end

    {state, bytes} =
      if state["phase"] == "configuration_ready",
        do: transition!(context, state, bytes, "registration_pending"),
        else: {state, bytes}

    {state, bytes} =
      if state["phase"] == "registration_pending" do
        validate_host!(context, owner)
        configuration!(context, owner, :verify)

        require_ok!(
          context.host.verify_units(context.root),
          "service parser refused configuration"
        )

        require_ok!(context.host.reload(), "service reload failed")
        require_ok!(context.host.effective_units(), "effective service configuration differs")
        require_ok!(context.host.enable_start(), "service registration/start failed")
        require_ok!(context.host.running(), "registered service is not active")
        transition!(context, state, bytes, "installed")
      else
        require_ok!(context.host.effective_units(), "effective service configuration differs")
        require_ok!(context.host.running(), "registered service is not active")
        {state, bytes}
      end

    ensure!(state["phase"] == "installed", "installation did not reach installed state")

    ensure!(
      state["owner_sha256"] == LinuxInstallFiles.digest(owner_bytes),
      "installation owner changed"
    )

    {:ok, result(owner, state, bytes)}
  end

  defp uninstall!(context, owner, _owner_bytes, state, bytes) do
    if state["phase"] == "uninstalled" do
      verify_uninstall_assets!(context, owner, state)
      configuration!(context, owner, :absent)
      {:ok, result(owner, state, bytes)}
    else
      verify_uninstall_assets!(context, owner, state)

      configuration!(
        context,
        owner,
        :verify_or_absent
      )

      {state, bytes} =
        if state["phase"] not in ["uninstall_pending", "uninstall_stopped"] do
          if state["phase"] == "installed",
            do:
              require_ok!(
                context.host.effective_units(),
                "effective configuration differs before uninstall"
              )

          transition!(
            context,
            %{state | "uninstall_from" => state["phase"]},
            bytes,
            "uninstall_pending"
          )
        else
          {state, bytes}
        end

      {state, bytes} =
        if state["phase"] == "uninstall_pending" do
          validate_host!(context, owner)
          require_ok!(context.host.disable_stop(), "Home disable/stop failed")
          require_ok!(context.host.stop_journal(), "owned journal/mount stop failed")
          transition!(context, state, bytes, "uninstall_stopped")
        else
          {state, bytes}
        end

      configuration!(context, owner, :remove)
      require_ok!(context.host.reload(), "service reload after uninstall failed")
      {state, bytes} = transition!(context, state, bytes, "uninstalled")
      {:ok, result(owner, state, bytes)}
    end
  end

  defp verify_uninstall_assets!(context, owner, state) do
    original = state["uninstall_from"] || state["phase"]

    if original in ~w(installed registration_pending configuration_ready configuration_pending accounts_ready) do
      verify_accounts!(context, owner)
    else
      {:ok, status} =
        require_ok!(
          context.host.accounts(owner["account_id"], owner["installation_id"]),
          "partial account ownership differs"
        )

      ensure!(status in [:absent, :group_only, :ready], "partial account namespace differs")
    end

    target = path(context, "/var/lib/wotex-home")
    if File.lstat(target) != {:error, :enoent}, do: verify_state_directory!(context, owner)
  end

  defp accounts!(context, owner) do
    id = owner["account_id"]

    {:ok, status} =
      require_ok!(
        context.host.accounts(id, owner["installation_id"]),
        "account observations differ"
      )

    ensure!(status in [:absent, :group_only, :ready], "foreign account namespace")

    if status == :absent,
      do: require_ok!(context.host.create_group(id), "Home group creation failed")

    if status != :ready,
      do:
        require_ok!(
          context.host.create_user(id, owner["installation_id"]),
          "Home user creation failed"
        )

    verify_accounts!(context, owner)
  end

  defp verify_accounts!(context, owner) do
    ensure!(
      context.host.accounts(owner["account_id"], owner["installation_id"]) == {:ok, :ready},
      "recorded Home account or group differs"
    )
  end

  defp ensure_state_directory!(context, owner) do
    target = path(context, "/var/lib/wotex-home")

    if File.lstat(target) == {:error, :enoent},
      do: mkdir!(context, target, 0o700, owner["account_id"], owner["account_id"])

    verify_state_directory!(context, owner)
  end

  defp verify_state_directory!(context, owner),
    do: private_directory!(path(context, "/var/lib/wotex-home"), owner["account_id"], 0o700)

  defp configuration!(context, owner, mode) do
    files = LinuxServicePackage.files(owner["artifact_id"])
    budget_directory = path(context, "/etc/systemd/system/systemd-journald@wotex-home.service.d")

    if mode == :create and File.lstat(budget_directory) == {:error, :enoent},
      do: mkdir!(context, budget_directory, 0o755, 0, 0)

    if File.lstat(budget_directory) != {:error, :enoent} do
      private_directory!(budget_directory, 0, 0o755)

      ensure!(
        Enum.sort(File.ls!(budget_directory)) in [[], ["home-budget.conf"]],
        "foreign journal budget files"
      )
    end

    for {relative, expected} <- Enum.sort(files) do
      target = path(context, "/" <> relative)

      case {mode, File.lstat(target)} do
        {:create, {:error, :enoent}} ->
          require_ok!(
            LinuxInstallFiles.write(target, 0o644, expected, nil, context.tool),
            "configuration publication failed"
          )

        {:remove, {:error, :enoent}} ->
          :ok

        {:absent, {:error, :enoent}} ->
          :ok

        {:verify_or_absent, {:error, :enoent}} ->
          :ok

        {_, {:ok, _}} ->
          ensure!(
            mode != :absent and owned_bytes!(target, 0o644) == expected,
            "installed configuration differs"
          )

          if mode == :remove,
            do:
              require_ok!(
                LinuxInstallFiles.remove(
                  target,
                  0o644,
                  LinuxInstallFiles.digest(expected),
                  context.tool
                ),
                "configuration removal failed"
              )

        _ ->
          fail!("configuration path unavailable")
      end
    end
  end

  defp validate_release!(context, owner) do
    release = path(context, "/opt/wotex-home/releases/" <> owner["artifact_id"])
    private_directory!(path(context, "/opt/wotex-home/releases"), 0, 0o755)
    private_directory!(release, 0, 0o755)
    {:ok, report} = require_ok!(LinuxServicePackage.verify(release), "installed release differs")

    ensure!(
      report["source_revision"] == owner["source_revision"] and
        report["artifact_id"] == owner["artifact_id"],
      "installed source identity differs"
    )
  end

  defp validate_namespaces!(context, snapshot, owner) do
    allowed =
      MapSet.new(
        [
          "/opt/wotex-home",
          "/var/lib/wotex-home",
          "/run/wotex-home",
          "/run/wotexhomejournal",
          "/etc/systemd/system/systemd-journald@wotex-home.service.d",
          "/etc/systemd/system/multi-user.target.wants/wotex-home.service"
        ] ++ Map.keys(owner["configuration"])
      )

    for target <- LinuxInstallPreflight.paths(), not MapSet.member?(allowed, target) do
      ensure!(snapshot[:paths][target] == :absent, "foreign Home service override or namespace")
    end

    for {target, uid, mode} <- [
          {"/run/wotex-home", owner["account_id"], 0o700},
          {"/run/wotexhomejournal", 0, 0o750}
        ] do
      absolute = path(context, target)
      if File.lstat(absolute) != {:error, :enoent}, do: private_directory!(absolute, uid, mode)
    end

    wanted = path(context, "/etc/systemd/system/multi-user.target.wants/wotex-home.service")

    if File.lstat(wanted) != {:error, :enoent} do
      {:ok, link} = File.read_link(wanted)
      info = File.lstat!(wanted)

      ensure!(
        info.type == :symlink and info.uid == 0 and info.gid == 0 and
          Path.expand(link, Path.dirname(wanted)) ==
            path(context, "/etc/systemd/system/wotex-home.service"),
        "foreign Home enablement link"
      )
    end
  end

  defp validate_host!(context, owner) do
    {:ok, snapshot} = require_ok!(context.host.snapshot(), "fresh host observations unavailable")
    require_ok!(LinuxInstallPreflight.check_cohort(snapshot), "fresh host cohort refused")
    validate_namespaces!(context, snapshot, owner)
  end

  defp transition!(context, state, old, phase) do
    ensure!(state["generation"] < @maximum_generation, "installer generation exhausted")
    updated = %{state | "generation" => state["generation"] + 1, "phase" => phase}
    bytes = JSON.encode!(updated) <> "\n"

    write!(
      context,
      path(context, "/opt/wotex-home/.installer/state.json"),
      bytes,
      LinuxInstallFiles.digest(old)
    )

    {updated, bytes}
  end

  defp make_traversable!(directory) do
    for name <- File.ls!(directory) do
      target = Path.join(directory, name)

      case File.lstat!(target).type do
        :directory -> make_traversable!(target)
        :regular -> :ok
        _ -> fail!("nonregular staged release")
      end
    end

    File.chmod!(directory, 0o755)
  end

  defp owned_bytes!(target, mode) do
    {:ok, info} = File.lstat(target)

    ensure!(
      info.type == :regular and info.uid == 0 and info.gid == 0 and info.links == 1 and
        (info.mode &&& 0o7777) == mode and info.size <= 65_536,
      "owned file type, owner, mode or bound differs"
    )

    bytes = File.read!(target)
    ensure!(byte_size(bytes) <= 65_536, "owned file exceeds bound")
    bytes
  end

  defp private_directory!(target, uid, mode) do
    {:ok, info} = File.lstat(target)

    ensure!(
      info.type == :directory and info.uid == uid and info.gid == uid and
        (info.mode &&& 0o7777) == mode,
      "owned directory type, owner or mode differs"
    )
  end

  defp mkdir!(context, target, mode, uid, gid),
    do:
      require_ok!(
        LinuxInstallFiles.mkdir(target, mode, uid, gid, context.tool),
        "owned directory creation failed"
      )

  defp write!(context, target, bytes, old),
    do:
      require_ok!(
        LinuxInstallFiles.write(target, 0o600, bytes, old, context.tool),
        "installer record publication failed"
      )

  defp path(context, absolute), do: Path.join(context.root, String.trim_leading(absolute, "/"))

  defp hex?(value, size),
    do: is_binary(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp result(owner, state, _bytes),
    do: %{
      "phase" => state["phase"],
      "artifact_id" => owner["artifact_id"],
      "source_revision" => owner["source_revision"],
      "private_state" => "preserved",
      "installed_host_qualification" => "missing",
      "physical_qualification" => "missing"
    }

  defp require_ok!(:ok, _), do: :ok
  defp require_ok!({:ok, _} = result, _), do: result
  defp require_ok!(_, reason), do: fail!(reason)
  defp ensure!(true, _), do: :ok
  defp ensure!(_, reason), do: fail!(reason)
  defp fail!(reason), do: raise(Error, message: reason)
end
