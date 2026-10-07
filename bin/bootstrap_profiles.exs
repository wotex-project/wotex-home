result =
  case System.argv() do
    ["manager"] -> WotexHome.Bootstrap.issue_profile_manager_credential()
    ["operator"] -> WotexHome.Bootstrap.issue_profile_operator_credential()
    _ -> {:error, :usage}
  end

:ok = Application.stop(:wotex_home)
Logger.flush()

case result do
  {:ok, encoded} ->
    IO.puts(encoded)

  {:error, :usage} ->
    IO.puts(:stderr, "usage: bootstrap_profiles.exs manager|operator")
    System.halt(2)

  {:error, reason} ->
    IO.puts(:stderr, "profile bootstrap failed: #{reason}")
    System.halt(1)
end
