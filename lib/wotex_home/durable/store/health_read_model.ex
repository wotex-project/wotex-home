defmodule WotexHome.Durable.Store.HealthReadModel do
  @moduledoc """
  Redacted operational projection for the single durable writer.

  The caller supplies the owned connection and non-secret runtime flags for
  one synchronous read. This module retains neither.
  """

  import WotexHome.Durable.Store.SQL, only: [query: 2]

  @spec read(Exqlite.Sqlite3.db(), pos_integer(), boolean()) ::
          {:ok, map()} | {:error, :store_unavailable}
  def read(db, receipt_limit, writable)
      when is_integer(receipt_limit) and receipt_limit >= 1 and is_boolean(writable) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[rule_generation]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         {:ok, [[held_count]]} <-
           query(db, "SELECT COUNT(*) FROM request_outbox WHERE state = 'held'"),
         {:ok, [[queued_count]]} <-
           query(db, "SELECT COUNT(*) FROM request_execution WHERE state = 'queued'"),
         {:ok, [[claimed_count]]} <-
           query(db, "SELECT COUNT(*) FROM request_execution WHERE state = 'claimed'"),
         {:ok, [[unknown_count]]} <-
           query(db, "SELECT COUNT(*) FROM request_execution WHERE state = 'outcome_unknown'"),
         {:ok, [[receipt_count]]} <- query(db, "SELECT COUNT(*) FROM request_receipts"),
         {:ok, [[thing_count]]} <-
           query(db, "SELECT COUNT(*) FROM enrolled_things WHERE status = 'active'"),
         {:ok, [[principal_count]]} <-
           query(db, "SELECT COUNT(*) FROM principals WHERE status = 'active'"),
         true <-
           is_integer(revision) and revision >= 0 and is_integer(epoch) and epoch >= 1 and
             is_integer(rule_generation) and rule_generation >= 0 and
             Enum.all?(
               [
                 held_count,
                 queued_count,
                 claimed_count,
                 unknown_count,
                 receipt_count,
                 thing_count,
                 principal_count
               ],
               &is_integer/1
             ) do
      {:ok,
       %{
         store_revision: revision,
         authority_epoch: epoch,
         rule_generation: rule_generation,
         held_requests: held_count,
         queued_requests: queued_count,
         claimed_requests: claimed_count,
         unknown_outcomes: unknown_count,
         retained_receipts: receipt_count,
         receipt_capacity: receipt_limit,
         active_things: thing_count,
         active_principals: principal_count,
         writable: writable,
         dispatch_enabled: false
       }}
    else
      _ -> {:error, :store_unavailable}
    end
  end

  def read(_db, _receipt_limit, _writable), do: {:error, :store_unavailable}
end
