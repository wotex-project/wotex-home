defmodule WotexHome.LocalAPI.PeerIdentity do
  @moduledoc """
  Effective UID of an accepted Unix stream peer from the operating system.

  Raw socket option layouts are confined here and fail closed on an unknown
  platform or layout. The bearer credential remains required after this check.

  `verify/2` compares the peer's effective UID with the private socket
  owner's UID before the server handles a request. Keep this check alongside
  filesystem permissions and credential verification; none substitutes for
  the others.
  """

  @mac_peercred_bytes 76
  @linux_peercred_bytes 12

  @spec verify(port(), non_neg_integer()) :: :ok | {:error, :wrong_peer}
  def verify(socket, owner_uid)
      when is_port(socket) and is_integer(owner_uid) and owner_uid >= 0 do
    case effective_uid(socket) do
      {:ok, ^owner_uid} -> :ok
      _ -> {:error, :wrong_peer}
    end
  end

  def verify(_socket, _owner_uid), do: {:error, :wrong_peer}

  @spec effective_uid(port()) :: {:ok, non_neg_integer()} | {:error, :peer_identity_unavailable}
  def effective_uid(socket) when is_port(socket) do
    case :os.type() do
      {:unix, :darwin} -> darwin_uid(socket)
      {:unix, :linux} -> linux_uid(socket)
      _ -> {:error, :peer_identity_unavailable}
    end
  end

  def effective_uid(_socket), do: {:error, :peer_identity_unavailable}

  # macOS SOL_LOCAL=0, LOCAL_PEERCRED=1, struct xucred version 0.
  defp darwin_uid(socket) do
    case :inet.getopts(socket, [{:raw, 0, 1, @mac_peercred_bytes}]) do
      {:ok,
       [{:raw, 0, 1, <<0::native-unsigned-32, uid::native-unsigned-32, _rest::binary-size(68)>>}]} ->
        {:ok, uid}

      _ ->
        {:error, :peer_identity_unavailable}
    end
  end

  # Linux SOL_SOCKET=1, SO_PEERCRED=17, struct ucred {pid, uid, gid}.
  defp linux_uid(socket) do
    case :inet.getopts(socket, [{:raw, 1, 17, @linux_peercred_bytes}]) do
      {:ok,
       [
         {:raw, 1, 17,
          <<_pid::native-signed-32, uid::native-unsigned-32, _gid::native-unsigned-32>>}
       ]} ->
        {:ok, uid}

      _ ->
        {:error, :peer_identity_unavailable}
    end
  end
end
