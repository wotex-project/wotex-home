defmodule WotexHome.Mutation do
  @moduledoc """
  Closed, typed mutation envelope shared by future input surfaces.

  Construction only checks envelope shape. It never authenticates, authorizes,
  admits, persists or dispatches a command. The final command gate must do all
  of those checks against current durable state.

  `new/1` retains the caller's operation ID, authority epoch and expected
  revision in a typed value. Reuse that ID when reconciling an uncertain
  response. A stale revision or changed grant is resolved by the Store, not
  by this constructor.
  """

  alias WotexHome.Id
  alias WotexHome.Semantics.Value

  @keys ~w(api_version operation_id authority_epoch expected_revision target_id capability_key value)
  @max_i64 9_223_372_036_854_775_807
  @enforce_keys [
    :operation_id,
    :authority_epoch,
    :expected_revision,
    :target_id,
    :capability_key,
    :value
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          operation_id: String.t(),
          authority_epoch: non_neg_integer(),
          expected_revision: non_neg_integer(),
          target_id: String.t(),
          capability_key: String.t(),
          value: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(input) when is_map(input) do
    with :ok <- closed(input),
         :ok <- version(input),
         :ok <- ids(input),
         :ok <- revisions(input),
         :ok <- value(input) do
      {:ok,
       %__MODULE__{
         operation_id: input["operation_id"],
         authority_epoch: input["authority_epoch"],
         expected_revision: input["expected_revision"],
         target_id: input["target_id"],
         capability_key: input["capability_key"],
         value: input["value"]
       }}
    end
  end

  def new(_input), do: {:error, :invalid_envelope}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = mutation) do
    input = %{
      "api_version" => 1,
      "operation_id" => mutation.operation_id,
      "authority_epoch" => mutation.authority_epoch,
      "expected_revision" => mutation.expected_revision,
      "target_id" => mutation.target_id,
      "capability_key" => mutation.capability_key,
      "value" => mutation.value
    }

    new(input) == {:ok, mutation}
  end

  def valid?(_mutation), do: false

  defp closed(input) do
    if Map.keys(input) |> Enum.sort() == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp version(%{"api_version" => 1}), do: :ok
  defp version(_input), do: {:error, :unsupported_api_version}

  defp ids(input) do
    if Enum.all?(~w(operation_id target_id capability_key), &(input[&1] |> Id.valid?())),
      do: :ok,
      else: {:error, :invalid_id}
  end

  defp revisions(input) do
    if Enum.all?(~w(authority_epoch expected_revision), fn key ->
         is_integer(input[key]) and input[key] >= 0 and input[key] <= @max_i64
       end),
       do: :ok,
       else: {:error, :invalid_revision}
  end

  defp value(%{"value" => value}) when is_map(value) do
    case Value.new(value) do
      {:ok, _value} -> :ok
      {:error, _reason} -> {:error, :invalid_value}
    end
  end

  defp value(_input), do: {:error, :invalid_value}
end
