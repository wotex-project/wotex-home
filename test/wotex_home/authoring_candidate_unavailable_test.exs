defmodule WotexHome.AuthoringCandidateUnavailableTest do
  use ExUnit.Case
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.{AuthoringObject, Custody}

  test "the default Store retains imports but cannot assess without an explicitly selected producer contract" do
    directory =
      Path.join(System.tmp_dir!(), "authoring-default-#{System.unique_integer([:positive])}")

    directory =
      if String.starts_with?(directory, "/var/"), do: "/private" <> directory, else: directory

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    root = Path.join(directory, "profiles")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    owner = __MODULE__.Store
    custody = start_supervised!({Custody, root: root, store_owner: owner})

    store =
      start_supervised!(
        {Store, path: Path.join(directory, "home.sqlite"), profile_custody: custody, name: owner}
      )

    {:ok, credential, 1} = Store.provision_principal(store, "author:1", ["profile:manage"], [])
    {:ok, object} = AuthoringObject.new("draft", "{")
    {:ok, summary} = AuthoringObject.summary(object)

    assert {:ok, _} =
             Store.import_authoring_object(
               store,
               credential,
               %{
                 "authority_epoch" => 1,
                 "operation_id" => "import:1",
                 "expected_revision" => 1,
                 "object" => summary
               },
               "{"
             )

    input =
      JSON.decode!(File.read!("test/fixtures/profiles/authoring-candidate.json"))["input"]
      |> Map.put("expected_revision", 2)
      |> put_in(["request", "base_draft_ref"], %{
        "object_digest" => summary["object_digest"],
        "first_revision" => 2
      })

    assert {:error, :authoring_unavailable} =
             Store.assess_authoring_candidate(store, credential, input)

    assert :not_found = Store.authoring_candidate_status(store, credential, 1, "candidate:1")
    assert {:ok, 2} = Store.revision(store)
    assert {:ok, %{object_count: 1, lease_count: 0}} = Custody.inventory(custody)
  end
end
