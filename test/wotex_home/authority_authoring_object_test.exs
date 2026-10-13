defmodule WotexHome.AuthorityAuthoringObjectTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.Custody

  test "current authenticated profile management is required and inert staging does not change Store state" do
    root =
      System.tmp_dir!()
      |> Path.join("home-authoring-authority-#{System.unique_integer([:positive])}")
      |> Path.expand()

    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root})

    store =
      start_supervised!({Store, path: Path.join(root, "home.sqlite"), profile_custody: custody})

    {:ok, manager, 1} = Store.provision_principal(store, "author:1", ["profile:manage"], [])
    {:ok, reader, 2} = Store.provision_principal(store, "reader:1", ["read"], [])
    authority = Authority.new(store: store, profile_custody: custody)

    assert {:error, :permission_denied} =
             Authority.stage_authoring_object(authority, reader, "source", "original")

    assert {:error, :invalid_credential} =
             Authority.stage_authoring_object(authority, "invalid", "source", "original")

    assert {:ok, %{object_count: 0}} = Custody.inventory(custody)

    assert {:ok, summary} =
             Authority.stage_authoring_object(authority, manager, "source", "private source")

    assert Map.keys(summary) |> Enum.sort() == ~w(kind object_digest payload_bytes payload_sha256)
    refute inspect(summary) =~ "private source"

    assert {:ok, ^summary} =
             Authority.stage_authoring_object(authority, manager, "source", "private source")

    assert {:ok, 2} = Store.revision(store)
    assert {:ok, 3} = Store.revoke_principal(store, "author:1")

    assert {:error, :unauthorized} =
             Authority.stage_authoring_object(authority, manager, "source", "other")

    assert {:ok, %{object_count: 1}} = Custody.inventory(custody)
    assert {:ok, 3} = Store.revision(store)
  end
end
