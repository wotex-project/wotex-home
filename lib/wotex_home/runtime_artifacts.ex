defmodule WotexHome.RuntimeArtifacts do
  @moduledoc """
  Inventories retained BEAM artifacts for trusted Home runtime checks.

  `manifest/1` accepts an explicit list of up to eleven distinct application
  atoms and returns `{:ok, manifest}` with application versions and module
  digests. `digest/2` binds that inventory to the supplied digest domain.
  Invalid inputs, incomplete metadata, unavailable artifacts, old code or
  loaded/file-code disagreement return `{:error, :runtime_artifact_unavailable}`.
  Callers own the trusted application selection; these APIs are not an
  external application or plugin admission boundary.

  Temporal proofs use the fixed ten-application calculation cohort, including
  its producer dependencies. The internal Store guard adds `:wotex_udp`, forming
  an eleven-application inventory. It may reuse that complete inventory within
  one guard invocation, then freshly compares it before the final unscoped
  execution guards. Drift leaves the callback result unpublished for the
  Store's refusal or withdrawal path; no inventory survives the invocation.

  Complete retained BEAM bytes are SHA-256 bound. A bounded process-local memo
  reuses parsed code checksums only after a fresh complete-byte digest match;
  loaded-code checks and application metadata remain fresh. Ordinary-directory
  lookup uses a bounded filename index and at most four temporary readers.
  Unsupported layouts retain OTP's sequential artifact lookup.

  An inventory establishes compiled-code correspondence, not admission
  authority or a durable receipt. Native libraries, ERTS/OS qualification,
  coordinated upgrades and physical effects require separate evidence.
  """

  @max_applications 11
  @max_modules 1024
  @max_artifact_bytes 16_777_216
  @checksum_cache_key {__MODULE__, :file_code_checksums}
  @max_cached_modules @max_applications * @max_modules
  @max_paths 256
  @max_directory_entries 16_384
  @readers 4
  @reader_timeout_ms 5_000
  @read_chunk_bytes 65_536
  @guard_key {__MODULE__, :guard_inventory}
  @temporal_applications [
    :wotex_home,
    :wotex_routines,
    :wotex_continuum,
    :wotex,
    :ex_booking,
    :decimal,
    :jason,
    :ex_json_schema,
    :nimble_options,
    :tz
  ]
  @guard_applications @temporal_applications ++ [:wotex_udp]

  @doc false
  def temporal_applications, do: @temporal_applications

  @doc false
  def with_guard(callback) when is_function(callback, 0) do
    if Process.get(@guard_key) == nil do
      with {:ok, inventory} <- collect_applications(@guard_applications) do
        token = make_ref()
        Process.put(@guard_key, {:open, token, inventory})

        try do
          result = callback.()

          case finish_guard() do
            :ok ->
              if Process.get(@guard_key) == {:closed, token, :ok},
                do: {:ok, result},
                else: unavailable()

            error ->
              {:error, elem(error, 1), result}
          end
        after
          Process.delete(@guard_key)
        end
      end
    else
      unavailable()
    end
  end

  def with_guard(_), do: unavailable()

  @doc false
  def finish_guard do
    case Process.get(@guard_key) do
      {:open, token, inventory} ->
        result =
          case collect_applications(@guard_applications) do
            {:ok, ^inventory} -> :ok
            _ -> unavailable()
          end

        Process.put(@guard_key, {:closed, token, result})
        result

      {:closed, _token, result} ->
        result

      nil ->
        :ok

      _ ->
        unavailable()
    end
  end

  @spec manifest([atom()]) :: {:ok, [map()]} | {:error, :runtime_artifact_unavailable}
  def manifest(applications)
      when is_list(applications) and length(applications) in 1..@max_applications do
    if Enum.all?(applications, &is_atom/1) and Enum.uniq(applications) == applications do
      case Process.get(@guard_key) do
        {:open, _token, inventory} ->
          if Enum.all?(applications, &(&1 in @guard_applications)),
            do:
              {:ok,
               Enum.map(applications, fn app -> Enum.find(inventory, &(&1.application == app)) end)},
            else: collect_applications(applications)

        _ ->
          collect_applications(applications)
      end
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

  defp module_digests(modules) when length(modules) <= 8,
    do: module_digests_sequential(modules)

  defp module_digests(modules) do
    paths = :code.get_path()
    cwd = File.cwd!()

    result =
      case file_index(paths, cwd, modules) do
        {:ok, index} -> parallel_digests(modules, index)
        :fallback -> module_digests_sequential(modules)
        _ -> unavailable()
      end

    if paths == :code.get_path() and {:ok, cwd} == File.cwd(),
      do: result,
      else: unavailable()
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp file_index(paths, cwd, modules) when length(paths) <= @max_paths do
    wanted = MapSet.new(Enum.map(modules, &(Atom.to_charlist(&1) ++ ~c".beam")))

    Enum.reduce_while(paths, {:searching, %{}, wanted}, fn path, {:searching, found, needed} ->
      case :file.list_dir(path) do
        {:ok, files} when length(files) <= @max_directory_entries ->
          directory = :filename.absname(List.to_string(path), cwd)

          {found, needed} =
            Enum.reduce(files, {found, needed}, fn name, {found, needed} ->
              if MapSet.member?(needed, name) do
                filename = List.to_string(name)
                absolute = :filename.join(directory, filename)
                {Map.put(found, filename, absolute), MapSet.delete(needed, name)}
              else
                {found, needed}
              end
            end)

          if MapSet.size(needed) == 0,
            do: {:halt, {:ok, found}},
            else: {:cont, {:searching, found, needed}}

        {:error, :enoent} ->
          {:cont, {:searching, found, needed}}

        _ ->
          # Archives, inaccessible directories and oversized listings use OTP's
          # existing lookup semantics rather than skipping a preceding source.
          {:halt, :fallback}
      end
    end)
  end

  defp file_index(_, _, _), do: :fallback

  defp parallel_digests(modules, index) do
    memo = checksum_cache()
    chunk_size = div(length(modules) + @readers - 1, @readers)

    modules
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(fn chunk ->
      files = Enum.map(chunk, &{&1, Map.fetch!(index, Atom.to_string(&1) <> ".beam")})
      {files, Map.take(memo, chunk)}
    end)
    |> Task.async_stream(
      fn {files, parsed} ->
        Process.put(@checksum_cache_key, parsed)
        {module_digests_files(files), checksum_cache()}
      end,
      max_concurrency: @readers,
      ordered: true,
      timeout: @reader_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, [], memo}, fn
      {:ok, {{:ok, entries}, parsed}}, {:ok, all, memo} ->
        {:cont, {:ok, all ++ entries, Map.merge(memo, parsed)}}

      _, _ ->
        {:halt, unavailable()}
    end)
    |> case do
      {:ok, entries, parsed} ->
        parsed =
          if map_size(parsed) <= @max_cached_modules,
            do: parsed,
            else: Map.take(parsed, modules)

        Process.put(@checksum_cache_key, parsed)
        {:ok, entries}

      error ->
        error
    end
  end

  defp module_digests_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn {module, path}, {:ok, acc} ->
      case module_digest(module, fn -> read_file(path) end) do
        {:ok, digest} -> {:cont, {:ok, [{module, digest} | acc]}}
        _ -> {:halt, unavailable()}
      end
    end)
    |> ordered_digests()
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp read_file(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          read_complete(file, @max_artifact_bytes, [])
        after
          :file.close(file)
        end

      _ ->
        unavailable()
    end
  end

  defp read_complete(file, remaining, chunks) do
    case :file.read(file, min(@read_chunk_bytes, remaining + 1)) do
      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= remaining ->
        read_complete(file, remaining - byte_size(bytes), [bytes | chunks])

      :eof when chunks != [] ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      _ ->
        unavailable()
    end
  end

  defp module_digests_sequential(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      case module_digest(module, fn ->
             case :code.get_object_code(module) do
               {^module, bytes, _path} -> {:ok, bytes}
               _ -> unavailable()
             end
           end) do
        {:ok, digest} -> {:cont, {:ok, [{module, digest} | acc]}}
        _ -> {:halt, unavailable()}
      end
    end)
    |> ordered_digests()
  end

  defp module_digest(module, read) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         false <- :erlang.check_old_code(module),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) in 1..@max_artifact_bytes <-
           read.(),
         digest = term_digest(bytes),
         {:ok, checksum} <- file_code_checksum(module, bytes, digest),
         ^checksum <- :erlang.get_module_info(module, :md5),
         false <- :erlang.check_old_code(module),
         do: {:ok, digest},
         else: (_ -> unavailable())
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp ordered_digests({:ok, digests}), do: {:ok, Enum.reverse(digests)}
  defp ordered_digests(error), do: error
  defp unavailable, do: {:error, :runtime_artifact_unavailable}

  defp checksum_cache do
    cache = Process.get(@checksum_cache_key, %{})
    if is_map(cache) and map_size(cache) <= @max_cached_modules, do: cache, else: %{}
  end

  defp file_code_checksum(module, bytes, digest) do
    cache = checksum_cache()

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
