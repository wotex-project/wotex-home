defmodule ExMaude.Syntax do
  @moduledoc false

  @doc false
  @spec encode_string(String.t()) :: String.t()
  def encode_string(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  @doc false
  @spec quoted_strings(String.t()) :: [String.t()]
  def quoted_strings(input) when is_binary(input) do
    ~r/"((?:\\.|[^"\\])*)"/s
    |> Regex.scan(input, capture: :all_but_first)
    |> Enum.map(fn [content] -> decode_string_content(content) end)
  end

  @doc false
  @spec captured_strings(Regex.t(), String.t()) :: [String.t()]
  def captured_strings(regex, input) do
    regex
    |> Regex.scan(input, capture: :all_but_first)
    |> Enum.map(fn [content] -> decode_string_content(content) end)
  end

  defp decode_string_content(content) do
    content
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end
end
