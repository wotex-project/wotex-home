defmodule WotexHome.Durable.Store.FactReadModel do
  @moduledoc """
  Authenticated reported facts using the Store's own receipt epoch and clock.

  This synchronous borrowed-handle projection performs no writes or I/O. It
  authenticates the current review/read scope and binds every retained current
  report to its original journal row. Missing, old-boot, untimed, expired or lab
  reports remain unknown. Receipt age is not source age or physical causation.
  This is a preview input snapshot, never admission or dispatch authority.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, ObservationCodec}
  alias WotexHome.Rules.Fact
  alias WotexHome.Semantics.{Capability, Observation, Thing}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @max_i64 9_223_372_036_854_775_807
  @fields ~w(profile_ref evidence_ref source_epoch source_sequence boot_epoch source_time_utc_ms received_time_utc_ms received_monotonic_ms quality trust value_kind value_a value_b revision received_store_boot_epoch received_store_monotonic_ms)
  @select "SELECT " <>
            Enum.map_join(@fields, ", ", &("c." <> &1)) <>
            ", " <>
            Enum.map_join(@fields, ", ", &("j." <> &1)) <>
            ", j.event_type, j.thing_id, j.capability_key " <>
            "FROM observation_current c LEFT JOIN journal j ON j.revision=c.revision " <>
            "WHERE c.thing_id=? AND c.capability_key=?"

  def read(db, credential, fact_ids, {epoch, now_ms}) do
    with :ok <- inputs(fact_ids, epoch, now_ms),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         :ok <- permission(permissions),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         :ok <- scope(fact_ids, grants),
         {:ok, [[revision, authority_epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         true <- integer?(revision) and integer?(authority_epoch) and authority_epoch >= 1,
         {:ok, projection} <- project(db, Enum.sort(fact_ids), epoch, now_ms) do
      {:ok,
       Map.merge(projection, %{
         profile: "home-reported-facts-v1",
         scope: :reported_fact_preview_only,
         store_revision: revision,
         authority_epoch: authority_epoch,
         store_boot_epoch: epoch,
         sampled_ms: now_ms
       })}
    else
      false -> {:error, :corrupt_value}
      error -> error
    end
  end

  @doc "Store-only projection after an authority domain validates its pinned scope."
  def project(db, fact_ids, epoch, now_ms)
      when is_list(fact_ids) and length(fact_ids) <= 32 do
    if Enum.all?(fact_ids, &Fact.valid?/1) and Enum.uniq(fact_ids) == fact_ids and
         WotexHome.Id.valid?(epoch) and integer?(now_ms) do
      project_valid(db, fact_ids, epoch, now_ms)
    else
      {:error, :invalid_fact_scope}
    end
  end

  def project(_db, _facts, _epoch, _ms), do: {:error, :invalid_fact_scope}

  defp project_valid(db, fact_ids, epoch, now_ms) do
    Enum.reduce_while(
      fact_ids,
      {:ok, %{facts: %{}, report_revisions: %{}, resource_revisions: %{}}},
      fn {id, key} = fact, {:ok, projection} ->
        with {:ok, thing, resource} <- Access.enrolled_thing(db, id),
             {:ok, %Capability{} = capability} <- Thing.capability(thing, key),
             true <- Capability.supports?(capability, "read"),
             {:ok, value, report} <- report(db, id, key, capability, epoch, now_ms) do
          {:cont,
           {:ok,
            %{
              projection
              | facts: Map.put(projection.facts, fact, value),
                report_revisions: Map.put(projection.report_revisions, fact, report),
                resource_revisions: Map.put(projection.resource_revisions, id, resource)
            }}}
        else
          :error -> {:halt, {:error, :unsupported_fact}}
          false -> {:halt, {:error, :unsupported_fact}}
          error -> {:halt, error}
        end
      end
    )
  end

  defp report(db, id, key, capability, epoch, now_ms) do
    case query(db, @select, [id, key]) do
      {:ok, []} ->
        {:ok, :unknown, nil}

      {:ok, [row]} when length(row) == 35 ->
        {current, rest} = Enum.split(row, 16)
        {journal, identity} = Enum.split(rest, 16)
        {fields, clock} = Enum.split(current, 14)

        with true <- current == journal and identity == ["observation", id, key],
             true <- valid_clock?(clock),
             {:ok, observation, revision} <- ObservationCodec.decode_current(id, key, fields),
             true <- revision >= 1,
             true <-
               Observation.valid?(observation, capability) and
                 Enum.take(fields, 2) == [capability.profile_ref, capability.evidence_ref] do
          value =
            if current?(clock, observation, capability, epoch, now_ms),
              do: {:known, observation.value},
              else: :unknown

          {:ok, value, revision}
        else
          _ -> {:error, :corrupt_value}
        end

      {:error, _reason} ->
        {:error, :store_unavailable}

      _ ->
        {:error, :corrupt_value}
    end
  end

  defp current?([epoch, received_ms], observation, capability, epoch, now_ms)
       when is_integer(received_ms),
       do:
         observation.quality == "reported" and observation.trust != "synthetic_lab" and
           now_ms >= received_ms and now_ms - received_ms <= capability.freshness_ms

  defp current?(_clock, _observation, _capability, _epoch, _now), do: false

  defp valid_clock?([nil, nil]), do: true
  defp valid_clock?([epoch, ms]), do: WotexHome.Id.valid?(epoch) and integer?(ms)
  defp valid_clock?(_clock), do: false

  defp valid_inputs?(facts, epoch, now_ms) when is_list(facts) and length(facts) in 1..32,
    do:
      Enum.all?(facts, &Fact.valid?/1) and Enum.uniq(facts) == facts and
        WotexHome.Id.valid?(epoch) and integer?(now_ms)

  defp valid_inputs?(_facts, _epoch, _now_ms), do: false

  defp inputs(facts, epoch, now_ms),
    do: if(valid_inputs?(facts, epoch, now_ms), do: :ok, else: {:error, :invalid_fact_scope})

  defp permission(permissions),
    do:
      if(
        "rule:review" in permissions and
          Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
        do: :ok,
        else: {:error, :permission_denied}
      )

  defp scope(facts, grants),
    do:
      if(Enum.all?(facts, fn {id, _key} -> MapSet.member?(grants, id) end),
        do: :ok,
        else: {:error, :permission_denied}
      )

  defp integer?(value), do: is_integer(value) and value in 0..@max_i64
end
