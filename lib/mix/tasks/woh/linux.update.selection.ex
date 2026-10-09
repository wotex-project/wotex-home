defmodule Woh.Tool.LinuxUpdateSelection do
  @moduledoc false
  alias Woh.Tool.{LinuxInstallFiles, LinuxServicePackage, LinuxUpdateJournal, LinuxUpdateRecords}

  @keys ~w(schema_version scope owner_sha256 selection_generation release selected_nonce intent_sha256 configuration)
  @identity_keys ~w(source_revision artifact_id bootstrap_sha256 inventory_sha256)

  def new(owner, journal) do
    with :ok <- journal?(journal, owner),
         [] <- journal["updates"] do
      {:ok, record(journal, 0, journal["initial_release"], nil, nil)}
    else
      _ -> error()
    end
  end

  # The coordinator must join live target process/schema/barrier evidence before
  # selection. Administrative phase names alone never authorize service effects.
  def select(selection, journal, nonce) do
    with true <- shape?(selection) and binding?(selection, journal),
         %{"nonce" => ^nonce} = intent <- List.last(journal["updates"]),
         true <- intent["phase"] in ~w(target_running selected complete) do
      generation = length(journal["updates"])
      candidate = record(journal, generation, intent["target"], nonce, intent_digest(intent))

      cond do
        selection == candidate ->
          {:ok, selection}

        selection["selection_generation"] == generation - 1 and
          selection["release"] == intent["source"] and intent["phase"] == "target_running" ->
          {:ok, candidate}

        true ->
          error()
      end
    else
      _ -> error()
    end
  end

  def encode(selection) do
    if shape?(selection), do: {:ok, JSON.encode!(selection) <> "\n"}, else: error()
  end

  def decode(bytes, owner, journal) do
    with :ok <- journal?(journal, owner),
         {:ok, selection} <- json(bytes),
         true <- shape?(selection) and binding?(selection, journal) do
      {:ok, selection}
    else
      _ -> error()
    end
  end

  def load(base, owner, journal, tool \\ LinuxInstallFiles.packaged_tool()) do
    with {:ok, ^journal, _} <- LinuxUpdateJournal.load(base, owner, tool),
         {:ok, bytes} <- LinuxUpdateRecords.read(base, owner, "current-release.json", tool),
         {:ok, selection} <- decode(bytes, owner, journal),
         {:ok, ^journal, _} <- LinuxUpdateJournal.load(base, owner, tool) do
      {:ok, selection, bytes}
    else
      _ -> error()
    end
  end

  def persist(
        base,
        owner,
        journal,
        selection,
        previous \\ nil,
        tool \\ LinuxInstallFiles.packaged_tool()
      ) do
    with {:ok, ^journal, _} <- LinuxUpdateJournal.load(base, owner, tool),
         {:ok, bytes} <- encode(selection),
         {:ok, ^selection} <- decode(bytes, owner, journal),
         true <- successor?(selection, previous, owner, journal),
         {:ok, ^bytes} <-
           LinuxUpdateRecords.write(base, owner, "current-release.json", bytes, previous, tool),
         {:ok, ^journal, _} <- LinuxUpdateJournal.load(base, owner, tool) do
      {:ok, bytes}
    else
      _ -> error()
    end
  end

  defp successor?(selection, nil, owner, journal), do: new(owner, journal) == {:ok, selection}

  defp successor?(selection, bytes, owner, journal) do
    with {:ok, previous} <- decode(bytes, owner, journal),
         %{"nonce" => nonce} <- List.last(journal["updates"]),
         {:ok, ^selection} <- select(previous, journal, nonce) do
      previous != selection
    else
      _ -> false
    end
  end

  defp record(journal, generation, identity, nonce, digest),
    do: %{
      "schema_version" => 1,
      "scope" => "linux_current_release",
      "owner_sha256" => journal["owner_sha256"],
      "selection_generation" => generation,
      "release" => identity,
      "selected_nonce" => nonce,
      "intent_sha256" => digest,
      "configuration" => configuration(identity["artifact_id"])
    }

  defp shape?(selection) do
    keys?(selection, @keys) and selection["schema_version"] === 1 and
      selection["scope"] == "linux_current_release" and hex?(selection["owner_sha256"], 64) and
      is_integer(selection["selection_generation"]) and selection["selection_generation"] in 0..16 and
      identity?(selection["release"]) and
      selection["configuration"] == configuration(selection["release"]["artifact_id"]) and
      if selection["selection_generation"] == 0 do
        selection["selected_nonce"] == nil and selection["intent_sha256"] == nil
      else
        hex?(selection["selected_nonce"], 64) and hex?(selection["intent_sha256"], 64)
      end
  end

  defp binding?(selection, journal) do
    with {:ok, _} <- LinuxUpdateJournal.encode(journal),
         true <- selection["owner_sha256"] == journal["owner_sha256"] do
      updates = journal["updates"]
      count = length(updates)
      generation = selection["selection_generation"]

      allowed =
        case List.last(updates) do
          nil -> [0]
          %{"phase" => "target_running"} -> [count - 1, count]
          %{"phase" => phase} when phase in ["selected", "complete"] -> [count]
          _ -> [count - 1]
        end

      generation in allowed and
        if generation == 0 do
          selection["release"] == journal["initial_release"]
        else
          intent = Enum.at(updates, generation - 1)

          selection["release"] == intent["target"] and
            selection["selected_nonce"] == intent["nonce"] and
            selection["intent_sha256"] == intent_digest(intent)
        end
    else
      _ -> false
    end
  end

  defp intent_digest(intent) do
    begin = intent["maintenance"]
    process = intent["source_process"]
    version = if process, do: "2", else: "1"

    fields =
      [intent["nonce"]] ++
        Enum.map(@identity_keys, &intent["source"][&1]) ++
        Enum.map(@identity_keys, &intent["target"][&1]) ++
        [intent["original_main_pid"]] ++
        if(process,
          do:
            Enum.map(
              ~w(pid account_id start_ticks boot_id cgroup image_sha256 image_device image_inode invocation_id),
              &process[&1]
            ),
          else: []
        ) ++
        Enum.map(
          ~w(principal_id authority_epoch operation_id expected_revision begin_revision),
          &begin[&1]
        )

    LinuxInstallFiles.digest(
      "WOTEX_HOME_UPDATE_SELECTION\t" <>
        version <> "\n" <> Enum.map_join(fields, "\t", &to_string/1) <> "\n"
    )
  end

  defp configuration(artifact),
    do:
      Map.new(LinuxServicePackage.files(artifact, 2), fn {path, bytes} ->
        {"/" <> path, LinuxInstallFiles.digest(bytes)}
      end)

  defp identity?(identity),
    do:
      keys?(identity, @identity_keys) and hex?(identity["source_revision"], 40) and
        Enum.all?(~w(artifact_id bootstrap_sha256 inventory_sha256), &hex?(identity[&1], 64))

  defp keys?(map, keys), do: is_map(map) and MapSet.new(Map.keys(map)) == MapSet.new(keys)

  defp hex?(value, length),
    do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp journal?(journal, owner) do
    with {:ok, bytes} <- LinuxUpdateJournal.encode(journal),
         {:ok, ^journal} <- LinuxUpdateJournal.decode(bytes, owner),
         do: :ok,
         else: (_ -> error())
  end

  defp json(bytes) when is_binary(bytes) and byte_size(bytes) in 1..65_536 do
    {value, nil, ""} =
      JSON.decode(bytes, nil,
        object_push: fn key, value, pairs ->
          if List.keymember?(pairs, key, 0), do: raise(ArgumentError)
          [{key, value} | pairs]
        end
      )

    {:ok, value}
  rescue
    _ -> error()
  end

  defp json(_), do: error()
  defp error, do: {:error, :invalid_current_release}
end
