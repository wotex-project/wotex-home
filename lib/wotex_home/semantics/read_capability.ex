defmodule WotexHome.Semantics.ReadCapability do
  @moduledoc """
  Format-qualified retained external read metadata for one EnvironmentalSensor channel.

  Construction checks representation, not current trust, enrollment, report
  acceptance or physical evidence. It provides no value or write admission path.
  """

  alias WotexHome.Profiles.{EnvelopeCodec, ReadDeclarationCodec}

  @enforce_keys ~w(thing_id role key value_kind unit operations risk_class profile_ref evidence_ref freshness_ms constraints record)a
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @doc "Constructs one read capability from its exact retained declaration record."
  @spec new(term()) :: {:ok, t()} | {:error, atom()}
  def new(record) do
    with {:ok, %{"data" => data}} <- ReadDeclarationCodec.decode(record) do
      {:ok,
       %__MODULE__{
         thing_id: data["thing_id"],
         role: "EnvironmentalSensor",
         key: data["capability_key"],
         value_kind: data["value_kind"],
         unit: data["unit"],
         operations: ["read"],
         risk_class: data["risk_class"],
         profile_ref: "external:" <> record["artifact_digest"],
         evidence_ref: data["evidence_ref"],
         freshness_ms: data["freshness_ms"],
         constraints: data["constraints"],
         record: record
       }}
    end
  end

  @doc "Checks the format-qualified external profile reference without resolving trust."
  @spec profile_ref?(term()) :: boolean()
  def profile_ref?("external:" <> digest), do: EnvelopeCodec.digest?(digest)
  def profile_ref?(_), do: false

  @doc "Reports only read support after reconstructing every native field."
  @spec supports?(term(), term()) :: boolean()
  def supports?(%__MODULE__{} = value, "read"), do: new(value.record) == {:ok, value}
  def supports?(_, _), do: false
end
