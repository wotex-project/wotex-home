defmodule WotexHome.Recovery.Source do
  @moduledoc "Isolated retired-source reader; Store lock precedes custody, with no Host or transports."
  use Supervisor
  import Bitwise
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.Custody
  @store __MODULE__.Store
  @custody __MODULE__.Custody

  def start_link(directory) do
    with true <-
           is_binary(directory) and Path.type(directory) == :absolute and
             Path.expand(directory) == directory,
         :ok <- directories(Path.split(directory), ""),
         {:ok, root} <- File.lstat(directory),
         true <- band(root.mode, 0o777) == 0o700,
         {:ok, profile_root} <- File.lstat(Path.join(directory, "profiles")),
         true <- profile_root.type == :directory and band(profile_root.mode, 0o777) == 0o700,
         {:ok, database} <- File.lstat(Path.join(directory, "home.sqlite")),
         true <- database.type == :regular and band(database.mode, 0o777) == 0o600 do
      Supervisor.start_link(__MODULE__, directory)
    else
      _ -> {:error, :invalid_retired_source}
    end
  end

  @impl true
  def init(directory) do
    children = [
      {Store,
       path: Path.join(directory, "home.sqlite"),
       controller_mode: :retired_readonly,
       name: @store,
       profile_custody: @custody},
      %{id: Custody, start: {__MODULE__, :start_custody, [directory]}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  def start_custody(directory) do
    with pid when is_pid(pid) <- Process.whereis(@store) do
      Custody.start_link(root: Path.join(directory, "profiles"), name: @custody, store_owner: pid)
    else
      _ -> {:error, :retired_source_unavailable}
    end
  end

  def authority(supervisor) do
    case Enum.find(Supervisor.which_children(supervisor), &(elem(&1, 0) == Store)) do
      {Store, pid, :worker, _} when is_pid(pid) -> {:ok, Authority.new(store: pid)}
      _ -> {:error, :retired_source_unavailable}
    end
  end

  # Root aliases are rejected: this trusted offline boundary requires the
  # canonical source path already selected by its owning Host.
  defp directories([], _), do: :ok

  defp directories([part | rest], parent) do
    path = if parent == "", do: part, else: Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> directories(rest, path)
      _ -> {:error, :invalid_retired_source}
    end
  end
end
