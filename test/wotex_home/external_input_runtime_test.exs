defmodule WotexHome.ExternalInputRuntimeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Profiles.ProducerIdentity
  alias WotexHome.Rules.ExternalInputRuntime
  alias WotexHome.RuntimeArtifacts

  @routines [
    :wotex_home,
    :wotex_routines,
    :wotex_continuum,
    :wotex,
    :ex_booking,
    :decimal,
    :jason,
    :ex_json_schema,
    :nimble_options,
    :tz
  ]
  @transport [:wotex_binding_mqtt, :emqtt, :gun, :cowlib, :wotex_udp]
  @storage [:exqlite, :db_connection, :telemetry]
  @profiles [
    {"core_runtime_sha256", :wotex},
    {"runtime_runtime_sha256", :wotex_runtime},
    {"profiles_runtime_sha256", :wotex_profiles}
  ]

  test "the pure claimed identity matches the independently frozen ordered hash" do
    vector = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    context = vector["definition"]["context"]
    data = context["runtime"]
    expected = context["runtime_sha256"]
    assert {:ok, ^expected} = ExternalInputRuntime.digest(data)

    assert {:error, :runtime_artifact_unavailable} =
             ExternalInputRuntime.check_current(data, expected)

    for field <- ~w(routines_sha256 transport_sha256 storage_sha256) do
      assert {:ok, different} =
               ExternalInputRuntime.digest(Map.put(data, field, String.duplicate("0", 64)))

      refute different == expected
    end

    for field <-
          ~w(core_runtime_sha256 runtime_runtime_sha256 profiles_runtime_sha256 source_revision) do
      changed =
        put_in(
          data,
          ["profiles", field],
          String.duplicate("0", if(field == "source_revision", do: 40, else: 64))
        )

      assert {:ok, different} = ExternalInputRuntime.digest(changed)
      refute different == expected
    end

    archive =
      Map.new(
        ~w(core_archive_sha256 runtime_archive_sha256 profiles_archive_sha256),
        &{&1, String.duplicate("a", 64)}
      )

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(data, :__struct__, __MODULE__),
          Map.put(data, "authorized", true),
          Map.delete(data, "storage_sha256"),
          Map.put(data, "format", "other"),
          Map.put(data, "transport_sha256", String.duplicate("A", 64)),
          Map.put(data, "profiles", archive),
          put_in(data, ["profiles", "extra"], true),
          put_in(data, ["profiles", "source_revision"], "latest")
        ] do
      assert {:error, :runtime_artifact_unavailable} = ExternalInputRuntime.digest(invalid)

      assert {:error, :runtime_artifact_unavailable} =
               ExternalInputRuntime.check_current(invalid, expected)
    end
  end

  test "current data binds every complete application inventory and native producer assertion" do
    assert {:ok, data, sha256} = ExternalInputRuntime.current()

    for {field, apps, domain} <- [
          {"routines_sha256", @routines, "wotex-home.external-input-runtime:routines@1"},
          {"transport_sha256", @transport, "wotex-home.external-input-runtime:transport@1"},
          {"storage_sha256", @storage, "wotex-home.external-input-runtime:storage@1"}
        ] do
      assert {:ok, manifest} = RuntimeArtifacts.manifest(apps)
      assert Enum.map(manifest, & &1.application) == apps

      for entry <- manifest do
        assert entry.version == Application.spec(entry.application, :vsn)

        assert Enum.map(entry.modules, &elem(&1, 0)) ==
                 Enum.sort(Application.spec(entry.application, :modules))
      end

      assert data[field] == term_hash({domain, manifest})
    end

    assert {:ok, profiles} = ProducerIdentity.current()
    assert data["profiles"] == profiles

    for {field, app} <- @profiles do
      assert {:ok, manifest} = RuntimeArtifacts.manifest([app])
      assert profiles[field] == term_hash({profiles["format"], manifest})
    end

    assert :ok = ExternalInputRuntime.check_current(data, sha256)

    assert {:error, :runtime_artifact_unavailable} =
             ExternalInputRuntime.check_current(data, String.duplicate("0", 64))
  end

  @tag timeout: 120_000
  test "every member refuses closing byte, version, module-list and absence drift inside a warm Store guard" do
    applications =
      Enum.uniq(@routines ++ Enum.map(@profiles, &elem(&1, 1)) ++ @transport ++ @storage)

    paths = Enum.map(applications, &{&1, Application.app_dir(&1, "ebin")})

    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-external-input-runtime-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    script = """
    alias WotexHome.RuntimeArtifacts
    alias WotexHome.Rules.ExternalInputRuntime
    directory = #{inspect(directory)}
    try do
      private_apps = Map.new(#{inspect(paths)}, fn {app, original} ->
        private = Path.join(directory, Atom.to_string(app))
        File.mkdir!(private)
        for path <- Path.wildcard(Path.join(original, "*")), File.regular?(path),
          do: File.cp!(path, Path.join(private, Path.basename(path)))
        original_priv = Path.join(Path.dirname(original), "priv")
        if File.dir?(original_priv), do: File.ln_s!(original_priv, Path.join(private, "priv"))
        true = :code.del_path(String.to_charlist(original))
        true = :code.add_patha(String.to_charlist(private))
        {app, private}
      end)
      {:ok, data, sha256} = ExternalInputRuntime.current()
      for app <- #{inspect(applications)} do
        private = Map.fetch!(private_apps, app)
        [module | _] = Application.spec(app, :modules)
        path = Path.join(private, Atom.to_string(module) <> ".beam")
        bytes = File.read!(path)
        {:ok, ^module, chunks} = :beam_lib.all_chunks(bytes)
        {:ok, changed} = :beam_lib.build_module(chunks ++ [{~c"TEST", "changed complete input runtime bytes"}])
        {:ok, {^module, checksum}} = :beam_lib.md5(bytes)
        {:ok, {^module, ^checksum}} = :beam_lib.md5(changed)
        {:ok, :caught_before_outer_close} = RuntimeArtifacts.with_guard(fn ->
          :ok = ExternalInputRuntime.check_current(data, sha256)
          try do
            File.write!(path, changed)
            {:error, :runtime_artifact_unavailable} = ExternalInputRuntime.check_current(data, sha256)
            :caught_before_outer_close
          after
            File.write!(path, bytes)
          end
        end)
        app_path = Path.join(private, Atom.to_string(app) <> ".app")
        {:ok, [spec = {:application, ^app, properties}]} = :file.consult(String.to_charlist(app_path))
        for modified <- [Keyword.put(properties, :vsn, ~c"changed"), Keyword.update!(properties, :modules, &tl/1)] do
          {:ok, :caught_before_outer_close} = RuntimeArtifacts.with_guard(fn ->
            try do
              :ok = Application.unload(app)
              :ok = :application.load({:application, app, modified})
              {:error, :runtime_artifact_unavailable} = ExternalInputRuntime.check_current(data, sha256)
              :caught_before_outer_close
            after
              :ok = Application.unload(app)
              :ok = :application.load(spec)
            end
          end)
        end
        try do
          :ok = Application.unload(app)
          File.rename!(app_path, app_path <> ".absent")
          {:error, :runtime_artifact_unavailable} = ExternalInputRuntime.current()
        after
          File.rename!(app_path <> ".absent", app_path)
          :ok = :application.load(spec)
        end
        :ok = ExternalInputRuntime.check_current(data, sha256)
      end
      IO.puts("verified #{length(applications)} complete application members")
    after
      File.rm_rf!(directory)
    end
    """

    try do
      arguments =
        Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
          ["-e", script]

      assert {"verified #{length(applications)} complete application members\n", 0} ==
               System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)
    after
      File.rm_rf!(directory)
    end

    refute File.exists?(directory)
  end

  defp term_hash(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
