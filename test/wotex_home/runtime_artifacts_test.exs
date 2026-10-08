defmodule WotexHome.RuntimeArtifactsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias WotexHome.RuntimeArtifacts

  test "fixed application manifests are complete, domain-separated and preserve the LIFX identity" do
    assert {:ok, [home, udp] = manifest} = RuntimeArtifacts.manifest([:wotex_home, :wotex_udp])

    for entry <- [home, udp] do
      assert entry.version == Application.spec(entry.application, :vsn)

      assert Enum.map(entry.modules, &elem(&1, 0)) ==
               Enum.sort(Application.spec(entry.application, :modules))
    end

    assert {:ok, expected} =
             RuntimeArtifacts.digest(
               [:wotex_home, :wotex_udp],
               "wotex-home.lifx-power-runtime.v2"
             )

    assert expected == term_digest({"wotex-home.lifx-power-runtime.v2", manifest})
    assert {:ok, ^expected} = WotexHome.Lifx.ProfileBasis.runtime_digest()

    assert {:ok, alternate} =
             RuntimeArtifacts.digest([:wotex_home, :wotex_udp], "different-domain")

    refute alternate == expected

    for {module, digest} <- home.modules do
      {^module, bytes, _} = :code.get_object_code(module)
      assert digest == term_digest(bytes)
    end
  end

  test "invalid application scopes and digest domains never fall back to a smaller closure" do
    for apps <- [
          [],
          [:wotex_home, :wotex_home],
          ["wotex_home"],
          [:home_runtime_missing_application],
          [:wotex_home, :wotex_udp, :crypto, :elixir, :logger],
          nil
        ] do
      assert {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest(apps)
    end

    for domain <- [nil, "", String.duplicate("x", 129)] do
      assert {:error, :runtime_artifact_unavailable} =
               RuntimeArtifacts.digest([:wotex_home], domain)
    end
  end

  test "invalid versions, module inventories and missing files fail in an isolated VM" do
    isolated("""
    alias WotexHome.RuntimeArtifacts
    for {version, modules} <- [
      {~c"1", []}, {~c"1", [RuntimeArtifacts, RuntimeArtifacts]},
      {~c"1", ["not-a-module"]}, {~c"1", [WotexHome.MissingRuntimeArtifact]},
      {~c"1", List.duplicate(RuntimeArtifacts, 513)}, {~c"1", [RuntimeArtifacts | :bad_tail]},
      {[], [RuntimeArtifacts]}, {"1", [RuntimeArtifacts]},
      {List.duplicate(?x, 129), [RuntimeArtifacts]}, {[-1], [RuntimeArtifacts]}
    ] do
      :ok = :application.load({:application, :home_runtime_inventory_fixture,
        [vsn: version, modules: modules]})
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_inventory_fixture])
      :ok = Application.unload(:home_runtime_inventory_fixture)
    end
    IO.puts("verified")
    """)
  end

  test "loaded/file-code mismatch, old code and a deleted retained artifact fail closed" do
    isolated("""
    alias WotexHome.RuntimeArtifacts
    directory = Path.join(System.tmp_dir!(), "home-runtime-code-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(directory)
    module = :home_runtime_code_fixture
    path = Path.join(directory, "home_runtime_code_fixture.beam")
    compile = fn value ->
      forms = [{:attribute, 1, :module, module}, {:attribute, 1, :export, [{:value, 0}]},
        {:function, 1, :value, 0, [{:clause, 1, [], [], [{:integer, 1, value}]}]}]
      {:ok, ^module, bytes, []} = :compile.forms(forms, [:binary, :return_errors, :return_warnings])
      bytes
    end
    try do
      original = compile.(1)
      changed = compile.(2)
      File.write!(path, original)
      true = :code.add_patha(String.to_charlist(directory))
      :ok = :application.load({:application, :home_runtime_code_app, [vsn: ~c"1", modules: [module]]})
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      # Warm parsing never skips the next complete file read or loaded check.
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      1 = apply(module, :value, [])
      # Disk bytes changed but the VM still executes the original code.
      File.write!(path, changed)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      File.write!(path, original)
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      File.write!(path, changed)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), changed)
      2 = apply(module, :value, [])
      true = :erlang.check_old_code(module)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      :code.purge(module)
      false = :erlang.check_old_code(module)
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      # A warm file-code checksum cannot authorize changed loaded code.
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), original)
      :code.purge(module)
      false = :erlang.check_old_code(module)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), changed)
      :code.purge(module)
      {:ok, [_]} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      File.rm!(path)
      {:error, :runtime_artifact_unavailable} = RuntimeArtifacts.manifest([:home_runtime_code_app])
      IO.puts("verified")
    after
      :code.purge(module)
      :code.delete(module)
      :code.del_path(String.to_charlist(directory))
      File.rm_rf!(directory)
    end
    """)
  end

  defp isolated(script) do
    ebin = RuntimeArtifacts |> :code.which() |> List.to_string() |> Path.dirname()

    assert {"verified\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
               stderr_to_stdout: true
             )
  end

  defp term_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
