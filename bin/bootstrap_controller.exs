result =
  case System.argv() do
    ["provision", principal_id, thing_id] ->
      WotexHome.Bootstrap.issue_controller_credential(principal_id, thing_id)

    ["grant", principal_id, thing_id] ->
      WotexHome.Bootstrap.extend_controller_credential(principal_id, thing_id)

    _ ->
      {:error, :usage}
  end

:ok = Application.stop(:wotex_home)
Logger.flush()

case result do
  {:ok, encoded} ->
    IO.puts(encoded)

  {:error, :usage} ->
    IO.puts(:stderr, "usage: bootstrap_controller.exs provision|grant PRINCIPAL_ID THING_ID")
    System.halt(2)

  {:error, reason} ->
    IO.puts(:stderr, "controller bootstrap failed: #{reason}")
    System.halt(1)
end
