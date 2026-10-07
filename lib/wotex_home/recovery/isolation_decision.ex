defmodule WotexHome.Recovery.IsolationDecision do
  @moduledoc """
  Closed, bounded signed isolation-decision data for a separately reviewed transfer.

  Signature verification binds an explicitly trusted issuer and its current
  policy to an exact destination review. It does not inspect physical evidence,
  retire a source, clear quarantine, install trust or grant device authority.
  Keys, expected scope and clock confidence come from the trusted host, never
  from the package. There are no default issuers or accepted unknown counters.
  """
  alias WotexHome.Id
  alias WotexHome.LocalAPI.Frame
  alias WotexHome.Profiles.{Artifact, Codec}

  @format "wotex-home.controller-isolation.v1"
  @record "wotex-home.controller-isolation-record.v1"
  @domain "WOH15-controller-isolation-v1\0"
  @fields ~w(format deployment_id source_owner_id destination_owner_id source_epoch retirement_revision archive_digest review_digest runtime_digest challenge_id domain_digest domain_count counter_state counter_state_digest method procedure_ref issuer_id issuer_generation isolation_policy_digest issued_at_utc_ms expires_at_utc_ms)
  @scope_fields ~w(deployment_id source_owner_id destination_owner_id source_epoch retirement_revision archive_digest review_digest runtime_digest challenge_id domain_digest domain_count counter_state counter_state_digest)
  @digests ~w(deployment_id source_owner_id destination_owner_id archive_digest review_digest runtime_digest domain_digest isolation_policy_digest)
  @methods ~w(physical_disconnection qualified_network_isolation device_credential_revocation)
  @max_i64 9_223_372_036_854_775_807
  @max_bytes 8_192
  @max_window_ms 600_000
  @policy_keys [:counter_state, :generation, :method, :policy_digest, :procedure_ref, :public_key]

  @doc "Versioned ordered JSON signed payload; construction establishes no isolation."
  def signing_payload(decision) do
    with :ok <- shape(decision), do: {:ok, @domain <> JSON.encode!(values(decision))}
  end

  @doc "Closed portable package, suitable for private inert custody only."
  def encode(decision, signature) when is_binary(signature) and byte_size(signature) == 64 do
    with :ok <- shape(decision) do
      bytes =
        JSON.encode!(%{
          "decision" => decision,
          "signature" => Base.url_encode64(signature, padding: false)
        })

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  def encode(_, _), do: invalid()

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@max_bytes do
    with {:ok, package} <- Frame.decode_request(bytes),
         true <- exact?(package, ~w(decision signature)),
         decision = package["decision"],
         :ok <- shape(decision),
         {:ok, signature} <- signature(package["signature"]) do
      document = JSON.encode!([@record, values(decision), package["signature"]])

      {:ok,
       %{
         decision: decision,
         signature: signature,
         document: document,
         decision_digest: Artifact.digest(document),
         package_bytes: bytes,
         package_digest: Artifact.digest(bytes)
       }}
    else
      _ -> invalid()
    end
  end

  def decode(_), do: invalid()

  @doc "Repeat exact current scope, issuer policy and trusted clock checks; no Store transition."
  def verify(bytes, expected, issuers, clock)
      when is_map(issuers) and not is_struct(issuers) and map_size(issuers) <= 8 do
    with {:ok, parsed} <- decode(bytes),
         :ok <- scope(parsed.decision, expected),
         :ok <- time(parsed.decision, clock),
         {:ok, policy} <- issuer(parsed.decision, issuers),
         {:ok, payload} <- signing_payload(parsed.decision),
         true <-
           :crypto.verify(:eddsa, :none, payload, parsed.signature, [policy.public_key, :ed25519]) do
      {:ok, parsed}
    else
      false -> invalid()
      error -> error
    end
  rescue
    _ -> invalid()
  end

  def verify(_, _, _, _), do: invalid()

  defp shape(decision) do
    if exact?(decision, @fields) and decision["format"] == @format and
         Enum.all?(@digests, &Codec.digest?(decision[&1])) and
         decision["source_owner_id"] != decision["destination_owner_id"] and
         integer?(decision["source_epoch"], 1, @max_i64 - 1) and
         integer?(decision["retirement_revision"], 1, @max_i64) and
         integer?(decision["domain_count"], 0, 64) and
         Id.valid?(decision["challenge_id"]) and Id.valid?(decision["issuer_id"]) and
         Id.valid?(decision["procedure_ref"]) and
         integer?(decision["issuer_generation"], 1, @max_i64) and
         decision["method"] in @methods and counter?(decision) and
         integer?(decision["issued_at_utc_ms"], 0, @max_i64) and
         integer?(decision["expires_at_utc_ms"], 1, @max_i64) and
         decision["expires_at_utc_ms"] > decision["issued_at_utc_ms"] and
         decision["expires_at_utc_ms"] - decision["issued_at_utc_ms"] <= @max_window_ms,
       do: :ok,
       else: invalid()
  end

  defp counter?(%{"counter_state" => "no_radio_state", "counter_state_digest" => nil}), do: true

  defp counter?(%{"counter_state" => "verified_continuity", "counter_state_digest" => digest}),
    do: Codec.digest?(digest)

  defp counter?(_), do: false

  defp scope(decision, expected) do
    if exact?(expected, @scope_fields) and Map.take(decision, @scope_fields) == expected,
      do: :ok,
      else: {:error, :isolation_scope_changed}
  end

  defp issuer(decision, issuers) do
    case issuers[decision["issuer_id"]] do
      policy when is_map(policy) and not is_struct(policy) ->
        if exact?(policy, @policy_keys) and is_binary(policy.public_key) and
             byte_size(policy.public_key) == 32 and
             policy.generation == decision["issuer_generation"] and
             policy.method == decision["method"] and
             policy.procedure_ref == decision["procedure_ref"] and
             policy.policy_digest == decision["isolation_policy_digest"] and
             policy.counter_state == decision["counter_state"],
           do: {:ok, policy},
           else: {:error, :isolation_trust_unavailable}

      _ ->
        {:error, :isolation_trust_unavailable}
    end
  end

  defp time(decision, %{confidence: :trusted, now_utc_ms: now} = clock)
       when map_size(clock) == 2 do
    if integer?(now, 0, @max_i64) and now >= decision["issued_at_utc_ms"] and
         now < decision["expires_at_utc_ms"], do: :ok, else: {:error, :isolation_decision_expired}
  end

  defp time(_, _), do: {:error, :isolation_clock_unavailable}

  defp signature(value) when is_binary(value) and byte_size(value) == 86 do
    with {:ok, signature} <- Base.url_decode64(value, padding: false),
         true <-
           byte_size(signature) == 64 and Base.url_encode64(signature, padding: false) == value,
         do: {:ok, signature},
         else: (_ -> invalid())
  end

  defp signature(_), do: invalid()
  defp values(decision), do: Enum.map(@fields, &decision[&1])
  defp integer?(value, minimum, maximum), do: is_integer(value) and value in minimum..maximum

  defp exact?(value, keys) when is_map(value) and not is_struct(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact?(_, _), do: false
  defp invalid, do: {:error, :invalid_isolation_decision}
end
