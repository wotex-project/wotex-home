defmodule HomeExternalReviewMutationAssertions do
  @moduledoc false

  use GenServer
  @impl true
  def init(_), do: {:ok, %{assertions: 0, errors: 0}}
  @impl true
  def handle_cast({:test_finished, %{state: {:failed, failures}}}, state) do
    assertions = Enum.count(failures, &match?({:error, %ExUnit.AssertionError{}, _}, &1))

    {:noreply,
     %{
       assertions: state.assertions + assertions,
       errors: state.errors + length(failures) - assertions
     }}
  end

  def handle_cast({:suite_finished, _}, state) do
    IO.puts("EXTERNAL_REVIEW_ASSERTIONS=" <> JSON.encode!(state))
    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}
end

ebins = System.fetch_env!("HOME_EXTERNAL_INPUT_ARCHIVE_EBINS") |> JSON.decode!()
true = length(ebins) == 5 and Enum.uniq(ebins) == ebins
Enum.each(ebins, &Code.prepend_path/1)

for module <- [
      Wotex.JSON,
      Wotex.Runtime,
      Wotex.Profiles.Interpreter,
      Wotex.Routines.Input,
      WotexContinuum
    ] do
  Code.ensure_loaded!(module)
  loaded = module |> :code.which() |> List.to_string() |> Path.dirname()
  true = loaded in ebins
end

ExUnit.start(
  autorun: false,
  seed: 0,
  formatters: [ExUnit.CLIFormatter, HomeExternalReviewMutationAssertions]
)

[replacement] = System.argv()

if replacement != "baseline" do
  Code.compiler_options(ignore_module_conflict: true)

  Code.compile_string(
    File.read!(replacement),
    Path.expand("lib/wotex_home/qualification/external_input_decision.ex")
  )
end

watched = fn ->
  Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :wotex_home end)
end

false = watched.()
Code.require_file(Path.expand("test/wotex_home/external_input_decision_test.exs"))
result = ExUnit.run()
false = watched.()
IO.puts("EXTERNAL_REVIEW_RESULT=" <> JSON.encode!(result))
System.halt(if result.failures == 0, do: 0, else: 1)
