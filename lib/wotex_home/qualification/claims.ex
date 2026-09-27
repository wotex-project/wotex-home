defmodule WotexHome.Qualification.Claims do
  @moduledoc """
  Private, content-addressed custody for sanitized signed qualification claims.

  Raw captures remain in the separately reviewed artifact directory. A missing,
  changed or untrusted claim package never grants qualification at admission or
  claim time, including after database restore.

  `put/2` stores a signed package under its digest in a private directory.
  `verify/4` reopens it using pinned case and decision keys when current
  authority needs to rely on that qualification. Restoring a database row
  without its matching package cannot restore send authority.
  """

  import Bitwise

  alias WotexHome.Qualification.Decision

  @prefix "qualification:"
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @max_bytes 262_144

  def put(root, %{evidence_ref: @prefix <> digest, package_bytes: bytes})
      when is_binary(root) and is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with true <- digest =~ @hex64,
         true <- ref(bytes) == @prefix <> digest,
         :ok <- private_directory(root) do
      path = Path.join(root, digest)

      case File.lstat(path) do
        {:ok, _} -> verify_file(root, digest) |> result_as_put()
        {:error, :enoent} -> write_new(root, path, digest, bytes)
        _ -> {:error, :qualification_artifact_unavailable}
      end
    else
      _ -> {:error, :qualification_artifact_unavailable}
    end
  end

  def put(_, _), do: {:error, :qualification_artifact_unavailable}

  def verify(root, @prefix <> digest = expected_ref, case_keys, decision_keys)
      when is_binary(root) and is_map(case_keys) and is_map(decision_keys) do
    with true <- digest =~ @hex64,
         :ok <- check_directory(root),
         {:ok, bytes} <- verify_file(root, digest),
         package when is_map(package) <- :erlang.binary_to_term(bytes, [:safe]),
         true <- Enum.sort(Map.keys(package)) == [:attestations, :basis, :cohort, :signed],
         {:ok, verified} <-
           Decision.verify(
             package.signed,
             package.basis,
             package.cohort,
             package.attestations,
             case_keys,
             decision_keys
           ),
         true <- verified.evidence_ref == expected_ref do
      {:ok, verified}
    else
      _ -> {:error, :qualification_artifact_unavailable}
    end
  rescue
    _ -> {:error, :qualification_artifact_unavailable}
  end

  def verify(_, _, _, _), do: {:error, :qualification_artifact_unavailable}

  defp result_as_put({:ok, _}), do: :ok
  defp result_as_put(error), do: error

  defp private_directory(root) do
    case File.lstat(root) do
      {:error, :enoent} ->
        with :ok <- File.mkdir(root),
             :ok <- File.chmod(root, 0o700) do
          check_directory(root)
        else
          _ -> {:error, :qualification_artifact_unavailable}
        end

      _ ->
        check_directory(root)
    end
  end

  defp check_directory(root) do
    with true <- Path.type(root) == :absolute,
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(root),
         true <- (mode &&& 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :qualification_artifact_unavailable}
    end
  end

  defp verify_file(root, digest) do
    path = Path.join(root, digest)

    with {:ok, %{uid: uid}} <- File.lstat(root),
         {:ok, %{type: :regular, uid: ^uid, mode: mode, size: size}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o600 and size <= @max_bytes and size > 0,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) == size and ref(bytes) == @prefix <> digest do
      {:ok, bytes}
    else
      _ -> {:error, :qualification_artifact_unavailable}
    end
  end

  defp write_new(root, path, digest, bytes) do
    temporary =
      Path.join(
        root,
        ".#{digest}.#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    result =
      with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive, :raw]) do
        try do
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file),
               :ok <- File.rename(temporary, path),
               {:ok, ^bytes} <- verify_file(root, digest) do
            :ok
          else
            _ -> {:error, :qualification_artifact_unavailable}
          end
        after
          File.close(file)
        end
      end

    _ = File.rm(temporary)
    result
  end

  defp ref(bytes), do: @prefix <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
end
