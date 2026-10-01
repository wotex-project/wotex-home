defmodule WotexHome.Lifx.ProfileBasis do
  @moduledoc """
  Closed mapping check for one reviewed LIFX Light power declaration.

  The result binds identity, exact registry metadata, declaration and runtime
  bytes. It remains pending physical qualification and grants no command path.

  `assess/6` combines one enrollment review with the pinned registry and
  packaged runtime closure. Keep its digest with qualification receipts so a
  change in protocol mapping or executable bytes reopens the decision.
  """

  alias WotexHome.Discovery.{EnrollmentReview, Interview}
  alias WotexHome.Durable.Registry
  alias WotexHome.Id

  alias WotexHome.Lifx.{DirectPowerSafety, Packet, ProductRegistry}

  alias WotexHome.Semantics.{Capability, Thing}

  @profile "lifx-direct-power-v1"
  @runtime_applications [:wotex_home, :wotex_udp]
  @runtime_domain "wotex-home.lifx-power-runtime.v2"
  @basis_keys ~w(profile thing_id profile_ref qualification_ref identity_digest product firmware registry_digest declaration_digest runtime_digest scope status basis_digest)a
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @spec assess(list(), Interview.t(), list(), Thing.t(), map(), ProductRegistry.t()) ::
          {:ok, map()} | {:error, atom()}
  def assess(
        candidates,
        %Interview{} = interview,
        profiles,
        %Thing{} = thing,
        selection,
        %ProductRegistry{} = registry
      ) do
    with {:ok, review} <-
           EnrollmentReview.new(candidates, interview, profiles, thing, selection),
         :ok <- lifx_identity(interview, review),
         :ok <- power_declaration(thing, review),
         {:ok, vendor_id} <- decimal_suffix(interview.manufacturer, "lifx.vendor."),
         {:ok, product_id} <- decimal_suffix(interview.model, "lifx.product."),
         {:ok, {major, minor}} <- firmware(interview.firmware),
         {:ok, product} <-
           ProductRegistry.lookup(registry, vendor_id, product_id, major, minor),
         true <- product.vendor_name == "LIFX",
         {:ok, document} <- Registry.encode_thing(thing),
         {:ok, runtime_digest} <- runtime_digest() do
      basis = %{
        profile: @profile,
        thing_id: thing.id,
        profile_ref: thing.profile_ref,
        qualification_ref: review.qualification_ref,
        identity_digest: review.identity_digest,
        product: {vendor_id, product_id},
        firmware: {major, minor},
        registry_digest: registry.digest,
        declaration_digest: digest(document),
        runtime_digest: runtime_digest,
        scope: :profile_mapping_only,
        status: :pending_physical_qualification
      }

      {:ok, Map.put(basis, :basis_digest, digest(basis))}
    else
      false -> {:error, :unsupported_lifx_profile}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unsupported_lifx_profile}
    end
  end

  def assess(_candidates, _interview, _profiles, _thing, _selection, _registry),
    do: {:error, :unsupported_lifx_profile}

  @doc "Recheck the closed digest-bearing mapping basis before a review decision binds it."
  @spec valid?(term()) :: boolean()
  def valid?(basis) when is_map(basis) do
    Enum.sort(Map.keys(basis)) == Enum.sort(@basis_keys) and
      basis.profile == @profile and basis.scope == :profile_mapping_only and
      basis.status == :pending_physical_qualification and
      Enum.all?([basis.thing_id, basis.profile_ref, basis.qualification_ref], &Id.valid?/1) and
      Enum.all?(
        [
          basis.identity_digest,
          basis.registry_digest,
          basis.declaration_digest,
          basis.runtime_digest,
          basis.basis_digest
        ],
        &(is_binary(&1) and &1 =~ @hex64)
      ) and basis.registry_digest == ProductRegistry.pinned_digest() and
      valid_pair?(basis.product, 4_294_967_295) and
      valid_pair?(basis.firmware, 65_535) and
      digest(Map.delete(basis, :basis_digest)) == basis.basis_digest
  end

  def valid?(_), do: false

  defp valid_pair?({a, b}, ceiling),
    do: is_integer(a) and is_integer(b) and a in 0..ceiling and b in 0..ceiling

  defp valid_pair?(_, _), do: false

  defp lifx_identity(
         %Interview{transport: "udp", stable_id: "lifx:" <> serial} = interview,
         review
       ) do
    with {:ok, _target} <- Packet.target_from_hex(serial),
         true <- review.stable_id == interview.stable_id,
         true <- review.method == "legacy_tofu" do
      :ok
    else
      _ -> {:error, :unsupported_lifx_identity}
    end
  end

  defp lifx_identity(_interview, _review), do: {:error, :unsupported_lifx_identity}

  defp power_declaration(%Thing{role: "Light", capabilities: capabilities} = thing, review)
       when map_size(capabilities) == 1 do
    case Map.fetch(capabilities, "power") do
      {:ok, %Capability{} = power} ->
        if thing.id == review.thing_id and thing.profile_ref == review.profile_ref and
             power.evidence_ref == review.qualification_ref and
             DirectPowerSafety.decision(thing) == :allow do
          :ok
        else
          {:error, :unsupported_lifx_declaration}
        end

      _ ->
        {:error, :unsupported_lifx_declaration}
    end
  end

  defp power_declaration(_thing, _review), do: {:error, :unsupported_lifx_declaration}

  defp decimal_suffix(value, prefix) do
    case value do
      <<^prefix::binary, suffix::binary>> ->
        case Integer.parse(suffix) do
          {number, ""} when number >= 0 and number <= 4_294_967_295 -> {:ok, number}
          _ -> {:error, :unsupported_lifx_identity}
        end

      _ ->
        {:error, :unsupported_lifx_identity}
    end
  end

  defp firmware(value) do
    case String.split(value, ".") do
      [major, minor] ->
        with {major, ""} <- Integer.parse(major),
             {minor, ""} <- Integer.parse(minor),
             true <- major in 0..65_535 and minor in 0..65_535 do
          {:ok, {major, minor}}
        else
          _ -> {:error, :unsupported_lifx_firmware}
        end

      _ ->
        {:error, :unsupported_lifx_firmware}
    end
  end

  @doc "Digest of the complete packaged Home/UDP compiled-code manifest."
  @spec runtime_digest() :: {:ok, String.t()} | {:error, :runtime_artifact_unavailable}
  def runtime_digest,
    do: WotexHome.RuntimeArtifacts.digest(@runtime_applications, @runtime_domain)

  @doc "The exact BEAM inventory bound by runtime_digest/0; not an OS or native-library claim."
  @spec runtime_manifest() :: {:ok, [map()]} | {:error, :runtime_artifact_unavailable}
  def runtime_manifest, do: WotexHome.RuntimeArtifacts.manifest(@runtime_applications)

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
