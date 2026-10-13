defmodule WotexHome.Profiles.AuthoringProducer do
  @moduledoc false

  def call(module, function, arguments, refusal) do
    case apply(module, function, arguments) do
      {:ok, value} ->
        {:ok, value}

      {:error, %{code: code}} when code in [:input_limit, :numeric_limit, :report_limit] ->
        {:error, :authoring_limit}

      {:error, %{code: code}}
      when code in [
             :byte_limit_exceeded,
             :depth_limit_exceeded,
             :node_limit_exceeded,
             :collection_limit_exceeded,
             :string_limit_exceeded
           ] ->
        {:error, :authoring_limit}

      _ ->
        {:error, refusal}
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == module and error.function == function and
           error.arity == length(arguments),
         do: {:error, :profiles_producer_unavailable},
         else: {:error, refusal}
  end

  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
