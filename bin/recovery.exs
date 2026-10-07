# The exact 43-character unpadded URL-safe key plus LF arrives through stdin.
# No secret appears in arguments, the result or tracked custody.
Logger.configure(level: :error)
key_input = IO.binread(:stdio, 44)
result = WotexHome.Recovery.run(System.argv(), key_input)
_ = Application.stop(:wotex_home)
Logger.flush()

case result do
  {:ok, summary} ->
    IO.puts(JSON.encode!(WotexHome.Profiles.Wire.encode(summary)))

  {:error, :usage} ->
    IO.puts(
      :stderr,
      "usage: recovery.exs export ARCHIVE | verify ARCHIVE | stage ARCHIVE NEW_DIRECTORY; key via stdin"
    )

    System.halt(2)

  {:error, reason} when is_atom(reason) ->
    IO.puts(:stderr, "recovery failed: #{reason}")
    System.halt(1)
end
