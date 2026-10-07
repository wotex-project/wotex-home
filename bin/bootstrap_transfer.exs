Logger.configure(level: :error)
result = WotexHome.Bootstrap.issue_transfer_credential()
_ = Application.stop(:wotex_home)
Logger.flush()

case result do
  {:ok, encoded} ->
    IO.puts(encoded)

  {:error, reason} when is_atom(reason) ->
    IO.puts(:stderr, "transfer bootstrap failed: #{reason}")
    System.halt(1)
end
