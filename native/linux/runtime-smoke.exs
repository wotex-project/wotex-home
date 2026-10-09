# Trusted developer probe, evaluated by the selected packaged release only.
# Its private fixtures never enroll devices, create credentials or enable I/O.
defmodule Woh.Native.LinuxRuntimeSmoke do
  @moduledoc false
  import Bitwise

  alias Woh.Tool.{Command, Json, LinuxNativeBundle, ReleaseInventory, ReleaseSmoke}
  alias WotexHome.Durable.Store
  alias WotexHome.Host

  def run do
    root = System.fetch_env!("WOTEX_HOME_RUNTIME_RELEASE") |> Path.expand()
    revision = System.fetch_env!("WOTEX_HOME_EXPECT_SOURCE_REVISION")
    require!(Regex.match?(~r/\A[0-9a-f]{40}\z/, revision), "invalid expected source revision")
    require!(:os.type() == {:unix, :linux}, "probe requires Linux")

    require!(
      String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64"),
      "probe requires arm64"
    )

    require!(not Node.alive?(), "distributed Erlang is enabled")
    {:ok, uid} = Command.run("id", ["-u"], 128, 5_000)
    require!(String.trim(uid) != "0", "probe requires an unprivileged user")

    for tool <- ~w(elixir mix cc gcc clang readelf patchelf) do
      require!(System.find_executable(tool) == nil, "ambient build tool is present: #{tool}")
    end

    # ERTS adds its own bin directory to PATH during boot.
    for tool <- ~w(erl erlc epmd), path = System.find_executable(tool), path != nil do
      require!(
        String.starts_with?(Path.expand(path), root <> "/erts-"),
        "ambient Erlang executable is present: #{tool}"
      )
    end

    code = :code.which(Host) |> to_string() |> Path.expand()
    require!(String.starts_with?(code, root <> "/lib/"), "Home code is outside selected release")
    require!(File.stat!("/etc/os-release").size <= 16_384, "overlong OS metadata")
    os = File.read!("/etc/os-release") |> String.split("\n")
    require!("ID=debian" in os and "VERSION_ID=\"13\"" in os, "probe requires Debian 13")

    {:ok, glibc} = Command.run("dpkg-query", ["-W", "-f=${Version}", "libc6"], 256, 5_000)
    require!(not String.contains?(glibc, "\n"), "invalid glibc package version")
    require_private_defaults!()
    {:ok, count} = ReleaseInventory.verify(root)
    {:ok, manifest} = Json.read(Path.join(root, ReleaseInventory.manifest()), 2_000_000)
    require!(manifest["source_revision"] == revision, "release source differs from expected")
    {:ok, _} = ReleaseSmoke.check_payload(Path.join(root, "bin/wotex_home"))

    directory =
      Path.join(System.tmp_dir!(), "woh-minimal-runtime-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      for boot <- 1..2, do: boot!(directory, root, boot)
      {:ok, ^count} = ReleaseInventory.verify(root)

      IO.puts(
        "MINIMAL_RUNTIME_OK source=#{revision} glibc=#{String.trim(glibc)} " <>
          "inventory=#{count}; no installed-service or hardware qualification"
      )
    after
      File.rm_rf!(directory)
    end
  end

  defp boot!(directory, root, boot) do
    require_private_defaults!()
    {:ok, host} = Host.start_link(data_dir: directory)

    try do
      socket = Path.join(directory, "ipc/home.sock")
      database = Path.join(directory, "home.sqlite")
      require!(ReleaseSmoke.host_ready?(socket, database), "private host is not ready")
      require!(not Host.authority().power_dispatch, "physical dispatch unexpectedly enabled")
      require!(Host.lifx_capture() == nil, "network capture unexpectedly started")
      {:ok, 0} = Store.revision(Host.store())

      for {path, mode} <- [
            {directory, 0o700},
            {Path.dirname(socket), 0o700},
            {socket, 0o600},
            {database, 0o600}
          ] do
        require!((File.lstat!(path).mode &&& 0o777) == mode, "private path mode differs")
      end

      require!(File.stat!("/proc/self/maps").type == :regular, "process maps unavailable")
      maps = File.read!("/proc/self/maps")
      require!(byte_size(maps) <= 1_048_576, "overlong process maps")

      for provider <- LinuxNativeBundle.profile()["libraries"] do
        path = Path.join(root, "native/linux-libraries/lib/" <> provider["library"])

        require!(
          String.contains?(maps, path),
          "packaged provider not mapped: #{provider["library"]}"
        )
      end
    after
      if Process.alive?(host), do: Supervisor.stop(host, :normal, 10_000)
    end

    require!(not File.exists?(Path.join(directory, "ipc/home.sock")), "shutdown left a socket")
    require!(File.regular?(Path.join(directory, "home.sqlite")), "shutdown lost private Store")
    IO.puts("MINIMAL_PRIVATE_HOST_BOOT_#{boot}_OK")
  end

  defp require_private_defaults! do
    require!(Host.store() == nil and Host.lifx_capture() == nil, "an existing host is running")

    for key <- ~w(WOTEX_HOME_DATA_DIR WOTEX_HOME_LIFX_INTERFACE) do
      require!(System.get_env(key) == nil, "existing host configuration is present")
    end

    for key <- [:data_dir, :lifx_capture_interface, :component_preview] do
      require!(
        Application.get_env(:wotex_home, key) == nil,
        "configured host integration is present"
      )
    end

    require!(not Host.authority().power_dispatch, "physical dispatch is configured")

    require!(
      Application.get_env(:wotex_home, :schedule_delivery_enabled, false) == false,
      "temporal delivery is configured"
    )
  end

  defp require!(true, _reason), do: :ok
  defp require!(_, reason), do: raise(reason)
end

Woh.Native.LinuxRuntimeSmoke.run()
