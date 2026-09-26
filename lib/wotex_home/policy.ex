defmodule WotexHome.Policy do
  @moduledoc """
  Pure baseline command checks used before durable admission.

  The future authority service must obtain `Context` from its authenticated,
  current durable state and rerun these checks immediately before dispatch.
  A successful pure check is not a receipt or permission to call a driver.
  """

  alias WotexHome.{Id, Mutation}
  alias WotexHome.Semantics.{Capability, Thing, Value}

  defmodule Context do
    @moduledoc """
    Trusted inputs the future authority must derive from authenticated state.
    Caller-supplied context is not an authorization mechanism.
    """

    @enforce_keys [
      :principal_id,
      :permissions,
      :allowed_targets,
      :authority_epoch,
      :resource_revision,
      :enrollment_valid,
      :profile_valid,
      :invariants
    ]
    defstruct @enforce_keys
  end

  @spec check(Mutation.t(), Thing.t(), Context.t()) :: :ok | {:error, atom()}
  def check(%Mutation{} = mutation, %Thing{} = thing, %Context{} = context) do
    with :ok <- context(context),
         :ok <- epoch(mutation, context),
         :ok <- revision(mutation, context),
         :ok <- target(mutation, thing, context),
         {:ok, capability} <- capability(mutation, thing),
         :ok <- permission(capability, context),
         :ok <- invariants(context),
         :ok <- value(mutation, capability) do
      :ok
    end
  end

  def check(_mutation, _thing, _context), do: {:error, :invalid_context}

  defp context(context) do
    if Id.valid?(context.principal_id) and is_list(context.permissions) and
         Enum.all?(context.permissions, &(&1 in ["read", "control:ordinary", "rule:review"])) and
         match?(%MapSet{}, context.allowed_targets) and
         is_integer(context.authority_epoch) and context.authority_epoch >= 0 and
         is_integer(context.resource_revision) and context.resource_revision >= 0 and
         is_boolean(context.enrollment_valid) and is_boolean(context.profile_valid) and
         context.invariants in [:allow, :deny, :unknown],
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp epoch(mutation, context) do
    if mutation.authority_epoch == context.authority_epoch,
      do: :ok,
      else: {:error, :stale_authority_epoch}
  end

  defp revision(mutation, context) do
    if mutation.expected_revision == context.resource_revision,
      do: :ok,
      else: {:error, :stale_resource_revision}
  end

  defp target(mutation, thing, context) do
    if mutation.target_id == thing.id and MapSet.member?(context.allowed_targets, thing.id) and
         context.enrollment_valid and context.profile_valid,
       do: :ok,
       else: {:error, :target_unavailable}
  end

  defp capability(mutation, thing) do
    case Thing.capability(thing, mutation.capability_key) do
      {:ok, %Capability{} = capability} ->
        if Capability.supports?(capability, "write"),
          do: {:ok, capability},
          else: {:error, :read_only_capability}

      :error ->
        {:error, :unsupported_capability}
    end
  end

  defp permission(%Capability{risk_class: "ordinary"}, context) do
    if "control:ordinary" in context.permissions,
      do: :ok,
      else: {:error, :permission_denied}
  end

  defp permission(_capability, _context), do: {:error, :risk_not_supported}

  defp invariants(%Context{invariants: :allow}), do: :ok
  defp invariants(_context), do: {:error, :invariant_unresolved}

  defp value(mutation, capability) do
    with {:ok, value} <- Value.new(mutation.value),
         true <- Capability.accepts?(capability, value) do
      :ok
    else
      _ -> {:error, :invalid_value}
    end
  end
end
