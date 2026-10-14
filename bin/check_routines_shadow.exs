defmodule Woh.RoutineArchiveShadow do
  @moduledoc false

  @sources ~w(id.ex semantics/value.ex semantics/capability.ex semantics/thing.ex
    rules/fact.ex rules/predicate.ex rules/rule.ex rules/event.ex rules/compiler.ex
    rules/codec.ex rules/arbitration.ex rules/sandbox.ex rules/runtime_gate.ex rules/override_lease.ex)
  @temporal_sources ~w(id.ex profiles/codec.ex schedules/codec.ex schedules/tzif_footer.ex
    schedules/tzif.ex schedules/calendar_reference.ex schedules/occurrence.ex schedules/routine_timezone.ex)
  @profile_sources ~w(id.ex profiles/envelope_codec.ex profiles/external_envelope.ex
    profiles/authoring_producer.ex profiles/authoring_contract.ex profiles/authoring_assessment.ex
    profiles/authoring_fixtures.ex profiles/authoring_object.ex profiles/source_passages.ex
    profiles/source_review.ex profiles/authored_envelope.ex profiles/external_value.ex
    profiles/reader_selection.ex profiles/external_inspection.ex profiles/envelope_summary.ex profiles/authoring_wire.ex
    profiles/inspection_preparation.ex profiles/external_artifact.ex profiles/external_approval_preparation.ex
    profiles/external_read_declaration.ex profiles/read_declaration_codec.ex semantics/value.ex
    semantics/capability.ex semantics/read_capability.ex semantics/thing.ex permissions.ex
    durable/registry.ex local_api/frame.ex profiles/external_source_selection.ex)
  @archive_limit 32 * 1024 * 1024
  @contents_limit 16 * 1024 * 1024

  def main do
    options = [
      core_archive: :string,
      core_sha: :string,
      continuum_archive: :string,
      continuum_sha: :string,
      routines_archive: :string,
      routines_sha: :string,
      temporal_consumer: :boolean,
      ex_booking_archive: :string,
      ex_booking_sha: :string,
      profile_consumer: :boolean,
      profile_store_consumer: :boolean,
      runtime_archive: :string,
      runtime_sha: :string,
      profiles_archive: :string,
      profiles_sha: :string
    ]

    {opts, rest, invalid} = OptionParser.parse(System.argv(), strict: options)

    temporal = opts[:temporal_consumer] == true
    profile_store = opts[:profile_store_consumer] == true
    profiles = opts[:profile_consumer] == true or profile_store

    expected =
      cond do
        profiles ->
          ~w(core_archive core_sha runtime_archive runtime_sha profiles_archive profiles_sha)a ++
            [if(profile_store, do: :profile_store_consumer, else: :profile_consumer)]

        temporal ->
          ~w(core_archive core_sha continuum_archive continuum_sha routines_archive routines_sha ex_booking_archive ex_booking_sha temporal_consumer)a

        true ->
          ~w(core_archive core_sha continuum_archive continuum_sha routines_archive routines_sha)a
      end

    if rest != [] or invalid != [] or Enum.sort(Keyword.keys(opts)) != Enum.sort(expected) or
         length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))),
       do: raise("complete distinct archive/digest arguments required")

    archives =
      if profiles,
        do: [
          {:wotex, opts[:core_archive], opts[:core_sha]},
          {:wotex_runtime, opts[:runtime_archive], opts[:runtime_sha]},
          {:wotex_profiles, opts[:profiles_archive], opts[:profiles_sha]}
        ],
        else: [
          {:wotex, opts[:core_archive], opts[:core_sha]},
          {:wotex_continuum, opts[:continuum_archive], opts[:continuum_sha]},
          {:wotex_routines, opts[:routines_archive], opts[:routines_sha]}
        ]

    archives =
      if temporal,
        do: archives ++ [{:ex_booking, opts[:ex_booking_archive], opts[:ex_booking_sha]}],
        else: archives

    checked = Enum.map(archives, &check_archive/1)

    temporary =
      Path.join(System.tmp_dir!(), "home-routine-shadow-#{System.unique_integer([:positive])}")

    File.mkdir!(temporary)

    try do
      execute(checked, temporary, temporal, profiles, profile_store)
    after
      File.rm_rf!(temporary)
    end
  end

  defp check_archive({app, path, expected}) do
    unless is_binary(path) and is_binary(expected) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, expected),
           do: raise("invalid archive selection")

    unless File.regular?(path) and File.stat!(path).size <= @archive_limit,
      do: raise("missing or over-budget archive")

    bytes =
      File.open!(path, [:read, :binary], fn file -> IO.binread(file, @archive_limit + 1) end)

    unless is_binary(bytes) and byte_size(bytes) <= @archive_limit,
      do: raise("over-budget archive read")

    unless sha(bytes) == expected, do: raise("archive digest mismatch")
    IO.puts("#{app} archive sha256: #{expected}")
    {app, bytes}
  end

  defp execute(archives, temporary, temporal, profiles, profile_store) do
    deps =
      Enum.map(archives, fn {app, bytes} ->
        directory = Path.join(temporary, Atom.to_string(app))
        unpack(bytes, directory)
        {app, [path: directory, env: :prod, override: true]}
      end)

    consumer = Path.join(temporary, "consumer")
    File.mkdir!(consumer)
    File.mkdir!(Path.join(consumer, "test"))

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule HomeShadowConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :home_shadow_consumer, version: "0.0.0", elixir: "~> 1.18",
        deps: #{inspect(deps, limit: :infinity)}]
      def application, do: [extra_applications: []]
    end
    """)

    root = Path.expand("..", __DIR__)

    sources =
      cond do
        profiles -> @profile_sources
        temporal -> @temporal_sources
        true -> @sources
      end

    Enum.each(sources, fn relative ->
      source = Path.join([root, "lib/wotex_home", relative])
      destination = Path.join([consumer, "lib/wotex_home", relative])
      File.mkdir_p!(Path.dirname(destination))
      copy(source, destination, "lib/wotex_home/" <> relative)
    end)

    fixture =
      cond do
        profiles -> "profiles_external_consumer.exs"
        temporal -> "routines_timezone_consumer.exs"
        true -> "routines_shadow_consumer.exs"
      end

    copy(
      Path.join(root, "test/support/" <> fixture),
      Path.join(consumer, "test/shadow_test.exs"),
      "test/support/" <> fixture
    )

    if temporal do
      File.mkdir!(Path.join(consumer, "fixtures"))

      copy(
        Path.join(root, "test/fixtures/schedules/timezone_vectors.json"),
        Path.join(consumer, "fixtures/timezone_vectors.json"),
        "test/fixtures/schedules/timezone_vectors.json"
      )
    end

    if profiles do
      File.mkdir!(Path.join(consumer, "fixtures"))

      copy(
        Path.join(root, "test/support/profiles_authoring_consumer.exs"),
        Path.join(consumer, "test/authoring_test.exs"),
        "test/support/profiles_authoring_consumer.exs"
      )

      copy(
        Path.join(root, "test/fixtures/profiles/authoring-sources.json"),
        Path.join(consumer, "fixtures/authoring-sources.json"),
        "test/fixtures/profiles/authoring-sources.json"
      )

      copy(
        Path.join(root, "test/support/profiles_source_consumer.exs"),
        Path.join(consumer, "test/sources_test.exs"),
        "test/support/profiles_source_consumer.exs"
      )

      copy(
        Path.join(root, "test/fixtures/profiles/authoring-mechanics.json"),
        Path.join(consumer, "fixtures/authoring-mechanics.json"),
        "test/fixtures/profiles/authoring-mechanics.json"
      )

      copy(
        Path.join(root, "test/support/profiles_fixture_consumer.exs"),
        Path.join(consumer, "test/fixtures_test.exs"),
        "test/support/profiles_fixture_consumer.exs"
      )

      copy(
        Path.join(root, "test/fixtures/profiles/authoring-fixtures.json"),
        Path.join(consumer, "fixtures/authoring-fixtures.json"),
        "test/fixtures/profiles/authoring-fixtures.json"
      )

      for {source, target} <- [
            {"test/support/profiles_value_consumer.exs", "test/values_test.exs"},
            {"test/fixtures/profiles/external-values.json", "fixtures/external-values.json"},
            {"test/fixtures/profiles/external-read-declarations.json",
             "fixtures/external-read-declarations.json"},
            {"test/fixtures/profiles/generic-read-semantics.json",
             "fixtures/generic-read-semantics.json"},
            {"test/fixtures/profiles/external-source-selections.json",
             "fixtures/external-source-selections.json"},
            {"priv/profiles/external-consumer.schema.json",
             "fixtures/external-consumer.schema.json"}
          ] do
        copy(Path.join(root, source), Path.join(consumer, target), source)
      end

      for {source, target} <- [
            {"test/support/profiles_reader_consumer.exs", "test/readers_test.exs"},
            {"test/fixtures/profiles/external-inspections.json",
             "fixtures/external-inspections.json"},
            {"test/fixtures/profiles/external-trust.json", "fixtures/external-trust.json"},
            {"priv/profiles/external-inspection.schema.json",
             "fixtures/external-inspection.schema.json"}
          ] do
        copy(Path.join(root, source), Path.join(consumer, target), source)
      end

      for family <- ~w(temperature research) do
        relative = "test/fixtures/profiles/" <> family <> ".json"

        copy(
          Path.join(root, relative),
          Path.join(consumer, "fixtures/" <> family <> ".json"),
          relative
        )
      end

      relative = "priv/profiles/external-envelope.schema.json"

      copy(
        Path.join(root, relative),
        Path.join(consumer, "fixtures/envelope.schema.json"),
        relative
      )
    end

    File.write!(Path.join(consumer, "test/test_helper.exs"), "ExUnit.start()\n")

    environment = [
      {"WOTEX_HOME_PROFILES_CORE_SHA", if(profiles, do: opts_sha(archives, :wotex))},
      {"WOTEX_HOME_PROFILES_RUNTIME_SHA", if(profiles, do: opts_sha(archives, :wotex_runtime))},
      {"WOTEX_HOME_PROFILES_ARCHIVE_SHA", if(profiles, do: opts_sha(archives, :wotex_profiles))},
      {"WOTEX_PATH_DEPS", nil},
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil},
      {"HOME_SHADOW_CONSUMER_ROOT", consumer},
      {"HOME_SHADOW_COMPILER_BASIS",
       if(not profiles, do: "sha256:" <> sha(Keyword.fetch!(archives, :wotex_routines)))}
    ]

    environment =
      if temporal,
        do: [
          {"HOME_SHADOW_PRODUCER_BASIS", "sha256:" <> sha(Keyword.fetch!(archives, :ex_booking))}
          | environment
        ],
        else: environment

    command(["deps.get"], consumer, environment)
    command(["compile", "--warnings-as-errors"], consumer, environment)
    command(["test", "--warnings-as-errors"], consumer, environment)
    IO.puts("consumer lock sha256: #{sha(File.read!(Path.join(consumer, "mix.lock")))}")

    if profile_store do
      test_path = Path.join(temporary, "authoring_store_consumer_test.exs")

      copy(
        Path.join(root, "test/support/authoring_store_consumer.exs"),
        test_path,
        "test/support/authoring_store_consumer.exs"
      )

      ebins =
        consumer
        |> Path.join("_build/test/lib/*/ebin")
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "home_shadow_consumer"))

      command(
        ["test", "--warnings-as-errors", test_path],
        root,
        [
          {"HOME_AUTHORING_ARCHIVE_EBINS", JSON.encode!(ebins)},
          {"WOTEX_HOME_GIT_DEPS", "1"} | environment
        ]
      )
    end

    IO.puts(
      if temporal,
        do: "immutable timezone archive comparison passed",
        else: "restricted archive shadow comparison passed"
    )
  end

  defp opts_sha(archives, app) do
    {_, bytes} = Enum.find(archives, fn {selected, _} -> selected == app end)
    sha(bytes)
  end

  defp copy(source, destination, relative) do
    File.cp!(source, destination)
    IO.puts("#{relative} source sha256: #{sha(File.read!(source))}")
  end

  defp unpack(bytes, destination) do
    {:ok, outer} = :erl_tar.extract({:binary, bytes}, [:memory])
    unless length(outer) <= 16, do: raise("over-budget outer archive")

    {_, compressed} =
      Enum.find(outer, fn {name, _} -> to_string(name) == "contents.tar.gz" end) ||
        raise "missing archive contents"

    contents = inflate(compressed)
    {:ok, entries} = :erl_tar.table({:binary, contents}, [:verbose])
    unless length(entries) <= 2048, do: raise("over-budget archive members")

    Enum.each(entries, fn {name, type, _, _, _, _, _} ->
      safe_path!(to_string(name))
      unless type in [:regular, :directory], do: raise("unsupported archive member")
    end)

    {:ok, members} = :erl_tar.extract({:binary, contents}, [:memory])
    File.mkdir!(destination)

    Enum.each(members, fn {name, data} ->
      name = to_string(name)
      safe_path!(name)
      path = Path.join(destination, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
    end)
  end

  defp safe_path!(name) do
    unless String.valid?(name) and Path.type(name) == :relative and
             ".." not in Path.split(name) and not String.contains?(name, <<0>>),
           do: raise("unsafe archive member")
  end

  defp inflate(compressed) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31)
      contents = drain(stream, compressed, [], 0)
      :ok = :zlib.inflateEnd(stream)
      contents
    after
      :zlib.close(stream)
    end
  end

  defp drain(stream, input, accumulated, size) do
    {status, chunk} = :zlib.safeInflate(stream, input)
    size = size + IO.iodata_length(chunk)
    if size > @contents_limit, do: raise("over-budget decompressed archive")

    if status == :finished,
      do: IO.iodata_to_binary(Enum.reverse([chunk | accumulated])),
      else: drain(stream, <<>>, [chunk | accumulated], size)
  end

  defp command(arguments, directory, environment) do
    {output, status} =
      System.cmd("mix", arguments, cd: directory, env: environment, stderr_to_stdout: true)

    IO.write(output)
    if status != 0, do: raise("shadow consumer command failed")
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

Woh.RoutineArchiveShadow.main()
