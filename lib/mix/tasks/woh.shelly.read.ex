defmodule Mix.Tasks.Woh.Shelly.Read do
  @moduledoc """
  Prints an untrusted, read-only Shelly Gen2+ identity and switch report.

  Run `mix woh.shelly.read INTERFACE IPV4 SWITCH_ID [PORT]` on the local host.
  The task sends `Shelly.GetDeviceInfo` and `Switch.GetStatus` only, using one
  explicitly selected LAN interface and canonical dotted-decimal IPv4 peer.
  Its JSON output names that interface and endpoint beside the device claims.
  It does not discover, enroll, authenticate or control the device. HTTP is
  plaintext; an authentication challenge is reported as an error.
  """

  @shortdoc "Read one local Shelly Gen2+ identity and switch"
  @requirements ["app.start"]
  use Mix.Task

  alias WotexHome.Shelly.Gen2Interview

  @impl Mix.Task
  def run(args) do
    with {:ok, interface, address, switch_id, port} <- parse(args),
         {:ok, report} <- Gen2Interview.run(interface, address, port, switch_id) do
      Mix.shell().info(
        JSON.encode!(%{
          "interface" => interface,
          "endpoint" => to_string(:inet.ntoa(address)) <> ":" <> Integer.to_string(port),
          "reported" => report
        })
      )
    else
      {:error, :usage} ->
        Mix.raise("usage: mix woh.shelly.read INTERFACE IPV4 SWITCH_ID [PORT]")

      {:error, reason} ->
        Mix.raise("Shelly read-only interview failed: #{reason}")
    end
  end

  defp parse([interface, address, switch_id]), do: parse([interface, address, switch_id, "80"])

  defp parse([interface, address, switch_id, port]) do
    with true <- byte_size(interface) in 1..64,
         {:ok, parsed_address} <- :inet.parse_ipv4_address(String.to_charlist(address)),
         true <- to_string(:inet.ntoa(parsed_address)) == address,
         {parsed_switch, ""} <- Integer.parse(switch_id),
         true <- parsed_switch in 0..15,
         {parsed_port, ""} <- Integer.parse(port),
         true <- parsed_port in 1..65_535 do
      {:ok, interface, parsed_address, parsed_switch, parsed_port}
    else
      _ -> {:error, :usage}
    end
  end

  defp parse(_), do: {:error, :usage}
end
