defmodule WotexHome.Profiles.OpenAIEndpoint do
  @moduledoc """
  Checks explicit literal routing and CA trust for the fixed generation peer.

  `new/3` binds one numeric IPv4/IPv6 address, port in 1–65,535 and ordered CA
  certificate set to `api.openai.com`. The set contains 1–32 DER certificates,
  each at most 16,384 bytes and at most 262,144 bytes in total; its SHA-256
  identities must be sorted and unique. The returned value retains the exact
  routing/trust inputs and their content identity.

  `validate/1` reconstructs all native fields. `options/1` returns verified
  TLS 1.2/1.3 options with HTTPS hostname checking and HTTP/1.1 ALPN without
  opening a connection. No DNS, proxy, caller URL, redirect, ambient trust store
  or hostname bypass is selected.

  Trust and routing are supplied by the native host. Their content identity
  establishes configuration correspondence, not live account/model access.
  A controlled loopback TLS fixture remains synthetic provider evidence.
  """

  alias WotexHome.Profiles.AuthoringProducer
  import Bitwise

  @enforce_keys [:address, :port, :cacerts, :sha256]
  @derive {Inspect, only: [:sha256]}
  defstruct @enforce_keys

  @doc "Constructs an exact finite endpoint from trusted literal routing and CA DER bytes."
  def new(address, port, cacerts) do
    with true <- address?(address) and is_integer(port) and port in 1..65535,
         true <- cacerts != [] and bounded?(cacerts, 32),
         true <- Enum.all?(cacerts, &certificate?/1),
         true <- Enum.sum(Enum.map(cacerts, &byte_size/1)) <= 262_144,
         hashes = Enum.map(cacerts, &AuthoringProducer.sha/1),
         true <- hashes == Enum.sort(Enum.uniq(hashes)),
         bytes = JSON.encode!([Tuple.to_list(address), port, hashes]) do
      {:ok,
       %__MODULE__{
         address: address,
         port: port,
         cacerts: cacerts,
         sha256: AuthoringProducer.sha("wotex-home.openai-endpoint@1\n" <> bytes)
       }}
    else
      _ -> invalid()
    end
  end

  @doc "Reconstructs every endpoint field before connection or identity use."
  def validate(%__MODULE__{} = endpoint) when map_size(endpoint) == 5 do
    with {:ok, ^endpoint} <- new(endpoint.address, endpoint.port, endpoint.cacerts),
         do: :ok,
         else: (_ -> invalid())
  end

  def validate(_), do: invalid()

  @doc "Produces verified fixed-host TLS options without starting a connection."
  def options(endpoint) do
    with :ok <- validate(endpoint) do
      {:ok,
       [
         mode: :binary,
         active: false,
         packet: :line,
         packet_size: 8192,
         verify: :verify_peer,
         cacerts: endpoint.cacerts,
         server_name_indication: ~c"api.openai.com",
         customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
         versions: [:"tlsv1.3", :"tlsv1.2"],
         alpn_advertised_protocols: ["http/1.1"],
         log_level: :none
       ]}
    end
  end

  defp address?({a, b, c, d} = address) do
    Enum.all?(Tuple.to_list(address), &(is_integer(&1) and &1 in 0..255)) and
      a != 0 and a < 224 and {a, b, c, d} != {255, 255, 255, 255}
  end

  defp address?({0, 0, 0, 0, 0, 65535, upper, lower})
       when is_integer(upper) and is_integer(lower) and upper in 0..65535 and lower in 0..65535,
       do: address?({upper >>> 8, upper &&& 255, lower >>> 8, lower &&& 255})

  defp address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    Enum.all?(Tuple.to_list(address), &(is_integer(&1) and &1 in 0..65535)) and
      address != {0, 0, 0, 0, 0, 0, 0, 0} and (elem(address, 0) &&& 0xFF00) != 0xFF00
  end

  defp address?(_), do: false

  defp certificate?(bytes) when is_binary(bytes) and byte_size(bytes) in 1..16384 do
    _ = :public_key.pkix_decode_cert(bytes, :otp)
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp certificate?(_), do: false
  defp bounded?([], _), do: true
  defp bounded?([_ | _], 0), do: false
  defp bounded?([_ | rest], count), do: bounded?(rest, count - 1)
  defp bounded?(_, _), do: false
  defp invalid, do: {:error, :invalid_openai_endpoint}
end
