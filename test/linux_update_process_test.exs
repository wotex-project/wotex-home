defmodule WotexHome.LinuxUpdateProcessTest do
  use ExUnit.Case

  alias Woh.Tool.{LinuxInstallHost, LinuxUpdateProcess}

  @cgroup "/system.slice/wotex-home.service"
  @digest String.duplicate("a", 64)
  @boot "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  test "registration binds a stable owned service to its cgroup and invocation" do
    assert {:ok, %{pid: 42, cgroup: @cgroup, invocation_id: id}} =
             LinuxInstallHost.controller_registration(query(registration()))

    assert id == String.duplicate("b", 32)

    for changed <- [
          String.replace(registration(), @cgroup, "/foreign"),
          String.replace(registration(), String.duplicate("b", 32), ""),
          String.replace(registration(), String.duplicate("b", 32), String.duplicate("0", 32)),
          String.replace(registration(), String.duplicate("b", 32), String.duplicate("B", 32)),
          registration() <> "InvocationID=expanded\n",
          String.replace(registration(), "ControlGroup=" <> @cgroup <> "\n", ""),
          String.replace(registration(), "MainPID=42", "MainPID=43\nPrivate=expanded")
        ],
        do: assert({:error, _} = LinuxInstallHost.controller_registration(query(changed)))

    assert {:ok, %{state: :stopped, pid: 0}} =
             LinuxInstallHost.controller_registration(query(registration(:stopped)))
  end

  test "kernel frames have closed fields and canonical incarnation identity" do
    assert {:ok, observed} = LinuxUpdateProcess.decode(frame())
    assert observed.pid == 42 and observed.start_ticks == 90 and observed.account_id == 211
    assert :ok = LinuxUpdateProcess.join_peer(observed, 42)
    assert {:error, _} = LinuxUpdateProcess.join_peer(observed, 43)

    for changed <- [
          frame() <> "expanded\n",
          String.trim_trailing(frame(), "\n"),
          String.replace(frame(), "42\t211", "042\t211"),
          String.replace(frame(), "42\t211", "1\t211"),
          String.replace(frame(), "\t90\t", "\t0\t"),
          String.replace(frame(), "\t90\t", "\t90.0\t"),
          String.replace(frame(), @boot, String.upcase(@boot)),
          String.replace(frame(), @cgroup, "/foreign"),
          String.replace(frame(), "\t6\t7\n", "\t6\t0\n"),
          String.duplicate("x", 4097)
        ],
        do: assert({:error, _} = LinuxUpdateProcess.decode(changed))
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    alias Woh.Tool.{LinuxInstallFiles, LinuxServicePackage, ReleaseBootstrap, ReleaseInventory}
    @tool Path.expand("../native/linux/installer-files", __DIR__)

    setup do
      root = Path.join(System.tmp_dir!(), "woh-process-#{System.unique_integer([:positive])}")
      image = root <> "/release/erts-28.5.0.6/bin/beam.smp"
      File.mkdir_p!(Path.dirname(image))

      for path <- [
            root,
            root <> "/release",
            root <> "/release/erts-28.5.0.6",
            Path.dirname(image)
          ],
          do: File.chmod!(path, 0o755)

      File.cp!("/usr/bin/sleep", image)
      File.chmod!(image, 0o755)
      {:ok, report} = LinuxServicePackage.assemble(root <> "/release", String.duplicate("c", 40))
      {:ok, _} = ReleaseInventory.create(root <> "/release", report["source_revision"])
      File.chmod!(root <> "/release/release-inventory.json", 0o644)
      {:ok, bootstrap} = ReleaseBootstrap.render(root <> "/release")

      identity = %{
        "source_revision" => report["source_revision"],
        "artifact_id" => report["artifact_id"],
        "bootstrap_sha256" => LinuxInstallFiles.digest(bootstrap),
        "inventory_sha256" =>
          LinuxInstallFiles.digest(File.read!(root <> "/release/release-inventory.json"))
      }

      on_exit(fn -> File.rm_rf!(root) end)

      %{
        root: root,
        image: image,
        release: root <> "/release",
        identity: identity,
        digest: LinuxInstallFiles.digest(File.read!(image)),
        size: File.stat!(image).size
      }
    end

    test "held actual process observations bind the root image and dropped service identity", c do
      {port, pid} = child(c.image)
      on_exit(fn -> stop_child(port, pid, c.image) end)
      await_image(pid, c.image, 100)

      assert {:ok, bytes} =
               LinuxInstallFiles.observe_process(pid, c.image, c.digest, c.size, 211, @tool)

      ["WOTEX_HOME_PROCESS\t1", fields, ""] = String.split(bytes, "\n")

      [observed_pid, "211", start, boot, cgroup, digest, _device, inode] =
        String.split(fields, "\t")

      assert observed_pid == to_string(pid) and String.to_integer(start) > 0
      assert byte_size(boot) == 36 and digest == c.digest and String.to_integer(inode) > 0
      # This container has no installed systemd service. Kernel reads are actual;
      # production joining must refuse its different cgroup, not rename evidence.
      refute cgroup == @cgroup
      assert {:error, _} = LinuxUpdateProcess.decode(bytes)

      assert {:error, _} =
               LinuxInstallFiles.observe_process(
                 pid,
                 c.image,
                 String.duplicate("0", 64),
                 c.size,
                 211,
                 @tool
               )

      assert {:error, _} =
               LinuxInstallFiles.observe_process(pid, c.image, c.digest, c.size, 212, @tool)

      other = c.root <> "/release/erts-28.5.0.7/bin/beam.smp"
      File.mkdir_p!(Path.dirname(other))
      File.cp!(c.image, other)

      assert {:error, _} =
               LinuxInstallFiles.observe_process(pid, other, c.digest, c.size, 211, @tool)

      assert File.read!(c.image) == File.read!("/usr/bin/sleep")

      {_, status} =
        System.cmd(
          @tool,
          ["observe-process", to_string(pid), c.image, c.digest, to_string(c.size), "211"],
          stderr_to_stdout: true
        )

      assert status != 0
    end

    test "a service UID without no-new-privileges refuses observation", c do
      {port, pid} = child(c.image, false)
      on_exit(fn -> stop_child(port, pid, c.image) end)
      await_image(pid, c.image, 100)
      assert String.contains?(File.read!("/proc/#{pid}/status"), "NoNewPrivs:\t0\n")

      assert {:error, _} =
               LinuxInstallFiles.observe_process(pid, c.image, c.digest, c.size, 211, @tool)
    end

    test "payload image selection requires retained whole-release pins and root custody", c do
      assert {:ok, %{path: path, sha256: digest}} =
               LinuxUpdateProcess.image(c.release, c.identity)

      assert path == c.image and digest == c.digest

      assert {:error, _} =
               LinuxUpdateProcess.image(c.release, %{
                 c.identity
                 | "bootstrap_sha256" => String.duplicate("0", 64)
               })

      assert {:error, _} =
               LinuxUpdateProcess.image(
                 c.release,
                 Map.put(c.identity, "credential", "inert canary")
               )

      File.chmod!(c.release <> "/release-inventory.json", 0o600)
      assert {:ok, _} = LinuxServicePackage.verify(c.release)
      assert {:error, _} = LinuxUpdateProcess.image(c.release, c.identity)
      File.chmod!(c.release <> "/release-inventory.json", 0o644)
      File.chmod!(c.root, 0o777)
      assert {:error, _} = LinuxUpdateProcess.image(c.release, c.identity)
    end

    test "running joins reject changed process, registration, peer and retained incarnation", c do
      script = c.root <> "/observation-tool"

      File.write!(
        script,
        "#!/bin/sh\nprintf '%s\\n' 'WOTEX_HOME_PROCESS\t1' '42\t211\t90\t#{@boot}\t#{@cgroup}\t#{c.digest}\t6\t7'\n"
      )

      File.chmod!(script, 0o755)
      # This is a synthetic process frame; actual kernel parsing is tested above.
      options = [query: query(registration()), tool: script]
      assert {:ok, observed} = LinuxUpdateProcess.running(c.release, c.identity, 211, options)
      assert :ok = LinuxUpdateProcess.join_peer(observed, 42)

      assert {:error, _} =
               LinuxUpdateProcess.running(
                 c.release,
                 c.identity,
                 211,
                 options ++ [expected: %{observed | start_ticks: 91}]
               )

      Process.put(:registration_reads, 0)

      changing = fn path, args, bound, deadline ->
        count = Process.get(:registration_reads)
        Process.put(:registration_reads, count + 1)

        query(
          if(count == 0,
            do: registration(),
            else: String.replace(registration(), "MainPID=42", "MainPID=43")
          )
        ).(path, args, bound, deadline)
      end

      assert {:error, _} =
               LinuxUpdateProcess.running(c.release, c.identity, 211,
                 query: changing,
                 tool: script
               )

      File.write!(
        script,
        "#!/bin/sh\nprintf '%s\\n' 'WOTEX_HOME_PROCESS\t1' '42\t212\t90\t#{@boot}\t#{@cgroup}\t#{c.digest}\t6\t7'\n"
      )

      assert {:error, _} = LinuxUpdateProcess.running(c.release, c.identity, 211, options)
    end

    test "empty cgroup observation refuses live descendants, links and changed registration", c do
      cgroup_root = c.root <> "/cgroup"
      group = cgroup_root <> @cgroup
      options = [query: stopped_query(), tool: @tool, cgroup_root: cgroup_root]
      File.mkdir_p!(group)
      File.write!(group <> "/cgroup.events", "populated 0\nfrozen 0\n")
      File.write!(group <> "/cgroup.procs", "")
      File.rename!(group <> "/cgroup.events", group <> "/events.saved")
      File.ln_s!(group <> "/events.saved", group <> "/cgroup.events")
      assert {:error, _} = LinuxUpdateProcess.stopped(options)
      File.rm!(group <> "/cgroup.events")
      File.rename!(group <> "/events.saved", group <> "/cgroup.events")
      assert :ok = LinuxUpdateProcess.stopped(options)

      for {events, procs} <- [
            # nested live processes despite empty parent
            {"populated 1\nfrozen 0\n", ""},
            {"populated 0\nfrozen 0\n", "42\n"},
            {"populated 0\nfrozen 1\n", ""},
            {"populated 0\nfrozen 0\nexpanded 0\n", ""}
          ] do
        File.write!(group <> "/cgroup.events", events)
        File.write!(group <> "/cgroup.procs", procs)
        assert {:error, _} = LinuxUpdateProcess.stopped(options)
      end

      File.write!(group <> "/cgroup.events", "populated 0\nfrozen 0\n")
      File.write!(group <> "/cgroup.procs", "")
      File.rename!(group, group <> ".saved")
      File.ln_s!(group <> ".saved", group)
      assert {:error, _} = LinuxUpdateProcess.stopped(options)
      File.rm!(group)
      assert :ok = LinuxUpdateProcess.stopped(options)

      assert {:error, _} =
               LinuxUpdateProcess.stopped(Keyword.put(options, :query, stopped_query(:running)))

      # Filesystem/event bytes and registration are synthetic. These cases prove
      # native descriptor checks and joins, not an actual installed cgroup stop.
    end

    defp child(image, no_new_privileges \\ true) do
      port =
        Port.open({:spawn_executable, "/usr/bin/setpriv"}, [
          :binary,
          :exit_status,
          args:
            [
              "--bounding-set=-all",
              "--inh-caps=-all",
              "--ambient-caps=-all",
              "--clear-groups",
              "--reuid=211",
              "--regid=211"
            ] ++ if(no_new_privileges, do: ["--no-new-privs"], else: []) ++ [image, "60"]
        ])

      {:os_pid, pid} = Port.info(port, :os_pid)
      {port, pid}
    end

    defp await_image(_pid, _image, 0), do: flunk("service identity child did not become ready")

    defp await_image(pid, image, remaining) do
      if File.read_link("/proc/#{pid}/exe") != {:ok, image} do
        Process.sleep(10)
        await_image(pid, image, remaining - 1)
      end
    end

    defp stop_child(port, pid, image) do
      if File.read_link("/proc/#{pid}/exe") == {:ok, image},
        do: System.cmd("/bin/kill", ["-TERM", to_string(pid)])

      if Port.info(port), do: Port.close(port)
    end

    defp stopped_query(state \\ :stopped) do
      fn path, args, bound, deadline ->
        case path do
          "/usr/bin/stat" ->
            assert Enum.take(args, 3) == ["-f", "-c", "%T"] and bound == 128 and deadline == 5000
            {:ok, "cgroup2fs\n"}

          _ ->
            query(registration(state)).(path, args, bound, deadline)
        end
      end
    end
  end

  defp query(output) do
    fn path, args, bound, deadline ->
      assert path == "/usr/bin/systemctl" and bound == 4096 and deadline == 5000
      assert "--all" in args and List.last(args) == "wotex-home.service"
      {:ok, output}
    end
  end

  defp registration(state \\ :running) do
    "LoadState=loaded\nActiveState=#{if state == :running, do: "active", else: "inactive"}\nSubState=#{if state == :running, do: "running", else: "dead"}\nMainPID=#{if state == :running, do: 42, else: 0}\nControlPID=0\nFragmentPath=/etc/systemd/system/wotex-home.service\nDropInPaths=\nControlGroup=#{if state == :running, do: @cgroup, else: ""}\nInvocationID=#{if state == :running, do: String.duplicate("b", 32), else: ""}\n"
  end

  defp frame, do: "WOTEX_HOME_PROCESS\t1\n42\t211\t90\t#{@boot}\t#{@cgroup}\t#{@digest}\t6\t7\n"
end
