defmodule WotexHome.PortableProfileCustodyTest do
  use ExUnit.Case, async: true

  alias WotexHome.Profiles.{Artifact, Custody}

  setup do
    temporary = System.tmp_dir!() |> String.trim_trailing("/")

    temporary =
      if String.starts_with?(temporary, "/var/"), do: "/private" <> temporary, else: temporary

    root = Path.join(temporary, "woh-profile-custody-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    bytes = File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(root <> "-moved")
    end)

    %{root: root, bytes: bytes}
  end

  test "immutable synchronized publication, retry and restart preserve exact bytes", context do
    server = start_supervised!({Custody, root: context.root})
    assert {:ok, digest} = Custody.stage(server, context.bytes)
    assert {:ok, ^digest} = Custody.stage(server, context.bytes)
    assert {:ok, %{bytes: bytes}} = Custody.read(server, digest)
    assert bytes == context.bytes

    assert {:ok, %{object_count: 1, total_bytes: size, digests: [^digest]}} =
             Custody.inventory(server)

    assert size == byte_size(bytes)
    assert File.ls!(context.root) == [digest <> ".json"]

    assert Bitwise.band(File.stat!(Path.join(context.root, digest <> ".json")).mode, 0o777) ==
             0o400

    stop_supervised(Custody)
    server = start_supervised!({Custody, root: context.root})
    assert {:ok, %{bytes: ^bytes}} = Custody.read(server, digest)
  end

  test "bounded verification returns only exact readable commitments", c do
    server = start_supervised!({Custody, root: c.root})
    {:ok, raw} = Custody.stage(server, c.bytes)
    {:ok, artifact} = Custody.read(server, raw)
    pin = [raw, artifact.projection_digest, hd(artifact.data["dependencies"])["sha256"]]
    absent = [String.duplicate("a", 64), artifact.projection_digest, List.last(pin)]
    wrong = [raw, String.duplicate("b", 64), List.last(pin)]
    assert {:ok, [^pin]} = Custody.verify_many(server, [pin, absent, wrong])
    assert {:error, :invalid_profile_verification} = Custody.verify_many(server, [pin, pin])

    assert {:error, :invalid_profile_verification} =
             Custody.verify_many(server, List.duplicate(pin, 65))

    assert {:error, :invalid_profile_verification} = Custody.verify_many(server, [[raw]])
    assert {:ok, %{lease_count: 0}} = Custody.inventory(server)
    File.rm!(Path.join(c.root, raw <> ".json"))
    assert {:ok, []} = Custody.verify_many(server, [pin])
  end

  test "same-label different-byte staging retains two inert identities", context do
    server = start_supervised!({Custody, root: context.root})
    assert {:ok, first} = Custody.stage(server, context.bytes)
    assert {:ok, second} = Custody.stage(server, " " <> context.bytes)
    refute first == second
    assert {:ok, %{object_count: 2}} = Custody.inventory(server)
    assert {:ok, original} = Custody.read(server, first)
    assert {:ok, successor} = Custody.read(server, second)
    assert original.profile_ref == successor.profile_ref
  end

  test "tampered, missing, symlinked and multiply linked bytes fail without replacement",
       context do
    server = start_supervised!({Custody, root: context.root})
    {:ok, digest} = Custody.stage(server, context.bytes)
    path = Path.join(context.root, digest <> ".json")
    File.chmod!(path, 0o600)
    File.write!(path, " " <> context.bytes)
    File.chmod!(path, 0o400)
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, digest)
    assert {:error, :profile_publication_failed} = Custody.stage(server, context.bytes)
    assert File.read!(path) == " " <> context.bytes

    File.rm!(path)
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, digest)
    File.ln_s!("missing", path)
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, digest)
    File.rm!(path)
    {:ok, ^digest} = Custody.stage(server, context.bytes)
    File.ln!(path, Path.join(context.root, "extra"))
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, digest)
  end

  test "object and byte quotas are finite and exact retries work at capacity", context do
    server =
      start_supervised!(
        {Custody, root: context.root, max_objects: 1, max_bytes: byte_size(context.bytes)}
      )

    {:ok, digest} = Custody.stage(server, context.bytes)
    assert {:ok, ^digest} = Custody.stage(server, context.bytes)
    assert {:error, :profile_custody_capacity} = Custody.stage(server, " " <> context.bytes)
    assert {:ok, %{object_count: 1}} = Custody.inventory(server)
  end

  test "concurrent publishers share one bounded serial capacity", context do
    server = start_supervised!({Custody, root: context.root, max_objects: 2})

    tasks =
      for n <- 1..8,
          do:
            Task.async(fn -> Custody.stage(server, String.duplicate(" ", n) <> context.bytes) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
    assert Enum.count(results, &(&1 == {:error, :profile_custody_capacity})) == 6
    assert {:ok, %{object_count: 2}} = Custody.inventory(server)
  end

  test "leases are scoped, bounded and released on caller death", context do
    server = start_supervised!({Custody, root: context.root, max_leases: 1})
    {:ok, digest} = Custody.stage(server, context.bytes)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = Custody.lease(server, digest)
        send(parent, {:leased, lease.token})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:leased, token}
    assert {:error, :invalid_profile_lease} = Custody.release(server, token)
    assert {:error, :profile_lease_capacity} = Custody.lease(server, digest)
    monitor = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    # A call from the custody owner provides a deterministic mailbox barrier.
    :sys.get_state(server)
    assert {:ok, lease} = Custody.lease(server, digest)
    assert lease.artifact.digest == digest
    assert :ok = Custody.release(server, lease.token)
    assert {:error, :invalid_profile_lease} = Custody.release(server, lease.token)
  end

  test "root substitution and changed permissions block access", context do
    server = start_supervised!({Custody, root: context.root})
    {:ok, digest} = Custody.stage(server, context.bytes)
    File.rename!(context.root, context.root <> "-moved")
    File.ln_s!(context.root <> "-moved", context.root)
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, digest)
    assert {:error, :invalid_profile_custody} = Custody.stage(server, context.bytes)
  end

  test "crash orphan consumes quota but cannot become an active artifact", context do
    orphan = Path.join(context.root, ".stage-" <> String.duplicate("0", 32))
    File.write!(orphan, context.bytes)
    File.chmod!(orphan, 0o400)
    server = start_supervised!({Custody, root: context.root, max_objects: 1})
    assert {:ok, %{object_count: 1, digests: []}} = Custody.inventory(server)
    assert {:error, :profile_custody_capacity} = Custody.stage(server, context.bytes)

    assert {:error, :profile_artifact_unavailable} =
             Custody.read(server, Artifact.digest(context.bytes))
  end

  test "invalid bytes and traversal never publish a file", context do
    server = start_supervised!({Custody, root: context.root})
    assert {:error, :invalid_profile_data} = Custody.stage(server, "(component)")
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, "../outside")
    assert File.ls!(context.root) == []
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, nil)
  end

  test "restart completes only a verified publication alias", context do
    digest = Artifact.digest(context.bytes)
    stage = Path.join(context.root, ".stage-" <> String.duplicate("1", 32))
    destination = Path.join(context.root, digest <> ".json")
    File.write!(stage, context.bytes)
    File.chmod!(stage, 0o400)
    File.ln!(stage, destination)
    server = start_supervised!({Custody, root: context.root, max_objects: 1})
    assert {:ok, %{object_count: 1, digests: [^digest]}} = Custody.inventory(server)
    assert {:ok, %{bytes: bytes}} = Custody.read(server, digest)
    assert bytes == context.bytes
    refute File.exists?(stage)
  end

  test "an empty interrupted stage is inert and counted", context do
    stage = Path.join(context.root, ".stage-" <> String.duplicate("2", 32))
    File.write!(stage, "")
    server = start_supervised!({Custody, root: context.root, max_objects: 1})
    assert {:ok, %{object_count: 1, total_bytes: 0, digests: []}} = Custody.inventory(server)
    assert {:error, :profile_custody_capacity} = Custody.stage(server, context.bytes)
  end

  test "unsafe roots, ancestor links and duplicate custody owners fail", context do
    server = start_supervised!({Custody, root: context.root})
    assert {:error, _} = start_supervised({Custody, root: context.root}, id: :duplicate)
    assert Process.alive?(server)
    stop_supervised(Custody)
    File.chmod!(context.root, 0o755)
    assert {:error, _} = start_supervised({Custody, root: context.root})
    File.chmod!(context.root, 0o700)
    alias_path = context.root <> "-moved"
    File.ln_s!(context.root, alias_path)
    assert {:error, _} = start_supervised({Custody, root: alias_path})
  end

  test "collection accepts retained snapshots only from the configured Store owner", context do
    server = start_supervised!({Custody, root: context.root})
    {:ok, digest} = Custody.stage(server, context.bytes)
    assert {:error, :invalid_profile_collection} = Custody.collect(server, [])
    assert {:ok, _} = Custody.read(server, digest)
    stop_supervised(Custody)
    server = start_supervised!({Custody, root: context.root, store_owner: self()})

    assert {:error, :invalid_profile_collection} =
             Task.async(fn -> Custody.collect(server, []) end) |> Task.await()

    assert {:ok, _} = Custody.read(server, digest)
    assert {:ok, %{removed_objects: 1, object_count: 0}} = Custody.collect(server, [])
  end

  test "retained history and monitored leases protect exact bytes", context do
    server = start_supervised!({Custody, root: context.root, store_owner: self()})
    {:ok, retained} = Custody.stage(server, context.bytes)
    {:ok, leased} = Custody.stage(server, " " <> context.bytes)
    {:ok, inert} = Custody.stage(server, "  " <> context.bytes)
    {:ok, lease} = Custody.lease(server, leased)

    assert {:ok, %{removed_objects: 1, object_count: 2, digests: digests}} =
             Custody.collect(server, [retained])

    assert digests == Enum.sort([retained, leased])
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, inert)
    assert :ok = Custody.release(server, lease.token)

    assert {:ok, %{removed_objects: 1, digests: [^retained]}} =
             Custody.collect(server, [retained])

    assert {:ok, %{removed_objects: 0, digests: [^retained]}} =
             Custody.collect(server, [retained])
  end

  test "collection frees verified inert publication and incomplete crash stages at quota",
       context do
    first = Path.join(context.root, ".stage-" <> String.duplicate("3", 32))
    second = Path.join(context.root, ".stage-" <> String.duplicate("4", 32))
    File.write!(first, "")
    File.write!(second, "incomplete")
    server = start_supervised!({Custody, root: context.root, store_owner: self(), max_objects: 2})
    assert {:error, :profile_custody_capacity} = Custody.stage(server, context.bytes)

    assert {:ok, %{removed_objects: 2, removed_bytes: 10, object_count: 0}} =
             Custody.collect(server, [])

    assert {:ok, digest} = Custody.stage(server, context.bytes)
    stop_supervised(Custody)
    server = start_supervised!({Custody, root: context.root, store_owner: self()})
    assert {:ok, %{removed_objects: 0, digests: [^digest]}} = Custody.collect(server, [digest])
  end

  test "preflight rejects modified bytes before removing any other inert object", context do
    server = start_supervised!({Custody, root: context.root, store_owner: self()})
    {:ok, first} = Custody.stage(server, context.bytes)
    {:ok, second} = Custody.stage(server, " " <> context.bytes)
    file = Path.join(context.root, second <> ".json")
    File.chmod!(file, 0o600)
    File.write!(file, context.bytes <> " ")
    File.chmod!(file, 0o400)
    assert {:error, :invalid_profile_custody} = Custody.collect(server, [])
    assert {:ok, _} = Custody.read(server, first)
    assert File.exists?(file)
  end

  test "root substitution and invalid retained sets cannot delete objects", context do
    server = start_supervised!({Custody, root: context.root, store_owner: self()})
    {:ok, digest} = Custody.stage(server, context.bytes)

    for invalid <- [[digest, digest], ["../outside"], List.duplicate(digest, 65), :all] do
      assert {:error, :invalid_profile_collection} = Custody.collect(server, invalid)
      assert {:ok, _} = Custody.read(server, digest)
    end

    File.rename!(context.root, context.root <> "-moved")
    File.ln_s!(context.root <> "-moved", context.root)
    assert {:error, :invalid_profile_custody} = Custody.collect(server, [])
    assert File.exists?(Path.join(context.root <> "-moved", digest <> ".json"))
  end

  test "inert historical bytes can be collected without installing their old registry", context do
    data = JSON.decode!(context.bytes)
    dependency = %{"kind" => "registry", "sha256" => String.duplicate("0", 64)}
    bytes = JSON.encode!(Map.put(data, "dependencies", [dependency]))
    digest = Artifact.digest(bytes)
    File.write!(Path.join(context.root, digest <> ".json"), bytes)
    File.chmod!(Path.join(context.root, digest <> ".json"), 0o400)
    server = start_supervised!({Custody, root: context.root, store_owner: self()})
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, digest)
    assert {:ok, %{removed_objects: 0}} = Custody.collect(server, [digest])
    assert {:ok, %{removed_objects: 1, removed_bytes: size}} = Custody.collect(server, [])
    assert size == byte_size(bytes)
  end
end
