defmodule WotexHome.Lifx.ProfileCatalogue do
  @moduledoc """
  Immutable Home-packaged LIFX enrollment profiles.

  Callers select a profile reference and a Home Thing ID. They cannot provide
  fingerprint predicates, capabilities or qualification references. This
  module constructs and validates those values from compiled data; matching a
  reported interview remains a review hint and grants no control qualification.

  The initial profile deliberately exposes only direct power for one exact
  reported product/firmware tuple. Its qualification reference is explicitly
  pending physical evidence, so enrollment cannot make the dispatch path
  executable by itself.
  """

  alias WotexHome.Discovery.{Interview, Profile}
  alias WotexHome.Id
  alias WotexHome.Semantics.Thing

  @schema "wotex-home.lifx-profile-catalogue.v1"
  @entries [
    %{
      profile: %{
        "id" => "lifx.product-27",
        "version" => "1.0.0",
        "transport" => "udp",
        "manufacturer" => "lifx.vendor.1",
        "model" => "lifx.product.27",
        "firmware_versions" => ["3.60"],
        "rank" => 10,
        "qualification_ref" => "qualification:pending:lifx:1:27:3.60"
      },
      thing: %{
        "role" => "Light",
        "capabilities" => [
          %{
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      }
    }
  ]

  @type package :: %{
          required(:profile) => Profile.t(),
          required(:thing) => Thing.t(),
          required(:catalogue_digest) => String.t()
        }

  @doc "Builds the exact packaged profile and declaration for one Home identity."
  @spec fetch(String.t(), String.t()) :: {:ok, package()} | {:error, atom()}
  def fetch(profile_ref, thing_id) do
    with true <- Id.valid?(profile_ref) and Id.valid?(thing_id),
         {:ok, entry} <- unique_entry(profile_ref),
         {:ok, profile} <- Profile.new(entry.profile),
         {:ok, thing} <- Thing.new(thing_input(entry, profile_ref, thing_id)) do
      {:ok, %{profile: profile, thing: thing, catalogue_digest: digest()}}
    else
      false -> {:error, :invalid_profile_selection}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_packaged_profile}
    end
  end

  @doc "Digest of the closed compiled catalogue, for diagnostics and review evidence."
  @spec digest() :: String.t()
  def digest do
    {@schema, @entries}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns the bounded public identity of each packaged profile."
  @spec summaries() :: [map()]
  def summaries do
    Enum.map(@entries, fn %{profile: profile} ->
      %{
        profile_ref: profile_ref(profile),
        transport: profile["transport"],
        manufacturer: profile["manufacturer"],
        model: profile["model"],
        firmware_versions: profile["firmware_versions"],
        qualification_ref: profile["qualification_ref"],
        qualification_status: :pending_physical_evidence,
        capability_keys: Enum.map(entry_capabilities(profile_ref(profile)), & &1["key"])
      }
    end)
  end

  @doc "Returns only packaged profiles whose exact fingerprint matches an interview."
  @spec matching(Interview.t()) :: [map()]
  def matching(%Interview{} = interview) do
    summaries()
    |> Enum.filter(fn summary ->
      summary.transport == interview.transport and
        summary.manufacturer == interview.manufacturer and summary.model == interview.model and
        interview.firmware in summary.firmware_versions
    end)
  end

  def matching(_), do: []

  defp unique_entry(requested_ref) do
    case Enum.filter(@entries, &(profile_ref(&1.profile) == requested_ref)) do
      [entry] -> {:ok, entry}
      [] -> {:error, :unsupported_profile}
      _ -> {:error, :invalid_packaged_profile}
    end
  end

  defp thing_input(entry, profile_ref, thing_id) do
    capabilities =
      Enum.map(entry.thing["capabilities"], fn capability ->
        Map.merge(capability, %{
          "thing_id" => thing_id,
          "role" => entry.thing["role"],
          "profile_ref" => profile_ref,
          "evidence_ref" => entry.profile["qualification_ref"]
        })
      end)

    %{
      "id" => thing_id,
      "role" => entry.thing["role"],
      "profile_ref" => profile_ref,
      "capabilities" => capabilities
    }
  end

  defp entry_capabilities(requested_ref) do
    case Enum.find(@entries, &(profile_ref(&1.profile) == requested_ref)) do
      %{thing: %{"capabilities" => capabilities}} -> capabilities
      _ -> []
    end
  end

  defp profile_ref(profile), do: profile["id"] <> ":" <> profile["version"]
end
