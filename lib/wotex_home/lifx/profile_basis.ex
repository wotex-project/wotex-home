defmodule WotexHome.Lifx.ProfileBasis do
  @moduledoc """
  Closed mapping check for one reviewed LIFX Light power declaration.

  The result binds identity, exact registry metadata, declaration and runtime
  bytes. It remains pending physical qualification and grants no command path.
  """

  alias WotexHome.Discovery.{EnrollmentReview, Interview}
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.{Packet, PowerSession, ProductRegistry, ReadSession, Report}
  alias WotexHome.Semantics.{Capability, Thing}

  @profile "lifx-direct-power-v1"
  @runtime [Packet, PowerSession, ReadSession, Report, ProductRegistry, __MODULE__]

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
             power.operations == ["read", "write"] and power.value_kind == "boolean" and
             power.risk_class == "ordinary" do
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

  @doc "Digest of the compiled modules covered by the direct-power mapping basis."
  @spec runtime_digest() :: {:ok, String.t()} | {:error, :runtime_artifact_unavailable}
  def runtime_digest do
    Enum.reduce_while(@runtime, {:ok, []}, fn module, {:ok, acc} ->
      case :code.get_object_code(module) do
        {^module, bytes, _path} -> {:cont, {:ok, [{module, digest(bytes)} | acc]}}
        _ -> {:halt, {:error, :runtime_artifact_unavailable}}
      end
    end)
    |> case do
      {:ok, digests} -> {:ok, digest(Enum.reverse(digests))}
      error -> error
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
