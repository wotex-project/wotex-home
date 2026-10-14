defmodule WotexHome.NativeSetup.TargetBasis do
  @moduledoc """
  Checks a native access proposal against an exact Store lifecycle snapshot.

  `validate/2` compares the closed grant input with an active reviewed usable
  target, selected profile/resource revisions and the supported ordinary Boolean
  Light-power declaration. It rejects changed or unsupported correspondence
  instead of widening the native principal's scope.

  The function is pure. Store must establish the snapshot, native verifier
  custody and revision basis before committing a grant; validation alone grants
  no control or physical qualification.
  """

  alias WotexHome.NativeSetup.TargetCodec
  alias WotexHome.Semantics.{Capability, Thing}

  def validate(input, snapshot) when is_map(snapshot) do
    with {:ok, _} <- TargetCodec.encode("grant", input),
         true <-
           Map.get(snapshot, :status) == "active" and
             Map.get(snapshot, :selection_state) == "selected" and
             Map.get(snapshot, :identity_status) == :reviewed and
             Map.get(snapshot, :current_use) == :usable,
         {:ok,
          %Thing{
            id: target,
            role: "Light",
            capabilities: %{"power" => %Capability{} = power} = capabilities
          }} <-
           Thing.new(Map.get(snapshot, :declaration)),
         true <-
           target == Map.get(snapshot, :target_id) and map_size(capabilities) == 1 and
             power.risk_class == "ordinary" and
             Capability.supports?(power, "write"),
         :ok <- correspondence(input, snapshot),
         do: :ok,
         else: (
           {:error, :invalid_native_target_record} = error -> error
           {:error, :native_target_changed} = error -> error
           _ -> {:error, :native_target_unavailable}
         )
  end

  def validate(_, _), do: {:error, :native_target_unavailable}

  defp correspondence(input, snapshot) do
    fields = [
      {"authority_epoch", :authority_epoch},
      {"expected_revision", :store_revision},
      {"target_id", :target_id},
      {"resource_revision", :resource_revision},
      {"binding_revision", :binding_revision},
      {"selection_generation", :selection_generation},
      {"artifact_digest", :artifact_digest}
    ]

    if Enum.all?(fields, fn {key, stored} -> input[key] == Map.get(snapshot, stored) end),
      do: :ok,
      else: {:error, :native_target_changed}
  end
end
