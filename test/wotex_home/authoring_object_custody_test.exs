defmodule WotexHome.Profiles.AuthoringObjectCustodyTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{AuthoringObject, Custody}

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("home-authoring-custody-#{System.unique_integer([:positive])}")
      |> Path.expand()

    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      profile: File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))
    }
  end

  test "shared byte/object quotas include both kinds and duplicates allocate nothing", c do
    server = start_supervised!({Custody, root: c.root, max_objects: 2, store_owner: self()})
    assert {:ok, profile} = Custody.stage(server, c.profile)
    assert {:ok, object} = Custody.stage_object(server, "draft", String.duplicate("x", 40_000))
    assert {:ok, ^object} = Custody.stage_object(server, "draft", String.duplicate("x", 40_000))
    assert {:error, :profile_custody_capacity} = Custody.stage_object(server, "source", "another")
    assert {:ok, %{object_count: 2, total_bytes: bytes}} = Custody.inventory(server)
    assert bytes == byte_size(c.profile) + 40_042
    assert {:error, :profile_artifact_unavailable} = Custody.read(server, object)
    assert {:error, :authoring_object_unavailable} = Custody.read_object(server, profile)
    assert {:ok, %{payload: payload}} = Custody.read_object(server, object)
    assert payload == String.duplicate("x", 40_000)
    stop_supervised(Custody)
    server = start_supervised!({Custody, root: c.root, max_objects: 2, store_owner: self()})
    assert {:ok, %{payload: ^payload}} = Custody.read_object(server, object)
    assert {:ok, _} = Custody.read(server, profile)
  end

  test "header bytes count toward capacity and no partial file survives refusal", c do
    server = start_supervised!({Custody, root: c.root, max_bytes: 44})
    assert {:ok, _} = Custody.stage_object(server, "source", "ab")
    assert {:error, :profile_custody_capacity} = Custody.stage_object(server, "source", "a")
    assert {:ok, %{object_count: 1, total_bytes: 44}} = Custody.inventory(server)
    assert {:error, :invalid_authoring_object} = Custody.stage_object(server, "draft", "")
    assert length(File.ls!(c.root)) == 1
  end

  test "leases from both APIs share capacity and protect objects from Store-only collection", c do
    server = start_supervised!({Custody, root: c.root, max_leases: 1, store_owner: self()})
    {:ok, profile} = Custody.stage(server, c.profile)
    {:ok, digest} = Custody.stage_object(server, "source", "original")
    assert {:ok, %{token: token, object: object}} = Custody.lease_object(server, digest)
    assert {:error, :profile_lease_capacity} = Custody.lease(server, profile)
    assert {:ok, %{removed_objects: 1}} = Custody.collect(server, [])
    assert {:ok, ^object} = Custody.read_object(server, digest)

    assert {:error, :invalid_profile_lease} =
             Task.async(fn -> Custody.release(server, token) end) |> Task.await()

    assert :ok = Custody.release(server, token)
    assert {:ok, %{removed_objects: 1}} = Custody.collect(server, [])
    assert {:error, :authoring_object_unavailable} = Custody.read_object(server, digest)
  end

  test "only configured Store exports an exact complete verified set", c do
    server = start_supervised!({Custody, root: c.root, store_owner: self()})
    {:ok, digest} = Custody.stage_object(server, "source", "private source")
    {:ok, object} = Custody.read_object(server, digest)
    {:ok, summary} = AuthoringObject.summary(object)

    assert {:error, :invalid_profile_export} =
             Task.async(fn -> Custody.export_objects(server, [summary]) end) |> Task.await()

    assert {:ok, [exported]} = Custody.export_objects(server, [summary])
    assert Map.delete(exported, "bytes") == summary
    assert exported["bytes"] == object.bytes
    assert {:error, :invalid_profile_export} = Custody.export_objects(server, [summary, summary])
    assert {:error, :invalid_profile_export} = Custody.export_objects(server, [summary | :bad])

    assert {:error, :authoring_object_unavailable} =
             Custody.export_objects(server, [Map.put(summary, "kind", "draft")])

    assert {:error, :invalid_profile_export} = Custody.export_many(server, [summary])
  end

  test "corrupt bytes and unsafe descriptor state cannot be read or collected", c do
    server = start_supervised!({Custody, root: c.root, store_owner: self()})
    {:ok, digest} = Custody.stage_object(server, "source", "original")
    path = Path.join(c.root, digest <> ".json")
    File.chmod!(path, 0o600)
    File.write!(path, "corrupt")
    File.chmod!(path, 0o400)
    assert {:error, :authoring_object_unavailable} = Custody.read_object(server, digest)
    assert {:error, :invalid_profile_custody} = Custody.collect(server, [])
    assert File.exists?(path)
  end

  test "a linked publication orphan restarts with its exact complete object", c do
    server = start_supervised!({Custody, root: c.root})
    {:ok, digest} = Custody.stage_object(server, "draft", String.duplicate("x", 40_000))
    stage = Path.join(c.root, ".stage-" <> String.duplicate("a", 32))
    File.ln!(Path.join(c.root, digest <> ".json"), stage)
    stop_supervised(Custody)
    server = start_supervised!({Custody, root: c.root})
    assert {:ok, %{payload: payload}} = Custody.read_object(server, digest)
    assert byte_size(payload) == 40_000
    refute File.exists?(stage)
    assert {:ok, %{object_count: 1}} = Custody.inventory(server)
  end
end
