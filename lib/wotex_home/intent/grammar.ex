defmodule WotexHome.Intent.Grammar do
  @moduledoc """
  Exact English Light-power grammar baseline for classifier comparison.

  It returns an ephemeral candidate with an untrusted target phrase. No score,
  device identity, permission or command outcome is inferred from a match.
  DistilBERT remains a separate required demonstration input profile.

  `classify/2` accepts only the anchored English Light power subset and
  abstains on unsupported or compound text. Use `valid?/1` to recheck a
  candidate at a boundary. Exact aliases and current grants are handled by
  `WotexHome.Intent.Resolve`; a grammar match cannot choose a device.
  """

  @max_bytes 256
  @pattern ~r/\A(?:(?:please|could you|can you) )?(?:turn|switch) (on|off) (?:the )?([a-z0-9][a-z0-9 ._-]{0,79})\z/
  @pronouns ~w(it them this that everything all)

  @enforce_keys [:intent, :target_phrase, :source, :locale]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec classify(binary(), String.t()) :: {:ok, t()} | {:abstain, atom()}
  def classify(text, locale \\ "en")

  def classify(text, "en") when is_binary(text) and byte_size(text) <= @max_bytes do
    if String.valid?(text) and not String.contains?(text, ["\n", "\r", "\t", <<0>>]) do
      normalized =
        text
        |> String.trim()
        |> String.downcase()
        |> String.replace(~r/ +/, " ")

      case Regex.run(@pattern, normalized) do
        [^normalized, direction, target_phrase] ->
          target_phrase = String.trim(target_phrase)

          if target_phrase in @pronouns or ambiguous_target_phrase?(target_phrase) do
            {:abstain, :target_ambiguous}
          else
            intent = if direction == "on", do: :light_power_on, else: :light_power_off

            {:ok,
             %__MODULE__{
               intent: intent,
               target_phrase: target_phrase,
               source: :exact_grammar,
               locale: "en"
             }}
          end

        _ ->
          {:abstain, :unsupported_phrase}
      end
    else
      {:abstain, :invalid_text}
    end
  end

  def classify(_text, "en"), do: {:abstain, :invalid_text}
  def classify(_text, _locale), do: {:abstain, :unsupported_locale}

  @spec valid?(term()) :: boolean()
  def valid?(
        %__MODULE__{intent: intent, target_phrase: phrase, source: :exact_grammar, locale: "en"} =
          candidate
      )
      when intent in [:light_power_on, :light_power_off] and is_binary(phrase) do
    direction = if intent == :light_power_on, do: "on", else: "off"
    classify("turn " <> direction <> " " <> phrase) == {:ok, candidate}
  end

  def valid?(_candidate), do: false

  defp ambiguous_target_phrase?(phrase) do
    String.contains?(phrase, [" and ", " or ", " then ", " not ", ".", ","]) or
      String.ends_with?(phrase, " please")
  end
end
