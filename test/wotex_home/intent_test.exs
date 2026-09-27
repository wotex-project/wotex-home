defmodule WotexHome.IntentTest do
  use ExUnit.Case, async: true

  alias WotexHome.Intent.{Grammar, Resolve}
  alias WotexHome.Semantics.Thing

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  test "exact English power phrase creates an ephemeral candidate" do
    assert {:ok, %Grammar{intent: :light_power_on, target_phrase: "desk light"} = candidate} =
             Grammar.classify(" Please turn ON the Desk Light ")

    assert Grammar.valid?(candidate)
    assert {:ok, %Grammar{intent: :light_power_off}} = Grammar.classify("switch off desk light")
    assert {:ok, %Grammar{intent: :light_power_on, target_phrase: "desk light"}} =
             Grammar.classify("could you turn on the desk light")

    assert {:ok, %Grammar{intent: :light_power_off, target_phrase: "desk light"}} =
             Grammar.classify("can you switch off desk light")
    refute Grammar.valid?(%{candidate | target_phrase: "desk light "})
    refute Grammar.valid?(%{candidate | source: :model})
  end

  test "ambiguous, unsupported and unsafe phrases abstain" do
    assert {:abstain, :target_ambiguous} = Grammar.classify("turn off it")
    assert {:abstain, :target_ambiguous} = Grammar.classify("turn off desk and hall lights")
    assert {:abstain, :unsupported_phrase} = Grammar.classify("don't turn off desk light")
    assert {:abstain, :unsupported_phrase} = Grammar.classify("turn off desk light; unlock door")
    assert {:abstain, :target_ambiguous} = Grammar.classify("turn off desk light please")
    assert {:abstain, :unsupported_locale} = Grammar.classify("turn off desk light", "sv")
    assert {:abstain, :invalid_text} = Grammar.classify("turn on\ndesk light")
    assert {:abstain, :invalid_text} = Grammar.classify(String.duplicate("x", 257))
  end

  test "exact, unique, granted writable target yields only a typed preview" do
    candidate = candidate("turn on desk light")
    thing = light()

    assert {:ok, preview} =
             Resolve.preview(
               candidate,
               %{"Desk Light" => ["light:desk"]},
               %{"light:desk" => thing},
               MapSet.new(["light:desk"]),
               "request:1",
               3,
               4
             )

    assert preview.target_id == "light:desk"
    assert preview.capability_key == "power"
    assert preview.value == %{"type" => "boolean", "value" => true}
    assert preview.authority_epoch == 3
    assert preview.expected_revision == 4
  end

  test "unknown, ambiguous and ungranted aliases never select a target" do
    candidate = candidate("turn off desk light")
    thing = light()
    base = {candidate, %{"desk light" => ["light:desk"]}, %{"light:desk" => thing}}

    assert {:error, :target_unknown} =
             preview(put_elem(base, 1, %{"other" => ["light:desk"]}))

    assert {:error, :target_ambiguous} =
             preview(put_elem(base, 1, %{"desk light" => ["light:desk", "light:other"]}))

    assert {:error, :target_unavailable} = preview(base, MapSet.new())
    assert {:error, :target_unavailable} = preview(put_elem(base, 2, %{}))
  end

  test "forged capabilities, read-only targets and forged candidates fail closed" do
    candidate = candidate("turn on desk light")
    thing = light()
    base = {candidate, %{"desk light" => ["light:desk"]}, %{"light:desk" => thing}}

    assert {:error, :target_unavailable} =
             preview(put_elem(base, 2, %{"light:desk" => light(["read"])}))

    forged = put_in(thing.capabilities["power"].operations, ["write", "raw"])

    assert {:error, :invalid_thing} =
             preview(put_elem(base, 2, %{"light:desk" => forged}))

    assert {:error, :target_unavailable} =
             preview(put_elem(base, 0, %{candidate | target_phrase: "desk light "}))
  end

  test "authored corpus labels agree with the shipped exact grammar and split aliases" do
    corpus =
      "priv/intent/corpus-v2.json"
      |> File.read!()
      |> :json.decode()

    for {_split, data} <- corpus["splits"] do
      targets = MapSet.new(data["targets"])

      for {label, intent} <- [
            {"light_power_on", :light_power_on},
            {"light_power_off", :light_power_off}
          ],
          template <- data[label],
          target <- data["targets"] do
        text = String.replace(template, "{target}", target)
        assert {:ok, %Grammar{intent: ^intent, target_phrase: ^target}} = Grammar.classify(text)
      end

      for template <- data["other"],
          text <- render_negative(template, data["targets"]) do
        case Grammar.classify(text) do
          {:abstain, _reason} -> :ok
          {:ok, candidate} -> refute MapSet.member?(targets, candidate.target_phrase)
        end
      end
    end
  end

  defp render_negative(template, targets) do
    if String.contains?(template, "{target}") do
      Enum.map(targets, &String.replace(template, "{target}", &1))
    else
      [template]
    end
  end

  defp candidate(text) do
    assert {:ok, candidate} = Grammar.classify(text)
    candidate
  end

  defp light(operations \\ ["read", "write"]) do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [%{@power | "operations" => operations}]
             })

    thing
  end

  defp preview({candidate, aliases, things}, grants \\ MapSet.new(["light:desk"])) do
    Resolve.preview(candidate, aliases, things, grants, "request:1", 3, 4)
  end
end
