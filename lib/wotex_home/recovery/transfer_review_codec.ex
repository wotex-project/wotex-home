defmodule WotexHome.Recovery.TransferReviewCodec do
  @moduledoc "Canonical inert destination review and signed isolation scope; no activation or custody."
  alias WotexHome.{Id, Profiles.Artifact, Profiles.Codec}
  @format "wotex-home.controller-transfer-review.v1"
  @maximum 9_223_372_036_854_775_807
  @fields ~w(deployment_id source_owner_id destination_owner_id source_epoch retirement_revision source_maintenance_revision source_rule_generation archive_digest snapshot_digest runtime_digest owner_custody_digest challenge_id principal_id credential_hash permissions_document domain_digest domain_count counter_state counter_state_digest issued_at_utc_ms expires_at_utc_ms)
  @digests ~w(deployment_id source_owner_id destination_owner_id archive_digest snapshot_digest runtime_digest owner_custody_digest credential_hash domain_digest)
  @scope ~w(deployment_id source_owner_id destination_owner_id source_epoch retirement_revision archive_digest runtime_digest challenge_id domain_digest domain_count counter_state counter_state_digest)
  @permissions "[\"read\",\"host:maintain\",\"profile:manage\",\"enroll:review\"]"

  def encode(value) when is_map(value) and not is_struct(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(@fields) and shape?(value) do
      document = JSON.encode!([@format, Enum.map(@fields, &value[&1])])
      if byte_size(document) <= 4_096, do: {:ok, document}, else: invalid()
    else
      invalid()
    end
  end

  def encode(_), do: invalid()

  def decode(document) when is_binary(document) and byte_size(document) in 1..4_096 do
    with {:ok, [@format, values]} <- JSON.decode(document),
         true <- is_list(values) and length(values) == length(@fields),
         value = Map.new(Enum.zip(@fields, values)),
         {:ok, ^document} <- encode(value) do
      {:ok, value}
    else
      _ -> invalid()
    end
  end

  def decode(_), do: invalid()

  @doc "Only structurally complete counter decisions yield the exact isolation-verifier scope."
  def isolation_scope(value) do
    with {:ok, document} <- encode(value) do
      if value["counter_state"] == "unknown" do
        {:error, :counter_continuity_unavailable}
      else
        {:ok, Map.put(Map.take(value, @scope), "review_digest", Artifact.digest(document))}
      end
    end
  end

  defp shape?(value) do
    Enum.all?(@digests, &Codec.digest?(value[&1])) and
      value["source_owner_id"] != value["destination_owner_id"] and
      integer?(value["source_epoch"], 1, @maximum - 1) and
      integer?(value["retirement_revision"], 2, @maximum - 3) and
      integer?(value["source_maintenance_revision"], 1, @maximum) and
      value["source_maintenance_revision"] < value["retirement_revision"] and
      integer?(value["source_rule_generation"], 1, @maximum - 1) and
      Id.valid?(value["challenge_id"]) and Id.valid?(value["principal_id"]) and
      value["permissions_document"] == @permissions and
      integer?(value["domain_count"], 0, 64) and counter?(value) and
      integer?(value["issued_at_utc_ms"], 0, @maximum) and
      integer?(value["expires_at_utc_ms"], 1, @maximum) and
      value["expires_at_utc_ms"] > value["issued_at_utc_ms"] and
      value["expires_at_utc_ms"] - value["issued_at_utc_ms"] <= 600_000
  end

  defp counter?(%{"counter_state" => state, "counter_state_digest" => nil})
       when state in ["unknown", "no_radio_state"], do: true

  defp counter?(%{"counter_state" => "verified_continuity", "counter_state_digest" => digest}),
    do: Codec.digest?(digest)

  defp counter?(_), do: false
  defp integer?(value, minimum, maximum), do: is_integer(value) and value in minimum..maximum
  defp invalid, do: {:error, :invalid_transfer_review}
end
