defmodule PackagedLinuxStageProbe do
  alias Woh.Tool.{
    LinuxInstallFiles,
    LinuxInstallStage,
    LinuxServicePackage,
    ReleaseBootstrap,
    ReleaseInventory
  }

  def run do
    try do
      phase(:source)
      source = System.fetch_env!("WOTEX_HOME_RUNTIME_RELEASE")
      pin = System.fetch_env!("WOTEX_HOME_BOOTSTRAP_PIN")
      expected_source = System.fetch_env!("WOTEX_HOME_EXPECT_SOURCE_REVISION")
      manifest = File.read!("/bootstrap.tsv")
      :ok = LinuxInstallFiles.assert_lock()
      {:ok, _} = ReleaseBootstrap.verify(source, "/bootstrap.tsv", pin)
      {:ok, report} = LinuxServicePackage.verify(source)
      ^expected_source = report["source_revision"]

      for executable <- ~w(elixir mix cc gcc clang),
          do: false = System.find_executable(executable) != nil

      {:ok, declared} = LinuxInstallStage.decode_manifest(manifest, pin)
      ^manifest = elem(ReleaseBootstrap.render(source), 1)

      base = "/tmp/woh-stage-fixture/installation"
      admin = base <> "/.installer"
      :ok = LinuxInstallFiles.mkdir(base, 0o755, 0, 0)
      :ok = LinuxInstallFiles.mkdir(admin, 0o700, 0, 0)
      :ok = LinuxInstallFiles.mkdir(base <> "/releases", 0o755, 0, 0)
      owner = "{\"scope\":\"private_packaged_stage_probe\"}\n"
      owner_path = admin <> "/owner.json"
      :ok = LinuxInstallFiles.write(owner_path, 0o600, owner)

      phase(:copy)
      {stage, marker} = stage(admin, "a")
      release = stage <> "/release"
      :ok = LinuxInstallFiles.bootstrap(source, "/bootstrap.tsv", pin, release)
      {:ok, %{complete: true} = copied} = LinuxInstallStage.snapshot(stage, marker, manifest, pin)
      {:ok, _} = ReleaseInventory.verify(release)
      {:ok, ^report} = LinuxServicePackage.verify(release)
      inventory = LinuxInstallFiles.digest(File.read!(release <> "/release-inventory.json"))
      destination = base <> "/releases/" <> report["artifact_id"]

      phase(:publish)

      :ok =
        LinuxInstallFiles.publish_release(
          release,
          destination,
          owner_path,
          owner,
          marker,
          copied.sha256,
          inventory
        )

      false = File.exists?(release)
      false = File.exists?(destination <> "/.installer")
      false = File.exists?(destination <> "/stage.json")
      ^owner = File.read!(owner_path)
      {:ok, ^manifest} = ReleaseBootstrap.render(destination)
      {:ok, ^report} = LinuxServicePackage.verify(destination)
      :ok = LinuxInstallFiles.sync_release(destination, owner_path, owner, inventory)
      {:ok, empty} = LinuxInstallStage.snapshot(stage, marker, manifest, pin)
      :ok = LinuxInstallFiles.remove_stage(stage, owner_path, owner, marker, empty.sha256)
      false = File.exists?(stage)

      phase(:partial)
      {partial_stage, partial_marker} = stage(admin, "b")
      partial_release = partial_stage <> "/release"
      :ok = LinuxInstallFiles.mkdir(partial_release, 0o700, 0, 0)
      :ok = LinuxInstallFiles.mkdir(partial_release <> "/bin", 0o700, 0, 0)
      source_bytes = File.read!(source <> "/bin/wotex_home")
      prefix = binary_part(source_bytes, 0, min(100, byte_size(source_bytes)))
      partial_path = partial_release <> "/bin/wotex_home"
      :ok = LinuxInstallFiles.write(partial_path, 0o600, prefix)

      {:ok, %{complete: false} = partial} =
        LinuxInstallStage.snapshot(partial_stage, partial_marker, manifest, pin, source)

      phase(:preserve_changed)
      changed = <<1>> <> binary_part(prefix, 1, byte_size(prefix) - 1)

      :ok =
        LinuxInstallFiles.write(partial_path, 0o600, changed, LinuxInstallFiles.digest(prefix))

      {:error, _} =
        LinuxInstallStage.snapshot(partial_stage, partial_marker, manifest, pin, source)

      {:error, _} =
        LinuxInstallFiles.remove_stage(
          partial_stage,
          owner_path,
          owner,
          partial_marker,
          partial.sha256
        )

      ^changed = File.read!(partial_path)
      ^owner = File.read!(owner_path)

      phase(:cleanup)

      :ok =
        LinuxInstallFiles.write(partial_path, 0o600, prefix, LinuxInstallFiles.digest(changed))

      :ok =
        LinuxInstallFiles.remove_stage(
          partial_stage,
          owner_path,
          owner,
          partial_marker,
          partial.sha256
        )

      false = File.exists?(partial_stage)
      ^owner = File.read!(owner_path)
      {:ok, _} = ReleaseInventory.verify(source)
      {:ok, _} = ReleaseInventory.verify(destination)
      {:ok, ^manifest} = ReleaseBootstrap.render(destination)

      phase(:bridge)
      bridge_fixture(Path.dirname(source))

      IO.puts(
        "packaged full-release staging, publication, sync, source-prefix cleanup, changed-byte preservation and closed maintenance bridge guards passed (#{map_size(declared.files)} payload files); no service or Store was changed"
      )
    rescue
      error in File.Error ->
        fail(error.reason)

      error in MatchError ->
        case error.term do
          {:error, reason} when is_atom(reason) -> fail(reason)
          _ -> fail(:unexpected)
        end

      _ ->
        fail(:unexpected)
    catch
      _, _ -> fail(:unexpected)
    end
  end

  defp bridge_fixture(parent) do
    phase(:bridge_directory)
    directory = parent <> "/bridge"
    :ok = LinuxInstallFiles.mkdir(directory, 0o700, 211, 211)
    phase(:bridge_listener)
    path = directory <> "/trap.sock"

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    phase(:bridge_mode)
    File.chmod!(path, 0o600)
    phase(:bridge_owner)
    File.chown!(path, 211)

    try do
      # In-memory synthetic fixture only; never logged or sent to a controller.
      credential = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)
      common = %{"api_version" => 1, "credential" => credential}

      requests = [
        Map.put(common, "operation", "maintenance_status"),
        Map.put(common, "operation", "maintenance_update_status"),
        Map.merge(common, %{
          "operation" => "maintenance_operation_status",
          "authority_epoch" => 9_223_372_036_854_775_807,
          "operation_id" => "fixture:original"
        }),
        Map.merge(common, %{
          "operation" => "begin_maintenance",
          "authority_epoch" => 1,
          "operation_id" => "fixture:original",
          "expected_revision" => 9_223_372_036_854_775_807
        })
      ]

      normal = JSON.encode!(hd(requests))

      invalid = [
        String.replace(normal, "\"api_version\":1", "\"api_version\":\"1\""),
        String.replace(normal, "{", "{\"api_version\":1,"),
        normal <> "{}",
        JSON.encode!(Map.put(List.last(requests), "expected_revision", "1"))
      ]

      phase(:bridge_malformed)

      for body <- invalid do
        {:error, _} =
          LinuxInstallFiles.maintenance(211, path, <<byte_size(body)::32, body::binary>>)

        {:error, :timeout} = :gen_tcp.accept(listener, 20)
      end

      phase(:bridge_kinds)

      for request <- requests do
        {:ok, frame} = WotexHome.LocalAPI.Frame.encode_request(request)
        {:error, _} = LinuxInstallFiles.maintenance(211, path, frame)
        # The root listening peer refuses before any bearer transmission.
        {:ok, peer} = :gen_tcp.accept(listener, 1000)
        {:error, :closed} = :gen_tcp.recv(peer, 1, 1000)
        :gen_tcp.close(peer)
      end
    after
      :gen_tcp.close(listener)
    end
  end

  defp stage(admin, letter) do
    path = admin <> "/update-stage-" <> String.duplicate(letter, 64)
    marker = "{\"scope\":\"private_packaged_stage_probe\",\"nonce\":\"#{letter}\"}\n"
    :ok = LinuxInstallFiles.mkdir(path, 0o700, 0, 0)
    :ok = LinuxInstallFiles.write(path <> "/stage.json", 0o600, marker)
    {path, marker}
  end

  defp phase(value), do: Process.put(:packaged_stage_probe_phase, value)

  defp fail(reason) do
    code =
      if reason in ~w(eacces eperm eaddrinuse eaddrnotavail timeout closed enotsup einval)a,
        do: reason,
        else: :unexpected

    IO.puts(
      "packaged update staging failed at #{Process.get(:packaged_stage_probe_phase)}: #{code}"
    )

    System.halt(1)
  end
end

PackagedLinuxStageProbe.run()
