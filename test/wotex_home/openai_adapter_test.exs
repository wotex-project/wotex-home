Code.require_file("../support/controller_tls_fixture.exs", __DIR__)

defmodule WotexHome.OpenAIAdapterTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias WotexHome.{Authority, Host}
  alias WotexHome.Durable.Store
  alias WotexHome.Host.ProfileConfiguration

  alias WotexHome.Profiles.{
    AuthoringObject,
    GenerationPolicy,
    GenerationRunner,
    OpenAIAdapter,
    OpenAIEndpoint,
    OpenAIHTTPS
  }

  alias WotexHome.TestSupport.ControllerTLSFixture, as: PKI
  @moduletag requires_socket: true
  @key "sk-synthetic-fixture-key"

  setup_all do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "openai-pki-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Application.ensure_all_started(:ssl)
    %{pki: PKI.create(root, "api.openai.com")}
  end

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "openai-adapter-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    credential = Path.join(root, "model.key")
    File.write!(credential, @key <> "\n")
    File.chmod!(credential, 0o400)
    on_exit(fn -> File.rm_rf!(root) end)
    supervisor = start_supervised!({Task.Supervisor, []})
    %{root: root, credential: credential, peer_supervisor: supervisor}
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))
  defp vector(family \\ "temperature"), do: fixture("openai-generation")[family]

  defp peer(c, variant \\ "valid") do
    {:ok, listener} =
      :ssl.listen(0,
        ip: {127, 0, 0, 1},
        mode: :binary,
        active: false,
        reuseaddr: true,
        certfile: String.to_charlist(c.pki.certificates[variant]),
        keyfile: String.to_charlist(c.pki.key),
        versions: [:"tlsv1.3", :"tlsv1.2"],
        log_level: :none
      )

    {:ok, {_, port}} = :ssl.sockname(listener)
    parent = self()
    on_exit(fn -> :ssl.close(listener) end)

    {:ok, acceptor} =
      Task.Supervisor.start_child(c.peer_supervisor, fn ->
        accept(listener, c.peer_supervisor, parent)
      end)

    {:ok, endpoint} = OpenAIEndpoint.new({127, 0, 0, 1}, port, [c.pki.ca])
    %{endpoint: endpoint, listener: listener, acceptor: acceptor}
  end

  defp accept(listener, supervisor, parent) do
    case :ssl.transport_accept(listener, 5000) do
      {:ok, socket} ->
        {:ok, worker} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              {:socket, socket} -> serve(socket, parent)
            end
          end)

        :ok = :ssl.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept(listener, supervisor, parent)

      {:error, :timeout} ->
        accept(listener, supervisor, parent)

      _ ->
        :ok
    end
  end

  defp serve(socket, parent) do
    case :ssl.handshake(socket, 5000) do
      {:ok, ready} ->
        try do
          {:ok, headers, body} = read_request(ready, "")
          send(parent, {:peer_request, self(), headers, body})

          receive do
            {:respond, response} ->
              :ssl.send(ready, response)

            {:split, parts} ->
              Enum.each(parts, fn bytes ->
                :ssl.send(ready, bytes)
                Process.sleep(2)
              end)

            :drop ->
              :ok

            :watch_close ->
              send(parent, {:peer_closed, self(), :ssl.recv(ready, 0, 5000)})
          after
            5000 -> :ok
          end
        after
          :ssl.close(ready)
        end

      _ ->
        send(parent, {:no_application_bytes, self()})
        :ssl.close(socket)
    end
  end

  defp read_request(socket, bytes) do
    case :binary.match(bytes, "\r\n\r\n") do
      {offset, 4} ->
        <<headers::binary-size(offset), "\r\n\r\n", tail::binary>> = bytes
        [_, length] = Regex.run(~r/Content-Length: ([0-9]+)/, headers)
        remaining = String.to_integer(length) - byte_size(tail)
        rest = if remaining > 0, do: elem(:ssl.recv(socket, remaining, 5000), 1), else: ""
        {:ok, headers, tail <> rest}

      :nomatch ->
        with {:ok, part} <- :ssl.recv(socket, 0, 5000), do: read_request(socket, bytes <> part)
    end
  end

  defp response(body, framing \\ :length) do
    case framing do
      :length ->
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
          body

      :closed ->
        "HTTP/1.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\n\r\n" <>
          body

      :chunked ->
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" <>
          Integer.to_string(byte_size(body), 16) <>
          ";fixture=value\r\n" <> body <> "\r\n0\r\nX-Fixture: complete\r\n\r\n"
    end
  end

  defp adapter(c, endpoint, overrides \\ []) do
    {:ok, provider} = OpenAIAdapter.identity("generator:fixture", "model:fixture", endpoint)

    options =
      Keyword.merge(
        [
          provider: provider,
          endpoint: endpoint,
          credential_file: c.credential,
          max_output_tokens: 8192,
          timeout_ms: 3000,
          concurrency: 2
        ],
        overrides
      )

    pid = start_supervised!({OpenAIAdapter, options}, id: make_ref())
    {:ok, capability} = OpenAIAdapter.capability(pid)
    {pid, capability, options}
  end

  defp eventually(callback, attempts \\ 300)
  defp eventually(_, 0), do: flunk("bounded adapter transition did not complete")

  defp eventually(callback, attempts) do
    if callback.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(callback, attempts - 1)
        )
  end

  test "verified TLS framing returns exact API bytes without redirect, retry or key in the body",
       c do
    v = vector()

    for framing <- [:length, :chunked, :closed] do
      p = peer(c)
      task = Task.async(fn -> OpenAIHTTPS.post(p.endpoint, @key, v["request_document"], 3000) end)
      assert_receive {:peer_request, worker, headers, body}, 3000
      assert headers =~ "POST /v1/responses HTTP/1.1"
      assert headers =~ "Host: api.openai.com"
      assert headers =~ "Authorization: Bearer " <> @key
      assert body == v["request_document"]
      refute body =~ @key
      bytes = response(v["response_document"], framing)
      <<a::binary-size(19), b::binary-size(37), rest::binary>> = bytes
      send(worker, {:split, [a, b, rest]})
      assert {:ok, v["response_document"]} == Task.await(task, 5000)
      refute_receive {:peer_request, _, _, _}, 20
    end
  end

  test "bad chain, hostname, purpose or lifetime receives no application credential", c do
    for variant <- ~w(wrong_name wrong_purpose expired future unknown_critical unknown_ca corrupt) do
      p = peer(c, variant)
      assert {:error, :unavailable} = OpenAIHTTPS.post(p.endpoint, @key, "{}", 3000)
      assert_receive {:no_application_bytes, _}, 3000
      refute_receive {:peer_request, _, _, _}, 20
    end
  end

  test "native endpoint reconstructs bounds, DER, trust order and fixed hostname options", c do
    p = peer(c)
    assert :ok = OpenAIEndpoint.validate(p.endpoint)
    assert {:ok, options} = OpenAIEndpoint.options(p.endpoint)
    assert options[:verify] == :verify_peer
    assert options[:server_name_indication] == ~c"api.openai.com"
    refute inspect(p.endpoint) =~ "127"

    for {address, port, certs} <- [
          {{0, 0, 0, 0}, 443, [c.pki.ca]},
          {{224, 0, 0, 1}, 443, [c.pki.ca]},
          {{256, 0, 0, 1}, 443, [c.pki.ca]},
          {{127, 0, 0, 1}, 0, [c.pki.ca]},
          {{127, 0, 0, 1}, 443, []},
          {{127, 0, 0, 1}, 443, ["bad"]},
          {{127, 0, 0, 1}, 443, [c.pki.ca | nil]},
          {{127, 0, 0, 1}, 443, [c.pki.ca, c.pki.ca]}
        ] do
      assert {:error, :invalid_openai_endpoint} = OpenAIEndpoint.new(address, port, certs)
    end

    assert {:error, :invalid_openai_endpoint} =
             OpenAIEndpoint.validate(%{p.endpoint | port: p.endpoint.port + 1})

    assert {:error, :invalid_openai_endpoint} =
             OpenAIEndpoint.validate(Map.put(p.endpoint, :extra, true))
  end

  test "redirect/error bodies are not followed and malformed framing refuses before allocation",
       c do
    responses = [
      {"HTTP/1.1 200\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1;\x00invalid\r\nx\r\n0\r\n\r\n",
       :invalid_response},
      {"HTTP/1.1 302 Found\r\nLocation: https://rogue.example/\r\nContent-Length: 999999999\r\n\r\n",
       :unavailable},
      {"HTTP/1.1 429 Busy\r\nContent-Length: 999999999\r\n\r\n", :unavailable},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4194305\r\n\r\n",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n400001\r\n",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx!!",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 2\r\n\r\n",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nX-Huge: " <> String.duplicate("x", 8192) <> "\r\n\r\n",
       :invalid_response},
      {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\nx",
       :unknown}
    ]

    for {{bytes, expected}, index} <- Enum.with_index(responses) do
      p = peer(c)
      task = Task.async(fn -> OpenAIHTTPS.post(p.endpoint, @key, "{}", 3000) end)
      assert_receive {:peer_request, worker, _, _}, 3000
      send(worker, {:respond, bytes})
      assert {:error, ^expected} = Task.await(task, 5000), "HTTP refusal case #{index}"
      refute_receive {:peer_request, _, _, _}, 10
    end
  end

  test "both actual adapter calls produce unchanged drafts through the checked capability", c do
    for family <- ~w(temperature research) do
      v = vector(family)
      p = peer(c)
      {pid, capability, _} = adapter(c, p.endpoint)

      task =
        Task.async(fn ->
          GenServer.call(pid, {:generate_profile, v["document"], 262_144}, 4000)
        end)

      assert_receive {:peer_request, worker, _, body}, 3000
      assert body == v["request_document"]
      send(worker, {:respond, response(v["response_document"])})
      assert {:ok, v["draft_bytes"]} == Task.await(task, 5000)
      assert capability.pid == pid and capability.provider["locality"] == "remote"
      {:ok, identity} = OpenAIAdapter.identity("generator:fixture", "model:fixture", p.endpoint)
      assert capability.provider == identity
      safe = inspect(:sys.get_status(pid))
      refute safe =~ @key
      refute safe =~ c.credential
      refute safe =~ v["document"]
      eventually(fn -> map_size(:sys.get_state(pid).jobs) == 0 end)
    end
  end

  test "key replacement, mode/link and malformed native options refuse without connection", c do
    p = peer(c)
    {pid, _, options} = adapter(c, p.endpoint)

    for bad <- [
          Keyword.put(options, :timeout_ms, 0),
          Keyword.put(options, :concurrency, 17),
          Keyword.put(options, :model, "other"),
          options ++ [timeout_ms: 1],
          Keyword.put(options, :name, "string"),
          [{:provider, options[:provider]} | nil]
        ] do
      assert {:error, :invalid_openai_adapter} = OpenAIAdapter.start_link(bad)
    end

    File.chmod!(c.credential, 0o600)

    assert {:error, :unavailable} =
             GenServer.call(pid, {:generate_profile, vector()["document"], 262_144})

    assert {:error, :openai_credential_unavailable} = OpenAIAdapter.start_link(options)
    File.write!(c.credential, "sk-other-synthetic-key\n")
    File.chmod!(c.credential, 0o400)

    assert {:error, :unavailable} =
             GenServer.call(pid, {:generate_profile, vector()["document"], 262_144})

    refute_receive {:peer_request, _, _, _}, 20
  end

  test "caller cancellation and adapter deadline close the owned network worker", c do
    p = peer(c)
    {pid, _, _} = adapter(c, p.endpoint, concurrency: 1, timeout_ms: 1000)

    caller =
      spawn(fn ->
        GenServer.call(pid, {:generate_profile, vector()["document"], 262_144}, 2000)
      end)

    assert_receive {:peer_request, worker, _, _}, 3000

    assert {:error, :unavailable} =
             GenServer.call(pid, {:generate_profile, vector()["document"], 262_144})

    send(worker, :watch_close)
    Process.exit(caller, :kill)
    assert_receive {:peer_closed, ^worker, {:error, :closed}}, 3000
    eventually(fn -> map_size(:sys.get_state(pid).jobs) == 0 end)

    task =
      Task.async(fn ->
        GenServer.call(pid, {:generate_profile, vector()["document"], 262_144}, 2000)
      end)

    assert_receive {:peer_request, next, _, _}, 3000
    send(next, :watch_close)
    assert {:error, :deadline_expired} = Task.await(task, 3000)
    assert_receive {:peer_closed, ^next, {:error, :closed}}, 3000
    refute_receive {:peer_request, _, _, _}, 20
  end

  test "adapter/worker death and lost replies remain unknown with no second POST", c do
    p = peer(c)
    {pid, capability, _} = adapter(c, p.endpoint)
    token = make_ref()
    {:ok, runner} = GenerationRunner.start(capability, vector()["document"], 262_144, 3000, token)
    assert_receive {:peer_request, worker, _, _}, 3000
    send(worker, :drop)
    assert_receive {:generation_result, ^runner, ^token, {:error, :unknown}}, 3000
    refute_receive {:peer_request, _, _, _}, 20

    task =
      Task.async(fn ->
        GenServer.call(pid, {:generate_profile, vector()["document"], 262_144}, 4000)
      end)

    assert_receive {:peer_request, next, _, _}, 3000
    [job] = Map.values(:sys.get_state(pid).jobs)
    send(next, :watch_close)
    Process.exit(job.worker, :kill)
    assert {:error, :unknown} = Task.await(task, 5000)
    assert_receive {:peer_closed, ^next, {:error, :closed}}, 3000
  end

  test "actual Host reserves before remote export and retains both inert quantity candidates",
       c do
    for family <- ~w(temperature research) do
      p = peer(c)
      {_, capability, _} = adapter(c, p.endpoint)
      directory = Path.join(c.root, family)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      host = boot_host(directory, family, capability)
      credential = seed_host(family)
      {input, original} = host_attempt(family, credential, capability)
      assert_receive {:peer_request, worker, headers, body}, 3000
      assert headers =~ "Authorization: Bearer " <> @key
      assert body == vector(family)["request_document"]
      refute body =~ Base.url_encode64(credential, padding: false)
      send(worker, {:respond, response(vector(family)["response_document"], :chunked)})
      eventually(fn -> match?({:ok, %{"state" => "candidate"}}, host_status(credential)) end)
      assert {:ok, %{"original" => ^original, "result" => result}} = host_status(credential)
      assert result["assessment"]["source_review"] == "not_assessed"
      assert result["assessment"]["fixture_status"] == "not_supplied"

      assert {:ok, ^original} =
               Authority.start_authoring_generation(Host.authority(), credential, input)

      assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
      refute_receive {:peer_request, _, _, _}, 20
      Supervisor.stop(host)
    end
  end

  test "lost actual remote reply stays unknown and cancellation closes original export channel",
       c do
    p = peer(c)
    {_, capability, _} = adapter(c, p.endpoint)
    host = boot_host(c.root, "temperature", capability)
    credential = seed_host("temperature")
    {input, original} = host_attempt("temperature", credential, capability)
    assert_receive {:peer_request, worker, _, _}, 3000
    send(worker, :drop)

    eventually(fn ->
      match?(
        {:ok, %{"state" => "unknown", "result" => %{"disposition" => "unknown"}}},
        host_status(credential)
      )
    end)

    assert {:ok, ^original} =
             Authority.start_authoring_generation(Host.authority(), credential, input)

    refute_receive {:peer_request, _, _, _}, 20

    {next_input, _} =
      host_attempt("temperature", credential, capability, "generation:second", "attempt:second")

    assert_receive {:peer_request, next, _, _}, 3000
    send(next, :watch_close)

    assert {:ok, %{"state" => "cancelled"}} =
             Authority.cancel_authoring_generation(
               Host.authority(),
               credential,
               1,
               "generation:second"
             )

    assert_receive {:peer_closed, ^next, {:error, :closed}}, 3000

    assert {:ok, _} =
             Authority.start_authoring_generation(Host.authority(), credential, next_input)

    refute_receive {:peer_request, _, _, _}, 20
    Supervisor.stop(host)
  end

  defp boot_host(directory, family, capability) do
    data = %{
      "format" => "wotex-home.profile-authoring-installation@1",
      "installed" => Map.take(fixture(family), ~w(bindings contracts home_contracts)),
      "authoring_limits" => fixture("authoring-mechanics")[family]["limits"]
    }

    path = Path.join(directory, ProfileConfiguration.filename())
    File.write!(path, JSON.encode!(data))
    File.chmod!(path, 0o400)

    policy =
      fixture("generation-preparations")[family]["policy"]
      |> Map.put("provider", capability.provider)

    {:ok, checked} = GenerationPolicy.new(policy)

    assert {:ok, host} =
             Host.start_link(
               data_dir: directory,
               generation_installation: %{policies: [checked], providers: [capability]}
             )

    Process.unlink(host)
    on_exit(fn -> if Process.alive?(host), do: Supervisor.stop(host) end)
    host
  end

  defp seed_host(family) do
    store = Host.store()

    {:ok, credential, 1} =
      Store.provision_principal(store, "author:fixture", ["profile:manage", "host:maintain"], [])

    for n <- 2..6,
        do: assert({:ok, _, ^n} = Store.provision_principal(store, "reader:#{n}", ["read"], []))

    rows = fixture("generation-inputs")[family]["objects"]
    import_row(credential, Enum.find(rows, &(&1["kind"] == "source")), 6)
    {:ok, _, 8} = Store.provision_principal(store, "reader:8", ["read"], [])
    import_row(credential, Enum.find(rows, &(&1["kind"] == "fixture")), 8)
    credential
  end

  defp import_row(credential, row, revision) do
    bytes = Base.decode64!(row["payload_base64"])
    {:ok, object} = AuthoringObject.new(row["kind"], bytes)
    {:ok, summary} = AuthoringObject.summary(object)

    assert {:ok, _} =
             Store.import_authoring_object(
               Host.store(),
               credential,
               %{
                 "authority_epoch" => 1,
                 "operation_id" => "import:" <> row["kind"],
                 "expected_revision" => revision,
                 "object" => summary
               },
               bytes
             )
  end

  defp host_attempt(
         family,
         credential,
         capability,
         preparation_op \\ "generation:fixture",
         attempt_op \\ "attempt:fixture"
       ) do
    policy =
      fixture("generation-preparations")[family]["policy"]
      |> Map.put("provider", capability.provider)

    {:ok, checked} = GenerationPolicy.new(policy)
    {:ok, revision} = Store.revision(Host.store())

    preparation =
      fixture("generation-preparations")[family]["request"]
      |> Map.merge(%{
        "operation_id" => preparation_op,
        "expected_revision" => revision,
        "provider_sha256" => capability.provider_sha256,
        "policy_sha256" => checked.sha256
      })

    assert {:error, :generation_export_denied} =
             Authority.prepare_authoring_generation(
               Host.authority(),
               credential,
               Map.put(preparation, "remote_export", false)
             )

    assert {:ok, receipt} =
             Authority.prepare_authoring_generation(Host.authority(), credential, preparation)

    {:ok, revision} = Store.revision(Host.store())

    attempt = %{
      "authority_epoch" => 1,
      "operation_id" => attempt_op,
      "expected_revision" => revision,
      "preparation_operation_id" => preparation_op,
      "preparation_sha256" => receipt["input_sha256"],
      "attempt" => 1,
      "previous_operation_id" => nil,
      "repair_export" => false
    }

    assert {:ok, original} =
             Authority.start_authoring_generation(Host.authority(), credential, attempt)

    {attempt, original}
  end

  defp host_status(credential),
    do:
      Authority.authoring_generation_attempt_status(
        Host.authority(),
        credential,
        1,
        "attempt:fixture"
      )

  test "inclusive body and chunk bounds refuse excess during actual reads", c do
    body = String.duplicate("x", 4_194_304)

    for framing <- [:length, :chunked, :closed] do
      p = peer(c)
      task = Task.async(fn -> OpenAIHTTPS.post(p.endpoint, @key, "{}", 5000) end)
      assert_receive {:peer_request, worker, _, _}, 3000
      send(worker, {:respond, response(body, framing)})
      assert {:ok, ^body} = Task.await(task, 6000)
    end

    for count <- [4096, 4097] do
      p = peer(c)
      task = Task.async(fn -> OpenAIHTTPS.post(p.endpoint, @key, "{}", 5000) end)
      assert_receive {:peer_request, worker, _, _}, 3000

      bytes =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" <>
          String.duplicate("1\r\nx\r\n", count) <> "0\r\n\r\n"

      send(worker, {:respond, bytes})

      if count == 4096 do
        assert {:ok, value} = Task.await(task, 6000)
        assert value == String.duplicate("x", count)
      else
        assert {:error, :invalid_response} = Task.await(task, 6000)
      end
    end

    p = peer(c)
    task = Task.async(fn -> OpenAIHTTPS.post(p.endpoint, @key, "{}", 5000) end)
    assert_receive {:peer_request, worker, _, _}, 3000
    send(worker, {:respond, response(body <> "x", :closed)})
    assert {:error, :invalid_response} = Task.await(task, 6000)
  end

  test "unsafe private keys and link aliases are rejected before a model connection", c do
    p = peer(c)
    {_, _, options} = adapter(c, p.endpoint)

    for bytes <- [
          "short",
          "sk-synthetic-key\n\n",
          "sk-synthetic-key\r\n",
          "sk-synthetic-key with spaces",
          String.duplicate("x", 4098)
        ] do
      File.chmod!(c.credential, 0o600)
      File.write!(c.credential, bytes)
      File.chmod!(c.credential, 0o400)
      assert {:error, :openai_credential_unavailable} = OpenAIAdapter.start_link(options)
    end

    File.chmod!(c.credential, 0o600)
    File.write!(c.credential, @key)
    File.chmod!(c.credential, 0o400)
    link = Path.join(c.root, "linked.key")
    File.ln!(c.credential, link)
    assert {:error, :openai_credential_unavailable} = OpenAIAdapter.start_link(options)
    File.rm!(link)
    File.rename!(c.credential, link)
    File.ln_s!(link, c.credential)
    assert {:error, :openai_credential_unavailable} = OpenAIAdapter.start_link(options)
    File.rm!(c.credential)
    File.rename!(link, c.credential)
    File.chmod!(c.root, 0o755)
    assert {:error, :openai_credential_unavailable} = OpenAIAdapter.start_link(options)
    File.chmod!(c.root, 0o700)
    refute_receive {:peer_request, _, _, _}, 20
  end

  test "revocation before a real TLS response retains only withdrawn actor metadata", c do
    p = peer(c)
    {_, capability, _} = adapter(c, p.endpoint)
    host = boot_host(c.root, "temperature", capability)
    credential = seed_host("temperature")
    {_input, _original} = host_attempt("temperature", credential, capability)
    assert_receive {:peer_request, worker, _, _}, 3000
    assert {:ok, _} = Store.revoke_principal(Host.store(), "author:fixture")
    send(worker, {:respond, response(vector()["response_document"])})
    eventually(fn -> map_size(:sys.get_state(Host.store()).generation_jobs) == 0 end)
    assert {:error, :unauthorized} = host_status(credential)
    {:ok, db} = Exqlite.Sqlite3.open(Path.join(c.root, "home.sqlite"))

    try do
      assert {:ok, statement} =
               Exqlite.Sqlite3.prepare(
                 db,
                 "SELECT result_document FROM profile_authoring_generation_attempts WHERE operation_id = 'attempt:fixture'"
               )

      assert {:row, [result]} = Exqlite.Sqlite3.step(db, statement)
      assert JSON.decode!(result) == ["withdrawn", "actor", nil, nil, nil]
      Exqlite.Sqlite3.release(db, statement)

      assert {:ok, statement} =
               Exqlite.Sqlite3.prepare(
                 db,
                 "SELECT COUNT(*) FROM profile_authoring_objects WHERE kind IN ('draft','bundle')"
               )

      assert {:row, [0]} = Exqlite.Sqlite3.step(db, statement)
      Exqlite.Sqlite3.release(db, statement)
    after
      Exqlite.Sqlite3.close(db)
    end

    refute_receive {:peer_request, _, _, _}, 20
    Supervisor.stop(host)
  end

  test "adapter loss closes its socket and never restarts its temporary child", c do
    p = peer(c)
    {pid, capability, _} = adapter(c, p.endpoint)
    token = make_ref()
    {:ok, runner} = GenerationRunner.start(capability, vector()["document"], 262_144, 3000, token)
    assert_receive {:peer_request, worker, _, _}, 3000
    send(worker, :watch_close)
    Process.exit(pid, :kill)
    assert_receive {:generation_result, ^runner, ^token, {:error, :unknown}}, 3000
    assert_receive {:peer_closed, ^worker, {:error, :closed}}, 3000
    assert OpenAIAdapter.child_spec([]).restart == :temporary
    refute_receive {:peer_request, _, _, _}, 20
  end

  test "Store restart closes remote work and resolves the retained original without replay", c do
    p = peer(c)
    {_, capability, _} = adapter(c, p.endpoint)
    host = boot_host(c.root, "temperature", capability)
    credential = seed_host("temperature")
    {input, original} = host_attempt("temperature", credential, capability)
    assert_receive {:peer_request, worker, _, _}, 3000
    send(worker, :watch_close)
    old_store = Host.store()
    Process.exit(old_store, :kill)
    assert_receive {:peer_closed, ^worker, {:error, :closed}}, 3000
    eventually(fn -> is_pid(Host.store()) and Host.store() != old_store end)

    assert {:ok, %{"original" => ^original, "state" => "unknown", "result" => nil}} =
             host_status(credential)

    assert {:ok, ^original} =
             Authority.start_authoring_generation(Host.authority(), credential, input)

    refute_receive {:peer_request, _, _, _}, 20
    Supervisor.stop(host)
  end

  test "foreign and duplicate result tokens cannot replace the actual provider result", c do
    p = peer(c)
    {pid, _, _} = adapter(c, p.endpoint)

    task =
      Task.async(fn ->
        GenServer.call(pid, {:generate_profile, vector()["document"], 262_144}, 4000)
      end)

    assert_receive {:peer_request, worker, _, _}, 3000
    [{token, job}] = Map.to_list(:sys.get_state(pid).jobs)
    send(pid, {:openai_result, self(), token, {:ok, "forged"}})
    send(pid, {:openai_result, job.worker, make_ref(), {:ok, "forged"}})
    assert map_size(:sys.get_state(pid).jobs) == 1
    send(worker, {:respond, response(vector()["response_document"])})
    assert {:ok, vector()["draft_bytes"]} == Task.await(task, 5000)
    send(pid, {:openai_result, job.worker, token, {:ok, "late"}})
    assert map_size(:sys.get_state(pid).jobs) == 0
  end
end
