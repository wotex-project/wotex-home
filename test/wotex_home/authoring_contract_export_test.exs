defmodule WotexHome.AuthoringContractExportTest do
  @moduledoc false

  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Exchange, Server}
  alias WotexHome.Profiles.{AuthoringContract, ProducerIdentity}

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  setup do
    root =
      Path.join(System.tmp_dir!(), "authoring-contract-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp contract(family) do
    v = fixture(family)
    {:ok, producer} = ProducerIdentity.current()

    installed =
      Map.take(v, ~w(bindings contracts home_contracts)) |> Map.put("producer", producer)

    {:ok, contract} =
      AuthoringContract.export(installed, fixture("authoring-mechanics")[family]["limits"])

    contract
  end

  test "actual exports match two independent grammar vectors and consume no Store revision", %{
    root: root
  } do
    for family <- ~w(temperature research) do
      selected = contract(family)

      {:ok, store} =
        Store.start_link(path: Path.join(root, family <> ".sqlite"), authoring_contract: selected)

      try do
        {:ok, manager, 1} =
          Store.provision_principal(store, "author:#{family}", ["profile:manage"], [])

        authority = Authority.new(store: store)
        assert {:ok, exported} = Authority.authoring_contract_export(authority, manager)

        assert Enum.sort(Map.keys(exported)) ==
                 ~w(authority_epoch contract_base64 format principal_id store_revision summary)

        assert exported["principal_id"] == "author:#{family}"
        assert exported["authority_epoch"] == 1 and exported["store_revision"] == 1
        assert exported["format"] == "wotex-home.authoring-contract-export@1"
        assert {:ok, bytes} = Base.url_decode64(exported["contract_base64"], padding: false)
        assert bytes == selected.bytes
        assert Base.url_encode64(bytes, padding: false) == exported["contract_base64"]
        vector = fixture("authoring-mechanics")[family]
        assert exported["summary"]["contract_sha256"] == vector["contract_sha256"]
        assert exported["summary"]["contract_raw_sha256"] == vector["contract_raw_sha256"]
        assert {:ok, summary} = AuthoringContract.to_map(selected)
        assert summary == exported["summary"]
        assert {:ok, ^exported} = Authority.authoring_contract_export(authority, manager)
        assert {:ok, 1} = Store.revision(store)
      after
        GenServer.stop(store)
      end
    end
  end

  test "permission precedes missing installation and malformed native configuration is refused",
       %{root: root} do
    store = start_supervised!({Store, path: Path.join(root, "absent.sqlite")})
    {:ok, reader, 1} = Store.provision_principal(store, "reader:1", ["read"], [])
    {:ok, manager, 2} = Store.provision_principal(store, "author:1", ["profile:manage"], [])
    assert {:error, :permission_denied} = Store.authoring_contract_export(store, reader)
    assert {:error, :authoring_unavailable} = Store.authoring_contract_export(store, manager)
    assert {:error, :invalid_credential} = Store.authoring_contract_export(store, "short")
    assert {:ok, 2} = Store.revision(store)
    assert {:ok, 3} = Store.revoke_principal(store, "author:1")
    assert {:error, :unauthorized} = Store.authoring_contract_export(store, manager)
  end

  test "forged contract bytes and changed runtime assertions cannot become an export", %{
    root: root
  } do
    original = contract("temperature")

    for {changed, reason, name} <- [
          {%{original | bytes: original.bytes <> " "}, :invalid_authoring_contract, "bytes"},
          {put_in(
             original.inputs["installed"]["producer"]["core_runtime_sha256"],
             String.duplicate("0", 64)
           ), :stale_profile_runtime, "runtime"}
        ] do
      {:ok, store} =
        Store.start_link(path: Path.join(root, name <> ".sqlite"), authoring_contract: changed)

      try do
        {:ok, manager, 1} =
          Store.provision_principal(store, "author:forged", ["profile:manage"], [])

        assert {:error, ^reason} = Store.authoring_contract_export(store, manager)
        assert {:ok, 1} = Store.revision(store)
      after
        GenServer.stop(store)
      end
    end
  end

  @tag requires_socket: true
  test "socket and CLI preserve exact public bytes and read transport failure", %{root: root} do
    selected = contract("research")

    store =
      start_supervised!(
        {Store, path: Path.join(root, "wire.sqlite"), authoring_contract: selected}
      )

    {:ok, manager, 1} = Store.provision_principal(store, "author:wire", ["profile:manage"], [])
    authority = Authority.new(store: store)
    socket = Path.join(root, "home.sock")
    start_supervised!({Server, authority: authority, socket_path: socket})
    encoded = Base.url_encode64(manager, padding: false)

    request = %{
      "api_version" => 1,
      "operation" => "authoring_contract_export",
      "credential" => encoded
    }

    assert {:ok, exported} = Authority.authoring_contract_export(authority, manager)

    assert {:ok, %{"outcome" => "ok", "authoring_contract" => ^exported}} =
             Client.request(socket, request)

    credential_file = Path.join(root, "credential")
    File.write!(credential_file, encoded)
    File.chmod!(credential_file, 0o600)

    output =
      capture_io(fn ->
        assert 0 ==
                 CLI.main([
                   "--socket",
                   socket,
                   "--credential-file",
                   credential_file,
                   "authoring-contract"
                 ])
      end)

    assert JSON.decode!(output)["authoring_contract"] == exported
    assert {:error, :usage} = CLI.build_request(["authoring-contract", "extra"], encoded)

    for {bad, reason} <- [
          {Map.put(request, "extra", true), "unsupported_operation_or_fields"},
          {Map.put(request, "api_version", 2), "unsupported_api_version"}
        ] do
      assert {:ok, %{"outcome" => "error", "reason" => ^reason}} =
               Client.request(socket, bad)
    end

    response = Exchange.perform(authority, request, System.monotonic_time(:millisecond) - 1)
    assert response["reason"] == "request_timeout"
    assert {:ok, 1} = Store.revision(store)
  end

  test "maintenance permits the inert read without reserving its returned revision", %{root: root} do
    store =
      start_supervised!(
        {Store,
         path: Path.join(root, "maintenance.sqlite"), authoring_contract: contract("temperature")}
      )

    {:ok, manager, 1} =
      Store.provision_principal(store, "author:maintain", ["profile:manage", "host:maintain"], [])

    assert {:ok, before} = Store.authoring_contract_export(store, manager)
    assert {:ok, _} = Store.begin_maintenance(store, manager, 1, "maint:export", 1)
    assert {:ok, after_export} = Store.authoring_contract_export(store, manager)
    assert after_export["store_revision"] == 3
    assert after_export["summary"] == before["summary"]
    assert after_export["contract_base64"] == before["contract_base64"]
    assert {:ok, 3} = Store.revision(store)
  end
end
