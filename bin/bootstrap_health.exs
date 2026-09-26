result = WotexHome.Bootstrap.issue_diagnostic_credential()
:ok = Application.stop(:wotex_home)
Logger.flush()

case result do
  {:ok, encoded} ->
    IO.puts(encoded)

  {:error, reason} ->
    IO.puts(:stderr, "health bootstrap failed: #{reason}")
    System.halt(1)
end
