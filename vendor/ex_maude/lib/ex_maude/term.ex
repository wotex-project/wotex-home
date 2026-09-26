defmodule ExMaude.Term do
  @moduledoc """
  Structured representation of a Maude term.

  This module provides a rich type for representing Maude terms in Elixir,
  including their value, sort (type), and optionally the module they came from.

  ## Structure

  A term contains:

    * `:value` - The string representation of the term's value
    * `:sort` - The Maude sort (type) of the term
    * `:module` - The module the term belongs to (optional)
    * `:raw` - The raw output from Maude (for debugging)

  ## Examples

      # Parse a reduction result
      {:ok, term} = ExMaude.Term.parse("result Nat: 42")
      term.value   #=> "42"
      term.sort    #=> "Nat"

      # Create directly
      term = %ExMaude.Term{value: "true", sort: "Bool"}
  """

  @enforce_keys [:value, :sort]
  defstruct [:value, :sort, :module, :raw]

  @type t :: %__MODULE__{
          value: String.t(),
          sort: String.t(),
          module: String.t() | nil,
          raw: String.t() | nil
        }

  @doc """
  Parses Maude output into a Term struct.

  ## Examples

      iex> ExMaude.Term.parse("result Nat: 6")
      {:ok, %ExMaude.Term{value: "6", sort: "Nat", module: nil, raw: "result Nat: 6"}}

      iex> ExMaude.Term.parse("result Bool: true")
      {:ok, %ExMaude.Term{value: "true", sort: "Bool", module: nil, raw: "result Bool: true"}}
  """
  @spec parse(String.t(), String.t() | nil) :: {:ok, t()} | {:error, :no_result}
  def parse(output, module \\ nil) do
    case ExMaude.Parser.parse_result(output) do
      {:ok, value, sort} ->
        {:ok,
         %__MODULE__{
           value: value,
           sort: sort,
           module: module,
           raw: output
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Creates a new Term struct.

  ## Examples

      iex> term = ExMaude.Term.new("42", "Nat")
      ...> {term.value, term.sort}
      {"42", "Nat"}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(value, sort, opts \\ []) do
    %__MODULE__{
      value: value,
      sort: sort,
      module: Keyword.get(opts, :module),
      raw: Keyword.get(opts, :raw)
    }
  end

  @doc """
  Checks if the term has a specific sort.

  ## Examples

      iex> term = ExMaude.Term.new("42", "Nat")
      ...> ExMaude.Term.sort?(term, "Nat")
      true

      iex> term = ExMaude.Term.new("42", "Nat")
      ...> ExMaude.Term.sort?(term, "Bool")
      false
  """
  @spec sort?(t(), String.t()) :: boolean()
  def sort?(%__MODULE__{sort: sort}, expected_sort) do
    sort == expected_sort
  end

  @doc """
  Attempts to convert the term value to an Elixir integer.

  Only works for terms with numeric sorts (Nat, Int, NzNat, etc.).

  ## Examples

      iex> term = ExMaude.Term.new("42", "Nat")
      ...> ExMaude.Term.to_integer(term)
      {:ok, 42}

      iex> term = ExMaude.Term.new("true", "Bool")
      ...> ExMaude.Term.to_integer(term)
      {:error, :not_numeric}
  """
  @spec to_integer(t()) :: {:ok, integer()} | {:error, :not_numeric}
  def to_integer(%__MODULE__{value: value, sort: sort})
      when sort in ["Nat", "Int", "NzNat", "NzInt"] do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :not_numeric}
    end
  end

  def to_integer(_), do: {:error, :not_numeric}

  @doc """
  Attempts to convert the term value to an Elixir boolean.

  Only works for terms with Bool sort.

  ## Examples

      iex> term = ExMaude.Term.new("true", "Bool")
      ...> ExMaude.Term.to_boolean(term)
      {:ok, true}
  """
  @spec to_boolean(t()) :: {:ok, boolean()} | {:error, :not_boolean}
  def to_boolean(%__MODULE__{value: "true", sort: "Bool"}), do: {:ok, true}
  def to_boolean(%__MODULE__{value: "false", sort: "Bool"}), do: {:ok, false}
  def to_boolean(_), do: {:error, :not_boolean}

  @doc """
  Attempts to convert the term value to an Elixir float.

  Only works for terms with Float sort.

  ## Examples

      iex> term = ExMaude.Term.new("3.14", "Float")
      ...> ExMaude.Term.to_float(term)
      {:ok, 3.14}
  """
  @spec to_float(t()) :: {:ok, float()} | {:error, :not_float}
  def to_float(%__MODULE__{value: value, sort: "Float"}) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> {:error, :not_float}
    end
  end

  def to_float(_), do: {:error, :not_float}

  @doc """
  Returns the term value as a string (always succeeds).
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value

  defimpl String.Chars do
    def to_string(%ExMaude.Term{value: value, sort: sort}) do
      "#{value} : #{sort}"
    end
  end

  defimpl Inspect do
    @spec inspect(ExMaude.Term.t(), Inspect.Opts.t()) :: String.t()
    def inspect(%ExMaude.Term{value: value, sort: sort, module: module}, _) do
      if module do
        "#ExMaude.Term<#{value} : #{sort} in #{module}>"
      else
        "#ExMaude.Term<#{value} : #{sort}>"
      end
    end
  end
end
