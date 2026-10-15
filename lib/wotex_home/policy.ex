defmodule WotexHome.Policy do
  @moduledoc """
  Checks a typed command against one trusted current policy snapshot.

  `check/3` receives a `WotexHome.Mutation`, the exact enrolled
  `WotexHome.Semantics.Thing` declaration and a
  `WotexHome.Policy.Context` derived from authenticated durable state. It
  compares authority/resource revisions, target grants, capability write support,
  permissions, invariant disposition and value constraints, returning `:ok` or
  `{:error, reason}` for the first failed check. Unsupported argument shapes or
  invalid context return `{:error, :invalid_context}`.

  The function is pure and changes no state. A successful check is not a receipt
  or permission to call a driver. The owning `WotexHome.Durable.Store` operation
  must compare current state in its transaction and repeat the required guards
  before durable handoff; a caller-supplied context cannot authorize control.
  """

  alias WotexHome.{Id, Mutation, Permissions}
  alias WotexHome.Semantics.{Capability, Thing, Value}

  defmodule Context do
    @moduledoc """
    Holds the trusted current inputs for a pure Home command check.

    Construct this value inside the authenticated Store boundary using the
    current principal, permissions, target grants, authority/resource revisions,
    enrollment/profile eligibility and invariant disposition. Pass it with the
    exact mutation and Thing to `WotexHome.Policy.check/3`.

    The struct establishes no authentication or revision freshness by itself.
    Request payloads must not supply these fields as an authorization basis,
    and retaining a prior context cannot replace current transaction guards.
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

    @type t :: %__MODULE__{}
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
    if Id.valid?(context.principal_id) and Permissions.valid?(context.permissions) and
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
