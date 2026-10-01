defmodule Mix.Tasks.Woh.Hue.Read do
  @moduledoc """
  Read a selected Hue bridge over verified local HTTPS.

  `mix woh.hue.read INTERFACE IPV4 BRIDGE_ID PEER_SHA256 CA_PEM KEY_FILE [LIGHT_UUID]`
  requires previously reviewed bridge trust inputs and one private 0600 file
  containing the application key. It lists narrow Light reports or reads one
  exact resource. No pairing, event subscription, enrollment or write occurs.
  The CA is an explicit public input; it is not automatically downloaded or
  inferred from an untrusted discovery response. Output never includes the key.
  """
  @shortdoc "Read Hue v2 Light reports through explicit verified HTTPS"
  @requirements ["app.start"]
  use Mix.Task
  alias WotexHome.Hue.{ReadInputs, ReadPath}
  alias WotexHome.Lifx.InterfaceSelection

  def run(args) do
    with {:ok, interface, address, bridge, pin, ca, key, query} <- parse(args),
         {:ok, trust, credential} <- ReadInputs.load(ca, key, bridge, pin),
         {:ok, scope} <- InterfaceSelection.select(interface),
         {:ok, reports} <- ReadPath.run(scope, address, 443, trust, credential, query),
         {:ok, ^scope} <- InterfaceSelection.select(interface) do
      Mix.shell().info(
        JSON.encode!(%{
          "scope" => "read_only_lab",
          "reported" => reports,
          "qualification_status" => "pending_physical_evidence"
        })
      )
    else
      {:error, :usage} ->
        Mix.raise(
          "usage: mix woh.hue.read INTERFACE IPV4 BRIDGE_ID PEER_SHA256 CA_PEM KEY_FILE [LIGHT_UUID]"
        )

      {:error, reason} ->
        Mix.raise("Hue read-only check failed: #{reason}")

      _ ->
        Mix.raise("Hue read-only check failed: selected_interface_changed")
    end
  end

  defp parse([interface, ip, bridge, pin, ca, key]),
    do: parse([interface, ip, bridge, pin, ca, key, nil])

  defp parse([interface, ip, bridge, pin, ca, key, resource]) do
    with {:ok, address} <- :inet.parse_ipv4_address(String.to_charlist(ip)),
         true <- to_string(:inet.ntoa(address)) == ip,
         query = if(is_nil(resource), do: :lights, else: {:light, resource}),
         {:ok, _} <- WotexHome.Hue.V2.path(query) do
      {:ok, interface, address, bridge, pin, ca, key, query}
    else
      _ -> {:error, :usage}
    end
  end

  defp parse(_), do: {:error, :usage}
end
