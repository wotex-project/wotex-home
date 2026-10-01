defmodule WotexHome.Durable.Store.Journal do
  @moduledoc """
  Shared revision and journal primitives for the single Store writer.

  This module receives the Store-owned SQLite handle only for one synchronous
  call. It neither opens nor closes a connection and does not begin or commit a
  transaction. Callers use it only inside the Store's active transaction.
  """

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @max_i64 9_223_372_036_854_775_807

  @doc "Returns the next global revision without writing it."
  @spec next_revision(term()) :: {:ok, pos_integer()} | {:error, term()}
  def next_revision(db) do
    case query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      {:ok, [[revision]]} when is_integer(revision) and revision >= 0 and revision < @max_i64 ->
        {:ok, revision + 1}

      {:ok, _} ->
        {:error, :revision_exhausted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Appends an authority event and advances the global revision."
  @spec authority_event(term(), pos_integer(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def authority_event(db, revision, event_type, entity_id)
      when is_integer(revision) and revision in 1..@max_i64 and is_binary(event_type) and
             is_binary(entity_id) do
    with {:ok, []} <-
           query(db, "INSERT INTO authority_journal VALUES (?, ?, ?)", [
             revision,
             event_type,
             entity_id
           ]),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]),
         {:ok, [[1]]} <- query(db, "SELECT changes()") do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :revision_unavailable}
    end
  end

  def authority_event(_db, _revision, _event_type, _entity_id),
    do: {:error, :invalid_authority_event}

  @doc "Appends a request transition and advances the global revision."
  @spec request_event(
          term(),
          pos_integer(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t() | nil
        ) :: :ok | {:error, term()}
  def request_event(db, revision, principal_id, epoch, operation_id, state, reason)
      when is_integer(revision) and revision in 1..@max_i64 and is_binary(principal_id) and
             is_integer(epoch) and epoch >= 0 and epoch <= @max_i64 and is_binary(operation_id) and
             is_binary(state) and (is_nil(reason) or is_binary(reason)) do
    with {:ok, []} <-
           query(db, "INSERT INTO request_journal VALUES (?, ?, ?, ?, ?, ?)", [
             revision,
             principal_id,
             epoch,
             operation_id,
             state,
             reason
           ]),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]),
         {:ok, [[1]]} <- query(db, "SELECT changes()") do
      :ok
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :revision_unavailable}
    end
  end

  def request_event(_db, _revision, _principal_id, _epoch, _operation_id, _state, _reason),
    do: {:error, :invalid_request_event}
end
