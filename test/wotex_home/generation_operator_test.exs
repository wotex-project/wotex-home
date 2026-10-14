defmodule WotexHome.GenerationOperatorTest do
  @moduledoc false

  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.{Client, Exchange, Frame, Server}

  alias WotexHome.Profiles.{
    AuthoringContract,
    AuthoringObject,
    GenerationOperator,
    GenerationPolicy,
    GenerationProvider,
    ProducerIdentity
  }

  alias WotexHome.Profiles.Custody

  defmodule Provider do
    @moduledoc false

    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:generate_profile, document, output}, from, state) do
      send(state[:observer], {:provider_call, from, document, output})
      {:noreply, state}
    end
  end

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "generation-operator-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(Path.join(root, "profiles"))
    File.chmod!(Path.join(root, "profiles"), 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp contract(family) do
    {:ok, producer} = ProducerIdentity.current()

    installed =
      Map.take(fixture(family), ~w(bindings contracts home_contracts))
      |> Map.put("producer", producer)

    {:ok, contract} =
      AuthoringContract.export(installed, fixture("authoring-mechanics")[family]["limits"])

    contract
  end

  defp boot(root, family, overrides \\ []) do
    vector = fixture("generation-preparations")[family]
    {:ok, policy} = GenerationPolicy.new(vector["policy"])
    selected = contract(family)

    opts =
      [
        path: Path.join(root, "home.sqlite"),
        profile_custody: __MODULE__.Custody,
        authoring_contract: selected,
        generation_policies: [policy]
      ]
      |> Keyword.merge(overrides)

    provider_pid = start_supervised!({Provider, observer: self()}, id: :provider)
    {:ok, provider} = GenerationProvider.new(policy.input["provider"], provider_pid)
    opts = Keyword.put(opts, :generation_providers, [provider])
    store = start_supervised!({Store, opts}, id: :store)

    custody =
      start_supervised!(
        {Custody,
         root: Path.join(root, "profiles"), store_owner: store, name: __MODULE__.Custody},
        id: :custody
      )

    %{
      root: root,
      store: store,
      provider: provider,
      family: family,
      custody: custody,
      opts: opts,
      vector: vector,
      policy: policy,
      contract: selected,
      authority: Authority.new(store: store)
    }
  end

  defp seed(ctx) do
    {:ok, credential, 1} =
      Store.provision_principal(
        ctx.store,
        "author:fixture",
        ["profile:manage", "host:maintain"],
        []
      )

    for n <- 2..6,
        do:
          assert({:ok, _, ^n} = Store.provision_principal(ctx.store, "reader:#{n}", ["read"], []))

    source =
      Enum.find(fixture("generation-inputs")[family(ctx)]["objects"], &(&1["kind"] == "source"))

    example =
      Enum.find(fixture("generation-inputs")[family(ctx)]["objects"], &(&1["kind"] == "fixture"))

    import_object(ctx.store, credential, source, 6, "source:import")
    assert {:ok, _, 8} = Store.provision_principal(ctx.store, "reader:8", ["read"], [])
    import_object(ctx.store, credential, example, 8, "fixture:import")
    Map.put(ctx, :credential, credential)
  end

  defp family(ctx), do: ctx.family

  defp import_object(store, credential, row, revision, operation) do
    payload = Base.decode64!(row["payload_base64"])
    {:ok, object} = AuthoringObject.new(row["kind"], payload)
    {:ok, summary} = AuthoringObject.summary(object)

    input = %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "object" => summary
    }

    assert {:ok, receipt} = Store.import_authoring_object(store, credential, input, payload)
    assert receipt["first_revision"] == row["reference"]["first_revision"]
  end

  defp input(ctx, operation \\ "generation:fixture") do
    {:ok, revision} = Store.revision(ctx.store)

    ctx.vector["request"]
    |> Map.put("operation_id", operation)
    |> Map.put("expected_revision", revision)
  end

  defp prepare(ctx, overrides \\ %{}) do
    request = Map.merge(input(ctx), overrides)

    assert {:ok, root} =
             Authority.prepare_authoring_generation(ctx.authority, ctx.credential, request)

    Map.merge(ctx, %{preparation: root, preparation_input: request})
  end

  defp attempt(ctx, operation \\ "attempt:fixture", index \\ 1, previous \\ nil) do
    {:ok, revision} = Store.revision(ctx.store)

    %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "preparation_operation_id" => ctx.preparation["operation_id"],
      "preparation_sha256" => ctx.preparation["input_sha256"],
      "attempt" => index,
      "previous_operation_id" => previous,
      "repair_export" => index > 1
    }
  end

  defp await(ctx, operation \\ "attempt:fixture", n \\ 100) do
    assert {:ok, status} =
             Authority.authoring_generation_attempt_status(
               ctx.authority,
               ctx.credential,
               1,
               operation
             )

    if status["result"] == nil and n > 0 do
      Process.sleep(10)
      await(ctx, operation, n - 1)
    else
      status
    end
  end

  defp private(c, name, bytes) do
    path = Path.join(c.root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  defp socket(c) do
    path = Path.join(c.root, "home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: path}, id: :server)
    encoded = Base.url_encode64(c.credential, padding: false)
    file = private(c, "credential", encoded)
    {path, ["--socket", path, "--credential-file", file], encoded}
  end

  defp base(c, operation),
    do: %{
      "api_version" => 1,
      "operation" => operation,
      "credential" => Base.url_encode64(c.credential, padding: false)
    }

  defp query(c, operation, epoch, id),
    do: Map.merge(base(c, operation), %{"authority_epoch" => epoch, "operation_id" => id})

  defp cli(flags, command) do
    output = capture_io(fn -> assert 0 == CLI.main(flags ++ command) end)
    JSON.decode!(output)
  end

  defp stopped(c) do
    stop_supervised!(:server)
    stop_supervised!(:custody)
    stop_supervised!(:store)
    stop_supervised!(:provider)
    File.rm_rf!(c.root)
    File.mkdir!(c.root)
    File.chmod!(c.root, 0o700)
    File.mkdir!(Path.join(c.root, "profiles"))
    File.chmod!(Path.join(c.root, "profiles"), 0o700)
  end

  defp proxy(c, destination, operation, mode) do
    path = Path.join(c.root, "proxy-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)
    state = start_supervised!({Agent, fn -> false end}, id: {:proxy, path})
    peer = Task.async(fn -> proxy_loop(listener, destination, operation, mode, state) end)
    {path, listener, peer, state}
  end

  defp proxy_loop(listener, destination, operation, mode, state) do
    case :gen_tcp.accept(listener, 10000) do
      {:ok, peer} ->
        try do
          {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 3000)
          {:ok, bytes} = :gen_tcp.recv(peer, size, 3000)
          {:ok, request} = Frame.decode_request(bytes)

          first =
            request["operation"] == operation and
              Agent.get_and_update(state, fn old -> {not old, true} end)

          case mode do
            :drop ->
              {:ok, response} = Client.request(destination, request)

              unless first do
                {:ok, frame} = Frame.encode_response(response)
                :ok = :gen_tcp.send(peer, frame)
              end

            {:response, response} ->
              {:ok, frame} = Frame.encode_response(response)
              :ok = :gen_tcp.send(peer, frame)
          end
        after
          :gen_tcp.close(peer)
        end

        proxy_loop(listener, destination, operation, mode, state)

      _ ->
        :ok
    end
  end

  defp close_proxy(path, listener, peer) do
    :gen_tcp.close(listener)
    Task.shutdown(peer, :brutal_kill)
    File.rm(path)
  end

  @tag requires_socket: true
  test "actual socket and CLI preserve both families' original preparation, attempt and inert result",
       c do
    for family <- ~w(temperature research) do
      ctx = boot(c.root, family) |> seed()
      {path, flags, _} = socket(ctx)
      options = cli(flags, ["authoring-generation-options"])
      assert options == fixture("generation-operators")[family]["response"]
      request = input(ctx)
      file = private(ctx, "prepare.json", JSON.encode!(request))

      prepared =
        cli(flags, ["authoring-generation-prepare", file])["authoring_generation_receipt"]

      ctx = Map.merge(ctx, %{preparation: prepared, preparation_input: request})
      historical = fixture("generation-preparations")[family]["receipt"]
      assert Map.delete(prepared, "basis_sha256") == Map.delete(historical, "basis_sha256")
      assert prepared["basis_sha256"] == ctx.contract.basis_sha256

      assert {:ok, response} =
               Client.request(
                 path,
                 query(ctx, "authoring_generation_status", 1, prepared["operation_id"])
               )

      assert response["authoring_generation"]["original"] == prepared
      original = attempt(ctx)
      file = private(ctx, "attempt.json", JSON.encode!(original))

      receipt =
        cli(flags, ["authoring-generation-start", file])["authoring_generation_attempt_receipt"]

      assert receipt == fixture("generation-attempts")[family]["receipt"]
      assert_receive {:provider_call, from, document, _}
      assert document == fixture("generation-attempts")[family]["handoff_document"]

      status =
        cli(flags, ["authoring-generation-attempt-status", "1", original["operation_id"]])[
          "authoring_generation_attempt"
        ]

      assert status["state"] == "running" and status["original"] == receipt
      GenServer.reply(from, {:ok, fixture("authoring-mechanics")[family]["draft_bytes"]})
      assert await(ctx)["state"] == "candidate"

      result =
        cli(flags, ["authoring-generation-attempt-status", "1", original["operation_id"]])[
          "authoring_generation_attempt"
        ]

      assert result["result"]["assessment"]["disposition"] == "compatible"

      cancelled =
        cli(flags, ["authoring-generation-cancel", "1", prepared["operation_id"]])[
          "authoring_generation"
        ]

      assert cancelled["state"] == "cancelled" and cancelled["original"] == prepared
      assert {:ok, revision} = Store.revision(ctx.store)

      assert cli(flags, ["authoring-generation-start", file])[
               "authoring_generation_attempt_receipt"
             ] == receipt

      assert {:ok, ^revision} = Store.revision(ctx.store)
      refute_receive {:provider_call, _, _, _}, 20
      stopped(ctx)
    end
  end

  @tag requires_socket: true
  test "policy reads are actor-only and work without provider, producer or custody bytes", c do
    ctx = boot(c.root, "temperature") |> seed()
    {path, flags, _} = socket(ctx)

    assert {:ok, _, _} =
             Store.provision_principal(ctx.store, "author:other", ["profile:manage"], [])

    {:ok, other, _} = Store.provision_principal(ctx.store, "author:empty", ["profile:manage"], [])

    assert {:ok, %{"authoring_generation_options" => %{"policies" => []}}} =
             Client.request(
               path,
               %{
                 base(ctx, "authoring_generation_options")
                 | "credential" => Base.url_encode64(other, padding: false)
               }
             )

    assert {:ok, revision} = Store.revision(ctx.store)
    stop_supervised!(:custody)

    :sys.replace_state(ctx.store, fn s ->
      %{s | generation_providers: [], authoring_contract: nil}
    end)

    options = cli(flags, ["authoring-generation-options"])["authoring_generation_options"]
    assert options["store_revision"] == revision and options["principal_id"] == "author:fixture"
    assert hd(options["policies"])["provider_present"] == false
    assert :ok = GenerationOperator.validate_options(options)
    assert {:ok, ^revision} = Store.revision(ctx.store)
    refute inspect(options) =~ "#PID"
    refute inspect(options) =~ ctx.root
    refute_receive {:provider_call, _, _, _}, 20
  end

  @tag requires_socket: true
  test "discarded prepare/start/cancel replies recover exact originals with no new model call",
       c do
    ctx = boot(c.root, "temperature") |> seed()
    {path, flags, _} = socket(ctx)
    prep = input(ctx)
    prep_file = private(ctx, "prepare.json", JSON.encode!(prep))
    {proxy, listener, peer, dropped} = proxy(ctx, path, "authoring_generation_prepare", :drop)
    pflags = List.replace_at(flags, 1, proxy)

    try do
      message =
        capture_io(:stderr, fn ->
          assert 3 == CLI.main(pflags ++ ["authoring-generation-prepare", prep_file])
        end)

      assert message =~ "authoring-generation-status 1 generation:fixture"
      refute message =~ Base.url_encode64(ctx.credential, padding: false)
      assert Agent.get(dropped, & &1)

      status =
        cli(pflags, ["authoring-generation-status", "1", "generation:fixture"])[
          "authoring_generation"
        ]

      ctx = Map.merge(ctx, %{preparation: status["original"], preparation_input: prep})

      assert cli(pflags, ["authoring-generation-prepare", prep_file])[
               "authoring_generation_receipt"
             ] == ctx.preparation

      refute_receive {:provider_call, _, _, _}, 20
      close_proxy(proxy, listener, peer)
      {proxy, listener, peer, _} = proxy(ctx, path, "authoring_generation_start", :drop)
      pflags = List.replace_at(flags, 1, proxy)
      original = attempt(ctx)
      file = private(ctx, "attempt.json", JSON.encode!(original))

      try do
        message =
          capture_io(:stderr, fn ->
            assert 3 == CLI.main(pflags ++ ["authoring-generation-start", file])
          end)

        assert message =~ "authoring-generation-attempt-status 1 attempt:fixture"
        assert_receive {:provider_call, from, _, _}
        GenServer.reply(from, {:error, :unavailable})
        assert await(ctx)["state"] == "unavailable"

        status =
          cli(pflags, ["authoring-generation-attempt-status", "1", "attempt:fixture"])[
            "authoring_generation_attempt"
          ]

        assert cli(pflags, ["authoring-generation-start", file])[
                 "authoring_generation_attempt_receipt"
               ] == status["original"]

        refute_receive {:provider_call, _, _, _}, 20
      after
        close_proxy(proxy, listener, peer)
      end

      {proxy, listener, peer, _} = proxy(ctx, path, "authoring_generation_cancel", :drop)
      pflags = List.replace_at(flags, 1, proxy)

      try do
        message =
          capture_io(:stderr, fn ->
            assert 3 ==
                     CLI.main(
                       pflags ++ ["authoring-generation-cancel", "1", "generation:fixture"]
                     )
          end)

        assert message =~ "authoring-generation-status 1 generation:fixture"

        assert cli(pflags, ["authoring-generation-status", "1", "generation:fixture"])[
                 "authoring_generation"
               ]["state"] == "cancelled"
      after
        close_proxy(proxy, listener, peer)
      end
    after
      # The first proxy may already have been closed before subsequent operations.
      :gen_tcp.close(listener)
      Task.shutdown(peer, :brutal_kill)
      File.rm(proxy)
    end
  end

  test "closed wrappers, canonical credentials and frame duplicates fail before provider work",
       c do
    ctx = boot(c.root, "temperature") |> seed()
    request = Map.put(base(ctx, "authoring_generation_prepare"), "input", input(ctx))

    for field <- ~w(provider endpoint callback actor_id policy credential_file) do
      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               Server.route(ctx.authority, Map.put(request, field, "private"))
    end

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             Server.route(ctx.authority, Map.put(request, "api_version", 1.0))

    assert %{"outcome" => "error", "reason" => "invalid_credential"} =
             Server.route(ctx.authority, Map.update!(request, "credential", &(&1 <> "=")))

    assert %{"outcome" => "error", "reason" => "invalid_generation_preparation"} =
             Server.route(ctx.authority, put_in(request, ["input", "expected_revision"], 9.0))

    body = JSON.encode!(request)
    duplicate = String.replace(body, "\"api_version\":1", "\"api_version\":1,\"api_version\":1")
    assert {:error, :duplicate_member} = Frame.decode_request(duplicate)
    assert {:ok, 9} = Store.revision(ctx.store)
    refute_receive {:provider_call, _, _, _}, 20
  end

  test "private original files reject mode, symlink, hardlink, excess and duplicate data before connection",
       c do
    ctx = boot(c.root, "temperature") |> seed()
    file = private(ctx, "prepare.json", JSON.encode!(input(ctx)))
    credential = Base.url_encode64(ctx.credential, padding: false)
    assert {:ok, _} = CLI.build_request(["authoring-generation-prepare", file], credential)
    File.chmod!(file, 0o644)

    assert {:error, :invalid_authoring_original_file} =
             CLI.build_request(["authoring-generation-prepare", file], credential)

    File.chmod!(file, 0o600)
    symlink = Path.join(c.root, "symlink.json")
    File.ln_s!(file, symlink)

    assert {:error, :invalid_authoring_original_file} =
             CLI.build_request(["authoring-generation-prepare", symlink], credential)

    hardlink = Path.join(c.root, "hardlink.json")
    File.ln!(file, hardlink)

    assert {:error, :invalid_authoring_original_file} =
             CLI.build_request(["authoring-generation-prepare", file], credential)

    File.rm!(hardlink)
    oversized = private(ctx, "large.json", String.duplicate("x", 131_073))

    assert {:error, :invalid_authoring_original_file} =
             CLI.build_request(["authoring-generation-prepare", oversized], credential)

    duplicate = private(ctx, "duplicate.json", "{\"authority_epoch\":1,\"authority_epoch\":1}")

    assert {:error, :invalid_authoring_original_file} =
             CLI.build_request(["authoring-generation-prepare", duplicate], credential)

    assert {:ok, 9} = Store.revision(ctx.store)
  end

  @tag requires_socket: true
  test "malformed peer replies are unprinted and classified by mutation or read", c do
    ctx = boot(c.root, "temperature") |> seed()
    {path, flags, _} = socket(ctx)
    original = input(ctx)
    file = private(ctx, "prepare.json", JSON.encode!(original))
    p = fixture("generation-preparations")["temperature"]["receipt"]

    malformed = %{
      "api_version" => 1,
      "outcome" => "ok",
      "authoring_generation_receipt" => %{p | "input_sha256" => String.duplicate("0", 64)},
      "private_canary" => "raw source credential"
    }

    {proxy, listener, peer, _} =
      proxy(ctx, path, "authoring_generation_prepare", {:response, malformed})

    try do
      message =
        capture_io(:stderr, fn ->
          output =
            capture_io(fn ->
              assert 3 ==
                       CLI.main(
                         List.replace_at(flags, 1, proxy) ++
                           ["authoring-generation-prepare", file]
                       )
            end)

          assert output == ""
        end)

      assert message =~ "authoring-generation-status 1 generation:fixture"
      refute message =~ "raw source credential"
      refute message =~ Base.url_encode64(ctx.credential, padding: false)
    after
      close_proxy(proxy, listener, peer)
    end

    {proxy, listener, peer, _} =
      proxy(
        ctx,
        path,
        "authoring_generation_options",
        {:response,
         %{
           "api_version" => 1,
           "outcome" => "ok",
           "authoring_generation_options" => %{},
           "private_canary" => "raw source credential"
         }}
      )

    try do
      message =
        capture_io(:stderr, fn ->
          output =
            capture_io(fn ->
              assert 1 ==
                       CLI.main(
                         List.replace_at(flags, 1, proxy) ++ ["authoring-generation-options"]
                       )
            end)

          assert output == ""
        end)

      assert message =~ "invalid_generation_response"
      refute message =~ "raw source credential"
    after
      close_proxy(proxy, listener, peer)
    end

    assert {:ok, 9} = Store.revision(ctx.store)
    refute_receive {:provider_call, _, _, _}, 20
  end

  test "generation exchange mutation failures are uncertain without payload or bearer logs", c do
    ctx = boot(c.root, "temperature") |> seed()
    request = Map.put(base(ctx, "authoring_generation_prepare"), "input", input(ctx))
    stop_supervised!(:store)

    log =
      capture_log(fn ->
        for operation <-
              ~w(authoring_generation_prepare authoring_generation_start authoring_generation_cancel) do
          r =
            if operation == "authoring_generation_cancel",
              do: query(ctx, operation, 1, "generation:fixture"),
              else: Map.put(request, "operation", operation)

          assert %{"outcome" => "error", "reason" => "outcome_unknown"} =
                   Exchange.perform(
                     ctx.authority,
                     r,
                     System.monotonic_time(:millisecond) + 1000
                   )
        end

        assert %{"outcome" => "error", "reason" => "operation_unavailable"} =
                 Exchange.perform(
                   ctx.authority,
                   base(ctx, "authoring_generation_options"),
                   System.monotonic_time(:millisecond) + 1000
                 )
      end)

    assert log == ""
  end

  @tag requires_socket: true
  test "endpoint restart leaves one Store-owned attempt and original status intact", c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    {path, flags, _} = socket(ctx)
    original = attempt(ctx)
    file = private(ctx, "attempt.json", JSON.encode!(original))

    receipt =
      cli(flags, ["authoring-generation-start", file])["authoring_generation_attempt_receipt"]

    assert_receive {:provider_call, from, _, _}
    stop_supervised!(:server)
    assert {:ok, revision} = Store.revision(ctx.store)
    start_supervised!({Server, authority: ctx.authority, socket_path: path}, id: :server)

    status =
      cli(flags, ["authoring-generation-attempt-status", "1", "attempt:fixture"])[
        "authoring_generation_attempt"
      ]

    assert status["state"] == "running" and status["original"] == receipt

    assert cli(flags, ["authoring-generation-start", file])[
             "authoring_generation_attempt_receipt"
           ] == receipt

    assert {:ok, ^revision} = Store.revision(ctx.store)
    refute_receive {:provider_call, _, _, _}, 20
    GenServer.reply(from, {:error, :unavailable})
    assert await(ctx)["state"] == "unavailable"
  end

  @tag requires_socket: true
  test "explicit CLI repair carries exactly the prior invalid draft and cannot become approval",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    {_, flags, _} = socket(ctx)
    original = attempt(ctx)
    file = private(ctx, "attempt.json", JSON.encode!(original))
    cli(flags, ["authoring-generation-start", file])
    assert_receive {:provider_call, from, _, _}
    bad = "{\"untrusted_instruction\":\"pick different sources\"}"
    GenServer.reply(from, {:ok, bad})
    first = await(ctx)
    assert first["result"]["assessment"]["disposition"] == "invalid"
    repair = attempt(ctx, "attempt:repair", 2, "attempt:fixture")
    file = private(ctx, "repair.json", JSON.encode!(repair))

    receipt =
      cli(flags, ["authoring-generation-start", file])["authoring_generation_attempt_receipt"]

    assert receipt["attempt"] == 2
    assert_receive {:provider_call, from, document, _}
    [_, initial, [^bad, report]] = JSON.decode!(document)
    assert initial == JSON.decode!(fixture("generation-inputs")["temperature"]["document"])

    {:ok, expected} =
      WotexHome.Profiles.AuthoringCandidate.encode_assessment(first["result"]["assessment"])

    assert report == JSON.decode!(expected)
    GenServer.reply(from, {:ok, fixture("authoring-mechanics")["temperature"]["draft_bytes"]})
    assert await(ctx, "attempt:repair")["state"] == "candidate"

    status =
      cli(flags, ["authoring-generation-attempt-status", "1", "attempt:repair"])[
        "authoring_generation_attempt"
      ]

    assert status["result"]["assessment"]["source_review"] == "not_assessed"
    assert status["result"]["assessment"]["fixture_status"] == "not_supplied"

    assert cli(flags, ["authoring-generation-start", file])[
             "authoring_generation_attempt_receipt"
           ] == receipt

    refute_receive {:provider_call, _, _, _}, 20
  end

  @tag requires_socket: true
  test "foreign, unprivileged and revoked operators cannot read this author's policy or original",
       c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    {path, flags, _} = socket(ctx)

    assert {:ok, foreign, _} =
             Store.provision_principal(ctx.store, "author:foreign", ["profile:manage"], [])

    request =
      query(ctx, "authoring_generation_status", 1, "generation:fixture")
      |> Map.put("credential", Base.url_encode64(foreign, padding: false))

    assert {:ok, %{"outcome" => "not_found"}} = Client.request(path, request)
    assert {:ok, reader, _} = Store.provision_principal(ctx.store, "reader:foreign", ["read"], [])

    request = %{
      base(ctx, "authoring_generation_options")
      | "credential" => Base.url_encode64(reader, padding: false)
    }

    assert {:ok, %{"outcome" => "error", "reason" => "permission_denied"}} =
             Client.request(path, request)

    assert {:ok, _} = Store.revoke_principal(ctx.store, "author:fixture")
    output = capture_io(fn -> assert 1 == CLI.main(flags ++ ["authoring-generation-options"]) end)
    assert JSON.decode!(output)["reason"] == "unauthorized"

    output =
      capture_io(fn ->
        assert 1 == CLI.main(flags ++ ["authoring-generation-status", "1", "generation:fixture"])
      end)

    assert JSON.decode!(output)["reason"] == "unauthorized"
    refute_receive {:provider_call, _, _, _}, 20
  end

  test "transport deadline leaves a queued Store attempt uncertain and original-scoped", c do
    ctx = boot(c.root, "temperature") |> seed() |> prepare()
    original = attempt(ctx)
    request = Map.put(base(ctx, "authoring_generation_start"), "input", original)
    :ok = :sys.suspend(ctx.store)

    try do
      assert %{"outcome" => "error", "reason" => "outcome_unknown"} =
               Exchange.perform(ctx.authority, request, System.monotonic_time(:millisecond) + 150)
    after
      :ok = :sys.resume(ctx.store)
    end

    # Killing the adapter does not prove the already queued Store call rolled back.
    assert_receive {:provider_call, from, _, _}, 2000

    assert {:ok, receipt} =
             Authority.start_authoring_generation(ctx.authority, ctx.credential, original)

    assert receipt["input_sha256"] ==
             fixture("generation-attempts")["temperature"]["receipt"]["input_sha256"]

    refute_receive {:provider_call, _, _, _}, 20
    GenServer.reply(from, {:error, :unavailable})
    assert await(ctx)["state"] == "unavailable"
  end
end
