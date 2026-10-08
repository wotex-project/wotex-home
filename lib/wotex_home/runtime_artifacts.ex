defmodule WotexHome.RuntimeArtifacts do
  @moduledoc """
  Bounded compiled-code inventories for fixed trusted Home qualification scopes.

  Callers name their application closure and digest domain explicitly. The
  module owns no process, never accepts an external application/plugin
  name and never turns a checksum into admission authority. Each retained BEAM
  file is SHA-256 bound; OTP's code checksum only detects loaded/file-code drift.
  Old code, incomplete metadata and unavailable artifacts fail closed. Native
  libraries, ERTS/OS qualification and coordinated upgrades remain separate.

  A bounded process-local memo reuses parsed file-code checksums only after a
  fresh complete-byte SHA-256 match. It retains no artifact bytes or authority.
  Every pass still reads the retained file, checks old code and compares the
  current loaded checksum; metadata and the full manifest remain freshly bound.
  """

  @max_applications 4
  @max_modules 512
  @max_artifact_bytes 16_777_216
  @checksum_cache_key {__MODULE__, :file_code_checksums}
  @max_cached_modules @max_applications * @max_modules

  @spec manifest([atom()]) :: {:ok, [map()]} | {:error, :runtime_artifact_unavailable}
  def manifest(applications)
      when is_list(applications) and length(applications) in 1..@max_applications do
    if Enum.all?(applications, &is_atom/1) and Enum.uniq(applications) == applications do
      collect_applications(applications)
    else
      {:error, :runtime_artifact_unavailable}
    end
  end

  def manifest(_applications), do: {:error, :runtime_artifact_unavailable}

  @spec digest([atom()], String.t()) ::
          {:ok, String.t()} | {:error, :runtime_artifact_unavailable}
  def digest(applications, domain) when is_binary(domain) and byte_size(domain) in 1..128 do
    with {:ok, manifest} <- manifest(applications) do
      {:ok, term_digest({domain, manifest})}
    end
  end

  def digest(_applications, _domain), do: {:error, :runtime_artifact_unavailable}

  defp collect_applications(applications) do
    Enum.reduce_while(applications, {:ok, []}, fn application, {:ok, acc} ->
      with result when result in [:ok, {:error, {:already_loaded, application}}] <-
             Application.load(application),
           modules when is_list(modules) and length(modules) in 1..@max_modules <-
             Application.spec(application, :modules),
           true <-
             Enum.all?(modules, &is_atom/1) and
               Enum.uniq(modules) == modules,
           version when is_list(version) and length(version) in 1..128 <-
             Application.spec(application, :vsn),
           true <- Enum.all?(version, &(is_integer(&1) and &1 in 32..126)),
           {:ok, digests} <- module_digests(Enum.sort(modules)) do
        {:cont, {:ok, [%{application: application, version: version, modules: digests} | acc]}}
      else
        _ -> {:halt, {:error, :runtime_artifact_unavailable}}
      end
    end)
    |> case do
      {:ok, manifest} -> {:ok, Enum.reverse(manifest)}
      error -> error
    end
  end

  defp module_digests(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      with {:module, ^module} <- Code.ensure_loaded(module),
           false <- :erlang.check_old_code(module),
           {^module, bytes, _path}
           when is_binary(bytes) and byte_size(bytes) in 1..@max_artifact_bytes <-
             :code.get_object_code(module),
           digest = term_digest(bytes),
           {:ok, checksum} <- file_code_checksum(module, bytes, digest),
           ^checksum <- :erlang.get_module_info(module, :md5) do
        {:cont, {:ok, [{module, digest} | acc]}}
      else
        _ -> {:halt, {:error, :runtime_artifact_unavailable}}
      end
    end)
    |> case do
      {:ok, digests} -> {:ok, Enum.reverse(digests)}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :runtime_artifact_unavailable}
  end

  defp file_code_checksum(module, bytes, digest) do
    cache = Process.get(@checksum_cache_key, %{})
    cache = if is_map(cache) and map_size(cache) <= @max_cached_modules, do: cache, else: %{}

    case Map.get(cache, module) do
      {^digest, checksum} when is_binary(checksum) and byte_size(checksum) == 16 ->
        {:ok, checksum}

      _ ->
        case :beam_lib.md5(bytes) do
          {:ok, {^module, checksum}} ->
            cache = if map_size(cache) < @max_cached_modules, do: cache, else: %{}
            Process.put(@checksum_cache_key, Map.put(cache, module, {digest, checksum}))
            {:ok, checksum}

          _ ->
            {:error, :runtime_artifact_unavailable}
        end
    end
  end

  # Preserve the existing LIFX v2 term-encoding identity. This is deliberately
  # not a new raw-file digest convention under an unchanged caller domain.
  defp term_digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
