# Run with: elixir bin/test.exs [--socket-free] [--firmware-host] [test/path_test.exs ...]
# This uses already-built test dependencies, without Mix's TCP PubSub launcher.
defmodule WotexHome.TestRunner do
  @moduledoc false

  def run(args) do
    {options, paths, invalid} =
      OptionParser.parse(args,
        strict: [socket_free: :boolean, firmware_host: :boolean]
      )

    if invalid != [], do: raise(ArgumentError, "unknown test runner options: #{inspect(invalid)}")
    root = Path.expand("..", __DIR__)
    File.cd!(root)

    dependencies =
      Path.wildcard("_build/test/lib/*/ebin")
      |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "wotex_home"))
      |> Enum.map(&Path.expand/1)

    if dependencies == [],
      do: raise("Build the locked test dependencies with mix deps.get and mix compile first.")

    Code.prepend_paths(dependencies)
    Mix.start()
    Mix.env(:test)
    Code.require_file("mix.exs")

    temporary =
      Path.join(System.tmp_dir!(), "woh-tests-" <> Base.encode16(:crypto.strong_rand_bytes(12)))

    ebin = Path.join(temporary, "wotex_home/ebin")
    File.mkdir_p!(ebin)
    File.chmod!(temporary, 0o700)
    File.ln_s!(Path.join(root, "priv"), Path.join(temporary, "wotex_home/priv"))

    try do
      firmware_sources =
        if options[:firmware_host], do: Path.wildcard("native/nerves/lib/**/*.ex"), else: []

      modules =
        case Kernel.ParallelCompiler.compile_to_path(
               Path.wildcard("lib/**/*.ex") ++ firmware_sources,
               ebin,
               return_diagnostics: true
             ) do
          {:ok, modules, %{compile_warnings: [], runtime_warnings: []}} -> modules
          _ -> raise("Fresh Home compilation failed or emitted warnings.")
        end

      project = WotexHome.MixProject.project()
      application = WotexHome.MixProject.application()

      dependencies =
        for {app, _requirement, opts} <- normalize_dependencies(project[:deps]),
            Keyword.get(opts, :runtime, true),
            :test in List.wrap(Keyword.get(opts, :only, [:test])),
            do: app

      properties =
        application
        |> Keyword.delete(:extra_applications)
        |> Keyword.put(:modules, modules)
        |> Keyword.put(:vsn, String.to_charlist(project[:version]))
        |> Keyword.put(
          :applications,
          Enum.uniq(
            [:kernel, :stdlib, :elixir] ++
              Keyword.get(application, :extra_applications, []) ++ dependencies
          )
        )

      app = {:application, :wotex_home, properties}
      File.write!(Path.join(ebin, "wotex_home.app"), :io_lib.format(~c"~p.~n", [app]))
      Code.prepend_path(ebin)

      Mix.Tasks.Woh.Spec.Check.run([])
      ExUnit.start(autorun: false)

      if options[:socket_free] do
        IO.puts(
          "Socket-free run: requires_socket tests are explicitly excluded; OS integration is NOT verified."
        )

        ExUnit.configure(exclude: [requires_socket: true])
      end

      firmware_tests =
        if options[:firmware_host] do
          IO.puts(
            "Firmware host probes included; Nerves runtime, image and board are NOT qualified."
          )

          Path.wildcard("native/nerves/test/**/*test.exs")
        else
          []
        end

      files =
        if paths == [], do: Path.wildcard("test/**/*test.exs") ++ firmware_tests, else: paths

      if files == [], do: raise(ArgumentError, "no test files selected")

      Enum.each(files, fn path ->
        unless File.regular?(path) and String.ends_with?(path, "_test.exs"),
          do: raise(ArgumentError, "not a test file: #{path}")

        Code.require_file(Path.expand(path))
      end)

      %{failures: failures} = ExUnit.run()
      if failures == 0, do: 0, else: 1
    after
      File.rm_rf!(temporary)
    end
  end

  defp normalize_dependencies(dependencies) do
    Enum.map(dependencies, fn
      {app, opts} when is_list(opts) -> {app, nil, opts}
      {app, requirement} -> {app, requirement, []}
      {app, requirement, opts} -> {app, requirement, opts}
    end)
  end
end

System.halt(WotexHome.TestRunner.run(System.argv()))
