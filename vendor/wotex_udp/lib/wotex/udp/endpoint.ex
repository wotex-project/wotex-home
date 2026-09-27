defmodule Wotex.UDP.Endpoint do
  @moduledoc """
  A validated IPv4 or IPv6 address and UDP port.

  Use `bind/3` for a local address, including port `0` when the OS should
  choose a port. Use `unicast/3`, `broadcast/2`, or `multicast/3` for a remote
  destination. The kind is part of the value so a caller cannot accidentally
  send a broadcast or multicast through an ordinary unicast path.

  Addresses are numeric tuples. Resolution and interface discovery belong to
  the consumer. IPv4 addresses ending in `.255` must be constructed with
  `broadcast/2`; this conservative rule also covers directed broadcast.
  IPv6 link-local and link-local multicast addresses require an explicit
  `scope_id:` interface index. IPv4 addresses reject a scope index.
  """

  alias Wotex.UDP.Error

  @enforce_keys [:address, :port, :family, :kind, :scope_id]
  defstruct [:address, :port, :family, :kind, :scope_id]

  @type ipv4 :: {0..255, 0..255, 0..255, 0..255}
  @type ipv6 ::
          {0..65_535, 0..65_535, 0..65_535, 0..65_535, 0..65_535, 0..65_535, 0..65_535, 0..65_535}
  @type address :: ipv4() | ipv6()
  @type kind :: :bind | :unicast | :broadcast | :multicast
  @type t :: %__MODULE__{
          address: address(),
          port: 0..65_535,
          family: :inet | :inet6,
          kind: kind(),
          scope_id: non_neg_integer()
        }

  @doc "Creates a local bind address. Port zero requests OS allocation."
  @spec bind(address(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def bind(address, port, options \\ []), do: build(address, port, :bind, options)

  @doc "Creates a remote unicast address with a nonzero port."
  @spec unicast(address(), pos_integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def unicast(address, port, options \\ []), do: build(address, port, :unicast, options)

  @doc "Creates an explicitly marked IPv4 broadcast destination ending in `.255`."
  @spec broadcast(ipv4(), pos_integer()) :: {:ok, t()} | {:error, Error.t()}
  def broadcast(address, port), do: build(address, port, :broadcast, [])

  @doc "Creates an IPv4 or IPv6 multicast destination with a nonzero port."
  @spec multicast(address(), pos_integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def multicast(address, port, options \\ []), do: build(address, port, :multicast, options)

  @doc "Returns whether a value still satisfies the endpoint constructor contract."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{address: address, port: port, kind: kind, scope_id: scope} = endpoint) do
    case build(address, port, kind, scope_id: scope) do
      {:ok, ^endpoint} -> true
      _ -> false
    end
  end

  @doc "Converts an Erlang socket source address into a validated endpoint."
  @spec from_sockaddr(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_sockaddr(%{addr: address, port: port} = socket_address) do
    options = [scope_id: Map.get(socket_address, :scope_id, 0)]

    case build(address, port, :unicast, options) do
      {:ok, endpoint} -> {:ok, endpoint}
      _ -> build(address, port, :bind, options)
    end
  end

  def from_sockaddr(_), do: invalid()

  @doc "Converts an endpoint to an Erlang socket address map."
  @spec sockaddr(t()) :: map()
  def sockaddr(%__MODULE__{address: address, port: port, family: :inet}),
    do: %{family: :inet, addr: address, port: port}

  def sockaddr(%__MODULE__{address: address, port: port, family: :inet6, scope_id: scope}),
    do: %{family: :inet6, addr: address, port: port, scope_id: scope}

  defp build(address, port, kind, options) do
    scope =
      if is_list(options) and Keyword.keyword?(options),
        do: Keyword.get(options, :scope_id, 0),
        else: :invalid

    with {:ok, family} <- family(address),
         true <-
           is_list(options) and Keyword.keyword?(options) and
             Keyword.keys(options) in [[], [:scope_id]],
         true <- is_integer(port) and port >= 0 and port <= 65_535,
         true <- kind == :bind or port > 0,
         true <- scope_valid?(address, family, scope),
         true <- allowed_kind?(address, family, kind) do
      {:ok, %__MODULE__{address: address, port: port, family: family, kind: kind, scope_id: scope}}
    else
      _ -> invalid()
    end
  end

  defp family(address) when is_tuple(address) and tuple_size(address) == 4 do
    parts = Tuple.to_list(address)

    if Enum.all?(parts, &valid_part?(&1, 255)) do
      {:ok, :inet}
    else
      :error
    end
  end

  defp family(address) when is_tuple(address) and tuple_size(address) == 8 do
    parts = Tuple.to_list(address)

    if Enum.all?(parts, &valid_part?(&1, 65_535)) do
      {:ok, :inet6}
    else
      :error
    end
  end

  defp family(_), do: :error

  defp valid_part?(part, max), do: is_integer(part) and part >= 0 and part <= max

  defp scope_valid?(_, :inet, scope), do: scope == 0

  defp scope_valid?(address, :inet6, scope) do
    is_integer(scope) and scope >= 0 and scope <= 4_294_967_295 and
      (not scoped_ipv6?(address) or scope > 0)
  end

  defp scoped_ipv6?(address) do
    first = elem(address, 0)

    Bitwise.band(first, 0xFFC0) == 0xFE80 or
      (Bitwise.band(first, 0xFF00) == 0xFF00 and Bitwise.band(first, 0x000F) <= 2)
  end

  defp allowed_kind?(_, _, :bind), do: true

  defp allowed_kind?(address, :inet, :unicast),
    do:
      not ipv4_multicast?(address) and elem(address, 3) != 255 and
        address != {0, 0, 0, 0}

  defp allowed_kind?(address, :inet6, :unicast),
    do: not ipv6_multicast?(address) and address != {0, 0, 0, 0, 0, 0, 0, 0}

  defp allowed_kind?(address, :inet, :broadcast), do: elem(address, 3) == 255
  defp allowed_kind?(address, :inet, :multicast), do: ipv4_multicast?(address)
  defp allowed_kind?(address, :inet6, :multicast), do: ipv6_multicast?(address)
  defp allowed_kind?(_, _, _), do: false

  defp ipv4_multicast?(address), do: elem(address, 0) in 224..239
  defp ipv6_multicast?(address), do: Bitwise.band(elem(address, 0), 0xFF00) == 0xFF00

  defp invalid,
    do: {:error, %Error{kind: :invalid_endpoint, operation: :endpoint, reason: nil}}
end
