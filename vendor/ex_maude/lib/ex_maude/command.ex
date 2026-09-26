defmodule ExMaude.Command do
  @moduledoc false

  @doc false
  @spec normalize(String.t()) :: String.t()
  def normalize(command) when is_binary(command) do
    command = String.trim(command)

    if String.ends_with?(command, ".") do
      command
    else
      command <> " ."
    end
  end

  @doc false
  @spec port_command(String.t()) :: String.t()
  def port_command(command), do: normalize(command) <> "\n"

  @doc false
  @spec reduce(String.t(), String.t()) :: String.t()
  def reduce(module, term), do: "reduce in #{module} : #{term}"

  @doc false
  @spec rewrite(String.t(), String.t(), keyword()) :: String.t()
  def rewrite(module, term, opts) do
    case Keyword.get(opts, :max_rewrites) do
      nil -> "rewrite in #{module} : #{term}"
      count -> "rewrite [#{count}] in #{module} : #{term}"
    end
  end

  @doc false
  @spec search(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def search(module, initial, pattern, opts) do
    max_depth = Keyword.get(opts, :max_depth, 100)
    max_solutions = Keyword.get(opts, :max_solutions, 1)
    arrow = Keyword.get(opts, :arrow, "=>*")
    condition = Keyword.get(opts, :condition)

    base = "search [#{max_solutions}, #{max_depth}] in #{module} : #{initial} #{arrow} #{pattern}"

    if condition, do: "#{base} such that #{condition}", else: base
  end

  @doc false
  @spec parse(String.t(), String.t()) :: String.t()
  def parse(module, term), do: "parse in #{module} : #{term}"

  @doc false
  @spec load_file(Path.t()) :: String.t()
  def load_file(path) when is_binary(path), do: "load #{ExMaude.Syntax.encode_string(path)}"
end
