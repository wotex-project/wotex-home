defmodule WotexHome.ComponentNativeTest do
  use ExUnit.Case, async: false
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Plugins.{Bundle, Runner}

  @moduletag skip: System.get_env("WOTEX_HOME_COMPONENT_NATIVE_TESTS") != "1"
  @executable System.get_env("WOTEX_HOME_COMPONENT_RUNNER") ||
                Path.expand("../../_build/component-native/debug/woh-component-runner", __DIR__)
  @fixtures Path.expand("../../_build/component-fixtures", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "woh-native-components-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    assert File.regular?(@executable), "build the locked native runner first"
    on_exit(fn -> File.rm_rf!(root) end)
    runner = start_supervised!({Runner, root: root, executable: @executable})
    %{root: root, runner: runner}
  end

  test "two independently built components agree with golden values", context do
    for name <- ["reference", "rust"] do
      digest = install(context, name)

      for {operation, input, expected} <- [
            {:decode_power, <<0, 0>>, {:ok, false}},
            {:decode_power, <<255, 255>>, {:ok, true}},
            {:decode_power, <<>>, {:error, :malformed}},
            {:decode_power, <<0>>, {:error, :malformed}},
            {:decode_power, <<1, 0>>, {:error, :unsupported}},
            {:encode_power, true, {:ok, <<255, 255, 0, 0, 0, 0>>}},
            {:encode_power, false, {:ok, <<0, 0, 0, 0, 0, 0>>}}
          ] do
        assert {:ok,
                %{
                  scope: :unqualified_profile_preview,
                  component_digest: ^digest,
                  result: ^expected
                }} =
                 Runner.preview(context.runner, digest, operation, input)
      end
    end
  end

  test "initialization, fuel, growth, traps, ABI and dishonest output fail closed", context do
    for {name, operation, input, reason} <- [
          {"init-loop", :decode_power, <<0, 0>>, :resource_exhausted},
          {"call-loop", :decode_power, <<0, 0>>, :resource_exhausted},
          {"trap", :decode_power, <<0, 0>>, :guest_trap},
          {"memory", :decode_power, <<0, 0>>, :resource_exhausted},
          {"imports", :decode_power, <<0, 0>>, :incompatible_world},
          {"wrong-world", :decode_power, <<0, 0>>, :incompatible_world},
          {"wrong-types", :decode_power, <<0, 0>>, :incompatible_world},
          {"wrong-types-init", :decode_power, <<0, 0>>, :incompatible_world},
          {"extra-export", :decode_power, <<0, 0>>, :incompatible_world},
          {"extra-interface", :decode_power, <<0, 0>>, :incompatible_world},
          {"dishonest", :encode_power, true, :invalid_output},
          {"oversized", :encode_power, true, :guest_trap}
        ] do
      digest = install(context, name)

      assert {:ok, %{result: {:error, ^reason}}} =
               Runner.preview(context.runner, digest, operation, input)

      good = install(context, "reference")

      assert {:ok, %{result: {:ok, false}}} =
               Runner.preview(context.runner, good, :decode_power, <<0, 0>>)
    end
  end

  test "no component state survives another invocation", context do
    digest = install(context, "stateful")

    for _ <- 1..3 do
      assert {:ok, %{result: {:ok, true}}} =
               Runner.preview(context.runner, digest, :decode_power, <<255, 255>>)
    end
  end

  test "the Authority preview cannot write reports or requests", context do
    store = start_supervised!({Store, path: Path.join(context.root, "home.sqlite")})
    authority = Authority.new(store: store, component_runner: context.runner)
    digest = install(context, "lying-decoder")
    before = Store.health(store)

    assert {:ok, %{scope: :unqualified_profile_preview, result: {:ok, false}}} =
             Authority.profile_preview(authority, digest, :decode_power, <<255, 255>>)

    assert Store.health(store) == before
    refute authority.power_dispatch
  end

  defp install(context, name) do
    assert {:ok, digest} = Bundle.install(context.root, Path.join(@fixtures, name <> ".wasm"))
    digest
  end
end
