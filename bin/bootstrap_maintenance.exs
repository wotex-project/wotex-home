result = WotexHome.Bootstrap.issue_maintenance_credential()
:ok = Application.stop(:wotex_home)
Logger.flush()

case result do
  {:ok, encoded} ->
    IO.puts(encoded)

  {:error, reason} ->
    IO.puts(:stderr, "maintenance bootstrap failed: #{reason}")
    System.halt(1)
end
