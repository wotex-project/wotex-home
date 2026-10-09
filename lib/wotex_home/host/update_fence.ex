defmodule WotexHome.Host.UpdateFence do
  @moduledoc """
  Root-owned deny fence for an installed Linux release update.

  The fence starts after Store ownership and before every host consumer. It
  grants no authority; pending or unavailable custody prevents startup and a
  new maintenance end. Exact historical Store receipts remain unchanged.
  """
  use GenServer
  import Bitwise
  alias WotexHome.Durable.Store
  alias WotexHome.LocalAPI.Frame

  @path "/opt/wotex-home/update-guard.json"
  @maximum 9_223_372_036_854_775_807
  @keys ~w(schema_version scope owner_sha256 artifact_id authority_epoch begin_revision state)

  def path, do: @path

  def configuration do
    case {System.get_env("WOTEX_HOME_LINUX_ARTIFACT_ID"),
          System.get_env("WOTEX_HOME_UPDATE_GUARD_PATH")} do
      {nil, nil} -> :disabled
      {artifact, @path} -> %{artifact_id: artifact, path: @path}
      _ -> :invalid
    end
  end

  # Alternate protected paths are a trusted in-process fixture seam. Shipped
  # service configuration always names the fixed path; no request chooses it.
  def valid_configuration?(:disabled), do: true

  def valid_configuration?(%{artifact_id: artifact, path: path} = config),
    do: map_size(config) == 2 and hex?(artifact) and safe_path?(path)

  def valid_configuration?(_), do: false

  def enabled?(configuration),
    do: configuration != :disabled and valid_configuration?(configuration)

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    case check_boot(Keyword.fetch!(options, :store), Keyword.fetch!(options, :configuration)) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  def check_boot(store, configuration) do
    case read(configuration) do
      :absent ->
        :ok

      {:ok, guard} ->
        if guard["artifact_id"] == configuration.artifact_id do
          if guard["state"] == "pending",
            do:
              Store.validate_update_fence(
                store,
                guard["authority_epoch"],
                guard["begin_revision"]
              ),
            else: :ok
        else
          {:error, :update_artifact_changed}
        end

      {:error, _} = error ->
        error
    end
  end

  def allow_end(configuration) do
    case read(configuration) do
      :absent ->
        :ok

      {:ok, %{"state" => "complete", "artifact_id" => artifact}} ->
        if artifact == configuration.artifact_id,
          do: :ok,
          else: {:error, :update_artifact_changed}

      {:ok, %{"state" => "pending"}} ->
        {:error, :release_update_active}

      {:error, _} = error ->
        error
    end
  end

  def read(:disabled), do: :absent

  def read(configuration) do
    if enabled?(configuration) do
      with :ok <- protected_parents(Path.dirname(configuration.path)),
           {:ok, before} <- File.lstat(configuration.path),
           true <- owned_file?(before),
           {:ok, bytes} <- File.open(configuration.path, [:read, :binary], &IO.binread(&1, 4097)),
           true <- is_binary(bytes) and byte_size(bytes) in 1..4096,
           {:ok, after_read} <- File.lstat(configuration.path),
           true <- same_file?(before, after_read),
           {:ok, guard} <- decode(bytes) do
        {:ok, guard}
      else
        {:error, :enoent} ->
          # Only an absent final name permits initial setup. Its protected
          # parent must exist and have passed the complete traversal above.
          case {protected_parents(Path.dirname(configuration.path)),
                File.lstat(configuration.path)} do
            {:ok, {:error, :enoent}} -> :absent
            _ -> {:error, :update_guard_unavailable}
          end

        _ ->
          {:error, :update_guard_unavailable}
      end
    else
      {:error, :update_guard_unavailable}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..4096 do
    with {:ok, guard} <- Frame.decode_request(bytes),
         true <- MapSet.new(Map.keys(guard)) == MapSet.new(@keys),
         true <- guard["schema_version"] == 1 and guard["scope"] == "linux_release_update_guard",
         true <- hex?(guard["owner_sha256"]) and hex?(guard["artifact_id"]),
         true <- positive?(guard["authority_epoch"]) and positive?(guard["begin_revision"]),
         true <- guard["state"] in ["pending", "complete"] do
      {:ok, guard}
    else
      _ -> {:error, :update_guard_unavailable}
    end
  end

  def decode(_bytes), do: {:error, :update_guard_unavailable}

  defp protected_parents(path) do
    Path.split(path)
    |> Enum.reduce_while("", fn component, parent ->
      target = if parent == "", do: component, else: Path.join(parent, component)

      case File.lstat(target) do
        {:ok, info} when info.type == :directory and info.uid == 0 and info.gid == 0 ->
          if (info.mode &&& 0o7022) == 0,
            do: {:cont, target},
            else: {:halt, {:error, :update_guard_unavailable}}

        _ ->
          {:halt, {:error, :update_guard_unavailable}}
      end
    end)
    |> case do
      value when is_binary(value) -> :ok
      error -> error
    end
  end

  defp owned_file?(info),
    do:
      info.type == :regular and info.uid == 0 and info.gid == 0 and info.links == 1 and
        (info.mode &&& 0o7777) == 0o644 and info.size in 1..4096

  defp same_file?(before, after_read),
    do:
      Map.take(before, ~w(inode major_device minor_device uid gid links mode size mtime ctime)a) ==
        Map.take(
          after_read,
          ~w(inode major_device minor_device uid gid links mode size mtime ctime)a
        )

  defp hex?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp positive?(value), do: is_integer(value) and value in 1..@maximum

  defp safe_path?(path) when is_binary(path) and byte_size(path) in 1..1024,
    do:
      Regex.match?(~r/\A\/(?:[A-Za-z0-9_+@.-]+\/)*[A-Za-z0-9_+@.-]+\z/, path) and
        not Enum.any?(Path.split(path), &(&1 in [".", ".."]))

  defp safe_path?(_), do: false
end
