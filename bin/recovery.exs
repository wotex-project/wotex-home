# The exact 43-character unpadded URL-safe key plus LF arrives through stdin.
# No secret appears in arguments, the result or tracked custody.
Logger.configure(level: :error)
arguments = System.argv()
input_size = if List.first(arguments) == "retire-export", do: 88, else: 44
key_input = IO.binread(:stdio, input_size)
result = WotexHome.Recovery.run(arguments, key_input)
_ = Application.stop(:wotex_home)
Logger.flush()

case result do
  {:ok, summary} ->
    IO.puts(JSON.encode!(WotexHome.Profiles.Wire.encode(summary)))

  {:error, :usage} ->
    IO.puts(
      :stderr,
      "usage: recovery.exs export ARCHIVE | verify ARCHIVE | stage ARCHIVE NEW_DIRECTORY | export-retired SOURCE_DIRECTORY ARCHIVE | retire-export EPOCH OPERATION_ID EXPECTED_REVISION DESTINATION_OWNER_ID ARCHIVE; secrets via stdin"
    )

    System.halt(2)

  {:error, reason} when is_atom(reason) ->
    IO.puts(:stderr, "recovery failed: #{reason}")
    System.halt(1)
end
