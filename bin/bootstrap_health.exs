case WotexHome.Bootstrap.issue_diagnostic_credential() do
  {:ok, encoded} ->
    IO.puts(encoded)

  {:error, reason} ->
    IO.puts(:stderr, "health bootstrap failed: #{reason}")
    System.halt(1)
end
