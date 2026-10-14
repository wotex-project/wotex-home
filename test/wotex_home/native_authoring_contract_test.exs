defmodule WotexHome.NativeAuthoringContractTest do
  use ExUnit.Case, async: false
  @moduletag skip: :os.type() != {:unix, :darwin}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Server
  alias WotexHome.Profiles.{AuthoringContract, ProducerIdentity}

  @tag requires_socket: true
  test "fresh Swift client matches two actual Store exports without changing revision" do
    root =
      Path.join(System.tmp_dir!(), "native-contract-live-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    executable = Path.join(root, "client")

    assert :ok =
             Woh.Tool.NativeFixture.compile(
               File.cwd!(),
               "NativeAuthoringContractLiveSmoke.swift",
               executable,
               ["NativeAuthoringReadClient"]
             )

    fixture = fn name -> JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json")) end

    for family <- ~w(temperature research) do
      v = fixture.(family)
      {:ok, producer} = ProducerIdentity.current()

      installed =
        Map.take(v, ~w(bindings contracts home_contracts)) |> Map.put("producer", producer)

      {:ok, contract} =
        AuthoringContract.export(installed, fixture.("authoring-mechanics")[family]["limits"])

      {:ok, store} =
        Store.start_link(path: Path.join(root, family <> ".sqlite"), authoring_contract: contract)

      try do
        {:ok, credential, 1} =
          Store.provision_principal(store, "author:#{family}", ["profile:manage"], [])

        {:ok, expected} = Store.authoring_contract_export(store, credential)
        socket = Path.join(root, family <> ".sock")

        {:ok, server} =
          Server.start_link(authority: WotexHome.Authority.new(store: store), socket_path: socket)

        try do
          credential_file = Path.join(root, family <> ".credential")
          expected_file = Path.join(root, family <> ".json")
          File.write!(credential_file, Base.url_encode64(credential, padding: false))
          File.write!(expected_file, JSON.encode!(expected))
          File.chmod!(credential_file, 0o600)
          File.chmod!(expected_file, 0o600)

          {output, status} =
            System.cmd(executable, [socket, credential_file, expected_file],
              stderr_to_stdout: true
            )

          assert status == 0, output
          assert {:ok, 1} = Store.revision(store)
        after
          GenServer.stop(server)
        end
      after
        GenServer.stop(store)
      end
    end
  end
end
