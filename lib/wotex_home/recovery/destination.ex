defmodule WotexHome.Recovery.Destination do
  @moduledoc "Private foreground receiving session and original-operation delivery; no Host."
  use Supervisor
  import Bitwise
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.Artifact

  alias WotexHome.Recovery.{
    Owner,
    PrivateFile,
    ReviewOwner,
    TransferAcceptanceCodec,
    TransferReviewCodec
  }

  @reviews __MODULE__.Reviews
  @options ~w(directory review_root owner_file archive_basis issuer_policies clock runtime ttl_ms)a

  def start_link(options) do
    guarded(fn ->
      with true <- is_list(options) and Keyword.keyword?(options),
           keys = Keyword.keys(options),
           true <- length(Enum.uniq(keys)) == length(keys) and Enum.all?(keys, &(&1 in @options)),
           directory = options[:directory],
           true <-
             private_directory?(directory) and
               private_directory?(Path.join(directory, "profiles")),
           {:ok, database} <- File.lstat(Path.join(directory, "home.sqlite")),
           true <-
             database.type == :regular and database.links == 1 and
               band(database.mode, 0o777) == 0o600,
           {:ok, _} <- Owner.read(options[:owner_file]),
           {:ok, supervisor} <- Supervisor.start_link(__MODULE__, {self(), options}) do
        case authority(supervisor) do
          {:ok, %{store: store, recovery_reviews: reviews}} ->
            case ReviewOwner.bind_store(reviews, store) do
              :ok ->
                {:ok, supervisor}

              error ->
                Supervisor.stop(supervisor)
                error
            end

          error ->
            Supervisor.stop(supervisor)
            error
        end
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :invalid_recovery_destination}
      end
    end)
  end

  @impl true
  def init({operator, options}) do
    review_options =
      options
      |> Keyword.drop([:directory, :review_root])
      |> Keyword.merge(
        operator: operator,
        root: options[:review_root],
        name: @reviews,
        profile_root: Path.join(options[:directory], "profiles")
      )

    children = [
      Supervisor.child_spec({ReviewOwner, review_options}, restart: :temporary),
      %{
        id: Store,
        start: {__MODULE__, :start_store, [options[:directory], operator]},
        restart: :temporary,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc false
  def start_store(directory, operator) do
    case Process.whereis(@reviews) do
      reviews when is_pid(reviews) ->
        Store.start_link(
          path: Path.join(directory, "home.sqlite"),
          controller_mode: :recovery,
          recovery_operator: operator,
          recovery_reviews: reviews
        )

      _ ->
        {:error, :recovery_review_unavailable}
    end
  end

  def authority(supervisor) do
    guarded(fn ->
      with {:ok, %{start: {__MODULE__, :start_store, [_, operator]}}} <-
             :supervisor.get_childspec(supervisor, Store),
           true <- operator == self() do
        children = Supervisor.which_children(supervisor)
        store = child(children, Store)
        reviews = child(children, ReviewOwner)

        if is_pid(store) and is_pid(reviews) and Process.alive?(store) and Process.alive?(reviews),
          do: {:ok, Authority.new(store: store, recovery_reviews: reviews, capture: nil)},
          else: {:error, :recovery_destination_unavailable}
      else
        false -> {:error, :recovery_operation_forbidden}
        _ -> {:error, :recovery_destination_unavailable}
      end
    end)
  end

  def prepare(supervisor),
    do:
      guarded(fn ->
        with {:ok, authority} <- authority(supervisor),
             do: Authority.prepare_controller_transfer(authority)
      end)

  def approve(supervisor, token, digest, package),
    do:
      guarded(fn ->
        with {:ok, authority} <- authority(supervisor),
             do: Authority.approve_controller_transfer(authority, token, digest, package)
      end)

  def cancel(supervisor, token),
    do:
      guarded(fn ->
        with {:ok, authority} <- authority(supervisor),
             do: Authority.cancel_controller_transfer(authority, token)
      end)

  @doc "Publish the original operation before acceptance; credentials never enter output."
  def accept(supervisor, review_file, operation),
    do:
      guarded(fn ->
        with {:ok, authority} <- authority(supervisor),
             {:ok, material} <- material(review_file),
             {:ok, input, document} <- operation(material, operation),
             operation_file = Path.join(material.directory, "acceptance-operation.json"),
             :ok <- publish_original(operation_file, document, 4_096),
             {:ok, receipt} <-
               Authority.accept_controller_transfer(
                 authority,
                 material.review["challenge_id"],
                 material.credential,
                 input
               ),
             {:ok, receipt_document} <- TransferAcceptanceCodec.encode("acceptance", receipt) do
          receipt_file = Path.join(material.directory, "acceptance-receipt.json")
          delivered = publish_original(receipt_file, receipt_document, 4_096) == :ok

          {:ok,
           %{
             receipt: receipt,
             operation_file: operation_file,
             credential_file: material.credential_file,
             receipt_file: if(delivered, do: receipt_file),
             receipt_delivery: if(delivered, do: :published, else: :unavailable),
             dispatch_enabled: false
           }}
        end
      end)

  @doc "Resolve an exact private original operation with no challenge or write."
  def recover(supervisor, review_file),
    do:
      guarded(fn ->
        with {:ok, authority} <- authority(supervisor),
             {:ok, material} <- material(review_file),
             {:ok, document} <-
               PrivateFile.read(Path.join(material.directory, "acceptance-operation.json"), 4_096),
             {:ok, input} <- TransferAcceptanceCodec.decode("operation", document),
             {:ok, ^input, ^document} <- operation(material, input["operation_id"]) do
          Authority.transfer_acceptance_status(authority, material.credential, input)
        else
          {:error, _} = error -> error
          _ -> {:error, :recovery_operation_file_conflict}
        end
      end)

  defp material(review_file) do
    with {:ok, review_document} <- PrivateFile.read(review_file, 4_096),
         {:ok, review} <- TransferReviewCodec.decode(review_document),
         directory = Path.dirname(review_file),
         true <- Path.basename(review_file) == "review.json",
         {:ok, package} <- PrivateFile.read(Path.join(directory, "isolation.json"), 8_192),
         credential_file = Path.join(directory, "credential"),
         {:ok, credential} <- PrivateFile.read_credential(credential_file),
         true <- Artifact.digest(credential) == review["credential_hash"] do
      {:ok,
       %{
         directory: directory,
         review: review,
         review_digest: Artifact.digest(review_document),
         package_digest: Artifact.digest(package),
         credential: credential,
         credential_file: credential_file
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :recovery_operation_file_conflict}
    end
  end

  defp operation(material, operation) do
    input =
      Map.take(
        material.review,
        ~w(principal_id source_epoch retirement_revision destination_owner_id)
      )
      |> Map.merge(%{
        "operation_id" => operation,
        "review_digest" => material.review_digest,
        "isolation_package_digest" => material.package_digest
      })

    with {:ok, document} <- TransferAcceptanceCodec.encode("operation", input),
         do: {:ok, input, document}
  end

  defp publish_original(path, bytes, limit) do
    case PrivateFile.write(path, bytes, limit) do
      :ok ->
        :ok

      {:error, :private_custody_exists} ->
        case PrivateFile.read(path, limit) do
          {:ok, ^bytes} -> :ok
          _ -> {:error, :recovery_operation_file_conflict}
        end

      error ->
        error
    end
  end

  defp child(children, id) do
    case Enum.find(children, &(elem(&1, 0) == id)) do
      {^id, pid, :worker, _} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp private_directory?(path) do
    is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path and
      Enum.all?(path |> Path.split() |> Enum.scan(&Path.join(&2, &1)), fn parent ->
        match?({:ok, %{type: :directory}}, File.lstat(parent))
      end) and
      case File.lstat(path) do
        {:ok, stat} -> band(stat.mode, 0o777) == 0o700
        _ -> false
      end
  end

  defp guarded(callback) do
    callback.()
  rescue
    _ -> {:error, :recovery_destination_unavailable}
  catch
    _, _ -> {:error, :recovery_destination_unavailable}
  end
end
