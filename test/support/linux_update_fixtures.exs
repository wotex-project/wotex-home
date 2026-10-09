defmodule WotexHome.LinuxUpdateFixtures do
  @moduledoc false
  alias Woh.Tool.{LinuxInstallFiles, LinuxServicePackage, LinuxUpdateJournal}

  def identity(number),
    do: %{
      "source_revision" => hex(number, 40),
      "artifact_id" => hex(number, 64),
      "bootstrap_sha256" => hex(number + 100, 64),
      "inventory_sha256" => hex(number + 200, 64)
    }

  def nonce(number \\ 1), do: hex(number + 300, 64)

  def owner(identity),
    do:
      JSON.encode!(%{
        "schema_version" => 1,
        "scope" => "linux_initial_installation",
        "installation_id" => hex(9, 64),
        "source_revision" => identity["source_revision"],
        "artifact_id" => identity["artifact_id"],
        "bootstrap_sha256" => identity["bootstrap_sha256"],
        "profile" => LinuxServicePackage.profile(),
        "account_id" => 211,
        "configuration" => configuration(identity["artifact_id"])
      }) <> "\n"

  def configuration(artifact),
    do:
      Map.new(LinuxServicePackage.files(artifact, 2), fn {path, bytes} ->
        {"/" <> path, LinuxInstallFiles.digest(bytes)}
      end)

  def running(journal, source, target, nonce, checkpoint \\ &Function.identity/1) do
    # Administrative phase fixtures perform no service or maintenance operation.
    {:ok, journal} = LinuxUpdateJournal.prepare(journal, nonce, source, target, 123)
    journal = checkpoint.(journal)
    {:ok, journal} = LinuxUpdateJournal.advance(journal, nonce, "staged")
    journal = checkpoint.(journal)

    {:ok, journal} =
      LinuxUpdateJournal.record_begin(journal, nonce, %{
        "principal_id" => "maintainer:selection-fixture",
        "authority_epoch" => 1,
        "store_revision" => 4,
        "rule_generation" => 0,
        "begin_revision" => 0,
        "state" => "normal",
        "store_schema_version" => 27,
        "writable" => true,
        "update_fence_enabled" => true
      })

    journal = checkpoint.(journal)

    {:ok, journal} =
      LinuxUpdateJournal.accept_begin(journal, nonce, %{
        "principal_id" => "maintainer:selection-fixture",
        "authority_epoch" => 1,
        "operation_id" => "update:" <> nonce,
        "action" => "begin",
        "begin_revision" => 6,
        "revision" => 6,
        "rule_generation" => 1,
        "affected_requests" => 0,
        "unknown_outcomes" => 0,
        "state" => "maintenance"
      })

    journal = checkpoint.(journal)

    Enum.reduce(~w(fenced stopped configuration_ready target_running), journal, fn phase,
                                                                                   journal ->
      {:ok, updated} = LinuxUpdateJournal.advance(journal, nonce, phase)
      checkpoint.(updated)
    end)
  end

  def complete(journal, nonce) do
    {:ok, journal} = LinuxUpdateJournal.advance(journal, nonce, "selected")
    {:ok, journal} = LinuxUpdateJournal.advance(journal, nonce, "complete")
    journal
  end

  defp hex(n, size),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")
end
