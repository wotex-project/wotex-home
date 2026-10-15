ebins = System.fetch_env!("HOME_EXTERNAL_INPUT_ARCHIVE_EBINS") |> JSON.decode!()
true = length(ebins) == 5 and Enum.uniq(ebins) == ebins
Enum.each(ebins, &Code.prepend_path/1)

# The isolated pure consumer may have consolidated this protocol. Load the
# standard library protocol before running Home's separate native process.
:code.purge(String.Chars)

{:module, String.Chars} =
  :code.load_abs(
    Path.join(:code.lib_dir(:elixir, :ebin), "Elixir.String.Chars")
    |> String.to_charlist()
  )

for module <- [
      Wotex.JSON,
      Wotex.Runtime,
      Wotex.Profiles.Compiler,
      Wotex.Profiles.Interpreter,
      Wotex.Routines.Input,
      Wotex.Routines.InputMapping,
      Wotex.Routines.Evaluation,
      WotexContinuum
    ] do
  Code.ensure_loaded!(module)
  loaded = module |> :code.which() |> List.to_string() |> Path.dirname()

  unless loaded in ebins,
    do: raise("native input consumer loaded a producer outside the selected archives")
end

Code.require_file(System.fetch_env!("HOME_EXTERNAL_INPUT_TEST_PATH"))
