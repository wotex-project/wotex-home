defmodule Woh.Tool.LinuxUpdateJournal do
  @moduledoc false
  alias Woh.Tool.{
    LinuxInstallFiles,
    LinuxInstallMaintenance,
    LinuxServicePackage,
    LinuxUpdateRecords
  }

  alias WotexHome.Id

  @maximum 9_223_372_036_854_775_807
  @capacity 16
  @limit 65_536
  @phases ~w(planned staged begin_recorded maintenance_active fenced stopped configuration_ready target_running selected complete)
  @identity_keys ~w(source_revision artifact_id bootstrap_sha256 inventory_sha256)
  @journal_keys ~w(schema_version scope owner_sha256 initial_release generation updates)
  @intent_keys ~w(nonce source target original_main_pid phase maintenance)
  @begin_keys ~w(principal_id authority_epoch operation_id expected_revision begin_revision)
  @owner_keys ~w(schema_version scope installation_id source_revision artifact_id bootstrap_sha256 profile account_id configuration)

  # Administrative progress is not a Store receipt or permission to stop/start.
  # The coordinator must join live payload/process/barrier evidence at each
  # effect boundary. Credentials never enter this closed record shape.
  def new(owner_bytes, initial) do
    with true <- identity?(initial),
         {:ok, owner} <- json(owner_bytes),
         true <- owner?(owner, initial) do
      {:ok,
       %{
         "schema_version" => 1,
         "scope" => "linux_release_update_journal",
         "owner_sha256" => LinuxInstallFiles.digest(owner_bytes),
         "initial_release" => initial,
         "generation" => 0,
         "updates" => []
       }}
    else
      _ -> error()
    end
  end

  def prepare(journal, nonce, source, target, main_pid) do
    with true <- valid?(journal),
         true <- hex?(nonce, 64) and identity?(source) and identity?(target),
         true <- source["artifact_id"] != target["artifact_id"] and pid?(main_pid) do
      original = %{
        "nonce" => nonce,
        "source" => source,
        "target" => target,
        "original_main_pid" => main_pid,
        "phase" => "planned",
        "maintenance" => nil
      }

      case Enum.find(journal["updates"], &(&1["nonce"] == nonce)) do
        nil ->
          previous = List.last(journal["updates"])

          if length(journal["updates"]) < @capacity and
               (previous == nil or previous["phase"] == "complete") and
               source == if(previous, do: previous["target"], else: journal["initial_release"]) do
            updated = %{
              journal
              | "updates" => journal["updates"] ++ [original],
                "generation" => journal["generation"] + 1
            }

            checked(updated)
          else
            error()
          end

        retained ->
          if Map.take(retained, ~w(nonce source target original_main_pid)) ==
               Map.take(original, ~w(nonce source target original_main_pid)),
             do: {:ok, journal},
             else: error()
      end
    else
      _ -> error()
    end
  end

  def advance(journal, nonce, phase) do
    change(journal, nonce, fn intent ->
      current = Enum.find_index(@phases, &(&1 == intent["phase"]))
      next = Enum.at(@phases, current + 1)

      cond do
        phase == intent["phase"] ->
          {:ok, intent}

        phase == next and phase not in ~w(begin_recorded maintenance_active) ->
          {:ok, %{intent | "phase" => phase}}

        true ->
          error()
      end
    end)
  end

  def record_begin(journal, nonce, status) do
    change(journal, nonce, fn intent ->
      response = %{"api_version" => 1, "outcome" => "ok", "maintenance_update_status" => status}

      with "staged" <- intent["phase"],
           {:ok, ^status} <-
             LinuxInstallMaintenance.decode_response(response, %{
               "operation" => "maintenance_update_status"
             }),
           true <-
             status["store_schema_version"] == 27 and status["writable"] and
               status["update_fence_enabled"] and status["state"] == "normal" and
               status["store_revision"] < @maximum do
        {:ok,
         %{
           intent
           | "phase" => "begin_recorded",
             "maintenance" => %{
               "principal_id" => status["principal_id"],
               "authority_epoch" => status["authority_epoch"],
               "operation_id" => "update:" <> nonce,
               "expected_revision" => status["store_revision"],
               "begin_revision" => nil
             }
         }}
      else
        _ -> error()
      end
    end)
  end

  def accept_begin(journal, nonce, receipt) do
    change(journal, nonce, fn intent ->
      original = intent["maintenance"]

      with "begin_recorded" <- intent["phase"],
           request = begin_request(original),
           {:ok, ^receipt} <-
             LinuxInstallMaintenance.decode_response(
               %{"api_version" => 1, "outcome" => "ok", "maintenance_receipt" => receipt},
               request
             ),
           true <- receipt["principal_id"] == original["principal_id"] do
        {:ok,
         %{
           intent
           | "phase" => "maintenance_active",
             "maintenance" => Map.put(original, "begin_revision", receipt["begin_revision"])
         }}
      else
        _ -> error()
      end
    end)
  end

  # A lost reply uses these original arguments, even after the Store revision
  # moves. Lookup must remain principal-private and is not live-barrier proof.
  def begin_commands(journal, nonce) do
    with true <- valid?(journal),
         %{"maintenance" => original} when is_map(original) <-
           Enum.find(journal["updates"], &(&1["nonce"] == nonce)) do
      epoch = Integer.to_string(original["authority_epoch"])
      operation = original["operation_id"]

      {:ok,
       %{
         lookup: ["maintenance-operation-status", epoch, operation],
         retry: ["maintenance-begin", epoch, operation, to_string(original["expected_revision"])]
       }}
    else
      _ -> error()
    end
  end

  def encode(journal) do
    if valid?(journal) do
      bytes = JSON.encode!(journal) <> "\n"
      if byte_size(bytes) <= @limit, do: {:ok, bytes}, else: error()
    else
      error()
    end
  end

  def decode(bytes, owner_bytes) do
    with {:ok, journal} <- json(bytes),
         true <- valid?(journal),
         true <- journal["owner_sha256"] == LinuxInstallFiles.digest(owner_bytes),
         {:ok, _} <- new(owner_bytes, journal["initial_release"]) do
      {:ok, journal}
    else
      _ -> error()
    end
  end

  def load(base, owner_bytes, tool \\ LinuxInstallFiles.packaged_tool()) do
    with {:ok, bytes} <- LinuxUpdateRecords.read(base, owner_bytes, "update-journal.json", tool),
         {:ok, journal} <- decode(bytes, owner_bytes) do
      {:ok, journal, bytes}
    else
      _ -> error()
    end
  end

  def persist(
        base,
        owner_bytes,
        journal,
        previous_bytes \\ nil,
        tool \\ LinuxInstallFiles.packaged_tool()
      ) do
    with {:ok, bytes} <- encode(journal),
         {:ok, ^journal} <- decode(bytes, owner_bytes),
         true <- successor?(journal, previous_bytes, owner_bytes),
         {:ok, ^bytes} <-
           LinuxUpdateRecords.write(
             base,
             owner_bytes,
             "update-journal.json",
             bytes,
             previous_bytes,
             tool
           ) do
      {:ok, bytes}
    else
      _ -> error()
    end
  end

  defp successor?(journal, nil, _owner), do: journal["generation"] == 0

  defp successor?(journal, bytes, owner) do
    with {:ok, previous} <- decode(bytes, owner),
         true <-
           Map.drop(journal, ~w(generation updates)) ==
             Map.drop(previous, ~w(generation updates)),
         true <- journal["generation"] == previous["generation"] + 1 do
      old = previous["updates"]
      new = journal["updates"]

      cond do
        length(new) == length(old) + 1 ->
          Enum.take(new, length(old)) == old and List.last(new)["phase"] == "planned"

        length(new) == length(old) and new != [] ->
          Enum.drop(new, -1) == Enum.drop(old, -1) and
            intent_successor?(List.last(old), List.last(new))

        true ->
          false
      end
    else
      _ -> false
    end
  end

  defp intent_successor?(old, new) do
    immutable = ~w(nonce source target original_main_pid)
    a = Enum.find_index(@phases, &(&1 == old["phase"]))
    b = Enum.find_index(@phases, &(&1 == new["phase"]))

    Map.take(old, immutable) == Map.take(new, immutable) and b == a + 1 and
      case new["phase"] do
        "begin_recorded" ->
          old["maintenance"] == nil

        "maintenance_active" ->
          Map.delete(old["maintenance"], "begin_revision") ==
            Map.delete(new["maintenance"], "begin_revision")

        _ ->
          old["maintenance"] == new["maintenance"]
      end
  end

  defp change(journal, nonce, fun) do
    with true <- valid?(journal),
         %{"nonce" => ^nonce} = intent <- List.last(journal["updates"]),
         {:ok, updated} <- fun.(intent) do
      if updated == intent do
        {:ok, journal}
      else
        checked(%{
          journal
          | "updates" => Enum.drop(journal["updates"], -1) ++ [updated],
            "generation" => journal["generation"] + 1
        })
      end
    else
      _ -> error()
    end
  end

  defp valid?(journal) do
    keys?(journal, @journal_keys) and journal["schema_version"] === 1 and
      journal["scope"] == "linux_release_update_journal" and
      hex?(journal["owner_sha256"], 64) and identity?(journal["initial_release"]) and
      is_list(journal["updates"]) and length(journal["updates"]) <= @capacity and
      Enum.all?(journal["updates"], &intent?/1) and linked?(journal) and
      integer?(journal["generation"]) and
      journal["generation"] ==
        Enum.reduce(journal["updates"], 0, fn intent, total ->
          total + 1 + Enum.find_index(@phases, &(&1 == intent["phase"]))
        end)
  end

  defp linked?(journal) do
    updates = journal["updates"]
    nonces = Enum.map(updates, & &1["nonce"])

    length(Enum.uniq(nonces)) == length(nonces) and
      Enum.reduce_while(updates, journal["initial_release"], fn intent, source ->
        if source == intent["source"], do: {:cont, intent["target"]}, else: {:halt, false}
      end) != false and
      Enum.all?(Enum.drop(updates, -1), &(&1["phase"] == "complete"))
  end

  defp intent?(intent) do
    keys?(intent, @intent_keys) and hex?(intent["nonce"], 64) and
      identity?(intent["source"]) and identity?(intent["target"]) and
      intent["source"]["artifact_id"] != intent["target"]["artifact_id"] and
      pid?(intent["original_main_pid"]) and intent["phase"] in @phases and
      maintenance?(intent)
  end

  defp maintenance?(%{"phase" => phase, "maintenance" => nil}),
    do: phase in ~w(planned staged)

  defp maintenance?(%{"phase" => phase, "maintenance" => begin, "nonce" => nonce}) do
    keys?(begin, @begin_keys) and Id.valid?(begin["principal_id"]) and
      positive?(begin["authority_epoch"]) and begin["operation_id"] == "update:" <> nonce and
      integer?(begin["expected_revision"]) and begin["expected_revision"] < @maximum and
      if phase == "begin_recorded" do
        begin["begin_revision"] == nil
      else
        phase in Enum.drop(@phases, 3) and positive?(begin["begin_revision"]) and
          begin["begin_revision"] > begin["expected_revision"]
      end
  end

  defp identity?(identity) do
    keys?(identity, @identity_keys) and hex?(identity["source_revision"], 40) and
      Enum.all?(~w(artifact_id bootstrap_sha256 inventory_sha256), &hex?(identity[&1], 64))
  end

  defp owner?(owner, initial) do
    keys?(owner, @owner_keys) and owner["schema_version"] === 1 and
      owner["scope"] == "linux_initial_installation" and hex?(owner["installation_id"], 64) and
      owner["source_revision"] == initial["source_revision"] and
      owner["artifact_id"] == initial["artifact_id"] and
      owner["bootstrap_sha256"] == initial["bootstrap_sha256"] and
      owner["profile"] == LinuxServicePackage.profile() and
      is_integer(owner["account_id"]) and owner["account_id"] in 100..999 and
      owner["configuration"] ==
        Map.new(LinuxServicePackage.files(initial["artifact_id"], 2), fn {path, bytes} ->
          {"/" <> path, LinuxInstallFiles.digest(bytes)}
        end)
  end

  defp json(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@limit do
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
  defp keys?(value, keys), do: is_map(value) and MapSet.new(Map.keys(value)) == MapSet.new(keys)

  defp hex?(value, size),
    do:
      is_binary(value) and byte_size(value) == size and
        Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp integer?(n), do: is_integer(n) and n in 0..@maximum
  defp positive?(n), do: integer?(n) and n > 0
  defp pid?(n), do: is_integer(n) and n in 2..2_147_483_647
  defp checked(journal), do: if(valid?(journal), do: {:ok, journal}, else: error())

  defp begin_request(original),
    do:
      Map.merge(Map.take(original, ~w(authority_epoch operation_id expected_revision)), %{
        "operation" => "begin_maintenance"
      })

  defp error, do: {:error, :invalid_update_journal}
end
