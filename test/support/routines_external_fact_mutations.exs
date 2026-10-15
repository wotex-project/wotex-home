defmodule HomeExternalFactMutationAssertions do
  @moduledoc false

  use GenServer

  @impl GenServer
  def init(_), do: {:ok, %{assertions: 0, errors: 0}}

  @impl GenServer
  def handle_cast({:test_finished, %{state: {:failed, failures}}}, state) do
    assertions = Enum.count(failures, &match?({:error, %ExUnit.AssertionError{}, _}, &1))

    {:noreply,
     %{
       assertions: state.assertions + assertions,
       errors: state.errors + length(failures) - assertions
     }}
  end

  def handle_cast({:suite_finished, _}, state) do
    IO.puts("EXTERNAL_FACT_ASSERTIONS=" <> JSON.encode!(state))
    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}
end

ExUnit.start(
  autorun: false,
  seed: 0,
  formatters: [ExUnit.CLIFormatter, HomeExternalFactMutationAssertions]
)

[replacement] = System.argv()

if replacement != "baseline" do
  paths =
    Map.new([WotexHome.Rules.ExternalFact, Wotex.Routines.Input], fn module ->
      Code.ensure_loaded!(module)
      {module, :code.which(module)}
    end)

  Code.compiler_options(ignore_module_conflict: true)

  for {module, bytes} <- Code.compile_file(replacement) do
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, Map.fetch!(paths, module), bytes)
    :code.purge(module)
  end
end

Code.require_file("test/shadow_test.exs")
result = ExUnit.run()
IO.puts("EXTERNAL_FACT_RESULT=" <> JSON.encode!(result))
System.halt(if result.failures == 0, do: 0, else: 1)
