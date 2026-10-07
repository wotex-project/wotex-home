defmodule WotexHome.Profiles.Bindings do
  @moduledoc """
  Host-owned portable profile bindings and their unqualified declarations.

  The first binding selects existing LIFX direct power. Exact registry support
  is checked locally; declared buttons or relays cannot become ordinary lights.
  New semantics require a host release. Registry metadata is never qualification.
  """

  alias WotexHome.Discovery.Profile
  alias WotexHome.Lifx.{ProductRegistry, ProfileCatalogue}
  alias WotexHome.Semantics.Thing

  @binding "lifx-direct-power-v1"
  @projection "wotex-home.profile-projection.v1"
  @compiler "wotex-home.profile-binding-compiler.v1"
  @capability %{
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  def resolve(data, raw_digest, %ProductRegistry{} = registry) do
    fingerprint = data["fingerprint"]
    reference = data["id"] <> ":" <> data["version"]
    qualification = "qualification:pending:profile:" <> raw_digest

    with true <- registry.digest == ProductRegistry.pinned_digest(),
         [%{"kind" => "registry", "sha256" => dependency}] <- data["dependencies"],
         true <- dependency == registry.digest,
         true <- data["binding"] == @binding and WotexHome.Id.valid?(reference),
         false <- Enum.any?(ProfileCatalogue.summaries(), &(&1.profile_ref == reference)),
         "udp" <- fingerprint["transport"],
         {:ok, vendor} <- number(fingerprint["manufacturer"], "lifx.vendor.", 4_294_967_295),
         {:ok, product} <- number(fingerprint["model"], "lifx.product.", 4_294_967_295),
         versions when is_list(versions) and length(versions) in 1..32 <-
           fingerprint["firmware_versions"],
         true <- Enum.uniq(versions) == versions,
         true <- Enum.all?(versions, &supported?(registry, vendor, product, &1)),
         {:ok, profile} <-
           Profile.new(
             Map.merge(fingerprint, %{
               "id" => data["id"],
               "version" => data["version"],
               "rank" => 0,
               "qualification_ref" => qualification
             })
           ) do
      projection = projection_document(data, vendor, product, versions, registry.digest)

      {:ok, %{profile: profile, profile_ref: reference, projection_document: projection}}
    else
      _ -> {:error, :unsupported_profile_binding}
    end
  end

  def resolve(_, _, _), do: {:error, :unsupported_profile_binding}

  @doc "Historical v1 projection encoding, without treating dependencies as installed."
  def historical_projection(data) when is_map(data) and not is_struct(data) do
    with {:ok, ^data} <- WotexHome.Profiles.Codec.decode(JSON.encode!(data)),
         "udp" <- data["fingerprint"]["transport"],
         {:ok, vendor} <-
           number(data["fingerprint"]["manufacturer"], "lifx.vendor.", 4_294_967_295),
         {:ok, product} <- number(data["fingerprint"]["model"], "lifx.product.", 4_294_967_295),
         versions when is_list(versions) and length(versions) in 1..32 <-
           data["fingerprint"]["firmware_versions"],
         true <- Enum.uniq(versions) == versions and Enum.all?(versions, &valid_firmware?/1) do
      {:ok,
       projection_document(data, vendor, product, versions, hd(data["dependencies"])["sha256"])}
    else
      _ -> {:error, :invalid_profile_projection}
    end
  end

  def historical_projection(_), do: {:error, :invalid_profile_projection}

  defp projection_document(data, vendor, product, versions, registry) do
    JSON.encode!([
      @projection,
      @compiler,
      data["id"],
      data["version"],
      ["udp", vendor, product, Enum.sort(versions)],
      @binding,
      registry,
      ["Light", "power", "boolean", "none", ["read", "write"], "ordinary", 5_000, 0],
      ["explicit_selection", "pending_physical_evidence", 0]
    ])
  end

  defp valid_firmware?(version) when is_binary(version) do
    with [major, minor] <- String.split(version, "."),
         {:ok, _} <- number(major, "", 65_535),
         {:ok, _} <- number(minor, "", 65_535),
         do: true,
         else: (_ -> false)
  end

  defp valid_firmware?(_), do: false

  def declaration(%Profile{} = profile, thing_id) do
    reference = profile.id <> ":" <> profile.version

    Thing.new(%{
      "id" => thing_id,
      "role" => "Light",
      "profile_ref" => reference,
      "capabilities" => [
        Map.merge(@capability, %{
          "thing_id" => thing_id,
          "role" => "Light",
          "profile_ref" => reference,
          "evidence_ref" => profile.qualification_ref
        })
      ]
    })
  end

  defp supported?(registry, vendor, product, version) when is_binary(version) do
    with [major, minor] <- String.split(version, "."),
         {:ok, major} <- number(major, "", 65_535),
         {:ok, minor} <- number(minor, "", 65_535),
         {:ok, %{features: features}} <-
           ProductRegistry.lookup(registry, vendor, product, major, minor) do
      features["relays"] == false and features["buttons"] == false
    else
      _ -> false
    end
  end

  defp supported?(_, _, _, _), do: false

  defp number(value, prefix, maximum) when is_binary(value) do
    if String.starts_with?(value, prefix) do
      value = String.replace_prefix(value, prefix, "")

      case Integer.parse(value) do
        {number, ""} when number >= 0 and number <= maximum ->
          if Integer.to_string(number) == value, do: {:ok, number}, else: :error

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp number(_, _, _), do: :error
end
