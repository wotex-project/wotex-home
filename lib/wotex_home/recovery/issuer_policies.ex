defmodule WotexHome.Recovery.IssuerPolicies do
  @moduledoc "Closed current isolation-issuer configuration selected by a trusted foreground host."
  alias WotexHome.Recovery.{PrivateFile, TransferAcceptanceCodec}
  @format "wotex-home.controller-isolation-issuers.v1"

  @doc "Inert canonical encoding; this does not install trust or qualify an issuer."
  def encode(policies)
      when is_map(policies) and not is_struct(policies) and map_size(policies) <= 32 do
    with {:ok, records} <-
           Enum.reduce_while(Enum.sort_by(policies, &elem(&1, 0)), {:ok, []}, fn {issuer, policy},
                                                                                 {:ok, records} ->
             case TransferAcceptanceCodec.policy_document(issuer, policy) do
               {:ok, document} ->
                 {:ok, record} = JSON.decode(document)
                 {:cont, {:ok, records ++ [record]}}

               _ ->
                 {:halt, invalid()}
             end
           end),
         document = JSON.encode!([@format, records]),
         true <- byte_size(document) <= 65_536 do
      {:ok, document}
    else
      _ -> invalid()
    end
  end

  def encode(_), do: invalid()

  @doc "Inert public policy decoding; archived records are not implicitly current."
  def decode(document) when is_binary(document) and byte_size(document) in 1..65_536 do
    with {:ok, [@format, records]} <- JSON.decode(document),
         true <- is_list(records) and length(records) <= 32,
         {:ok, policies} <-
           Enum.reduce_while(records, {:ok, %{}}, fn record, {:ok, policies} ->
             case TransferAcceptanceCodec.historical_issuer(JSON.encode!(record)) do
               {:ok, issuer, policy} ->
                 if Map.has_key?(policies, issuer),
                   do: {:halt, invalid()},
                   else: {:cont, {:ok, Map.put(policies, issuer, policy)}}

               _ ->
                 {:halt, invalid()}
             end
           end),
         {:ok, ^document} <- encode(policies) do
      {:ok, policies}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  def decode(_), do: invalid()

  @doc "Explicit trusted-host installation from pinned private out-of-archive custody."
  def open(path) do
    with {:ok, document, seal} <- PrivateFile.read_sealed(path, 65_536),
         {:ok, _} <- decode(document) do
      {:ok,
       fn ->
         with :ok <- PrivateFile.check(seal),
              {:ok, ^document} <- PrivateFile.read(path, 65_536),
              {:ok, policies} <- decode(document),
              :ok <- PrivateFile.check(seal) do
           policies
         else
           _ -> %{}
         end
       end}
    end
  end

  defp invalid, do: {:error, :invalid_isolation_issuer_configuration}
end
