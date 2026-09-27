defmodule WotexHome.SupportExportTest do
  @moduledoc false

  use ExUnit.Case
  import Bitwise

  alias WotexHome.Durable.{Store, SupportExport}
  alias WotexHome.Semantics.Thing

  setup do
    root =
      Path.join(System.tmp_dir!(), "wotex-home-support-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = Store.start_link(path: Path.join(root, "home.sqlite"))
    {:ok, root: root, store: store}
  end

  test "explicit support preview and file exclude identity and secret canaries", %{
    root: root,
    store: store
  } do
    private_id = "light:private-kitchen-canary"
    profile_ref = "profile:private-canary"

    assert {:ok, thing} =
             Thing.new(%{
               "id" => private_id,
               "role" => "Light",
               "profile_ref" => profile_ref,
               "capabilities" => [
                 %{
                   "thing_id" => private_id,
                   "role" => "Light",
                   "key" => "power",
                   "value_kind" => "boolean",
                   "unit" => "none",
                   "operations" => ["read", "write"],
                   "risk_class" => "ordinary",
                   "profile_ref" => profile_ref,
                   "evidence_ref" => "fixture:private-canary",
                   "freshness_ms" => 5_000,
                   "constraints" => %{},
                   "extensions" => %{}
                 }
               ]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:private-canary", ["read"], [private_id])

    assert {:ok, preview} = SupportExport.preview(store, credential)
    assert SupportExport.valid_summary?(preview)
    refute SupportExport.valid_summary?(Map.put(preview, "credential", "secret"))
    refute SupportExport.valid_summary?(put_in(preview, ["health", "thing_id"], private_id))
    assert preview["schema"] == "wotex-home.support.v2"
    assert preview["health"]["active_things"] == 1

    assert Map.take(preview["health"], [
             "rule_generation",
             "held_requests",
             "queued_requests",
             "claimed_requests",
             "unknown_outcomes",
             "retained_receipts",
             "receipt_capacity"
           ]) == %{
             "rule_generation" => 0,
             "held_requests" => 0,
             "queued_requests" => 0,
             "claimed_requests" => 0,
             "unknown_outcomes" => 0,
             "retained_receipts" => 0,
             "receipt_capacity" => 65_536
           }

    assert {:error, :unauthorized} = SupportExport.preview(store, :binary.copy(<<0>>, 32))

    path = Path.join(root, "support.json")
    assert {:ok, bytes} = SupportExport.write(store, credential, path)
    assert bytes <= 4_096
    assert {:ok, saved} = File.read(path)
    assert JSON.decode!(saved) == preview
    refute String.contains?(saved, [private_id, profile_ref, "private-canary"])
    refute String.contains?(saved, Base.url_encode64(credential, padding: false))
    assert {:ok, stat} = File.stat(path)
    assert (stat.mode &&& 0o777) == 0o600
    assert {:error, :support_exists} = SupportExport.write(store, credential, path)

    assert {:error, :support_unavailable} =
             SupportExport.write_preview(
               Map.put(preview, "credential", "secret"),
               Path.join(root, "bad.json")
             )

    assert {:error, :invalid_support_destination} =
             SupportExport.write(store, credential, "relative.json")

    :ok = GenServer.stop(store)
  end
end
